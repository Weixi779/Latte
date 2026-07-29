//
//  LatteTests.swift
//  LatteTests
//
//  Created by weixi on 2026/7/25.
//

import Testing
@testable import Latte

private func exerciseBasicBehavior<Cache: Caching>(
    _ cache: Cache
) where Cache.Key == String, Cache.Value == Int {
    #expect(cache.value(for: "missing") == nil)

    cache.insert(42, for: "answer")
    #expect(cache.value(for: "answer") == 42)

    cache.removeValue(for: "answer")
    #expect(cache.value(for: "answer") == nil)

    cache.insert(1, for: "first")
    cache.insert(2, for: "second")
    cache.removeAll()

    #expect(cache.value(for: "first") == nil)
    #expect(cache.value(for: "second") == nil)
}

@Test("LRUMemoryCache satisfies the common synchronous cache behavior")
func commonCachingBehavior() {
    let cache = LRUMemoryCache<String, Int>(
        configuration: .init(maximumCost: 10)
    )

    exerciseBasicBehavior(cache)
}

private struct AsyncCacheShape: AsyncCaching {
    func value(for key: String) async throws -> Int? {
        nil
    }

    func insert(_ value: Int, for key: String) async throws {}

    func removeValue(for key: String) async throws {}

    func removeAll() async throws {}
}

@Test("AsyncCaching expresses value-or-miss without a lookup enum")
func asyncCachingShape() async throws {
    let cache = AsyncCacheShape()

    #expect(try await cache.value(for: "missing") == nil)
}
