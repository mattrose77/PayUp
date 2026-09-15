import XCTest

/// XCTAssertThrowsError can't accept an async expression, so the suite uses
/// this instead. Behaviour is identical: fail if nothing throws, otherwise hand
/// the error to the caller for inspection.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected an error but none was thrown" : message(),
                file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
