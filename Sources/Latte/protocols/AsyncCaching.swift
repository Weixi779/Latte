//
//  AsyncCaching.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

/// An asynchronous cache for implementations that can suspend or fail.
///
/// A `nil` lookup result is a cache miss. Thrown errors represent storage
/// failures or cancellation and must not be used to report an ordinary miss.
public protocol AsyncCaching<Key, Value> {
    associatedtype Key: Hashable
    associatedtype Value

    /// Returns the cached value for `key`, or `nil` on a cache miss.
    func value(for key: Key) async throws -> Value?

    /// Submits a value to the cache.
    ///
    /// A completed call does not guarantee a subsequent hit. Algorithmic
    /// rejection is normal cache behavior rather than a storage error.
    func insert(_ value: Value, for key: Key) async throws

    /// Explicitly invalidates the cached value for `key`.
    func removeValue(for key: Key) async throws

    /// Explicitly invalidates every cached value.
    func removeAll() async throws
}
