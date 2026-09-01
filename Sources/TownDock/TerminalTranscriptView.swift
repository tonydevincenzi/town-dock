import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

/// A read-only terminal renderer for the PTY transcript captured by Town Sheriff.
/// Keeping the raw bytes lets ANSI color, cursor movement, carriage returns, and
/// terminal wrapping behave as they do in an interactive terminal.
struct TerminalTranscriptView: NSViewRepresentable {
    let transcript: Data

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalView {
        var options = TerminalOptions.default
        options.scrollback = 20_000

        let view = TerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            options: options
        )
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = NSColor(
            calibratedRed: 0.035,
            green: 0.039,
            blue: 0.045,
            alpha: 1
        )
        view.nativeForegroundColor = NSColor(
            calibratedRed: 0.83,
            green: 0.85,
            blue: 0.88,
            alpha: 1
        )
        view.caretViewTracksFocus = true
        context.coordinator.update(view, transcript: transcript)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.update(view, transcript: transcript)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private var renderedTranscript = Data()

        func update(_ view: TerminalView, transcript: Data) {
            guard transcript != renderedTranscript else { return }

            if transcript.starts(with: renderedTranscript) {
                feed(transcript.dropFirst(renderedTranscript.count), into: view)
            } else {
                view.terminal.resetToInitialState()
                view.terminal.clearScrollback()
                feed(transcript[...], into: view)
            }
            renderedTranscript = transcript
        }

        private func feed(_ bytes: Data.SubSequence, into view: TerminalView) {
            guard !bytes.isEmpty else { return }
            let buffer = Array(bytes)
            view.feed(byteArray: buffer[...])
        }

        // The transcript is deliberately read-only. Selection, links, scrolling,
        // and Command-C remain native SwiftTerm behavior, but keystrokes are not
        // sent to the detached stack process.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
