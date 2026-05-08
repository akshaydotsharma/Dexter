import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + lock-screen presentation for the Capture App Intent.
///
/// Why it exists: when the iPhone Action Button runs the Capture
/// shortcut, iOS shows a generic "AppIcon thumbnail" treatment in the
/// Dynamic Island while the App Intent is processing. We replace that
/// with the Deks brand mark — three horizontal lines — so the user has
/// visible proof the pipeline is alive AND the surface stays continuous
/// with the AppIcon. The system Dictate Text sheet is untouched — only
/// the Dynamic Island region.
///
/// How the compact view animates:
///   iOS does NOT redraw `TimelineView(.animation)` in the compact
///   Dynamic Island slot — compact is a static snapshot. The only
///   mechanism we have for compact-view motion is `activity.update(...)`,
///   which forces a redraw on every state change. So
///   `CaptureLiveActivityController` ticks `state.animationPhase` every
///   ~500 ms while the activity is in `.processing`, and `CaptureLogoLines`
///   reads that phase to compute each line's modulated width. iOS may
///   throttle update frequency in practice — we accept whatever cadence
///   it gives us; this is best-effort.
///
/// Lifecycle is owned by `CaptureToDashboardIntent`, not the activity
/// itself. The intent starts the activity in `.processing`, updates to
/// `.complete` / `.failed` when the on-device pipeline returns, then
/// dismisses with a short fade.
struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            // Lock screen / banner presentation. Used when the device is
            // locked or when the user pulls down the banner from the
            // Dynamic Island.
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // EXPANDED — visible when the user taps + holds the
                // island. Same surfaces a system "summary card" view.
                DynamicIslandExpandedRegion(.leading) {
                    CaptureLogoLines(
                        phase: context.state.phase,
                        animationPhase: context.state.animationPhase,
                        size: .expandedLeading
                    )
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusPip(phase: context.state.phase)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // Subtle hint at the bottom — keeps the expanded card
                    // from feeling empty while the activity is short-lived.
                    Text(footerCopy(for: context.state.phase))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 2)
                }
            } compactLeading: {
                CaptureLogoLines(
                    phase: context.state.phase,
                    animationPhase: context.state.animationPhase,
                    size: .compactLeading
                )
                .padding(.leading, 4)
            } compactTrailing: {
                StatusPip(phase: context.state.phase)
                    .padding(.trailing, 4)
            } minimal: {
                // Reduced when another activity is on the trailing side.
                // Rendered inside the small system pill — the lines need
                // to hold up at ~16pt wide.
                CaptureLogoLines(
                    phase: context.state.phase,
                    animationPhase: context.state.animationPhase,
                    size: .minimal
                )
            }
            .keylineTint(.white.opacity(0.6))
            .widgetURL(URL(string: "deks://capture"))
        }
    }

    private func footerCopy(for phase: CaptureActivityAttributes.Phase) -> String {
        switch phase {
        case .processing: return "Saving on-device — no server hop."
        case .complete:   return "Saved."
        case .failed:     return "Nothing was saved."
        }
    }
}

// MARK: - Status pip

/// Small filled circle that flips colour on phase change. Acts as the
/// Dynamic Island's "trailing affordance" while the lines carry the
/// motion on the leading side.
private struct StatusPip: View {
    let phase: CaptureActivityAttributes.Phase

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 0.5)
                )
            if phase == .processing {
                Circle()
                    .stroke(fillColor.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .scaleEffect(1.2)
                    .opacity(0.6)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        switch phase {
        case .processing: return Color(red: 0.78, green: 0.74, blue: 0.45) // jade-ish
        case .complete:   return Color(red: 0.34, green: 0.78, blue: 0.45) // soft green
        case .failed:     return Color(red: 0.94, green: 0.42, blue: 0.42) // soft red
        }
    }
}

// MARK: - Lock-screen view

/// Banner / lock-screen presentation. Uses paper / ink colours that
/// match the rest of the app (see Tokens.swift) — but Tokens lives in
/// the main target only, so the values are duplicated here in a small
/// local palette. Keeping them inline avoids pulling the whole Tokens
/// file into the widget extension.
private struct LockScreenView: View {
    let state: CaptureActivityAttributes.State

    var body: some View {
        HStack(spacing: 14) {
            // Lines everywhere for visual consistency with the compact +
            // expanded island slots. The banner has the room for a richer
            // treatment, but coherence beats novelty here.
            CaptureLogoLines(
                phase: state.phase,
                animationPhase: state.animationPhase,
                size: .banner
            )
            .frame(width: 68, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(muted)
                    .textCase(.uppercase)
                    .kerning(1.4)
                Text(state.statusText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            StatusPip(phase: state.phase)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper)
    }

    private var eyebrow: String {
        switch state.phase {
        case .processing: return "Capturing to Deks"
        case .complete:   return "Captured"
        case .failed:     return "Capture failed"
        }
    }

    // Local palette mirrors Tokens.paper / Tokens.ink / Tokens.muted.
    // Live Activity surfaces don't honour the system colour scheme on
    // older OS versions, so we fix to dark-mode values to match the
    // banner appearance on a typical lock screen.
    private var paper: Color { Color(red: 0.078, green: 0.067, blue: 0.051) }
    private var ink: Color { Color(red: 0.949, green: 0.922, blue: 0.855) }
    private var muted: Color { Color(red: 0.659, green: 0.620, blue: 0.541) }
}
