//
//  CacheProtocolTests.swift
//  LatteTests
//
//  Created by weixi on 2026/7/25.
//

import Foundation
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

private struct NetworkImageCacheShape<Image> {
    private let memory: any Caching<URL, Image>
    private let file: any AsyncCaching<URL, Data>

    init(
        memory: any Caching<URL, Image>,
        file: any AsyncCaching<URL, Data>
    ) {
        self.memory = memory
        self.file = file
    }

    func cachedImage(
        for url: URL,
        decode: (Data) throws -> Image
    ) async throws -> Image? {
        if let image = memory.value(for: url) {
            return image
        }
        guard let data = try await file.value(for: url) else {
            return nil
        }

        let image = try decode(data)
        memory.insert(image, for: url)
        return image
    }
}

private struct AsyncDataCacheShape: AsyncCaching {
    let storedValue: Data?

    func value(for key: URL) async throws -> Data? {
        storedValue
    }

    func insert(_ value: Data, for key: URL) async throws {}
    func removeValue(for key: URL) async throws {}
    func removeAll() async throws {}
}

@Test("Network image orchestration can inject both Cache protocols")
func networkImageCacheInjection() async throws {
    let memory = LRUMemoryCache<URL, Int>(
        configuration: .init(maximumCost: 1)
    )
    let file = AsyncDataCacheShape(storedValue: Data([42]))
    let cache = NetworkImageCacheShape(memory: memory, file: file)
    let url = URL(string: "https://example.com/image")!

    let first = try await cache.cachedImage(for: url) {
        Int($0.first!)
    }
    let second = try await cache.cachedImage(for: url) { _ in -1 }

    #expect(first == 42)
    #expect(second == 42)
}
