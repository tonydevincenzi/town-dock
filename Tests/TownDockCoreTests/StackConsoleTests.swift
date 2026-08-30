import XCTest
@testable import TownDockCore

final class StackConsoleTests: XCTestCase {
    func testTranscriptRemovesANSIAndResolvesCarriageReturnUpdates() {
        let raw = "\u{001B}[32mStarting\u{001B}[0m 10%\rStarting 100%\u{001B}[K\nReady\n"

        XCTAssertEqual(StackConsoleTranscript.render(raw), "Starting 100%\nReady\n")
    }

    func testTranscriptRedactsSecrets() {
        let raw = "API_KEY=super-secret\nAuthorization: Bearer abc.def.ghi\n"

        let rendered = StackConsoleTranscript.render(raw)

        XCTAssertFalse(rendered.contains("super-secret"))
        XCTAssertFalse(rendered.contains("abc.def.ghi"))
        XCTAssertTrue(rendered.contains("[REDACTED]"))
    }

    func testReaderReturnsBoundedManagedCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TownDockConsoleTests-\(UUID().uuidString)")
        let consoleRoot = root.appendingPathComponent("captures")
        let worktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let capture = StackConsoleCapture.captureURL(
            for: worktree.path,
            rootDirectory: consoleRoot
        )
        try FileManager.default.createDirectory(
            at: capture.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old line\nnew \u{001B}[31mline\u{001B}[0m\n".utf8).write(to: capture)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try await StackConsoleReader(rootDirectory: consoleRoot)
            .read(worktreePath: worktree.path)

        XCTAssertEqual(snapshot?.source, .managedCapture)
        XCTAssertEqual(snapshot?.text, "old line\nnew line\n")
        XCTAssertEqual(snapshot?.path, capture.path)
    }
}
