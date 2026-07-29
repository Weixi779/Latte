//
//  LRUList.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

/// An indexed least-to-most-recent key ordering.
///
/// `LRUList` owns only identity and recency. Capacity, cost, expiration,
/// admission, and value residency belong to the complete Cache using it.
package struct LRUList<Key: Hashable> {
    private struct Node {
        let key: Key
        var previous: Int?
        var next: Int?
    }

    private var indices: [Key: Int] = [:]
    private var nodes: [Node?] = []
    private var freeIndices: [Int] = []
    private var leastRecentIndex: Int?
    private var mostRecentIndex: Int?

    package init() {}

    package var count: Int {
        indices.count
    }

    package var keys: [Key] {
        var result: [Key] = []
        result.reserveCapacity(count)

        var current = leastRecentIndex
        while let index = current {
            let node = nodes[index]!
            result.append(node.key)
            current = node.next
        }

        return result
    }

    package var leastRecentlyUsedKey: Key? {
        leastRecentIndex.map { nodes[$0]!.key }
    }

    package var mostRecentlyUsedKey: Key? {
        mostRecentIndex.map { nodes[$0]!.key }
    }

    package func contains(_ key: Key) -> Bool {
        indices[key] != nil
    }

    package mutating func append(_ key: Key) {
        precondition(indices[key] == nil, "LRU key already exists")

        let index = allocate(key)
        appendAsMostRecent(index)
        indices[key] = index
    }

    @discardableResult
    package mutating func moveToMostRecent(_ key: Key) -> Bool {
        guard let index = indices[key] else {
            return false
        }
        guard mostRecentIndex != index else {
            return true
        }

        detach(index)
        appendAsMostRecent(index)
        return true
    }

    @discardableResult
    package mutating func remove(_ key: Key) -> Key? {
        guard let index = indices.removeValue(forKey: key) else {
            return nil
        }

        let storedKey = nodes[index]!.key
        detach(index)
        nodes[index] = nil
        freeIndices.append(index)
        return storedKey
    }

    @discardableResult
    package mutating func removeLeastRecentlyUsed() -> Key? {
        guard let leastRecentlyUsedKey else {
            return nil
        }

        return remove(leastRecentlyUsedKey)
    }

    package mutating func removeAll() {
        indices.removeAll(keepingCapacity: true)
        nodes.removeAll(keepingCapacity: true)
        freeIndices.removeAll(keepingCapacity: true)
        leastRecentIndex = nil
        mostRecentIndex = nil
    }

    private mutating func allocate(_ key: Key) -> Int {
        let node = Node(key: key, previous: nil, next: nil)

        if let index = freeIndices.popLast() {
            nodes[index] = node
            return index
        }

        nodes.append(node)
        return nodes.count - 1
    }

    private mutating func appendAsMostRecent(_ index: Int) {
        nodes[index]!.previous = mostRecentIndex
        nodes[index]!.next = nil

        if let mostRecentIndex {
            nodes[mostRecentIndex]!.next = index
        } else {
            leastRecentIndex = index
        }

        mostRecentIndex = index
    }

    private mutating func detach(_ index: Int) {
        let previous = nodes[index]!.previous
        let next = nodes[index]!.next

        if let previous {
            nodes[previous]!.next = next
        } else {
            leastRecentIndex = next
        }

        if let next {
            nodes[next]!.previous = previous
        } else {
            mostRecentIndex = previous
        }

        nodes[index]!.previous = nil
        nodes[index]!.next = nil
    }
}
