import EngineCore
import Foundation
import QueueKit

/// Terminalde tek satırlık ilerleme. TTY değilse (pipe, log) 2 sn'de bir yeni satır yazar.
final class ProgressRenderer {
    private let interactive = isatty(STDOUT_FILENO) == 1
    private var lastDraw = ContinuousClock.now - .seconds(10)
    private var hasLine = false

    func update(_ event: ProgressEvent) {
        let interval: Duration = interactive ? .milliseconds(250) : .seconds(2)
        let now = ContinuousClock.now
        guard now - lastDraw >= interval || event.phase == .postprocess else { return }
        lastDraw = now
        draw(Self.line(for: event))
    }

    func log(_ text: String) {
        clear()
        print("  \(text)")
    }

    func finish() { clear() }

    private func draw(_ text: String) {
        if interactive {
            FileHandle.standardOutput.write(Data("\r\u{1B}[K\(text)".utf8))
            hasLine = true
        } else {
            print(text)
        }
    }

    private func clear() {
        guard hasLine else { return }
        FileHandle.standardOutput.write(Data("\r\u{1B}[K".utf8))
        hasLine = false
    }

    static func line(for event: ProgressEvent) -> String {
        if event.phase == .postprocess { return "  işleniyor: \(event.message ?? "")" }
        var parts: [String] = []
        if let fraction = event.fraction {
            let approximate = event.bytesTotal == nil ? "~" : ""
            parts.append(approximate + String(format: "%5.1f%%", fraction * 100))
        }
        let total = (event.bytesTotal ?? event.bytesTotalEstimate).map { " / \(Format.bytes($0))" } ?? ""
        parts.append(Format.bytes(event.bytesDone) + total)
        if let speed = event.speed, speed > 0 { parts.append(Format.bytes(Int64(speed)) + "/s") }
        if let eta = event.eta { parts.append("kalan \(Format.duration(eta))") }
        if let message = event.message { parts.append(message) }
        return "  " + parts.joined(separator: "  ")
    }
}
