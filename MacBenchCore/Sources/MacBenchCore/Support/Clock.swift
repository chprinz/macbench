import Foundation

/// Injectable clock. The coalescing and backfill rules are all time-based, and a
/// test that has to sleep for twenty minutes is a test nobody runs.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ start: Date = Date(timeIntervalSince1970: 1_750_000_000)) { current = start }
    public var now: Date { lock.withLock { current } }
    public func advance(by interval: TimeInterval) { lock.withLock { current += interval } }
    public func set(_ date: Date) { lock.withLock { current = date } }
}
