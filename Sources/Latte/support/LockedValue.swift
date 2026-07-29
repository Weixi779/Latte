//
//  LockedValue.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

import os

/// Owns mutable state protected by a stable-address unfair lock.
package final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock: os_unfair_lock_t

    package init(_ value: Value) {
        self.value = value
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    package func withLock<Result>(
        _ operation: (inout Value) throws -> Result
    ) rethrows -> Result {
        // Callers that remove reentrant reference values must return ownership
        // from `operation` so their final release happens after this unlock.
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try operation(&value)
    }
}
