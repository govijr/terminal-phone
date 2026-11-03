import Foundation

/// Serialize native input, rather than holding the input lock while inspecting or waiting for UI.
@MainActor
public final class PhoneWorkQueue {
    private struct Waiter { let priority: Bool; let continuation: CheckedContinuation<Void, Never> }
    private var running = false
    private var waiters: [Waiter] = []
    public init() {}
    public func run<T>(priority: Bool = false, _ operation: () async throws -> T) async rethrows -> T {
        if running {
            await withCheckedContinuation { continuation in
                let waiter = Waiter(priority: priority, continuation: continuation)
                if priority { waiters.insert(waiter, at: waiters.firstIndex(where: { !$0.priority }) ?? waiters.endIndex) }
                else { waiters.append(waiter) }
            }
        } else { running = true }
        defer {
            if waiters.isEmpty { running = false }
            else { waiters.removeFirst().continuation.resume() }
        }
        return try await operation()
    }
}
