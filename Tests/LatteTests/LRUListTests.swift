//
//  LRUListTests.swift
//  LatteTests
//
//  Created by weixi on 2026/7/29.
//

import Testing
@testable import Latte

@Suite("LRUList")
struct LRUListTests {
    @Test("Orders keys from least to most recently used")
    func ordersKeys() {
        var list = LRUList<String>()

        list.append("a")
        list.append("b")
        list.append("c")

        #expect(list.keys == ["a", "b", "c"])
        #expect(list.leastRecentlyUsedKey == "a")
        #expect(list.mostRecentlyUsedKey == "c")
    }

    @Test("Access moves a resident key to most recent")
    func movesToMostRecent() {
        var list = LRUList<String>()
        list.append("a")
        list.append("b")
        list.append("c")

        let movedResident = list.moveToMostRecent("a")
        #expect(list.keys == ["b", "c", "a"])
        let movedMissing = list.moveToMostRecent("missing")

        #expect(movedResident)
        #expect(!movedMissing)
    }

    @Test("Removal returns the stored key and reuses node storage")
    func removesStoredKey() {
        let stored = IdentityKey(id: 1)
        let equalProbe = IdentityKey(id: 1)
        var list = LRUList<IdentityKey>()
        list.append(stored)
        list.append(IdentityKey(id: 2))

        let removed = list.remove(equalProbe)
        list.append(IdentityKey(id: 3))

        #expect(removed === stored)
        #expect(list.keys.map(\.id) == [2, 3])
    }

    @Test("Least-recent removal and remove all preserve invariants")
    func removesLeastRecentAndAll() {
        var list = LRUList<Int>()
        list.append(1)
        list.append(2)
        list.append(3)
        list.moveToMostRecent(1)

        #expect(list.removeLeastRecentlyUsed() == 2)
        #expect(list.keys == [3, 1])

        list.removeAll()

        #expect(list.count == 0)
        #expect(list.keys.isEmpty)
        #expect(list.leastRecentlyUsedKey == nil)
        #expect(list.mostRecentlyUsedKey == nil)
        #expect(!list.contains(1))
    }
}

private final class IdentityKey: Hashable {
    let id: Int

    init(id: Int) {
        self.id = id
    }

    static func == (lhs: IdentityKey, rhs: IdentityKey) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
