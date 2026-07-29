//
//  CacheStatisticsProviding.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

/// Provides a synchronous snapshot of cache statistics.
public protocol CacheStatisticsProviding {
    /// Returns the current snapshot, or `nil` when collection is disabled.
    var statistics: CacheStatistics? { get }
}

/// Provides an asynchronous snapshot of cache statistics.
public protocol AsyncCacheStatisticsProviding {
    /// Returns the current snapshot, or `nil` when collection is disabled.
    var statistics: CacheStatistics? { get async }
}
