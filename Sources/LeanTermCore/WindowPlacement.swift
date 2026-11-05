import Foundation
import CoreGraphics

/// The last active terminal window, independent of shell/session restoration.
public struct WindowPlacement: Equatable, Sendable {
    public let frame: CGRect
    private static let key = "windowFrame"

    public init?(frame: CGRect) {
        let values = [frame.minX, frame.minY, frame.width, frame.height]
        guard values.allSatisfy({ $0.isFinite && abs($0) < 10_000_000 }),
              frame.width >= 480, frame.height >= 300 else { return nil }
        self.frame = frame
    }
    public init?(defaults: UserDefaults) {
        guard let values = defaults.array(forKey: Self.key) as? [Double], values.count == 4 else { return nil }
        self.init(frame: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
    }
    public func save(to defaults: UserDefaults) {
        defaults.set([frame.minX, frame.minY, frame.width, frame.height], forKey: Self.key)
    }
    public static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "NSWindow Frame TerminalWindow")
    }

    /// Preserve visible placement; fit oversized windows and recover disconnected displays.
    public func fitted(to visibleScreens: [CGRect]) -> CGRect {
        let screens = visibleScreens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard let fallback = screens.first else { return frame }
        let best = screens.max { overlap($0) < overlap($1) } ?? fallback
        let target = overlap(best) > 0 ? best : fallback
        let width = min(frame.width, target.width)
        let height = min(frame.height, target.height)
        let x: CGFloat
        let y: CGFloat
        if overlap(target) == 0 {
            x = target.midX - width / 2; y = target.midY - height / 2
        } else {
            x = min(max(frame.minX, target.minX), target.maxX - width)
            y = min(max(frame.minY, target.minY), target.maxY - height)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    private func overlap(_ screen: CGRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
