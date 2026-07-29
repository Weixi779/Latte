//
//  main.swift
//  Latte
//
//  Created by weixi on 2026/7/26.
//

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct TraceRequest {
    let key: UInt64
    let size: Int
}

private enum CapacityMode: String, CaseIterable {
    case objects
    case bytes

    func policyCost(for request: TraceRequest) -> Int {
        switch self {
        case .objects:
            1
        case .bytes:
            request.size
        }
    }
}

private enum TraceFormat: String {
    case csv
    case oracleGeneral = "oracle-general"
}

private struct HitRateMetrics: Equatable {
    private(set) var requestCount: UInt64 = 0
    private(set) var requestHits: UInt64 = 0
    private(set) var requestedBytes: UInt64 = 0
    private(set) var byteHits: UInt64 = 0

    var objectHitRate: Double {
        guard requestCount > 0 else {
            return 0
        }

        return Double(requestHits) / Double(requestCount)
    }

    var byteHitRate: Double {
        guard requestedBytes > 0 else {
            return 0
        }

        return Double(byteHits) / Double(requestedBytes)
    }

    var requestMisses: UInt64 {
        requestCount - requestHits
    }

    var missedBytes: UInt64 {
        requestedBytes - byteHits
    }

    mutating func record(hit: Bool, requestSize: Int) {
        let size = UInt64(requestSize)
        requestCount += 1
        requestedBytes += size

        if hit {
            requestHits += 1
            byteHits += size
        }
    }
}

private protocol HitRatePolicy {
    mutating func request(key: UInt64, cost: Int) -> Bool
}

private struct QueueEntry: Equatable {
    let key: UInt64
    let cost: Int
    var frequency: UInt8
}

private struct IndexedFIFO {
    private struct Node {
        var entry: QueueEntry
        var previous: Int?
        var next: Int?
    }

    private var indices: [UInt64: Int] = [:]
    private var nodes: [Node?] = []
    private var freeIndices: [Int] = []
    private var firstIndex: Int?
    private var lastIndex: Int?

    private(set) var totalCost = 0

    var isEmpty: Bool {
        indices.isEmpty
    }

    var firstEntry: QueueEntry? {
        firstIndex.map { nodes[$0]!.entry }
    }

    var entries: [QueueEntry] {
        var result: [QueueEntry] = []
        result.reserveCapacity(indices.count)

        var current = firstIndex
        while let index = current {
            let node = nodes[index]!
            result.append(node.entry)
            current = node.next
        }

        return result
    }

    func contains(_ key: UInt64) -> Bool {
        indices[key] != nil
    }

    func entry(for key: UInt64) -> QueueEntry? {
        indices[key].map { nodes[$0]!.entry }
    }

    func entry(after key: UInt64) -> QueueEntry? {
        guard let index = indices[key],
              let next = nodes[index]!.next
        else {
            return nil
        }

        return nodes[next]!.entry
    }

    mutating func setFrequency(_ frequency: UInt8, for key: UInt64) -> Bool {
        guard let index = indices[key] else {
            return false
        }

        nodes[index]!.entry.frequency = frequency
        return true
    }

    mutating func incrementFrequency(for key: UInt64) -> Bool {
        guard let index = indices[key] else {
            return false
        }

        let frequency = nodes[index]!.entry.frequency
        nodes[index]!.entry.frequency = min(frequency + 1, 3)
        return true
    }

    mutating func moveToBack(_ key: UInt64) -> Bool {
        guard let entry = remove(key) else {
            return false
        }

        append(entry)
        return true
    }

    mutating func append(_ entry: QueueEntry) {
        precondition(indices[entry.key] == nil, "FIFO key already exists")

        let index = allocate(entry)
        nodes[index]!.previous = lastIndex
        nodes[index]!.next = nil

        if let lastIndex {
            nodes[lastIndex]!.next = index
        } else {
            firstIndex = index
        }

        lastIndex = index
        indices[entry.key] = index
        totalCost += entry.cost
    }

    @discardableResult
    mutating func remove(_ key: UInt64) -> QueueEntry? {
        guard let index = indices.removeValue(forKey: key) else {
            return nil
        }

        let node = nodes[index]!
        unlink(index)
        nodes[index] = nil
        freeIndices.append(index)
        totalCost -= node.entry.cost
        return node.entry
    }

    mutating func popFirst() -> QueueEntry? {
        guard let firstIndex else {
            return nil
        }

        return remove(nodes[firstIndex]!.entry.key)
    }

    private mutating func allocate(_ entry: QueueEntry) -> Int {
        let node = Node(entry: entry, previous: nil, next: nil)

        if let index = freeIndices.popLast() {
            nodes[index] = node
            return index
        }

        nodes.append(node)
        return nodes.count - 1
    }

    private mutating func unlink(_ index: Int) {
        let previous = nodes[index]!.previous
        let next = nodes[index]!.next

        if let previous {
            nodes[previous]!.next = next
        } else {
            firstIndex = next
        }

        if let next {
            nodes[next]!.previous = previous
        } else {
            lastIndex = previous
        }
    }
}

private struct LRUHitRateCache: HitRatePolicy {
    private let maximumCost: Int
    private var entries = IndexedFIFO()

    init(maximumCost: Int) {
        precondition(maximumCost >= 0)
        self.maximumCost = maximumCost
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        if entries.moveToBack(key) {
            return true
        }

        guard cost <= maximumCost else {
            return false
        }

        while entries.totalCost > maximumCost - cost {
            guard entries.popFirst() != nil else {
                preconditionFailure("LRU exceeded its cost budget without a victim")
            }
        }

        entries.append(QueueEntry(key: key, cost: cost, frequency: 0))
        return false
    }

    var debugEntries: [QueueEntry] {
        entries.entries
    }
}

/// SIEVE from NSDI 2024.
///
/// Entries stay in insertion order. A hit only sets one visited bit; it does
/// not change queue position. The eviction hand scans from older to newer
/// entries, clears visited entries, and evicts the first unvisited entry.
/// New entries are appended at the newest end, independently of the hand.
private struct SIEVEHitRateCache: HitRatePolicy {
    struct DebugState: Equatable {
        let entries: [QueueEntry]
        let hand: UInt64?
    }

    private let maximumCost: Int
    private var entries = IndexedFIFO()
    private var hand: UInt64?

    init(maximumCost: Int) {
        precondition(maximumCost >= 0)
        self.maximumCost = maximumCost
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        if entries.setFrequency(1, for: key) {
            return true
        }

        guard cost <= maximumCost else {
            return false
        }

        while entries.totalCost > maximumCost - cost {
            evictOne()
        }

        entries.append(QueueEntry(key: key, cost: cost, frequency: 0))
        return false
    }

    var debugState: DebugState {
        DebugState(entries: entries.entries, hand: hand)
    }

    private mutating func evictOne() {
        guard var candidate = hand ?? entries.firstEntry?.key else {
            preconditionFailure("SIEVE exceeded its cost budget without a victim")
        }

        while true {
            guard let entry = entries.entry(for: candidate) else {
                preconditionFailure("SIEVE hand points outside the queue")
            }

            let next = entries.entry(after: candidate)?.key

            if entry.frequency > 0 {
                precondition(entries.setFrequency(0, for: candidate))

                guard let wrapped = next ?? entries.firstEntry?.key else {
                    preconditionFailure("SIEVE lost its scan position")
                }
                candidate = wrapped
            } else {
                hand = next
                precondition(entries.remove(candidate) != nil)
                return
            }
        }
    }
}

/// The equal-sized, multi-segment SLRU policy used by the S3-FIFO paper.
///
/// New entries fill the lowest segment with available space. A hit promotes
/// an entry by one segment, and an overflow recursively cools the least-recent
/// entry into the segment below. The highest segment refreshes recency on hit.
private struct SLRUHitRateCache: HitRatePolicy {
    struct DebugState: Equatable {
        let segments: [[QueueEntry]]
    }

    private let maximumCost: Int
    private let segmentCapacity: Int
    private var segments: [IndexedFIFO]
    private var locations: [UInt64: Int] = [:]

    init(maximumCost: Int, segmentCount: Int) {
        precondition(segmentCount >= 2, "SLRU needs at least two segments")
        precondition(
            maximumCost >= segmentCount,
            "SLRU needs at least one cost unit per segment"
        )

        self.maximumCost = maximumCost
        self.segmentCapacity = maximumCost / segmentCount
        self.segments = Array(repeating: IndexedFIFO(), count: segmentCount)
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        if let segment = locations[key] {
            recordHit(for: key, in: segment)
            return true
        }

        guard cost <= segmentCapacity else {
            return false
        }

        while residentCost > maximumCost - cost {
            evictOne()
        }

        let insertionSegment = segments.firstIndex {
            $0.totalCost <= segmentCapacity - cost
        } ?? 0

        segments[insertionSegment].append(
            QueueEntry(key: key, cost: cost, frequency: 0)
        )
        locations[key] = insertionSegment
        return false
    }

    var debugState: DebugState {
        DebugState(segments: segments.map(\.entries))
    }

    private var residentCost: Int {
        segments.reduce(0) { $0 + $1.totalCost }
    }

    private mutating func recordHit(for key: UInt64, in segment: Int) {
        if segment == segments.count - 1 {
            precondition(segments[segment].moveToBack(key))
            return
        }

        guard let entry = segments[segment].remove(key) else {
            preconditionFailure("SLRU location index disagrees with segment")
        }

        let promotedSegment = segment + 1
        segments[promotedSegment].append(entry)
        locations[key] = promotedSegment

        while segments[promotedSegment].totalCost > segmentCapacity {
            cool(promotedSegment)
        }
    }

    private mutating func cool(_ segment: Int) {
        if segment == 0 {
            evictOne()
            return
        }

        guard let entry = segments[segment].popFirst() else {
            preconditionFailure("Cannot cool an empty SLRU segment")
        }

        let lowerSegment = segment - 1
        segments[lowerSegment].append(entry)
        locations[entry.key] = lowerSegment

        while segments[lowerSegment].totalCost > segmentCapacity {
            cool(lowerSegment)
        }
    }

    private mutating func evictOne() {
        guard let segment = segments.firstIndex(where: { !$0.isEmpty }),
              let victim = segments[segment].popFirst()
        else {
            preconditionFailure("SLRU exceeded its cost budget without a victim")
        }

        locations.removeValue(forKey: victim.key)
    }
}

/// Caffeine-style Window TinyLFU with a cost-aware queue extension.
///
/// The default configuration uses a 1% admission window and reserves 80% of
/// main for protected entries. TinyLFU uses a four-depth, four-bit Count-Min
/// sketch with periodic aging. Admission is deterministic for benchmark
/// reproducibility: a candidate must have a strictly greater estimated
/// frequency than the probation victim.
private struct WindowTinyLFUHitRateCache: HitRatePolicy {
    enum Status: Equatable {
        case window
        case probation
        case protected
    }

    struct DebugState: Equatable {
        let window: [QueueEntry]
        let probation: [QueueEntry]
        let protected: [QueueEntry]
    }

    private let maximumCost: Int
    private let maximumWindowCost: Int
    private let maximumProtectedCost: Int

    private var window = IndexedFIFO()
    private var probation = IndexedFIFO()
    private var protected = IndexedFIFO()
    private var locations: [UInt64: Status] = [:]
    private var sketch: TinyLFUSketch

    init(
        maximumCost: Int,
        sketchCapacity: Int,
        windowFraction: Double,
        protectedFraction: Double
    ) {
        precondition(maximumCost > 0)
        precondition(windowFraction > 0 && windowFraction < 1)
        precondition(protectedFraction > 0 && protectedFraction < 1)

        let maximumMainCost = Int(
            Double(maximumCost) * (1 - windowFraction)
        )

        self.maximumCost = maximumCost
        self.maximumWindowCost = maximumCost - maximumMainCost
        self.maximumProtectedCost = Int(
            Double(maximumMainCost) * protectedFraction
        )
        self.sketch = TinyLFUSketch(capacity: sketchCapacity)
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        sketch.increment(key)

        if let status = locations[key] {
            recordHit(for: key, status: status)
            return true
        }

        guard cost <= maximumCost else {
            return false
        }

        window.append(QueueEntry(key: key, cost: cost, frequency: 0))
        locations[key] = .window
        evictIfNeeded()
        return false
    }

    var debugState: DebugState {
        DebugState(
            window: window.entries,
            probation: probation.entries,
            protected: protected.entries
        )
    }

    func estimatedFrequency(of key: UInt64) -> UInt8 {
        sketch.frequency(of: key)
    }

    private var residentCost: Int {
        window.totalCost + probation.totalCost + protected.totalCost
    }

    private mutating func recordHit(for key: UInt64, status: Status) {
        switch status {
        case .window:
            precondition(window.moveToBack(key))
        case .probation:
            guard let entry = probation.remove(key) else {
                preconditionFailure("W-TinyLFU probation index disagrees")
            }

            protected.append(entry)
            locations[key] = .protected
            demoteProtectedIfNeeded()
        case .protected:
            precondition(protected.moveToBack(key))
        }
    }

    private mutating func demoteProtectedIfNeeded() {
        while protected.totalCost > maximumProtectedCost {
            guard let demoted = protected.popFirst() else {
                preconditionFailure("W-TinyLFU protected segment is empty")
            }

            probation.append(demoted)
            locations[demoted.key] = .probation
        }
    }

    private mutating func evictIfNeeded() {
        var candidateKeys: [UInt64] = []

        while window.totalCost > maximumWindowCost {
            guard let candidate = window.popFirst() else {
                preconditionFailure("W-TinyLFU window is empty")
            }

            probation.append(candidate)
            locations[candidate.key] = .probation
            candidateKeys.append(candidate.key)
        }

        var candidateIndex = 0
        while residentCost > maximumCost {
            var candidate: QueueEntry?

            while candidateIndex < candidateKeys.count {
                let key = candidateKeys[candidateIndex]
                candidateIndex += 1

                if locations[key] == .probation {
                    candidate = probation.entry(for: key)
                    break
                }
            }

            guard let candidate else {
                evictLeastValuable()
                continue
            }

            guard let victim = probation.firstEntry else {
                remove(candidate.key, from: .probation)
                continue
            }

            if candidate.key == victim.key {
                remove(candidate.key, from: .probation)
            } else if sketch.frequency(of: candidate.key)
                        > sketch.frequency(of: victim.key)
            {
                remove(victim.key, from: .probation)
            } else {
                remove(candidate.key, from: .probation)
            }
        }
    }

    private mutating func evictLeastValuable() {
        if let victim = probation.firstEntry {
            remove(victim.key, from: .probation)
        } else if let victim = protected.firstEntry {
            remove(victim.key, from: .protected)
        } else if let victim = window.firstEntry {
            remove(victim.key, from: .window)
        } else {
            preconditionFailure("W-TinyLFU exceeded capacity without a victim")
        }
    }

    private mutating func remove(_ key: UInt64, from status: Status) {
        let removed: QueueEntry?

        switch status {
        case .window:
            removed = window.remove(key)
        case .probation:
            removed = probation.remove(key)
        case .protected:
            removed = protected.remove(key)
        }

        precondition(removed != nil, "W-TinyLFU location index disagrees")
        locations.removeValue(forKey: key)
    }
}

private struct TinyLFUSketch {
    private static let resetMask: UInt64 = 0x7777_7777_7777_7777
    private static let oneMask: UInt64 = 0x1111_1111_1111_1111
    private static let seeds: [UInt64] = [
        0xc3a5_c85c_97cb_3127,
        0xb492_b66f_be98_f273,
        0x9ae1_6a3b_2f90_404f,
        0xcbf2_9ce4_8422_2325,
    ]

    private var table: [UInt64]
    private let tableMask: Int
    private let period: Int
    private var additions = 0

    init(capacity: Int) {
        let tableSize = Self.ceilingPowerOfTwo(max(capacity, 1))
        self.table = Array(repeating: 0, count: tableSize)
        self.tableMask = tableSize - 1
        self.period = tableSize > Int.max / 10
            ? Int.max
            : 10 * tableSize
    }

    func frequency(of key: UInt64) -> UInt8 {
        Self.locations(for: key, tableMask: tableMask).reduce(UInt8(15)) {
            minimum, location in
            let offset = location.counter * 4
            let count = UInt8((table[location.slot] >> offset) & 0x0f)
            return min(minimum, count)
        }
    }

    mutating func increment(_ key: UInt64) {
        var added = false

        for location in Self.locations(for: key, tableMask: tableMask) {
            let offset = location.counter * 4
            let mask = UInt64(0x0f) << offset

            if table[location.slot] & mask != mask {
                table[location.slot] += UInt64(1) << offset
                added = true
            }
        }

        guard added else {
            return
        }

        additions += 1
        if additions == period {
            reset()
        }
    }

    static func locations(
        for key: UInt64,
        tableMask: Int
    ) -> [(slot: Int, counter: Int)] {
        let hash = spread(
            UInt32(truncatingIfNeeded: key ^ (key >> 32))
        )
        let start = Int(hash & 3) << 2

        return seeds.indices.map { depth in
            let signedHash = Int64(Int32(bitPattern: hash))
            var mixed = UInt64(bitPattern: signedHash)
            mixed &+= seeds[depth]
            mixed &*= seeds[depth]
            mixed &+= mixed >> 32

            return (
                slot: Int(UInt32(truncatingIfNeeded: mixed)) & tableMask,
                counter: start + depth
            )
        }
    }

    private mutating func reset() {
        var oddCounterCount = 0

        for index in table.indices {
            oddCounterCount += (table[index] & Self.oneMask).nonzeroBitCount
            table[index] = (table[index] >> 1) & Self.resetMask
        }

        additions = (additions - (oddCounterCount >> 2)) >> 1
    }

    private static func spread(_ input: UInt32) -> UInt32 {
        var value = input
        value = ((value >> 16) ^ value) &* 0x045d_9f3b
        value = ((value >> 16) ^ value) &* 0x045d_9f3b
        return (value >> 16) ^ value
    }

    private static func ceilingPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value {
            result <<= 1
        }
        return result
    }
}

/// The original S3-FIFO policy from the SOSP 2023 paper.
///
/// This intentionally models the paper/libCacheSim `S3FIFOv0` behavior:
///
/// - 10% small FIFO, 90% main FIFO, and a ghost FIFO sized like main;
/// - cache hits only increment a capped two-bit frequency;
/// - small entries need two hits before promotion to main;
/// - main eviction uses FIFO reinsertion while decrementing frequency.
private struct S3FIFOHitRateCache: HitRatePolicy {
    struct DebugState: Equatable {
        let small: [QueueEntry]
        let main: [QueueEntry]
        let ghost: [QueueEntry]
    }

    private let maximumCost: Int
    private let smallCapacity: Int
    private let mainCapacity: Int
    private let ghostCapacity: Int

    private var small = IndexedFIFO()
    private var main = IndexedFIFO()
    private var ghost = IndexedFIFO()

    init(maximumCost: Int) {
        precondition(maximumCost >= 10, "S3-FIFO needs a capacity of at least 10")

        self.maximumCost = maximumCost
        self.smallCapacity = max(1, Int(Double(maximumCost) * 0.10))
        self.mainCapacity = maximumCost - smallCapacity
        self.ghostCapacity = mainCapacity
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        if small.incrementFrequency(for: key) {
            return true
        }

        if main.incrementFrequency(for: key) {
            return true
        }

        let wasGhostHit = ghost.remove(key) != nil

        // The reference implementation admits through the small queue and
        // rejects entries that cannot fit there. Equality is also rejected by
        // S3FIFOv0's insertion path.
        guard cost < smallCapacity else {
            return false
        }

        while residentCost > maximumCost - cost {
            evictOne()
        }

        let entry = QueueEntry(key: key, cost: cost, frequency: 0)
        if wasGhostHit {
            main.append(entry)
        } else {
            small.append(entry)
        }

        return false
    }

    var debugState: DebugState {
        DebugState(
            small: small.entries,
            main: main.entries,
            ghost: ghost.entries
        )
    }

    private var residentCost: Int {
        small.totalCost + main.totalCost
    }

    private mutating func evictOne() {
        if main.totalCost > mainCapacity || small.isEmpty {
            evictFromMain()
        } else {
            evictFromSmall()
        }
    }

    private mutating func evictFromSmall() {
        while let candidate = small.popFirst() {
            if candidate.frequency >= 2 {
                main.append(
                    QueueEntry(
                        key: candidate.key,
                        cost: candidate.cost,
                        frequency: 0
                    )
                )
            } else {
                appendToGhost(candidate)
                return
            }
        }
    }

    private mutating func evictFromMain() {
        while var candidate = main.popFirst() {
            if candidate.frequency > 0 {
                candidate.frequency = min(candidate.frequency, 3) - 1
                main.append(candidate)
            } else {
                return
            }
        }

        preconditionFailure("S3-FIFO exceeded its cost budget without a victim")
    }

    private mutating func appendToGhost(_ candidate: QueueEntry) {
        guard candidate.cost <= ghostCapacity else {
            return
        }

        while ghost.totalCost > ghostCapacity - candidate.cost {
            guard ghost.popFirst() != nil else {
                preconditionFailure("S3-FIFO ghost exceeded its cost budget")
            }
        }

        ghost.append(
            QueueEntry(
                key: candidate.key,
                cost: candidate.cost,
                frequency: 0
            )
        )
    }
}

private struct ReferenceLRU {
    private let maximumCost: Int
    private var entries: [QueueEntry] = []

    init(maximumCost: Int) {
        self.maximumCost = maximumCost
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return true
        }

        guard cost <= maximumCost else {
            return false
        }

        while entries.reduce(0, { $0 + $1.cost }) > maximumCost - cost {
            entries.removeFirst()
        }

        entries.append(QueueEntry(key: key, cost: cost, frequency: 0))
        return false
    }

    var debugEntries: [QueueEntry] {
        entries
    }
}

private struct ReferenceSIEVE {
    private let maximumCost: Int
    private var entries: [QueueEntry] = []
    private var hand: UInt64?

    init(maximumCost: Int) {
        self.maximumCost = maximumCost
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].frequency = 1
            return true
        }

        guard cost <= maximumCost else {
            return false
        }

        while Self.cost(of: entries) > maximumCost - cost {
            evictOne()
        }

        entries.append(QueueEntry(key: key, cost: cost, frequency: 0))
        return false
    }

    var debugState: SIEVEHitRateCache.DebugState {
        SIEVEHitRateCache.DebugState(entries: entries, hand: hand)
    }

    private mutating func evictOne() {
        precondition(!entries.isEmpty, "Reference SIEVE has no victim")

        var index = hand.flatMap {
            key in entries.firstIndex(where: { $0.key == key })
        } ?? 0

        while entries[index].frequency > 0 {
            entries[index].frequency = 0
            index = (index + 1) % entries.count
        }

        hand = index + 1 < entries.count ? entries[index + 1].key : nil
        entries.remove(at: index)
    }

    private static func cost(of entries: [QueueEntry]) -> Int {
        entries.reduce(0) { $0 + $1.cost }
    }
}

private struct ReferenceSLRU {
    private let maximumCost: Int
    private let segmentCapacity: Int
    private var segments: [[QueueEntry]]

    init(maximumCost: Int, segmentCount: Int) {
        self.maximumCost = maximumCost
        self.segmentCapacity = maximumCost / segmentCount
        self.segments = Array(repeating: [], count: segmentCount)
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        for segment in segments.indices {
            guard let index = segments[segment].firstIndex(
                where: { $0.key == key }
            ) else {
                continue
            }

            let entry = segments[segment].remove(at: index)
            if segment == segments.count - 1 {
                segments[segment].append(entry)
            } else {
                let promotedSegment = segment + 1
                segments[promotedSegment].append(entry)

                while segmentCost(promotedSegment) > segmentCapacity {
                    cool(promotedSegment)
                }
            }

            return true
        }

        guard cost <= segmentCapacity else {
            return false
        }

        while residentCost > maximumCost - cost {
            evictOne()
        }

        let insertionSegment = segments.indices.first {
            segmentCost($0) <= segmentCapacity - cost
        } ?? 0

        segments[insertionSegment].append(
            QueueEntry(key: key, cost: cost, frequency: 0)
        )
        return false
    }

    var debugState: SLRUHitRateCache.DebugState {
        SLRUHitRateCache.DebugState(segments: segments)
    }

    private var residentCost: Int {
        segments.indices.reduce(0) { $0 + segmentCost($1) }
    }

    private mutating func cool(_ segment: Int) {
        if segment == 0 {
            evictOne()
            return
        }

        let entry = segments[segment].removeFirst()
        let lowerSegment = segment - 1
        segments[lowerSegment].append(entry)

        while segmentCost(lowerSegment) > segmentCapacity {
            cool(lowerSegment)
        }
    }

    private mutating func evictOne() {
        guard let segment = segments.firstIndex(where: { !$0.isEmpty }) else {
            preconditionFailure("Reference SLRU has no victim")
        }

        segments[segment].removeFirst()
    }

    private func segmentCost(_ segment: Int) -> Int {
        segments[segment].reduce(0) { $0 + $1.cost }
    }
}

/// Deliberately simple, unpacked TinyLFU model.
///
/// This duplicates the hash calculation instead of sharing the optimized
/// sketch's packed-counter operations, so the differential check can catch
/// both queue-policy and counter-packing regressions.
private struct ReferenceTinyLFUSketch {
    private static let seeds: [UInt64] = [
        0xc3a5_c85c_97cb_3127,
        0xb492_b66f_be98_f273,
        0x9ae1_6a3b_2f90_404f,
        0xcbf2_9ce4_8422_2325,
    ]

    private var counters: [UInt8]
    private let tableSize: Int
    private let tableMask: Int
    private let period: Int
    private var additions = 0

    init(capacity: Int) {
        var size = 1
        while size < max(capacity, 1) {
            size <<= 1
        }

        self.counters = Array(repeating: 0, count: size * 16)
        self.tableSize = size
        self.tableMask = size - 1
        self.period = size > Int.max / 10 ? Int.max : 10 * size
    }

    func frequency(of key: UInt64) -> UInt8 {
        locations(for: key).reduce(UInt8(15)) {
            min($0, counters[$1])
        }
    }

    mutating func increment(_ key: UInt64) {
        var added = false

        for location in locations(for: key) where counters[location] < 15 {
            counters[location] += 1
            added = true
        }

        guard added else {
            return
        }

        additions += 1
        if additions == period {
            reset()
        }
    }

    private func locations(for key: UInt64) -> [Int] {
        let hash = Self.spread(
            UInt32(truncatingIfNeeded: key ^ (key >> 32))
        )
        let counterStart = Int(hash & 3) << 2
        let signedHash = Int64(Int32(bitPattern: hash))

        return Self.seeds.indices.map { depth in
            var mixed = UInt64(bitPattern: signedHash)
            mixed &+= Self.seeds[depth]
            mixed &*= Self.seeds[depth]
            mixed &+= mixed >> 32

            let slot =
                Int(UInt32(truncatingIfNeeded: mixed)) & tableMask
            return slot * 16 + counterStart + depth
        }
    }

    private mutating func reset() {
        var oddCounterCount = 0

        for index in counters.indices {
            oddCounterCount += Int(counters[index] & 1)
            counters[index] >>= 1
        }

        additions = (additions - (oddCounterCount >> 2)) >> 1
    }

    private static func spread(_ input: UInt32) -> UInt32 {
        var value = input
        value = ((value >> 16) ^ value) &* 0x045d_9f3b
        value = ((value >> 16) ^ value) &* 0x045d_9f3b
        return (value >> 16) ^ value
    }
}

private struct ReferenceWindowTinyLFU {
    private let maximumCost: Int
    private let maximumWindowCost: Int
    private let maximumProtectedCost: Int

    private var window: [QueueEntry] = []
    private var probation: [QueueEntry] = []
    private var protected: [QueueEntry] = []
    private var sketch: ReferenceTinyLFUSketch

    init(
        maximumCost: Int,
        sketchCapacity: Int,
        windowFraction: Double,
        protectedFraction: Double
    ) {
        let maximumMainCost = Int(
            Double(maximumCost) * (1 - windowFraction)
        )

        self.maximumCost = maximumCost
        self.maximumWindowCost = maximumCost - maximumMainCost
        self.maximumProtectedCost = Int(
            Double(maximumMainCost) * protectedFraction
        )
        self.sketch = ReferenceTinyLFUSketch(capacity: sketchCapacity)
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        sketch.increment(key)

        if Self.moveToBack(key, in: &window) {
            return true
        }

        if let index = probation.firstIndex(where: { $0.key == key }) {
            protected.append(probation.remove(at: index))
            demoteProtectedIfNeeded()
            return true
        }

        if Self.moveToBack(key, in: &protected) {
            return true
        }

        guard cost <= maximumCost else {
            return false
        }

        window.append(QueueEntry(key: key, cost: cost, frequency: 0))
        evictIfNeeded()
        return false
    }

    var debugState: WindowTinyLFUHitRateCache.DebugState {
        WindowTinyLFUHitRateCache.DebugState(
            window: window,
            probation: probation,
            protected: protected
        )
    }

    func estimatedFrequency(of key: UInt64) -> UInt8 {
        sketch.frequency(of: key)
    }

    private var residentCost: Int {
        Self.cost(of: window)
            + Self.cost(of: probation)
            + Self.cost(of: protected)
    }

    private static func moveToBack(
        _ key: UInt64,
        in entries: inout [QueueEntry]
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            return false
        }

        entries.append(entries.remove(at: index))
        return true
    }

    private mutating func demoteProtectedIfNeeded() {
        while Self.cost(of: protected) > maximumProtectedCost {
            probation.append(protected.removeFirst())
        }
    }

    private mutating func evictIfNeeded() {
        var candidateKeys: [UInt64] = []

        while Self.cost(of: window) > maximumWindowCost {
            let candidate = window.removeFirst()
            probation.append(candidate)
            candidateKeys.append(candidate.key)
        }

        var candidateIndex = 0
        while residentCost > maximumCost {
            var probationIndex: Int?

            while candidateIndex < candidateKeys.count {
                let key = candidateKeys[candidateIndex]
                candidateIndex += 1

                if let index = probation.firstIndex(
                    where: { $0.key == key }
                ) {
                    probationIndex = index
                    break
                }
            }

            guard let probationIndex else {
                evictLeastValuable()
                continue
            }

            let candidate = probation[probationIndex]
            let victim = probation[0]

            if probationIndex == 0 {
                probation.removeFirst()
            } else if sketch.frequency(of: candidate.key)
                        > sketch.frequency(of: victim.key)
            {
                probation.removeFirst()
            } else {
                probation.remove(at: probationIndex)
            }
        }
    }

    private mutating func evictLeastValuable() {
        if !probation.isEmpty {
            probation.removeFirst()
        } else if !protected.isEmpty {
            protected.removeFirst()
        } else if !window.isEmpty {
            window.removeFirst()
        } else {
            preconditionFailure("Reference W-TinyLFU has no victim")
        }
    }

    private static func cost(of entries: [QueueEntry]) -> Int {
        entries.reduce(0) { $0 + $1.cost }
    }
}

private struct ReferenceS3FIFO {
    private let maximumCost: Int
    private let smallCapacity: Int
    private let mainCapacity: Int
    private let ghostCapacity: Int

    private var small: [QueueEntry] = []
    private var main: [QueueEntry] = []
    private var ghost: [QueueEntry] = []

    init(maximumCost: Int) {
        self.maximumCost = maximumCost
        self.smallCapacity = max(1, Int(Double(maximumCost) * 0.10))
        self.mainCapacity = maximumCost - smallCapacity
        self.ghostCapacity = mainCapacity
    }

    mutating func request(key: UInt64, cost: Int) -> Bool {
        if Self.incrementFrequency(for: key, in: &small) {
            return true
        }

        if Self.incrementFrequency(for: key, in: &main) {
            return true
        }

        let ghostIndex = ghost.firstIndex(where: { $0.key == key })
        let wasGhostHit = ghostIndex.map { ghost.remove(at: $0) } != nil

        guard cost < smallCapacity else {
            return false
        }

        while residentCost > maximumCost - cost {
            evictOne()
        }

        let entry = QueueEntry(key: key, cost: cost, frequency: 0)
        if wasGhostHit {
            main.append(entry)
        } else {
            small.append(entry)
        }

        return false
    }

    var debugState: S3FIFOHitRateCache.DebugState {
        S3FIFOHitRateCache.DebugState(
            small: small,
            main: main,
            ghost: ghost
        )
    }

    private var residentCost: Int {
        Self.cost(of: small) + Self.cost(of: main)
    }

    private static func incrementFrequency(
        for key: UInt64,
        in entries: inout [QueueEntry]
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            return false
        }

        entries[index].frequency = min(entries[index].frequency + 1, 3)
        return true
    }

    private mutating func evictOne() {
        if Self.cost(of: main) > mainCapacity || small.isEmpty {
            evictFromMain()
        } else {
            evictFromSmall()
        }
    }

    private mutating func evictFromSmall() {
        while !small.isEmpty {
            let candidate = small.removeFirst()

            if candidate.frequency >= 2 {
                main.append(
                    QueueEntry(
                        key: candidate.key,
                        cost: candidate.cost,
                        frequency: 0
                    )
                )
            } else {
                appendToGhost(candidate)
                return
            }
        }
    }

    private mutating func evictFromMain() {
        while !main.isEmpty {
            var candidate = main.removeFirst()

            if candidate.frequency > 0 {
                candidate.frequency = min(candidate.frequency, 3) - 1
                main.append(candidate)
            } else {
                return
            }
        }

        preconditionFailure("Reference S3-FIFO has no victim")
    }

    private mutating func appendToGhost(_ candidate: QueueEntry) {
        guard candidate.cost <= ghostCapacity else {
            return
        }

        while Self.cost(of: ghost) > ghostCapacity - candidate.cost {
            ghost.removeFirst()
        }

        ghost.append(
            QueueEntry(
                key: candidate.key,
                cost: candidate.cost,
                frequency: 0
            )
        )
    }

    private static func cost(of entries: [QueueEntry]) -> Int {
        entries.reduce(0) { $0 + $1.cost }
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}

private enum SelfChecks {
    static func run() {
        checkLRUAgainstModel()
        checkSIEVEAgainstModel()
        checkSLRUAgainstModel()
        checkWindowTinyLFUAgainstModel()
        checkS3FIFOAgainstModel()
    }

    private static func checkLRUAgainstModel() {
        var optimized = LRUHitRateCache(maximumCost: 50)
        var reference = ReferenceLRU(maximumCost: 50)
        var generator = SeededGenerator(seed: 0xC0FFEE)

        for step in 0..<20_000 {
            let key = generator.next() % 100
            let cost = Int(generator.next() % 7) + 1
            let optimizedHit = optimized.request(key: key, cost: cost)
            let referenceHit = reference.request(key: key, cost: cost)

            precondition(
                optimizedHit == referenceHit,
                "LRU hit mismatch at step \(step)"
            )
            precondition(
                optimized.debugEntries == reference.debugEntries,
                "LRU state mismatch at step \(step)"
            )
        }
    }

    private static func checkSLRUAgainstModel() {
        var optimized = SLRUHitRateCache(
            maximumCost: 100,
            segmentCount: 4
        )
        var reference = ReferenceSLRU(
            maximumCost: 100,
            segmentCount: 4
        )
        var generator = SeededGenerator(seed: 0x51_2A_4B)

        for step in 0..<20_000 {
            let key = generator.next() % 150
            let cost = Int(generator.next() % 12) + 1
            let optimizedHit = optimized.request(key: key, cost: cost)
            let referenceHit = reference.request(key: key, cost: cost)

            precondition(
                optimizedHit == referenceHit,
                "SLRU hit mismatch at step \(step)"
            )
            precondition(
                optimized.debugState == reference.debugState,
                "SLRU state mismatch at step \(step)"
            )
        }
    }

    private static func checkSIEVEAgainstModel() {
        var optimized = SIEVEHitRateCache(maximumCost: 100)
        var reference = ReferenceSIEVE(maximumCost: 100)
        var generator = SeededGenerator(seed: 0x51_E7_E)

        for step in 0..<20_000 {
            let key = generator.next() % 150
            let cost = Int(generator.next() % 12) + 1
            let optimizedHit = optimized.request(key: key, cost: cost)
            let referenceHit = reference.request(key: key, cost: cost)

            precondition(
                optimizedHit == referenceHit,
                "SIEVE hit mismatch at step \(step)"
            )
            precondition(
                optimized.debugState == reference.debugState,
                "SIEVE state mismatch at step \(step)"
            )
        }
    }

    private static func checkS3FIFOAgainstModel() {
        var optimized = S3FIFOHitRateCache(maximumCost: 100)
        var reference = ReferenceS3FIFO(maximumCost: 100)
        var generator = SeededGenerator(seed: 0x53F1F0)

        for step in 0..<20_000 {
            let key = generator.next() % 150
            let cost = Int(generator.next() % 8) + 1
            let optimizedHit = optimized.request(key: key, cost: cost)
            let referenceHit = reference.request(key: key, cost: cost)

            precondition(
                optimizedHit == referenceHit,
                "S3-FIFO hit mismatch at step \(step)"
            )
            precondition(
                optimized.debugState == reference.debugState,
                "S3-FIFO state mismatch at step \(step)"
            )
        }
    }

    private static func checkWindowTinyLFUAgainstModel() {
        var optimized = WindowTinyLFUHitRateCache(
            maximumCost: 100,
            sketchCapacity: 32,
            windowFraction: 0.10,
            protectedFraction: 0.80
        )
        var reference = ReferenceWindowTinyLFU(
            maximumCost: 100,
            sketchCapacity: 32,
            windowFraction: 0.10,
            protectedFraction: 0.80
        )
        var generator = SeededGenerator(seed: 0x71_1F_1F)

        for step in 0..<20_000 {
            let key = generator.next() % 150
            let cost = Int(generator.next() % 12) + 1
            let optimizedHit = optimized.request(key: key, cost: cost)
            let referenceHit = reference.request(key: key, cost: cost)

            precondition(
                optimizedHit == referenceHit,
                "W-TinyLFU hit mismatch at step \(step)"
            )
            precondition(
                optimized.debugState == reference.debugState,
                "W-TinyLFU state mismatch at step \(step)"
            )
            precondition(
                optimized.estimatedFrequency(of: key)
                    == reference.estimatedFrequency(of: key),
                "W-TinyLFU sketch mismatch at step \(step)"
            )
        }
    }
}

private enum TraceLoader {
    static func load(
        at path: String,
        format: TraceFormat,
        limit: Int?
    ) throws -> [TraceRequest] {
        switch format {
        case .csv:
            try loadCSV(at: path, limit: limit)
        case .oracleGeneral:
            try loadOracleGeneral(at: path, limit: limit)
        }
    }

    private static func loadCSV(
        at path: String,
        limit: Int?
    ) throws -> [TraceRequest] {
        let data = try Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe
        )
        var requests: [TraceRequest] = []
        requests.reserveCapacity(min(limit ?? (data.count / 32), 10_000_000))

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var column = 0
            var number: UInt64 = 0
            var key: UInt64 = 0
            var size = 0
            var lineIsComment = false
            var atLineStart = true
            var index = 0

            func appendRequestIfComplete() {
                guard !lineIsComment, column >= 3 else {
                    return
                }

                requests.append(
                    TraceRequest(
                        key: key,
                        size: max(size, 1)
                    )
                )
            }

            while index < bytes.count {
                if let limit, requests.count >= limit {
                    break
                }

                let byte = bytes[index]

                if atLineStart && byte == 35 {
                    lineIsComment = true
                }

                if byte == 10 {
                    appendRequestIfComplete()
                    column = 0
                    number = 0
                    key = 0
                    size = 0
                    lineIsComment = false
                    atLineStart = true
                    index += 1
                    continue
                }

                atLineStart = false

                if !lineIsComment {
                    if byte >= 48, byte <= 57 {
                        number = number * 10 + UInt64(byte - 48)
                    } else if byte == 44 {
                        if column == 1 {
                            key = number
                        } else if column == 2 {
                            size = Int(number)
                        }

                        column += 1
                        number = 0
                    }
                }

                index += 1
            }

            if index == bytes.count,
               limit.map({ requests.count < $0 }) ?? true
            {
                appendRequestIfComplete()
            }
        }

        return requests
    }

    private static func loadOracleGeneral(
        at path: String,
        limit: Int?
    ) throws -> [TraceRequest] {
        let data = try Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe
        )
        let recordSize = 24
        var requests: [TraceRequest] = []
        requests.reserveCapacity(min(limit ?? (data.count / recordSize), 10_000_000))

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var offset = 0

            while offset + recordSize <= bytes.count {
                if let limit, requests.count >= limit {
                    break
                }

                let key = readUInt64LittleEndian(bytes, offset: offset + 4)
                let size = Int(
                    readUInt32LittleEndian(bytes, offset: offset + 12)
                )

                if size > 0 {
                    requests.append(TraceRequest(key: key, size: size))
                }

                offset += recordSize
            }
        }

        return requests
    }

    private static func readUInt32LittleEndian(
        _ bytes: UnsafeBufferPointer<UInt8>,
        offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64LittleEndian(
        _ bytes: UnsafeBufferPointer<UInt8>,
        offset: Int
    ) -> UInt64 {
        UInt64(bytes[offset])
            | (UInt64(bytes[offset + 1]) << 8)
            | (UInt64(bytes[offset + 2]) << 16)
            | (UInt64(bytes[offset + 3]) << 24)
            | (UInt64(bytes[offset + 4]) << 32)
            | (UInt64(bytes[offset + 5]) << 40)
            | (UInt64(bytes[offset + 6]) << 48)
            | (UInt64(bytes[offset + 7]) << 56)
    }
}

private struct TraceFootprint {
    let objectCount: Int
    let byteCount: UInt64

    init(requests: [TraceRequest]) {
        var objectSizes: [UInt64: Int] = [:]
        objectSizes.reserveCapacity(requests.count / 4)

        for request in requests {
            objectSizes[request.key] = request.size
        }

        objectCount = objectSizes.count
        byteCount = objectSizes.values.reduce(into: 0) {
            $0 += UInt64($1)
        }
    }

    func cost(for mode: CapacityMode) -> UInt64 {
        switch mode {
        case .objects:
            UInt64(objectCount)
        case .bytes:
            byteCount
        }
    }
}

private struct ComparisonResult {
    let lru: PolicyResult
    let sieve: PolicyResult
    let slru: PolicyResult
    let windowTinyLFU: PolicyResult
    let s3fifo: PolicyResult
}

private struct PolicyResult {
    let metrics: HitRateMetrics
    let medianNanosecondsPerRequest: Double

    var requestsPerSecond: Double {
        guard medianNanosecondsPerRequest > 0 else {
            return 0
        }

        return 1_000_000_000 / medianNanosecondsPerRequest
    }
}

private func replay<Policy: HitRatePolicy>(
    requests: [TraceRequest],
    mode: CapacityMode,
    timingRuns: Int,
    makePolicy: () -> Policy
) -> PolicyResult {
    precondition(!requests.isEmpty)
    precondition(timingRuns > 0)

    var expectedMetrics: HitRateMetrics?
    var nanosecondsPerRequest: [Double] = []
    nanosecondsPerRequest.reserveCapacity(timingRuns)

    for run in 0..<timingRuns {
        var policy = makePolicy()
        var metrics = HitRateMetrics()
        let start = DispatchTime.now().uptimeNanoseconds

        for request in requests {
            let policyCost = mode.policyCost(for: request)
            let hit = policy.request(key: request.key, cost: policyCost)
            metrics.record(hit: hit, requestSize: request.size)
        }

        let end = DispatchTime.now().uptimeNanoseconds
        nanosecondsPerRequest.append(
            Double(end - start) / Double(requests.count)
        )

        if let expectedMetrics {
            precondition(
                metrics == expectedMetrics,
                "Policy metrics changed during timing run \(run + 1)"
            )
        } else {
            expectedMetrics = metrics
        }
    }

    let sorted = nanosecondsPerRequest.sorted()
    let middle = sorted.count / 2
    let median: Double

    if sorted.count.isMultiple(of: 2) {
        median = (sorted[middle - 1] + sorted[middle]) / 2
    } else {
        median = sorted[middle]
    }

    return PolicyResult(
        metrics: expectedMetrics!,
        medianNanosecondsPerRequest: median
    )
}

private func simulate(
    requests: [TraceRequest],
    maximumCost: Int,
    mode: CapacityMode,
    slruSegmentCount: Int,
    sketchCapacity: Int,
    windowTinyLFUWindowFraction: Double,
    windowTinyLFUProtectedFraction: Double,
    timingRuns: Int
) -> ComparisonResult {
    let lru = replay(
        requests: requests,
        mode: mode,
        timingRuns: timingRuns
    ) {
        LRUHitRateCache(maximumCost: maximumCost)
    }
    let sieve = replay(
        requests: requests,
        mode: mode,
        timingRuns: timingRuns
    ) {
        SIEVEHitRateCache(maximumCost: maximumCost)
    }
    let slru = replay(
        requests: requests,
        mode: mode,
        timingRuns: timingRuns
    ) {
        SLRUHitRateCache(
            maximumCost: maximumCost,
            segmentCount: slruSegmentCount
        )
    }
    let windowTinyLFU = replay(
        requests: requests,
        mode: mode,
        timingRuns: timingRuns
    ) {
        WindowTinyLFUHitRateCache(
            maximumCost: maximumCost,
            sketchCapacity: sketchCapacity,
            windowFraction: windowTinyLFUWindowFraction,
            protectedFraction: windowTinyLFUProtectedFraction
        )
    }
    let s3fifo = replay(
        requests: requests,
        mode: mode,
        timingRuns: timingRuns
    ) {
        S3FIFOHitRateCache(maximumCost: maximumCost)
    }

    return ComparisonResult(
        lru: lru,
        sieve: sieve,
        slru: slru,
        windowTinyLFU: windowTinyLFU,
        s3fifo: s3fifo
    )
}

private struct Configuration {
    let tracePath: String
    let traceFormat: TraceFormat
    let ratios: [Double]
    let absoluteCapacities: [UInt64]?
    let modes: [CapacityMode]
    let slruSegmentCount: Int
    let windowTinyLFUWindowFraction: Double
    let windowTinyLFUProtectedFraction: Double
    let timingRuns: Int
    let limit: Int?

    static func parse(arguments: [String]) throws -> Configuration? {
        if arguments.contains("--help") || arguments.contains("-h") {
            return nil
        }

        guard let bundledTraceURL = Bundle.module.url(
            forResource: "smoke",
            withExtension: "csv",
            subdirectory: "fixtures"
        ) else {
            throw BenchmarkError.bundledSmokeTraceMissing
        }

        var tracePath = bundledTraceURL.path
        var usesBundledSmokeTrace = true
        var capacityWasSpecified = false
        var traceFormat: TraceFormat?
        var ratios = [0.001, 0.01, 0.1]
        var absoluteCapacities: [UInt64]?
        var modes = CapacityMode.allCases
        var slruSegmentCount = 4
        var windowTinyLFUWindowFraction = 0.01
        var windowTinyLFUProtectedFraction = 0.80
        var timingRuns = 3
        var limit: Int?
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--trace":
                tracePath = try value(after: argument, at: &index, in: arguments)
                usesBundledSmokeTrace = false
            case "--format":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let parsed = TraceFormat(rawValue: raw) else {
                    throw BenchmarkError.invalidFormat(raw)
                }
                traceFormat = parsed
            case "--ratios":
                capacityWasSpecified = true
                let raw = try value(after: argument, at: &index, in: arguments)
                ratios = raw.split(separator: ",").compactMap {
                    Double($0.trimmingCharacters(in: .whitespaces))
                }
                guard !ratios.isEmpty,
                      ratios.allSatisfy({ $0 > 0 && $0 <= 1 })
                else {
                    throw BenchmarkError.invalidRatios(raw)
                }
                absoluteCapacities = nil
            case "--capacities":
                capacityWasSpecified = true
                let raw = try value(after: argument, at: &index, in: arguments)
                let parsed = raw.split(separator: ",").compactMap {
                    UInt64($0.trimmingCharacters(in: .whitespaces))
                }
                guard !parsed.isEmpty, parsed.allSatisfy({ $0 >= 10 }) else {
                    throw BenchmarkError.invalidCapacities(raw)
                }
                absoluteCapacities = parsed.sorted()
            case "--mode":
                let raw = try value(after: argument, at: &index, in: arguments)
                if raw == "both" {
                    modes = CapacityMode.allCases
                } else if let mode = CapacityMode(rawValue: raw) {
                    modes = [mode]
                } else {
                    throw BenchmarkError.invalidMode(raw)
                }
            case "--slru-segments":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let parsed = Int(raw), parsed >= 2, parsed <= 16 else {
                    throw BenchmarkError.invalidSLRUSegmentCount(raw)
                }
                slruSegmentCount = parsed
            case "--wtinylfu-window":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let parsed = Double(raw), parsed > 0, parsed < 1 else {
                    throw BenchmarkError.invalidWTinyLFUFraction(
                        option: argument,
                        value: raw
                    )
                }
                windowTinyLFUWindowFraction = parsed
            case "--wtinylfu-protected":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let parsed = Double(raw), parsed > 0, parsed < 1 else {
                    throw BenchmarkError.invalidWTinyLFUFraction(
                        option: argument,
                        value: raw
                    )
                }
                windowTinyLFUProtectedFraction = parsed
            case "--timing-runs":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let parsed = Int(raw), parsed >= 1, parsed <= 20 else {
                    throw BenchmarkError.invalidTimingRuns(raw)
                }
                timingRuns = parsed
            case "--limit":
                let raw = try value(after: argument, at: &index, in: arguments)
                guard let parsed = Int(raw), parsed > 0 else {
                    throw BenchmarkError.invalidLimit(raw)
                }
                limit = parsed
            default:
                throw BenchmarkError.unknownArgument(argument)
            }

            index += 1
        }

        let inferredFormat: TraceFormat =
            tracePath.hasSuffix(".bin") ? .oracleGeneral : .csv

        let effectiveAbsoluteCapacities =
            usesBundledSmokeTrace && !capacityWasSpecified
            ? [10, 20, 40]
            : absoluteCapacities

        return Configuration(
            tracePath: tracePath,
            traceFormat: traceFormat ?? inferredFormat,
            ratios: ratios.sorted(),
            absoluteCapacities: effectiveAbsoluteCapacities,
            modes: modes,
            slruSegmentCount: slruSegmentCount,
            windowTinyLFUWindowFraction: windowTinyLFUWindowFraction,
            windowTinyLFUProtectedFraction: windowTinyLFUProtectedFraction,
            timingRuns: timingRuns,
            limit: limit
        )
    }

    private static func value(
        after option: String,
        at index: inout Int,
        in arguments: [String]
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw BenchmarkError.missingValue(option)
        }

        return arguments[index]
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case bundledSmokeTraceMissing
    case invalidCapacities(String)
    case invalidFormat(String)
    case invalidLimit(String)
    case invalidMode(String)
    case invalidRatios(String)
    case invalidSLRUSegmentCount(String)
    case invalidTimingRuns(String)
    case invalidWTinyLFUFraction(option: String, value: String)
    case missingValue(String)
    case traceTooSmall(mode: CapacityMode, ratio: Double, capacity: UInt64)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .bundledSmokeTraceMissing:
            "Bundled smoke trace is missing"
        case .invalidCapacities(let value):
            "Invalid absolute capacities: \(value)"
        case .invalidFormat(let value):
            "Invalid format '\(value)'; expected csv or oracle-general"
        case .invalidLimit(let value):
            "Invalid request limit: \(value)"
        case .invalidMode(let value):
            "Invalid mode '\(value)'; expected objects, bytes, or both"
        case .invalidRatios(let value):
            "Invalid capacity ratios: \(value)"
        case .invalidSLRUSegmentCount(let value):
            "Invalid SLRU segment count '\(value)'; expected 2 through 16"
        case .invalidTimingRuns(let value):
            "Invalid timing run count '\(value)'; expected 1 through 20"
        case .invalidWTinyLFUFraction(let option, let value):
            "Invalid \(option) fraction '\(value)'; expected a value between 0 and 1"
        case .missingValue(let option):
            "Missing value after \(option)"
        case .traceTooSmall(let mode, let ratio, let capacity):
            "Capacity \(capacity) for \(mode.rawValue) at ratio \(ratio) is below 10"
        case .unknownArgument(let argument):
            "Unknown argument: \(argument)"
        }
    }
}

private func printUsage() {
    print(
        """
        Usage:
          swift run -c release PolicyHitRateBenchmark [options]

        Options:
          --trace PATH       CSV or oracleGeneral binary trace
                             (default: bundled smoke trace)
          --format FORMAT    csv or oracle-general (normally inferred)
          --ratios LIST      Footprint ratios (default: 0.001,0.01,0.1)
          --capacities LIST  Absolute capacities instead of ratios
                             (smoke default: 10,20,40)
          --mode MODE        objects, bytes, or both (default: both)
          --slru-segments N  Equal SLRU segments (default: 4)
          --wtinylfu-window FRACTION
                             Admission-window share (default: 0.01)
          --wtinylfu-protected FRACTION
                             Protected share of main (default: 0.80)
          --timing-runs N    Independent serial replays per policy (default: 3)
          --limit COUNT      Read only the first COUNT requests
          --help             Show this help
        """
    )
}

private func formattedBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(bytes))
}

private func formattedRate(_ value: Double) -> String {
    String(format: "%.4f%%", value * 100)
}

private func formattedNanoseconds(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func formattedThroughput(_ value: Double) -> String {
    String(format: "%.0f", value)
}

private func formattedMetrics(_ result: PolicyResult) -> String {
    let metrics = result.metrics

    return "\(formattedRate(metrics.objectHitRate))\t"
        + "\(formattedRate(metrics.byteHitRate))\t"
        + "\(metrics.requestMisses)\t\(metrics.missedBytes)\t"
        + "\(formattedNanoseconds(result.medianNanosecondsPerRequest))\t"
        + formattedThroughput(result.requestsPerSecond)
}

private func run(_ configuration: Configuration) throws {
    SelfChecks.run()
    print("self-checks: passed")
    print("loading: \(configuration.tracePath)")

    let requests = try TraceLoader.load(
        at: configuration.tracePath,
        format: configuration.traceFormat,
        limit: configuration.limit
    )
    let footprint = TraceFootprint(requests: requests)

    print("requests: \(requests.count)")
    print(
        "footprint: \(footprint.objectCount) objects, "
            + "\(footprint.byteCount) bytes (\(formattedBytes(footprint.byteCount)))"
    )
    print(
        "timing: \(configuration.timingRuns) independent serial replay(s) "
            + "per policy; median of average ns/request"
    )

    for mode in configuration.modes {
        print("")
        print("capacity mode: \(mode.rawValue)")
        print(
            "size\tcapacity\tpolicy\tobject hit\tbyte hit"
                + "\tobject misses\tmissed bytes"
                + "\tmedian ns/request\trequests/s"
        )

        let capacities: [(label: String, value: UInt64)]
        if let absoluteCapacities = configuration.absoluteCapacities {
            capacities = absoluteCapacities.map { ("absolute", $0) }
        } else {
            capacities = configuration.ratios.map { ratio in
                (
                    String(ratio),
                    UInt64(Double(footprint.cost(for: mode)) * ratio)
                )
            }
        }

        for capacitySpec in capacities {
            let rawCapacity = capacitySpec.value
            guard rawCapacity >= max(10, UInt64(configuration.slruSegmentCount))
            else {
                throw BenchmarkError.traceTooSmall(
                    mode: mode,
                    ratio: 0,
                    capacity: rawCapacity
                )
            }
            guard rawCapacity <= UInt64(Int.max) else {
                preconditionFailure("Capacity does not fit in Int")
            }

            let capacity = Int(rawCapacity)
            let sketchCapacity: Int

            switch mode {
            case .objects:
                sketchCapacity = capacity
            case .bytes:
                let averageObjectSize =
                    Double(footprint.byteCount)
                        / Double(footprint.objectCount)
                sketchCapacity = max(
                    1,
                    Int(Double(capacity) / averageObjectSize)
                )
            }

            let result = simulate(
                requests: requests,
                maximumCost: capacity,
                mode: mode,
                slruSegmentCount: configuration.slruSegmentCount,
                sketchCapacity: sketchCapacity,
                windowTinyLFUWindowFraction:
                    configuration.windowTinyLFUWindowFraction,
                windowTinyLFUProtectedFraction:
                    configuration.windowTinyLFUProtectedFraction,
                timingRuns: configuration.timingRuns
            )
            let displayCapacity: String

            switch mode {
            case .objects:
                displayCapacity = "\(capacity)"
            case .bytes:
                displayCapacity =
                    "\(capacity) (\(formattedBytes(UInt64(capacity))))"
            }

            print(
                "\(capacitySpec.label)\t\(displayCapacity)\tLRU\t"
                    + formattedMetrics(result.lru)
            )
            print(
                "\(capacitySpec.label)\t\(displayCapacity)\tSIEVE\t"
                    + formattedMetrics(result.sieve)
            )
            print(
                "\(capacitySpec.label)\t\(displayCapacity)\t"
                    + "SLRU-\(configuration.slruSegmentCount)\t"
                    + formattedMetrics(result.slru)
            )
            print(
                "\(capacitySpec.label)\t\(displayCapacity)\tW-TinyLFU\t"
                    + formattedMetrics(result.windowTinyLFU)
            )
            print(
                "\(capacitySpec.label)\t\(displayCapacity)\tS3-FIFO\t"
                    + formattedMetrics(result.s3fifo)
            )
        }
    }
}

do {
    if let configuration = try Configuration.parse(
        arguments: CommandLine.arguments
    ) {
        try run(configuration)
    } else {
        printUsage()
    }
} catch {
    let message = "error: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    printUsage()
    exit(EXIT_FAILURE)
}
