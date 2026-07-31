import os

/// iOS 17-compatible subset of `Synchronization.Mutex` used by this SDK.
struct Mutex<State>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<State>

    init(_ initialState: State) {
        lock = OSAllocatedUnfairLock(uncheckedState: initialState)
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try lock.withLockUnchecked { try body(&$0) }
    }
}
