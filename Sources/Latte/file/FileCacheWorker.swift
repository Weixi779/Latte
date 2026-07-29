//
//  FileCacheWorker.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

import Dispatch

package final class FileCacheWorker<State>: @unchecked Sendable {
    private let queue: DispatchQueue
    private var state: State

    package init(
        state: State,
        label: String = "dev.weixi.Latte.FileCacheIO"
    ) {
        self.state = state
        self.queue = DispatchQueue(label: label)
    }

    package func perform<Output: Sendable>(
        _ operation: @escaping @Sendable (inout State) throws -> Output
    ) async throws -> Output {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try operation(&state)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    package func inspect<Output: Sendable>(
        _ operation: @escaping @Sendable (State) -> Output
    ) async -> Output {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: operation(state))
            }
        }
    }
}
