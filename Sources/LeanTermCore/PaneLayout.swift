import Foundation

/// The arrangement of split panes inside one window: a binary tree whose leaves are pane ids.
/// Pure value type so it can be tested and persisted.
public indirect enum PaneLayout: Codable, Equatable, Sendable {
    /// `horizontal` places the two children side by side, `vertical` stacks them (first on top).
    public enum Axis: String, Codable, Sendable { case horizontal, vertical }
    public enum Direction: Sendable { case left, right, up, down }

    case pane(UUID)
    case split(axis: Axis, ratio: Double, first: PaneLayout, second: PaneLayout)

    /// Divider positions stay inside this range of their split.
    public static let ratioRange = 0.05...0.95

    /// Every pane id, in reading order (first child before second).
    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    public func contains(_ id: UUID) -> Bool { paneIDs.contains(id) }

    /// Puts `new` after `id` along `axis`, sharing the pane's space equally.
    public func splitting(_ id: UUID, with new: UUID, axis: Axis) -> PaneLayout {
        switch self {
        case .pane(let existing):
            existing == id ? .split(axis: axis, ratio: 0.5, first: self, second: .pane(new)) : self
        case .split(let splitAxis, let ratio, let first, let second):
            .split(axis: splitAxis, ratio: ratio,
                   first: first.splitting(id, with: new, axis: axis), second: second.splitting(id, with: new, axis: axis))
        }
    }

    /// Removes a pane; its sibling takes the parent's place. Nil when nothing is left.
    public func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .pane(let existing):
            return existing == id ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let first = first.removing(id) else { return second }
            guard let second = second.removing(id) else { return first }
            return .split(axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    /// The first pane of the subtree next to `id`'s, or nil for a lone pane.
    public func sibling(of id: UUID) -> UUID? {
        guard case .split(_, _, let first, let second) = self else { return nil }
        if case .pane(let leaf) = first, leaf == id { return second.paneIDs.first }
        if case .pane(let leaf) = second, leaf == id { return first.paneIDs.first }
        return first.sibling(of: id) ?? second.sibling(of: id)
    }

    /// Sets the divider of the split whose second child starts with `id` (every split has a distinct one).
    public func settingRatio(_ value: Double, forSplitStartingWith id: UUID) -> PaneLayout {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        let clamped = value.isFinite ? min(max(value, Self.ratioRange.lowerBound), Self.ratioRange.upperBound) : ratio
        return .split(axis: axis, ratio: second.paneIDs.first == id ? clamped : ratio,
                      first: first.settingRatio(value, forSplitStartingWith: id),
                      second: second.settingRatio(value, forSplitStartingWith: id))
    }

    /// Gives every pane the same share along a run of same-axis splits.
    public func equalized() -> PaneLayout {
        guard case .split(let axis, _, let first, let second) = self else { return self }
        let one = Double(first.weight(along: axis))
        return .split(axis: axis, ratio: one / (one + Double(second.weight(along: axis))),
                      first: first.equalized(), second: second.equalized())
    }

    private func weight(along axis: Axis) -> Int {
        guard case .split(let splitAxis, _, let first, let second) = self, splitAxis == axis else { return 1 }
        return first.weight(along: axis) + second.weight(along: axis)
    }

    /// The pane next to `id` in a direction, judged by the layout in a unit square: the one sharing the
    /// longest edge with it, then the closest.
    public func neighbour(of id: UUID, _ direction: Direction) -> UUID? {
        let rects = frames(in: Rect(x: 0, y: 0, width: 1, height: 1))
        guard let target = rects.first(where: { $0.id == id })?.rect else { return nil }
        let epsilon = 1e-9
        var best: (id: UUID, overlap: Double, gap: Double)?
        for (other, rect) in rects.map({ ($0.id, $0.rect) }) where other != id {
            let gap: Double, overlap: Double
            switch direction {
            case .left: gap = target.minX - rect.maxX; overlap = Self.overlap(rect.minY, rect.maxY, target.minY, target.maxY)
            case .right: gap = rect.minX - target.maxX; overlap = Self.overlap(rect.minY, rect.maxY, target.minY, target.maxY)
            case .up: gap = target.minY - rect.maxY; overlap = Self.overlap(rect.minX, rect.maxX, target.minX, target.maxX)
            case .down: gap = rect.minY - target.maxY; overlap = Self.overlap(rect.minX, rect.maxX, target.minX, target.maxX)
            }
            guard gap > -epsilon, overlap > epsilon else { continue }
            if let current = best {
                if overlap < current.overlap - epsilon { continue }
                if abs(overlap - current.overlap) <= epsilon && gap >= current.gap - epsilon { continue }
            }
            best = (other, overlap, gap)
        }
        return best?.id
    }

    private static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        min(a1, b1) - max(a0, b0)
    }

    struct Rect: Equatable {
        var x, y, width, height: Double
        var minX: Double { x }
        var maxX: Double { x + width }
        var minY: Double { y }
        var maxY: Double { y + height }
    }

    func frames(in rect: Rect) -> [(id: UUID, rect: Rect)] {
        switch self {
        case .pane(let id):
            return [(id, rect)]
        case .split(let axis, let ratio, let first, let second):
            switch axis {
            case .horizontal:
                let w = rect.width * ratio
                return first.frames(in: Rect(x: rect.x, y: rect.y, width: w, height: rect.height))
                    + second.frames(in: Rect(x: rect.x + w, y: rect.y, width: rect.width - w, height: rect.height))
            case .vertical:
                let h = rect.height * ratio
                return first.frames(in: Rect(x: rect.x, y: rect.y, width: rect.width, height: h))
                    + second.frames(in: Rect(x: rect.x, y: rect.y + h, width: rect.width, height: rect.height - h))
            }
        }
    }
}
