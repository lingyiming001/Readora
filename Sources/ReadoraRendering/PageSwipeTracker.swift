public struct PageSwipeTracker: Sendable {
    private enum Axis: Sendable { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var x = 0.0, y = 0.0
    public init() {}
    public mutating func reset() { self = Self() }
    /// Delay axis locking until intentional movement, so initial finger jitter
    /// neither turns a page during vertical scrolling nor rejects a real swipe.
    public mutating func update(x deltaX: Double, y deltaY: Double) -> Double? {
        x += deltaX; y += deltaY
        if axis == .undecided {
            if abs(x) >= 6, abs(x) > abs(y) * 1.2 { axis = .horizontal }
            else if abs(y) >= 6, abs(y) > abs(x) * 1.2 { axis = .vertical }
        }
        return axis == .horizontal ? x : nil
    }
}
