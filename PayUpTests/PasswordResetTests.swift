import XCTest
import Supabase
@testable import PayUp

/// Reset links use PKCE, so the code can only be redeemed by this app on the
/// device that asked for it. These pin which links the app picks up, what it
/// does with them, and that every dead end is a message rather than a blank
/// screen — including the cold-start race between the link and restore().
@MainActor
final class PasswordResetTests: XCTestCase {
    private struct ServerError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var backend: FakeRecoveryBackend!

    override func setUp() {
        suiteName = "PasswordResetTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        backend = FakeRecoveryBackend()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil; backend = nil
    }

    /// A client that's never signed in and points nowhere, so restore() finds
    /// no session without touching the network.
    private func makeAuth() -> AuthService {
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://payup-tests.invalid")!,
            supabaseKey: "test-key",
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
        )
        return AuthService(client: client, recovery: backend, defaults: defaults)
    }

    private let resetURL = URL(string: "payup://reset-password?code=a1b2c3")!

    // MARK: - Which links are recognised

    func testRedirectURLIsTheCustomScheme() {
        // Has to match the Supabase Redirect URLs allow list character for character.
        XCTAssertEqual(PasswordResetLink.redirectURL.absoluteString, "payup://reset-password")
    }

    func testCodeLinkIsRecognised() {
        XCTAssertEqual(PasswordResetLink.parse(resetURL), .code("a1b2c3"))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(PasswordResetLink.parse(URL(string: "PayUp://Reset-Password?code=xyz")!), .code("xyz"))
    }

    func testPathFormIsRecognised() {
        // Some mail clients rewrite scheme://host into scheme:///path.
        XCTAssertEqual(PasswordResetLink.parse(URL(string: "payup:///reset-password?code=xyz")!), .code("xyz"))
    }

    func testOtherLinksAreIgnored() {
        XCTAssertNil(PasswordResetLink.parse(URL(string: "https://mattrose77.github.io/PayUp/?code=abc")!),
                     "the web fallback is not ours to redeem")
        XCTAssertNil(PasswordResetLink.parse(URL(string: "otherapp://reset-password?code=abc")!))
        XCTAssertNil(PasswordResetLink.parse(URL(string: "payup://join?code=abc")!),
                     "a different payup link must not be treated as a reset")
    }

    func testExpiredLinkErrorInFragmentIsRecognised() {
        let url = URL(string: "payup://reset-password#error=access_denied&error_code=otp_expired"
            + "&error_description=Email+link+is+invalid+or+has+expired")!
        XCTAssertEqual(PasswordResetLink.parse(url), .failed(ResetLinkProblem.expired))
    }

    func testErrorInQueryIsRecognised() {
        let url = URL(string: "payup://reset-password?error=access_denied&error_code=otp_expired"
            + "&error_description=Email%20link%20is%20invalid%20or%20has%20expired")!
        XCTAssertEqual(PasswordResetLink.parse(url), .failed(ResetLinkProblem.expired))
    }

    func testUnknownRedirectErrorIsShownVerbatim() {
        let url = URL(string: "payup://reset-password?error_description=Server+is+on+fire")!
        XCTAssertEqual(PasswordResetLink.parse(url), .failed("Server is on fire"))
    }

    func testLinkWithoutACodeIsAFailureNotIgnored() {
        XCTAssertEqual(PasswordResetLink.parse(URL(string: "payup://reset-password")!),
                       .failed(ResetLinkProblem.malformed))
        XCTAssertEqual(PasswordResetLink.parse(URL(string: "payup://reset-password?code=")!),
                       .failed(ResetLinkProblem.malformed))
    }

    // MARK: - Exchange failures

    func testSpentCodeReadsAsExpired() {
        XCTAssertEqual(ResetLinkProblem.message(for: ServerError(text: "invalid flow state, no valid flow state found")),
                       ResetLinkProblem.expired)
        XCTAssertEqual(ResetLinkProblem.message(for: ServerError(text: "flow_state_expired")),
                       ResetLinkProblem.expired)
    }

    func testMissingVerifierPointsAtTheOtherDevice() {
        let error = ServerError(text: "invalid request: both auth code and code verifier should be non-empty")
        XCTAssertEqual(ResetLinkProblem.message(for: error), ResetLinkProblem.otherDevice)
    }

    func testOfflineIsNotCalledExpired() {
        // The code is still good; telling them to request another would be wrong.
        XCTAssertEqual(ResetLinkProblem.message(for: URLError(.notConnectedToInternet)), ResetLinkProblem.offline)
    }

    // MARK: - New password form

    func testNewPasswordRules() {
        XCTAssertNotNil(NewPasswordRules.problem(password: "abc", confirmation: "abc"), "too short")
        XCTAssertEqual(NewPasswordRules.problem(password: "abcdef", confirmation: "abcdeg"),
                       "Those passwords don't match.")
        XCTAssertNil(NewPasswordRules.problem(password: "abcdef", confirmation: "abcdef"))
    }

    func testReusingTheOldPasswordIsExplained() {
        let text = NewPasswordRules.message(
            for: ServerError(text: "New password should be different from the old password.")
        )
        XCTAssertTrue(text.contains("current password"))
    }

    // MARK: - State transitions

    /// Warm start: app open on the sign-in screen, link tapped.
    func testWarmStartLinkMovesToRecovering() async {
        let auth = makeAuth()
        await auth.restore()
        XCTAssertEqual(auth.state, .signedOut)

        let handled = await auth.handle(resetURL)

        XCTAssertTrue(handled)
        XCTAssertEqual(auth.state, .recovering(userId: "user-reset", email: "keeper@minety.example"))
        XCTAssertNil(auth.resetLinkProblem)
        XCTAssertFalse(auth.isRedeemingResetLink)
        XCTAssertEqual(backend.exchanged, [resetURL], "the full URL goes to the SDK, not just the code")
    }

    /// Cold start: the link can beat restore(). restore() finishing afterwards
    /// must not replace the recovery state with a plain sign-in.
    func testColdStartLinkBeforeRestoreStaysRecovering() async {
        let auth = makeAuth()
        XCTAssertEqual(auth.state, .restoring)

        await auth.handle(resetURL)
        await auth.restore()

        XCTAssertEqual(auth.state, .recovering(userId: "user-reset", email: "keeper@minety.example"))
    }

    func testColdStartDeadLinkStillEndsSignedOutWithAMessage() async {
        backend.exchangeError = ServerError(text: "invalid flow state, no valid flow state found")
        let auth = makeAuth()

        await auth.handle(resetURL)
        await auth.restore()

        XCTAssertEqual(auth.state, .signedOut, "never left on the blank restoring screen")
        XCTAssertEqual(auth.resetLinkProblem, ResetLinkProblem.expired)
        XCTAssertFalse(auth.isRedeemingResetLink)
    }

    func testDeadLinkLeavesStateAloneAndExplains() async {
        backend.exchangeError = ServerError(text: "flow_state_expired")
        let auth = makeAuth()
        await auth.restore()

        await auth.handle(resetURL)

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.resetLinkProblem, ResetLinkProblem.expired)
        XCTAssertNil(PendingRecovery.userId(defaults))
    }

    func testErrorRedirectNeverCallsTheServer() async {
        let auth = makeAuth()
        await auth.restore()

        await auth.handle(URL(string: "payup://reset-password#error=access_denied&error_code=otp_expired")!)

        XCTAssertTrue(backend.exchanged.isEmpty)
        XCTAssertEqual(auth.resetLinkProblem, ResetLinkProblem.expired)
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testUnrelatedURLIsIgnored() async {
        let auth = makeAuth()
        await auth.restore()

        let handled = await auth.handle(URL(string: "https://example.com/?code=abc")!)

        XCTAssertFalse(handled)
        XCTAssertTrue(backend.exchanged.isEmpty)
        XCTAssertNil(auth.resetLinkProblem)
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testSettingThePasswordLetsTheUserIn() async throws {
        let auth = makeAuth()
        await auth.restore()
        await auth.handle(resetURL)
        XCTAssertEqual(PendingRecovery.userId(defaults), "user-reset")

        try await auth.setNewPassword("brand-new-pass")

        XCTAssertEqual(backend.passwords, ["brand-new-pass"])
        XCTAssertEqual(auth.state, .signedIn(userId: "user-reset", email: "keeper@minety.example"))
        XCTAssertNil(PendingRecovery.userId(defaults))
    }

    func testFailedPasswordUpdateStaysOnTheForm() async {
        let auth = makeAuth()
        await auth.restore()
        await auth.handle(resetURL)
        backend.updateError = ServerError(text: "New password should be different from the old password.")

        await XCTAssertThrowsErrorAsync(try await auth.setNewPassword("same-old"))

        XCTAssertEqual(auth.state, .recovering(userId: "user-reset", email: "keeper@minety.example"))
        XCTAssertEqual(PendingRecovery.userId(defaults), "user-reset", "still unfinished")
    }

    func testPasswordCantBeSetOutsideRecovery() async throws {
        let auth = makeAuth()
        await auth.restore()

        try await auth.setNewPassword("whatever")

        XCTAssertTrue(backend.passwords.isEmpty)
        XCTAssertEqual(auth.state, .signedOut)
    }

    /// Killed on the new-password screen: the next launch goes back there,
    /// not into the app on the recovery session.
    func testUnfinishedRecoveryResumesAfterRelaunch() {
        let auth = makeAuth()
        PendingRecovery.set("user-reset", defaults)

        XCTAssertEqual(auth.restoredState(userId: "user-reset", email: "k@m.example"),
                       .recovering(userId: "user-reset", email: "k@m.example"))
        XCTAssertEqual(auth.restoredState(userId: "someone-else", email: "s@m.example"),
                       .signedIn(userId: "someone-else", email: "s@m.example"))
    }

    func testNoPendingRecoveryRestoresAsSignedIn() {
        let auth = makeAuth()
        XCTAssertEqual(auth.restoredState(userId: "user-reset", email: "k@m.example"),
                       .signedIn(userId: "user-reset", email: "k@m.example"))
    }

    func testCancellingRecoverySignsOutAndForgetsIt() async {
        let auth = makeAuth()
        await auth.restore()
        await auth.handle(resetURL)

        await auth.signOut()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(PendingRecovery.userId(defaults))
    }
}

// MARK: - Doubles

private final class FakeRecoveryBackend: PasswordRecoveryBackend, @unchecked Sendable {
    var exchangeError: Error?
    var updateError: Error?
    private(set) var exchanged: [URL] = []
    private(set) var passwords: [String] = []

    func exchange(_ url: URL) async throws -> (userId: String, email: String) {
        exchanged.append(url)
        if let exchangeError { throw exchangeError }
        return ("user-reset", "keeper@minety.example")
    }

    func updatePassword(_ password: String) async throws {
        if let updateError { throw updateError }
        passwords.append(password)
    }
}
