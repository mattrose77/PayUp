import XCTest
@testable import PayUp

/// Email confirmation is on, so signing in before clicking the link is a normal
/// thing to do — and the app has to say which of the two it is, because the
/// fixes are completely different: resend a link, or retype your password.
final class EmailConfirmationTests: XCTestCase {
    private struct ServerError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private func problem(_ text: String, email: String = "keeper@minety.example") -> SignInProblem {
        AuthErrorText.signInProblem(ServerError(text: text), email: email)
    }

    // MARK: - Telling the two apart

    func testUnconfirmedEmailIsRecognised() {
        // Supabase words this differently depending on the endpoint.
        XCTAssertEqual(problem("email_not_confirmed"), .emailNotConfirmed(email: "keeper@minety.example"))
        XCTAssertEqual(problem("Email not confirmed"), .emailNotConfirmed(email: "keeper@minety.example"))
        XCTAssertEqual(
            problem(#"AuthError(message: "Email not confirmed", code: "email_not_confirmed")"#),
            .emailNotConfirmed(email: "keeper@minety.example")
        )
    }

    func testWrongCredentialsAreNotMistakenForAnUnconfirmedEmail() {
        XCTAssertEqual(problem("Invalid login credentials"), .wrongCredentials)
        XCTAssertEqual(problem("invalid_credentials"), .wrongCredentials)
        XCTAssertFalse(problem("Invalid login credentials").canResendConfirmation)
    }

    func testUnknownFailuresSurfaceRatherThanBeingGuessedAt() {
        XCTAssertEqual(problem("the network went away"), .other("the network went away"))
        XCTAssertFalse(problem("the network went away").canResendConfirmation)
    }

    // MARK: - What the user is told

    func testUnconfirmedMessageNamesTheAddressAndSaysWhatToDo() {
        let message = SignInProblem.emailNotConfirmed(email: "sam@minety.example").message
        XCTAssertTrue(message.contains("sam@minety.example"), "the address has to be named")
        XCTAssertTrue(message.contains("hasn't been confirmed"))
        XCTAssertTrue(message.contains("click it"), "say what to do, not just what went wrong")
        XCTAssertTrue(message.contains("Your account exists"), "don't imply the sign-up failed")
    }

    func testOnlyTheUnconfirmedCaseOffersAResend() {
        XCTAssertTrue(SignInProblem.emailNotConfirmed(email: "a@b.c").canResendConfirmation)
        XCTAssertFalse(SignInProblem.wrongCredentials.canResendConfirmation)
        XCTAssertFalse(SignInProblem.other("boom").canResendConfirmation)
    }

    func testRateLimitedResendIsExplained() {
        let text = AuthErrorText.forResend(ServerError(text: "For security purposes, you can only request this after 48 seconds"))
        XCTAssertTrue(text.contains("rate-limiting"))
    }

    func testDuplicateSignUpPointsAtSigningIn() {
        let text = AuthErrorText.forSignUp(ServerError(text: "User already registered"))
        XCTAssertTrue(text.contains("already an account"))
        XCTAssertTrue(text.contains("signing in"))
    }

    // MARK: - Throttle

    func testFirstResendIsAllowedAndTheNextIsNot() {
        var throttle = ResendThrottle()
        let now = Date()
        XCTAssertTrue(throttle.canSend(now: now))

        throttle.record(now: now)
        XCTAssertFalse(throttle.canSend(now: now), "a second tap must not send a second email")
        XCTAssertFalse(throttle.canSend(now: now.addingTimeInterval(59)))
    }

    func testResendIsAllowedAgainAfterTheInterval() {
        var throttle = ResendThrottle()
        let now = Date()
        throttle.record(now: now)

        XCTAssertTrue(throttle.canSend(now: now.addingTimeInterval(ResendThrottle.interval)))
        XCTAssertTrue(throttle.canSend(now: now.addingTimeInterval(ResendThrottle.interval + 1)))
    }

    /// The button says how long is left, so a disabled control explains itself.
    func testSecondsRemainingCountsDown() {
        var throttle = ResendThrottle()
        let now = Date()
        XCTAssertEqual(throttle.secondsRemaining(now: now), 0)

        throttle.record(now: now)
        XCTAssertEqual(throttle.secondsRemaining(now: now), 60)
        XCTAssertEqual(throttle.secondsRemaining(now: now.addingTimeInterval(30)), 30)
        XCTAssertEqual(throttle.secondsRemaining(now: now.addingTimeInterval(60)), 0)
        XCTAssertEqual(throttle.secondsRemaining(now: now.addingTimeInterval(120)), 0)
    }
}
