import Foundation
import CoreText
import CoreGraphics

// Produce portable outlined wordmarks using the system's CoreText renderer.
// No font files are redistributed and no app UI is launched.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 32, nil)

func outline(_ text: String) -> (String, Double) {
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    var paths: [String] = []
    var position: CGFloat = 0
    func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
    for (index, glyph) in glyphs.enumerated() {
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            var commands: [String] = []
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                func point(_ index: Int) -> String {
                    "\(number(element.points[index].x + position)) \(number(element.points[index].y))"
                }
                switch element.type {
                case .moveToPoint: commands.append("M" + point(0))
                case .addLineToPoint: commands.append("L" + point(0))
                case .addQuadCurveToPoint: commands.append("Q" + point(0) + " " + point(1))
                case .addCurveToPoint: commands.append("C" + point(0) + " " + point(1) + " " + point(2))
                case .closeSubpath: commands.append("Z")
                @unknown default: break
                }
            }
            paths.append(commands.joined(separator: " "))
        }
        position += advances[index].width - 0.55
    }
    return (paths.joined(separator: " "), Double(position))
}

var result: [String: [String: Any]] = [:]
for name in ["Lean Term"] {
    let (path, width) = outline(name)
    result[name] = ["path": path, "width": width, "font": "HelveticaNeue-Bold", "size": 32]
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try data.write(to: destination.appendingPathComponent("wordmark-outlines.json"))
