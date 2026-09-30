import Foundation
import CoreGraphics

/// The geometry of drag-to-create on the time grid (#687 round 3), as pure
/// functions so every rule is unit-tested without a gesture.
///
/// Everything here works in MINUTES AFTER THE DAY'S START, from 0 to 1440.
/// A point in a day column maps to a minute by `hourHeight` points per hour.
///
/// The rules, the Google Calendar ones:
/// - The press point is snapped DOWN to the step, so a press anywhere inside
///   the 2:00 to 2:15 row starts the draft at 2:00.
/// - Dragging down moves the END: it snaps to the nearest step, and it is never
///   less than one step past the start.
/// - Dragging up past the press point moves the START instead: the draft then
///   runs from the snapped pointer up to the end of the press point's step.
/// - Everything is clamped to the day: never before 0:00, never after 24:00.
/// - A click or tap with no drag makes a draft of `tapMinutes` (30).
enum PlannerDragGeometry {
    static let step = 15
    static let tapMinutes = 30
    static let dayMinutes = 24 * 60
    /// Points of travel before a mouse press counts as a drag, not a click.
    static let dragThreshold: CGFloat = 4

    struct Range: Equatable, Sendable {
        let start: Int
        let end: Int
        var minutes: Int { end - start }
    }

    /// The minute a y position stands for, clamped to the day. Not snapped.
    static func minute(atY y: CGFloat, hourHeight: CGFloat) -> Double {
        guard hourHeight > 0 else { return 0 }
        return min(Double(dayMinutes), max(0, Double(y / hourHeight) * 60))
    }

    static func floorToStep(_ m: Double, step: Int = step) -> Int {
        Int((m / Double(step)).rounded(.down)) * step
    }

    static func nearestStep(_ m: Double, step: Int = step) -> Int {
        Int((m / Double(step)).rounded()) * step
    }

    /// The draft range while the pointer is at `currentY`, for a press at `anchorY`.
    static func range(anchorY: CGFloat, currentY: CGFloat, hourHeight: CGFloat, step: Int = step) -> Range {
        let anchor = min(dayMinutes - step, floorToStep(minute(atY: anchorY, hourHeight: hourHeight), step: step))
        let current = nearestStep(minute(atY: currentY, hourHeight: hourHeight), step: step)
        if current > anchor {
            // Down: the end follows the pointer, at least one step long.
            return Range(start: anchor, end: min(dayMinutes, max(anchor + step, current)))
        }
        // Up (or not moved past the anchor's own step): the start follows the
        // pointer, and the end holds at the bottom of the press point's step.
        let start = max(0, min(current, anchor))
        return Range(start: start, end: min(dayMinutes, max(anchor + step, start + step)))
    }

    /// The draft a click or tap with no drag makes: `tapMinutes` from the
    /// press point snapped down, pulled back so it never runs past midnight.
    static func tapRange(atY y: CGFloat, hourHeight: CGFloat, length: Int = tapMinutes, step: Int = step) -> Range {
        let start = floorToStep(minute(atY: y, hourHeight: hourHeight), step: step)
        let clampedStart = max(0, min(start, dayMinutes - length))
        return Range(start: clampedStart, end: clampedStart + length)
    }

    /// The instants a range stands for on a day.
    static func dates(_ range: Range, dayStart: Date) -> (start: Date, end: Date) {
        (dayStart.addingTimeInterval(TimeInterval(range.start * 60)),
         dayStart.addingTimeInterval(TimeInterval(range.end * 60)))
    }

    /// True once a mouse press has moved far enough to be a drag.
    static func isDrag(from a: CGPoint, to b: CGPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) >= dragThreshold
    }

    // MARK: Resize (#687 fix)

    /// The new end of a tile whose bottom edge was dragged by `deltaY` points.
    ///
    /// The end snaps to the nearest quarter hour of the day, is never less than
    /// 15 minutes after the start (even when the start is off the grid, say
    /// 9:05), and never runs past midnight. Minutes are after the day's start.
    ///
    /// `previous` is the end shown a moment ago. With it, the end only moves
    /// to another quarter hour once the pointer is `hysteresis` points past
    /// the half-way line between the two, so a hand resting near the line
    /// does not make the tile flicker between them (#687 round 5).
    static func resizedEnd(
        start: Int, originalEnd: Int, deltaY: CGFloat, hourHeight: CGFloat,
        previous: Int? = nil, hysteresis: CGFloat = 3, step: Int = step
    ) -> Int {
        guard hourHeight > 0 else { return max(originalEnd, start + step) }
        let raw = Double(originalEnd) + Double(deltaY / hourHeight) * 60
        var snapped = nearestStep(raw, step: step)
        if let previous, snapped != previous {
            let margin = Double(hysteresis / hourHeight) * 60
            if abs(raw - Double(previous)) < Double(step) / 2 + margin { snapped = previous }
        }
        return min(dayMinutes, max(start + step, snapped))
    }

    /// Minutes after `dayStart` for an instant (may be negative or past 1440
    /// for an instant on another day).
    static func minutes(of date: Date, dayStart: Date) -> Int {
        Int((date.timeIntervalSince(dayStart) / 60).rounded())
    }

    // MARK: Drop a task (#687 fix)

    /// Where a task dropped at `y` lands: the drop point snapped DOWN to the
    /// quarter hour, for the task's `length`, pulled back so it never runs
    /// past midnight. The same rule as a plain click (`tapRange`), with the
    /// task's own length.
    static func dropRange(atY y: CGFloat, hourHeight: CGFloat, length: Int, step: Int = step) -> Range {
        tapRange(atY: y, hourHeight: hourHeight, length: max(step, min(length, dayMinutes)), step: step)
    }
}
