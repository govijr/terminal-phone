import Darwin
import Foundation

/// Every byte for the terminal goes through one serial queue, so the render thread and the
/// UI never interleave escape sequences. Each write is a complete, absolutely positioned chunk.
public final class TerminalWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "terminal-phone.output", qos: .userInteractive)
    public init() {}
    public func write(_ text: String) { send(text, wait: false) }
    /// Blocks until the terminal has accepted the bytes. The renderer uses this for backpressure:
    /// while a slow terminal drains a frame, newer frames replace each other instead of piling up.
    public func writeAndWait(_ text: String) { send(text, wait: true) }
    private func send(_ text: String, wait: Bool) {
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        let work = {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(1, raw.baseAddress! + offset, raw.count - offset)
                    if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                    offset += count
                }
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
    public func flush() { queue.sync {} }
}
