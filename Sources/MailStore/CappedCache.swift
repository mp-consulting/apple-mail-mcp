import Foundation

/// Recently read message files, by path, kept in memory up to `capacity` (in the units `size` measures): a message
/// file does not change (a moved message gets a new one, a body downloaded later a new name), so an entry stays
/// valid. Memory only, never written anywhere; when full, the oldest entries make room.
final class CappedCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (value: Value, size: Int)] = [:]
    private var order: [String] = []  // oldest first, from `head` on
    private var head = 0
    private var used = 0
    let capacity: Int
    private let size: (Value) -> Int

    init(capacity: Int, size: @escaping (Value) -> Int) {
        self.capacity = capacity
        self.size = size
    }

    /// The cached value for `path`, else `load`ed and kept (nil is not kept).
    func value(path: String, load: () throws -> Value?) rethrows -> Value? {
        if let known = lock.withLock({ entries[path]?.value }) { return known }
        guard let value = try load() else { return nil }
        let cost = size(value)
        lock.withLock {
            guard cost <= capacity, entries[path] == nil else { return }
            while used + cost > capacity, head < order.count {
                if let gone = entries.removeValue(forKey: order[head]) { used -= gone.size }
                head += 1
            }
            if head > 256, head * 2 > order.count {
                order.removeFirst(head)
                head = 0
            }
            entries[path] = (value, cost)
            order.append(path)
            used += cost
        }
        return value
    }

    func value(path: String, load: () throws -> Value) rethrows -> Value {
        // A loader that cannot fail to produce a value gets one back.
        try value(path: path, load: { () throws -> Value? in try load() })!
    }
}
