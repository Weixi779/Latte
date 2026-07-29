//
//  FileCacheWallClock.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

import Foundation

package protocol FileCacheWallClock: Sendable {
    func now() -> Date
}

package struct SystemFileCacheWallClock: FileCacheWallClock {
    package init() {}

    package func now() -> Date {
        Date()
    }
}
