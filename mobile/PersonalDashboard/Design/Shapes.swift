import SwiftUI

/// Chat user bubble: 16pt corners on TL/TR/BL, 4pt corner on BR.
/// Mirrors the webapp's `rounded-2xl rounded-br-sm`.
struct BubbleShape: Shape {
    var bigRadius: CGFloat = 16
    var smallRadius: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        let r = bigRadius
        let s = smallRadius
        var p = Path()

        // Start at top-left after the corner
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        // Top edge
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        // Top-right corner
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        // Right edge down to small corner
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - s))
        // Small bottom-right corner
        p.addArc(
            center: CGPoint(x: rect.maxX - s, y: rect.maxY - s),
            radius: s,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        // Bottom-left corner
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        // Left edge
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        // Top-left corner
        p.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
