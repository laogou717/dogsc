import Foundation

/// Small thread-safe LRU used for expensive deterministic render paths whose
/// parameter keys can change continuously while an inspector slider moves.
/// Keeping every historical parameter value turns one gesture on a long
/// recording into unbounded arrays of precomputed samples.
final class BoundedMemoizationCache<Key: Hashable, Value>: @unchecked Sendable {
    private let capacity: Int
    private let condition = NSCondition()
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []
    private var keysBeingBuilt: Set<Key> = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    func value(for key: Key, build: () -> Value) -> Value {
        if let existing = cachedValueOrClaimBuild(for: key) { return existing }
        let created = build()
        return finishBuild(created, for: key) ?? created
    }

    /// Builds a value only when the caller can finish the complete work. This
    /// is used by cancellable background prewarming: a cancelled partial result
    /// must never occupy the cache and later masquerade as a complete render
    /// path on the playback thread.
    func valueIfBuilt(for key: Key, build: () -> Value?) -> Value? {
        if let existing = cachedValueOrClaimBuild(for: key) { return existing }
        let created = build()
        return finishBuild(created, for: key)
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return values.count
    }

    /// Returns an existing value, or reserves this key for the caller. Other
    /// threads asking for the same key wait for that one build instead of
    /// independently allocating another long render path.
    private func cachedValueOrClaimBuild(for key: Key) -> Value? {
        condition.lock()
        while true {
            if let existing = values[key] {
                markRecentlyUsed(key)
                condition.unlock()
                return existing
            }
            if keysBeingBuilt.insert(key).inserted {
                condition.unlock()
                return nil
            }
            condition.wait()
        }
    }

    private func finishBuild(_ created: Value?, for key: Key) -> Value? {
        condition.lock()
        defer {
            keysBeingBuilt.remove(key)
            condition.broadcast()
            condition.unlock()
        }
        if let existing = values[key] {
            markRecentlyUsed(key)
            return existing
        }
        guard let created else { return nil }
        values[key] = created
        markRecentlyUsed(key)
        while recency.count > capacity {
            let evicted = recency.removeFirst()
            values.removeValue(forKey: evicted)
        }
        return created
    }

    private func markRecentlyUsed(_ key: Key) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}
