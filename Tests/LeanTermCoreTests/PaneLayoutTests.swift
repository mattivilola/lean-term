import Foundation
import Testing
@testable import LeanTermCore

@Test func paneLayoutSplitsRemovesNavigatesAndEqualizes() throws {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    var layout = PaneLayout.pane(a)
    layout = layout.splitting(a, with: b, axis: .horizontal)
    layout = layout.splitting(b, with: c, axis: .vertical)
    #expect(layout.paneIDs == [a, b, c])
    // a | (b over c)
    #expect(layout.neighbour(of: a, .right) == b)
    #expect(layout.neighbour(of: c, .left) == a)
    #expect(layout.neighbour(of: b, .down) == c)
    #expect(layout.neighbour(of: c, .up) == b)
    #expect(layout.neighbour(of: a, .left) == nil && layout.neighbour(of: a, .up) == nil)
    // A taller pane on the left prefers the neighbour sharing more of its edge.
    let skewed = layout.settingRatio(0.8, forSplitStartingWith: c)
    #expect(skewed.neighbour(of: a, .right) == b)
    let lower = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .pane(a),
                                 second: .split(axis: .vertical, ratio: 0.2, first: .pane(b), second: .pane(c)))
    #expect(lower.neighbour(of: a, .right) == c)
    #expect(layout.sibling(of: a) == b && layout.sibling(of: c) == b && layout.sibling(of: b) == c)
    // Removing a pane promotes its sibling.
    #expect(layout.removing(a) == .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c)))
    #expect(layout.removing(c) == .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b)))
    #expect(PaneLayout.pane(a).removing(a) == nil)
    // Ratios clamp, and equalising shares a same-axis run evenly.
    #expect(layout.settingRatio(0.99, forSplitStartingWith: b) == .split(axis: .horizontal, ratio: 0.95, first: .pane(a),
        second: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c))))
    let row = PaneLayout.pane(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: d, axis: .horizontal)
        .settingRatio(0.9, forSplitStartingWith: b)
    guard case .split(_, let ratio, _, let second) = row.equalized(), case .split(_, let inner, _, _) = second else {
        Issue.record("Expected nested splits"); return
    }
    #expect(abs(ratio - 1.0 / 3.0) < 1e-9 && abs(inner - 0.5) < 1e-9)
    // Moving takes a pane out and splits the target on the dropped side.
    #expect(layout.moving(c, to: a, edge: .left) == .split(axis: .horizontal, ratio: 0.5,
        first: .split(axis: .horizontal, ratio: 0.5, first: .pane(c), second: .pane(a)), second: .pane(b)))
    #expect(layout.moving(a, to: c, edge: .top) == .split(axis: .vertical, ratio: 0.5, first: .pane(b),
        second: .split(axis: .vertical, ratio: 0.5, first: .pane(a), second: .pane(c))))
    #expect(layout.moving(a, to: a, edge: .right) == layout && layout.moving(d, to: a, edge: .right) == layout)
    #expect(layout.moving(a, to: b, edge: .bottom).paneIDs == [b, a, c])
    // Swapping exchanges positions and keeps the shape.
    #expect(layout.swapping(a, c) == .split(axis: .horizontal, ratio: 0.5, first: .pane(c),
        second: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(a))))
    // The tree survives encoding.
    let decoded = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(row))
    #expect(decoded == row)
}
