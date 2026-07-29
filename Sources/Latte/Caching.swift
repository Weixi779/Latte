//
//  Caching.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

/// A synchronous cache with value-or-miss lookup semantics.
///
/// Conforming types own their complete caching behavior, including storage,
/// replacement state, synchronization, and any implementation-specific
/// capabilities.
public protocol Caching<Key, Value> {
    associatedtype Key: Hashable
    associatedtype Value

    /// Returns the cached value for `key`, or `nil` on a cache miss.
    func value(for key: Key) -> Value?

    /// Submits a value to the cache.
    ///
    /// A completed call does not guarantee a subsequent hit. A concrete cache
    /// can reject the candidate or evict it according to its own policy.
    func insert(_ value: Value, for key: Key)

    /// Explicitly invalidates the cached value for `key`.
    func removeValue(for key: Key)

    /// Explicitly invalidates every cached value.
    func removeAll()
}
