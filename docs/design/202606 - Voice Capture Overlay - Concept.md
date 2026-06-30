# Voice Capture Overlay

**Concept Document — June 2026**
**Status:** For approval
**Platform:** iOS 17+ · SwiftUI
**Issue:** #150

---

> **Revision — Full-Screen / Auto-Execute (June 2026)**
>
> This revision replaces the bottom-sheet form factor (v1, 44–48% height) with a full-screen cover. The "finalize to an editable box, user taps Send" model is replaced with auto-execution on silence detection. Glass-style controls replace the earlier solid/ghost button pair. The recording animation is redesigned from the existing WaveformBars into a new InkOrb treatment. State B (editable review) is removed. All other states are carried forward and updated. Section numbering is preserved for reference continuity; changed sections are marked [REVISED].

---

## Purpose

Design spec for the AI voice capture experience on the Dexter iOS app. When the user taps the AI button, a full-screen overlay covers the current screen — whether on Notes, Lists, Tasks, Activity, or Chat — showing a recording animation, a live transcript, and auto-executing the command after ~1.5s of silence. The user returns to the exact page they started from, unchanged, after execution completes.

---

## Section 1 — Overlay Form Factor [REVISED]

### Recommendation

**Full-screen cover using `.fullScreenCover`.** The overlay replaces the sheet entirely. It presents as a full-screen modal that slides up from the bottom (system default for `fullScreenCover` on iOS), covers the entire display including the navigation bar and tab bar, and dismisses back to the originating page with no navigation side effect.

Rationale: The Google-style voice experience the user described is specifically a full-screen take-over — the context shrinks away, the voice animation becomes the hero of the moment, and there is nothing competing for attention. A 46% sheet keeps the user in two contexts simultaneously; a full-screen cover puts them fully in "voice mode." This matches the established pattern of iOS voice search (Safari), Siri full-screen, and Google Assistant. The cognitive clarity this buys outweighs the loss of visible page context, especially since the interaction is brief (typically under 10 seconds from open to auto-dismiss).

The originating page is preserved automatically: `fullScreenCover` does not push a navigation entry, so dismissing it returns to the exact scroll position and tab the user was on.

### Viable Alternative

**Bottom sheet at 72% height with suppressed drag indicator.** If user testing shows that losing the page context causes orientation confusion (the user forgets which tab they were on), revert to a tall sheet at `.fraction(0.72)`. This preserves the spatial memory of the underlying page while still giving the recording animation enough vertical room. The glass buttons and InkOrb animation described below work identically in either form factor. Prefer the full-screen cover unless testing reveals the orientation confusion problem.

### Geometry

| Property | Value | Notes |
|---|---|---|
| Presentation style | `.fullScreenCover(isPresented:)` | Slides up from bottom. System handles the spring entry animation. Covers status bar, nav bar, and tab bar. |
| Background | `Tokens.surface` (paper-white in light mode, ~#FAFAF8) | Solid, not blurred — there is nothing to blur through on a full-screen cover. The calm paper ground is the canvas for the animation. |
| Safe area handling | Respect top and bottom safe areas | Content stays within safe area insets. The animation lives in the visual center of the safe area, not the screen center, so it clears the Dynamic Island / notch. |
| Status bar style | `.dark` on the `fullScreenCover` view | Matches the ink-on-paper palette. Use `preferredColorScheme(.light)` on the cover view if the system is in dark mode and the overlay should stay paper-light — or honor dark mode if the app supports it (see dark mode note below). |
| Scrim behind | None (full-screen cover, no scrim layer needed) | The cover IS the full surface. |
| Drag to dismiss | Disabled (`interactiveDismissDisabled(true)`) | Voice state is managed explicitly. Accidental swipe should not abort a recording. Cancel is always available via the glass Cancel button. |

**Dark mode note:** If the app supports dark mode, `Tokens.surface` maps to a dark ground (approximately #1A1A18). The InkOrb animation inverts naturally — use `Tokens.paper` as the orb fill on dark ground. This doc assumes light mode as the primary case; the token system handles both without custom overrides.

---

## Section 2 — Recording Animation [REVISED]

### Recommendation: InkOrb — Breathing Ink Sphere

**Concept:** A single circular element centered in the upper two-thirds of the screen (above the transcript area). At rest, it is a filled circle in `Tokens.ink` at approximately 30% opacity — a quiet, contained shape. When the user speaks, it breathes outward, the opacity deepens toward full ink, and a soft secondary ring pulses at a larger radius. The effect reads as "a living thing listening" without the rainbow complexity of Siri or the mechanical grid of Google's 4-dot indicator.

**Why this over the alternatives:**

- Siri morphing orb: requires a rainbow gradient and complex mesh deformation — off-palette and overproduced for Dexter's monochrome restraint.
- Google 4-dot listening indicator: closely associated with Google's brand identity; would read as borrowed.
- Concentric pulse rings: works well but is purely decorative — it does not react to voice amplitude, so it feels less alive.
- WaveformBars (existing): horizontal bars work well in a compact header slot; in a full-screen context they feel small and misplaced. The InkOrb fills the vertical space with authority.

The InkOrb is reactive to audio level if feasible (using `AVAudioRecorder` metering or the `SpeechTranscriber`'s existing audio session). If amplitude metering is not available in the first implementation pass, the animation runs on a gentle autonomous rhythm (see reduce-motion note) that still feels alive.

**Geometry:**

| Property | Value |
|---|---|
| Base diameter | 120pt |
| Active diameter (max, at peak amplitude) | 160pt |
| Inner circle fill | `Tokens.ink` |
| Inner circle opacity at rest | 0.22 |
| Inner circle opacity at peak | 0.90 |
| Outer ring stroke | `Tokens.ink`, 1pt |
| Outer ring diameter at rest | 140pt (hidden, opacity 0) |
| Outer ring diameter at peak | 200pt |
| Outer ring opacity range | 0 → 0.18 (soft, does not compete with text) |
| Position | Centered horizontally; vertical center at 38% of the safe area height (upper third, breathing room above the transcript) |

**Animation curves:**

- Inner circle scale and opacity: driven by audio level. Map normalized amplitude (0.0–1.0) to scale (1.0–1.33) and opacity (0.22–0.90). Apply a low-pass filter (rolling average over the last 4 frames at 30fps) so jitter does not create strobing. Transition with `.animation(.spring(response: 0.18, dampingFraction: 0.65), value: amplitude)`.
- Outer ring: lags the inner circle by 80ms (apply with `.animation(.spring(response: 0.28, dampingFraction: 0.70).delay(0.08), value: amplitude)`). Creates a trailing echo effect.
- Autonomous rhythm (fallback when amplitude is not available, or between words during brief silence): gentle sine wave cycling the inner circle between 0.22 and 0.42 opacity and 1.0–1.08 scale on a 1.4s period. `repeatForever(autoreverses: true)` with `.easeInOut`.
- On silence detection (just before auto-execute): the orb compresses slightly (scale 0.88, duration 0.15s ease-in), then the overlay transitions to the Executing state.

**Color:**

`Tokens.ink` throughout. No gradients. No color shifts with amplitude. The depth of the ink is the signal, not hue change. This keeps the animation strictly within the app's monochrome palette.

**Reduce-motion fallback:**

When `accessibilityReduceMotion` is true: the InkOrb is a static filled circle at `Tokens.ink` 50% opacity. No scale, no outer ring, no pulse. A thin 1pt `Tokens.border` ring at 144pt diameter makes it legible as a distinct element at rest. The listening state is communicated entirely by the "Listening" label and the live transcript text appearing.

### Alternative: Concentric Pulse Rings

A fixed mic icon (SF Symbol `mic.fill`, 32pt, `Tokens.ink`) at the center, surrounded by two concentric rings that pulse outward independently:
- Ring 1: starts at 64pt diameter, expands to 96pt, fades from opacity 0.25 to 0, duration 1.2s, linear, `repeatForever`.
- Ring 2: same geometry, offset 0.6s (half-period phase shift).
- Amplitude reactivity: the ring expansion range maps to audio level (at peak, rings expand to 120pt).

This is simpler to implement but less visually differentiated from generic "recording in progress" indicators. Choose it if the InkOrb spring-driven amplitude animation proves too complex for the first ship.

---

## Section 3 — All States [REVISED]

### Layout structure (all states)

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   [status label, left-aligned, edCaption, Tokens.muted]     [Cancel glass]  │
│                                                                               │
│                                                                               │
│                                                                               │
│                       ○  ●  ○                                                │
│                    (InkOrb, 120pt)                                           │
│                                                                               │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│   Live transcript text here. Grows downward.                                 │
│   Auto-scrolls to the last word.                                             │
│                                                                               │
│                                                                               │
│                                                                               │
│                                                                               │
│                                                                               │
│                              [  Stop  glass  ]                               │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
```

The three zones are fixed:
1. **Top bar** (status label + Cancel): 52pt height, pinned to top safe area edge.
2. **Animation zone**: upper 38% of safe-area height, vertically centered on the InkOrb.
3. **Transcript zone**: lower 55% of safe-area height, separated from the animation zone by a 0.5pt `Tokens.border` divider. Scrollable if content exceeds the zone.
4. **Bottom control zone**: 80pt height above the bottom safe area edge. Contains the glass Stop button (State A) or glass Done / Cancel pair (Executing state).

---

### State A: Listening — live partial transcript

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   Listening                                              [ Cancel ]          │
│                                                                               │
│                                                                               │
│                                                                               │
│                          (  ●  )                                             │
│                     InkOrb — breathing, reactive                             │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│   Remind me to call John tomorrow                                            │
│   at 3 pm, and also pick up —|                                              │
│                                                                               │
│   (live partial. Text grows here. Scrollable if exceeds zone.)              │
│                                                                               │
│                                                                               │
│                                                                               │
│                            [ Stop Now ]                                      │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
  (full-screen cover — underlying page fully hidden)
```

**Element specs:**

| Element | Spec | Detail |
|---|---|---|
| Status label | `.edCaption`, `Tokens.muted`, left-aligned in top bar | "Listening" — one word. No pulsing danger dot (the InkOrb IS the recording indicator; a second pulsing element would compete). |
| Cancel button | Glass style (see Section 5 — Glass Controls) | Top-right of the top bar. 44pt tap target. Stops recording, discards transcript, dismisses the overlay. |
| InkOrb | 120pt base, amplitude-reactive | Positioned at vertical center of the animation zone (upper 38% of safe area). See Section 2 for full spec. |
| Divider | 0.5pt, `Tokens.border` | Separates animation zone from transcript zone. Full-width, no padding. |
| Transcript area | Scrollable, `Space.xl` horizontal padding, `Space.lg` top padding | Font: `.edBody`, color: `Tokens.ink`. Text auto-scrolls to the last word as partials arrive. Cursor blink (`|`) at end while recording. No placeholder text when empty — silence while listening is understood from context. |
| Stop Now button | Glass style, centered horizontally in bottom control zone | "Stop Now" — triggers immediate auto-execute without waiting for silence. Same behavior as the silence timer firing. See glass spec in Section 5. Min tap target 44pt. |
| Silence auto-execute | 1.5s of detected silence | When `SpeechTranscriber` emits no new words for 1.5s and the transcript is non-empty, the overlay transitions to State A1 (Safety Window), then State C (Executing). Timer resets on each new word. |

---

### State A1: Safety Window — "Executing in a moment"

This state exists for approximately 1.5s between silence detection and actual AI execution. It gives the user an escape hatch in case the transcript was wrong or the command was not intended.

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   Got it                                                 [ Cancel ]          │
│                                                                               │
│                                                                               │
│                                                                               │
│                          (  ●  )                                             │
│                     InkOrb — gently settling                                 │
│                        (compress to 0.88, hold)                              │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│   Remind me to call John tomorrow at 3 pm, and also                         │
│   pick up the groceries on the way home.                                     │
│                                                                               │
│   (transcript is now static — recording stopped)                            │
│                                                                               │
│                                                                               │
│                                                                               │
│          [ Cancel ]               ─────── executing ──────                  │
│                        (glass)        (sweeping progress bar, 1.5s)         │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
```

**Element specs:**

| Element | Spec | Detail |
|---|---|---|
| Status label | "Got it" | Cross-fades from "Listening". Signals receipt of the command without being instructional. |
| InkOrb | Settles — scale compresses to 0.88, autonomous rhythm stops | The orb holds this compressed state for the duration of the safety window, communicating that listening has ended. No outer ring. |
| Transcript | Static text, `Tokens.ink` (still fully readable) | Recording has stopped. The transcript is finalized. The cursor blink disappears. |
| Cancel button (top-right) | Glass style, remains active | Same position as State A. Tap cancels the pending execution and dismisses the overlay. This is the primary escape hatch. |
| Bottom control zone | Progress bar + secondary Cancel | A thin horizontal progress bar (1pt, `Tokens.ink` 30% opacity) sweeps from left to right over 1.5s using `.linear` timing. It indicates how much time remains before execution fires. Below or beside it: a ghost-glass "Cancel" button for the user who needs a large target. The Cancel button at the top-right is sufficient; this is a redundant affordance for ergonomics (thumb reach on large phones). |
| After 1.5s | Auto-advance to State C (Executing) | If Cancel is not tapped, execution begins automatically. |
| Haptic on entering A1 | `UIImpactFeedbackGenerator(style: .light).impactOccurred()` | Signals that listening has stopped and execution is pending. Distinct from the recording-start haptic (`.medium`) so the user can distinguish the two by feel alone. |

**Design rationale for A1 vs always-visible Cancel:**

The 1.5s safety window pattern (like "Undo Send" in Gmail) is preferable to keeping a permanent "do not execute" button visible during State A, because a permanent abort button trains the user to second-guess the system. The safety window communicates confidence ("we heard you") while still giving an escape. The window length of 1.5s is deliberate: long enough to read the transcript and make a decision, short enough to feel instant in the happy path. The user can also tap "Stop Now" during State A to skip silence detection and trigger A1 immediately.

---

### State C: Executing — AI processing [REVISED]

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   Working…                                               [ Cancel ]          │
│                                                                               │
│                                                                               │
│                                                                               │
│                          (  ●  )                                             │
│                     InkOrb — slow pulse, autonomous                          │
│                       (waiting rhythm, not reactive)                         │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│   Remind me to call John tomorrow at 3 pm, and also                         │
│   pick up the groceries on the way home.                                     │
│                                                                               │
│   ●  ●  ●   (TypingIndicator, Tokens.muted, below transcript)               │
│                                                                               │
│                                                                               │
│                                                                               │
│                                                                               │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
```

**Element specs:**

| Element | Spec | Detail |
|---|---|---|
| Status label | "Working…" | Cross-fades from "Got it". Ellipsis is the standard iOS progress idiom. |
| InkOrb | Slow autonomous pulse: 0.30–0.55 opacity, 1.0–1.10 scale, 2.0s period, `.easeInOut` | Distinct from the listening rhythm (faster, amplitude-driven). The slower rhythm communicates "thinking, not listening." |
| Transcript | Static, `Tokens.muted` | Text color softens to communicate the field is no longer the focus. The AI is processing the content. |
| Typing indicator | Reuse `TypingIndicator` from `ChatComponents.swift` | Three-dot sequencer, `Tokens.muted`. Left-aligned below the transcript area, `Space.lg` top margin. Signals AI activity. |
| Cancel button | Glass style, top-right | Best-effort cancel: calls task cancel on the in-flight AI call. Dismisses overlay. If SwiftData writes have already committed, they are not rolled back (acceptable at this scale). |
| Bottom control zone | Empty | No Stop button. The user is no longer recording. Only the top Cancel is available. |

---

### State D: Success — confirmation + auto-dismiss [unchanged, updated layout]

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   Done                                                                       │
│                                                                               │
│                                                                               │
│                                                                               │
│                          (  ●  )                                             │
│                     InkOrb — slow fade to rest (opacity 0.15)               │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│   ✓  Task added: Call John tomorrow at 3 pm                                  │
│   ✓  Note created: Groceries list                                            │
│                                                                               │
│   (one SuccessRow per action applied. Stagger entrance 80ms apart.)         │
│                                                                               │
│                                                                               │
│                                                                               │
│                              ─────────────────                              │
│                           (progress line, 2.0s, auto-dismiss)               │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
```

**Element specs:**

| Element | Spec | Detail |
|---|---|---|
| Status label | "Done" | Cross-fades from "Working…". No buttons in top bar in this state. |
| InkOrb | Fades to rest: opacity 0.15, scale 1.0, `.easeOut` 0.4s | The orb quiets down as the work is complete. It does not disappear — it remains as a calm anchor in the animation zone. |
| Success rows | Reuse `SuccessRow` | One row per `ChatActionResult` outcome. Checkmark + label. Stagger entrance: each row `.transition(.opacity.combined(with: .move(edge: .bottom)))`, 80ms offset. Max 4 rows before scroll. |
| Haptic | `.notificationFeedback(.success)` | Fires once on transition into State D. |
| Auto-dismiss progress line | 1pt, `Tokens.ink` 20% opacity | Sweeps left-to-right over 2.0s `.linear` from the bottom control zone. After completion, the overlay dismisses with the system `fullScreenCover` slide-down animation. |
| Cancel / early dismiss | Swipe down gesture (re-enabled for State D) | `interactiveDismissDisabled(false)` in State D only. The user can swipe the overlay down at any time during State D to dismiss immediately. |
| After dismiss | Originating page, unchanged | The user lands on the exact tab, scroll position, and view they were on when they tapped the AI button. No navigation. |

---

### State E: Empty — silence detected with no speech [unchanged layout, updated form factor]

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   Nothing heard                                          [ Cancel ]          │
│                                                                               │
│                                                                               │
│                                                                               │
│                          (  ○  )                                             │
│                     InkOrb — static, rest opacity (0.22)                    │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│                                                                               │
│        Try speaking, or tap the mic to record again.                         │
│                                                                               │
│                                                                               │
│                                                                               │
│           [ Cancel ]                    [ Try Again ]                        │
│                (glass)                      (glass)                          │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
```

**Element specs:**

| Element | Spec | Detail |
|---|---|---|
| Trigger | Silence timer fires with empty transcript | `SFSpeech` error code 1110 (already silenced in transcriber) or 1.5s silence with zero words captured. |
| InkOrb | Static at rest opacity (0.22), no animation | Recording has stopped and there is nothing to show for it. The orb sits quietly. |
| Body text | `.edBody`, `Tokens.inkSoft`, centered in transcript zone | "Try speaking, or tap the mic to record again." |
| Cancel | Glass style, bottom-left | Dismisses overlay, no action. |
| Try Again | Glass style, bottom-right | Restarts recording from scratch — back to State A. `SpeechTranscriber` restarts. |

---

### State F: Permission denied [unchanged]

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   Microphone access needed                               [ Not now ]         │
│                                                                               │
│                                                                               │
│                                                                               │
│                          (  ○  )                                             │
│                     InkOrb — static, 0.15 opacity (dim)                     │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│                                                                               │
│   Dexter needs microphone and speech access to record                        │
│   your voice. Turn them on in Settings to continue.                          │
│                                                                               │
│                                                                               │
│                                                                               │
│         [ Not now ]                   [ Open Settings ]                      │
│              (glass)                       (glass)                           │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
```

**Element specs:**

| Element | Spec | Detail |
|---|---|---|
| InkOrb | Dimmed static: 0.15 opacity, no animation | The orb is visually "off" — feature is unavailable. |
| Open Settings | Glass style, bottom-right | `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`. Overlay stays open. |
| Not now | Glass style, top-right and bottom-left (two touch points for ergonomics) | Dismisses overlay. |

---

### State G: Error — transcription or AI failure [unchanged]

```
┌─ Safe area top ──────────────────────────────────────────────────────────────┐
│                                                                               │
│   Something went wrong                                   [ Dismiss ]         │
│                                                                               │
│                                                                               │
│                                                                               │
│                          (  ○  )                                             │
│                     InkOrb — static, 0.15 opacity (dim)                     │
│                                                                               │
│                                                                               │
│                                                                               │
│   ─────────────────────────────────────────────────────────────────────────  │
│                                                                               │
│                                                                               │
│   [inline error message from transcriber or AI — stripped of tech prefixes] │
│                                                                               │
│                                                                               │
│                                                                               │
│        [ Dismiss ]                       [ Try Again ]                       │
│             (glass)                           (glass)                        │
│                                                                               │
└─ Safe area bottom ───────────────────────────────────────────────────────────┘
```

**Element specs:**

| Element | Spec | Detail |
|---|---|---|
| Error message | `.edBody`, `Tokens.inkSoft`, centered | Raw message from `transcriber.errorMessage` or `ChatViewModel.errorMessage`, stripped of technical prefixes. Two lines max before truncation with "…". |
| Try Again | Glass style | For transcription errors: restart recording (State A). For AI errors: re-run `ChatViewModel.send()` with the last transcript. |
| Dismiss | Glass style | Dismisses overlay. No action on data. |

---

## Section 4 — State Machine (Auto-Execute Flow) [REVISED]

```
[Tap AI button]
       │
       ▼
  [State A: Listening]
  ┌─── Recording active, InkOrb reactive, live transcript ──────────────────┐
  │                                                                          │
  │  1.5s silence + non-empty transcript ──────────────────────────────────►[State A1: Safety Window]
  │                                                                          │         │
  │  "Stop Now" glass button ──────────────────────────────────────────────►[State A1]│
  │                                                                          │         │ 1.5s (no Cancel)
  │  Cancel button or swipe ───────────────────────────────────────────────►[Dismiss] │
  │                                                                          │         ▼
  │  1.5s silence + empty transcript ──────────────────────────────────────►[State E: Empty]
  │                                                                          │
  └──────────────────────────────────────────────────────────────────────────┘
                                                                             │
  [State A1: Safety Window]                                                  │
  ┌─── "Got it", progress bar sweeping, Cancel available ───────────────────┘
  │
  │  Cancel tapped ────────────────────────────────────────────────────────►[Dismiss]
  │
  │  1.5s elapsed (no Cancel) ─────────────────────────────────────────────►[State C: Executing]
  │
  └──────────────────────────────────────────────────────────────────────────┘

  [State C: Executing]
  ┌─── "Working…", InkOrb thinking rhythm, TypingIndicator ────────────────┐
  │                                                                         │
  │  AI success ───────────────────────────────────────────────────────────►[State D: Success]
  │                                                                         │
  │  AI error ─────────────────────────────────────────────────────────────►[State G: Error]
  │                                                                         │
  │  Cancel tapped ────────────────────────────────────────────────────────►[Dismiss]
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘

  [State D: Success]
  ┌─── "Done", success rows, auto-dismiss progress line ───────────────────┐
  │                                                                         │
  │  2.0s elapsed ─────────────────────────────────────────────────────────►[Dismiss → originating page]
  │                                                                         │
  │  User swipes down ─────────────────────────────────────────────────────►[Dismiss → originating page]
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘
```

**Silence timer implementation note:** The 1.5s timer starts (or restarts) on every `SpeechTranscriber` partial result. It fires when no new partial result arrives within 1.5s. The timer is cancelled immediately on entering State A1 (the safety window manages its own 1.5s countdown independently). Use `Task.sleep(nanoseconds:)` or a `Timer.publish` that is cancelled and recreated on each word. Do not use a single ongoing timer that counts total session duration.

---

## Section 5 — Glass Controls [NEW]

All interactive controls on the voice capture overlay use a glass treatment. There is no "solid primary" button in this overlay — the InkOrb is the visual hero; controls must not compete with it.

### Glass button specification

| Property | Value | Notes |
|---|---|---|
| Background material | `.ultraThinMaterial` | SwiftUI's thinnest material — the lightest blur. On the paper-white `Tokens.surface` background this reads as a subtle frosted disc. |
| Background tint overlay | `Color(Tokens.surface).opacity(0.5)` drawn over the material | Ensures the button stays legible even when the background is animated (prevents the material from looking too transparent). |
| Corner radius | `Radius.pill` (fully rounded capsule for single-line labels) | Matches the app's existing floating pill aesthetic. |
| Border stroke | `Color.white.opacity(0.35)` at 0.5pt | Hairline white inner border gives the glass a clean edge. In dark mode, use `Color.white.opacity(0.20)` (slightly more transparent because dark surfaces show borders more strongly). |
| Shadow | `Color(Tokens.ink).opacity(0.08)` radius 8pt, y offset 2pt | A very gentle lift — barely perceptible. The glass sits on the surface rather than floating dramatically over it. |
| Label / icon color | `Tokens.ink` | Full-opacity ink ensures the label passes contrast at 4.5:1 regardless of what is blurred behind the button. |
| Font | `.edBodyMedium` for action labels, `.edCaption` for secondary labels | Consistent with the app's named font system. |
| Padding | `Space.sm` vertical (8pt), `Space.lg` horizontal (20pt) for text buttons | Sufficient interior room for the glass effect to register. |
| Minimum tap target | 44pt × 44pt | Use `.frame(minWidth: 44, minHeight: 44)` with `.contentShape(Capsule())` if the visual size is smaller. |
| Pressed state | Scale to 0.96, `.easeOut 0.1s`, with `UIImpactFeedbackGenerator(style: .light).impactOccurred()` | Immediate, physical, tactile. No color change on press (the glass treats color change as too prominent). |
| Disabled state | Opacity 0.4 on the entire button, `.allowsHitTesting(false)` | Maintains the glass look while clearly communicating unavailability. |

### SwiftUI implementation sketch (not production code — for engineer reference)

```
// GlassButtonStyle
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.edBodyMedium)
            .foregroundStyle(Tokens.ink)
            .padding(.vertical, Space.sm)
            .padding(.horizontal, Space.lg)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule()
                            .fill(Color(Tokens.surface).opacity(0.5))
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                    }
                    .shadow(color: Color(Tokens.ink).opacity(0.08),
                            radius: 8, x: 0, y: 2)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
```

### Control map by state

| State | Top-right | Bottom-left | Bottom-center / right |
|---|---|---|---|
| A — Listening | Cancel (glass) | — | Stop Now (glass) |
| A1 — Safety Window | Cancel (glass) | Cancel (glass, secondary) | — (progress bar sweeps the zone) |
| C — Executing | Cancel (glass) | — | — |
| D — Success | — | — | — (progress line, swipe to dismiss) |
| E — Empty | Cancel (glass) | Cancel (glass) | Try Again (glass) |
| F — Permission | Not now (glass) | Not now (glass) | Open Settings (glass) |
| G — Error | Dismiss (glass) | Dismiss (glass) | Try Again (glass) |

Note: In State D, no glass buttons are visible. The auto-dismiss line handles the terminal action. The user can swipe down at any time.

---

## Section 6 — Motion [REVISED]

| Phase | Duration | Spec |
|---|---|---|
| Overlay entry | System default for `fullScreenCover` (~0.38s spring) | Slides up from bottom, full-screen. No custom override needed; the system spring matches the app's established `.spring(response: 0.35, dampingFraction: 0.85)`. |
| Status label cross-fade (any state transition) | 0.2s `.easeOut` | All state label changes use an opacity cross-fade. The label does not slide; only opacity animates. |
| InkOrb amplitude response | Per-frame, spring-driven (see Section 2) | `.spring(response: 0.18, dampingFraction: 0.65)`. Outer ring lags by 80ms. |
| InkOrb → A1 (settle) | 0.15s `.easeIn` | Scale to 0.88, autonomous rhythm stops. |
| InkOrb → C (thinking) | 0.3s `.easeInOut` | Transitions from settled (0.88 scale) back to base (1.0 scale) and begins slow autonomous pulse (2.0s period). |
| InkOrb → D (rest) | 0.4s `.easeOut` | Fades to 0.15 opacity, scale 1.0, all animation stops. |
| Transcript text arrival | Instant (SwiftUI diff) | New words appear as SFSpeech emits partials. Auto-scroll: `withAnimation(.easeOut(duration: 0.15))`. |
| A1 safety window progress bar | 1.5s `.linear` | Sweeps from 0 to full width. The linearity is intentional: the user needs a predictable countdown, not one that accelerates. |
| TypingIndicator entrance (C) | 0.2s `.easeOut`, `.transition(.opacity)` | Fades in below transcript when entering State C. |
| Success rows (D) | 80ms offset per row, `.transition(.opacity.combined(with: .move(edge: .bottom)))` | Same stagger pattern as v1. |
| D auto-dismiss progress line | 2.0s `.linear` | As in v1. Proceeds to native `fullScreenCover` dismiss (slide down) on completion. |
| Overlay dismiss (any terminal state) | Native `fullScreenCover` dismiss (~0.35s spring) | Slides down. No custom override. |
| Reduce-motion overrides | Global | When `accessibilityReduceMotion` is true: InkOrb is static (no scale, no pulse, no outer ring). State transitions use `.opacity` only, 0.15s. Success rows appear simultaneously (no stagger). Progress bars still animate (they are informational, not decorative) — per Apple's guidance that informational animations are exempt from reduce-motion. |

---

## Section 7 — Controls and Gestures [REVISED]

| Control / Gesture | Behavior | Tap target |
|---|---|---|
| AI button tap (entry) | Presents `fullScreenCover`. Haptic: `UIImpactFeedbackGenerator(style: .medium).impactOccurred()`. Recording begins immediately. | Existing tap target in `BottomTabBar`. |
| Cancel (top-right, States A / A1 / C) | Stop recording / cancel pending execution / best-effort cancel AI task. Discard transcript. Dismiss overlay. | 44pt × 44pt minimum. Glass button. |
| Stop Now (bottom, State A) | Trigger silence-end early: advance to State A1 immediately. Does not wait for the 1.5s silence timer. | 44pt height, glass button. Centered at bottom of screen. |
| Cancel during safety window (A1) | Abort pending execution. Return to State A to record again, OR dismiss overlay — design choice: recommend dismissing fully (the user who taps Cancel during A1 typically does not want to retry immediately; they want to think). Present State A again only if the user navigates back and taps the AI button again. | 44pt height, glass. Accessible from both top-right and bottom-left in A1. |
| Swipe down | Disabled during States A, A1, C via `interactiveDismissDisabled(true)`. Re-enabled in States D, E, F, G. | System gesture. |
| Tap outside overlay | Not applicable — full-screen cover has no "outside." | N/A |
| Try Again (States E, G) | Restarts recording from scratch (State A). | 44pt height, glass. |
| Open Settings (State F) | `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`. Overlay stays open. | 44pt height, glass. |
| Dismiss / Not now (States D, E, F, G) | Dismiss overlay. No data action. | 44pt height, glass. |
| Hardware back | Not applicable on iOS for a modal. | N/A |
| Volume buttons | No interaction with the overlay. | System behavior. |

---

## Section 8 — Microcopy [REVISED]

Voice and tone: plain, direct, lowercase-friendly. No em dashes. No exclamation marks. No apologies. State what is happening or what to do next.

| Context | String | Note |
|---|---|---|
| Listening status | "Listening" | One word. The InkOrb communicates recording is active; the label confirms it. |
| Safety window status | "Got it" | Two words. Communicates receipt without over-promising ("Done" would be premature). |
| Executing status | "Working…" | Unchanged from v1. |
| Success status | "Done" | Unchanged. |
| Empty / no speech status | "Nothing heard" | Unchanged. |
| Permission status | "Microphone access needed" | Unchanged. |
| Error status | "Something went wrong" | Unchanged. |
| Stop Now button | "Stop Now" | Two words, title case. Actionable. Not "Send" (no explicit sending in auto-execute model) or "Done" (reserved for success state). |
| Cancel button | "Cancel" | Single word. Always the same label regardless of state — predictability matters for a control the user may grab in a hurry. |
| Try Again button | "Try Again" | States E and G. |
| Open Settings | "Open Settings" | State F. Names the destination. |
| Not now | "Not now" | State F. Lowercase "now". |
| Empty body text | "Try speaking, or tap the mic to record again." | Unchanged. |
| Permission body text | "Dexter needs microphone and speech access to record your voice. Turn them on in Settings to continue." | Unchanged. |
| Error body text | [inline from `transcriber.errorMessage` or `ChatViewModel.errorMessage`] | Strip technical prefixes. 2-line max. |
| First-launch hint (State A, empty transcript, first session only) | "Start speaking — Dexter is listening." | Replaces the v1 "Hold to record. Release to finalize." which referenced a gesture that no longer applies. Shown centered in the transcript zone only when the transcript is empty and `AppStorage("hasSeenVoiceHint")` is false. Hidden after first recording completes. |

---

## Section 9 — Accessibility [REVISED]

| Element | VoiceOver label | Notes |
|---|---|---|
| AI button | "Voice capture. Tap to start." | Update the existing `.accessibilityHint` on the AI button in `BottomTabBar`. The "touch and hold" wording no longer applies if the gesture changes to a tap. |
| InkOrb | "Recording in progress." (State A) / "Processing." (State C) / Hidden in States D, E, F, G | `.accessibilityElement(children: .ignore)`. Post `.announcement` on state change. In State A: announce once when the overlay opens. |
| Status label | Read by VoiceOver as the container's label (via `.accessibilityLabel` on the top bar zone) | The status label and InkOrb are combined into a single VoiceOver region. |
| Cancel button | "Cancel voice capture" | `.accessibilityLabel("Cancel voice capture")`. VoiceOver users may not know they are in a voice capture context; the label names it. |
| Stop Now button | "Stop and execute" | More descriptive than the visual label "Stop Now" — tells VoiceOver users what happens next. |
| Safety window progress | Announce once: "Executing in 1.5 seconds. Double tap Cancel to abort." | `UIAccessibility.post(notification: .announcement, argument: ...)` on entering A1. The visual progress bar is `.accessibilityHidden(true)`. |
| Transcript text | System `Text` view; VoiceOver reads normally | No label override needed. VoiceOver focus should move to the transcript as text appears. Post `.screenChanged` notification when the first partial result arrives. |
| Typing indicator (State C) | Announce once: "Processing your request." | Post `.announcement` on entering State C. Dots themselves are `.accessibilityHidden(true)`. |
| Success rows | One announcement per row, 500ms staggered | Post `.announcement` for each `SuccessRow`. Then: "Closing in 2 seconds." |
| Auto-dismiss progress line | `.accessibilityHidden(true)` | Already announced via text. |
| Glass buttons | All buttons get `.accessibilityAddTraits(.isButton)` and explicit `.accessibilityLabel` | The glass material effect does not affect VoiceOver — VoiceOver reads the label, not the visual. |
| Dynamic Type | Full support via named font styles | Test at Accessibility Extra Extra Extra Large. The animation zone may need to shrink slightly at max sizes to give the transcript zone more room — use `@Environment(\.dynamicTypeSize)` to adjust the zone split ratio from 38/55 to 30/63 at sizes above `.xxLarge`. |
| Reduce Motion | InkOrb is static; all transitions use `.opacity` only | See Section 6. |
| Color contrast | `Tokens.ink` on `Tokens.surface` (light mode): ~18.5:1 (AAA). Glass button labels (`Tokens.ink` on ultraThinMaterial over `Tokens.surface`): the blur background is effectively `Tokens.surface`-adjacent, so contrast is maintained at ~18.5:1. `Tokens.muted` on `Tokens.surface`: ~4.6:1 (AA). No element uses color as the only indicator of state. | |

---

## Section 10 — Architecture Note [REVISED]

The overlay must be presentable from any tab. The `.fullScreenCover` replaces the `.sheet` attachment point but the architecture recommendation from v1 stands and is now cleaner:

**`VoiceCaptureViewModel`** (`@Observable`, `@MainActor`) owns:
- `SpeechTranscriber` instance
- The silence timer (1.5s, resets on each partial result)
- The safety-window timer (1.5s, starts when silence timer fires and transcript is non-empty)
- `VoiceCaptureState` enum: `.listening`, `.safetyWindow`, `.executing`, `.success([ChatActionResult])`, `.empty`, `.permissionDenied`, `.error(String)`
- `transcript: String` (the live partial)
- `audioLevel: Float` (normalized 0.0–1.0 from `AVAudioRecorder` metering, published at 30fps via a `Timer.publish`)
- The `ChatViewModel.send()` call (or a dedicated `executeVoiceCapture(_ transcript: String)` method)

Inject into the environment from `ContentView`. `AppRouter.showVoiceCaptureOverlay: Bool` triggers the `.fullScreenCover`. The overlay binds to `VoiceCaptureViewModel` from environment.

**Audio level metering:** Enable `AVAudioRecorder` metering with `isMeteringEnabled = true` and call `updateMeters()` at 30fps via `Timer.publish(every: 1/30, ...)`. Normalize the `averagePower(forChannel: 0)` dB value (typical range -60dBFS to 0dBFS) to 0.0–1.0 using a simple linear map with a -40dBFS floor. Apply a rolling average (last 4 readings) before publishing to `VoiceCaptureViewModel.audioLevel`. The InkOrb animation subscribes to `audioLevel` and the spring handles smoothing.

**`interactiveDismissDisabled` management:** Set to `true` when state is `.listening`, `.safetyWindow`, or `.executing`. Set to `false` when state is `.success`, `.empty`, `.permissionDenied`, or `.error`. Handle via a computed property on `VoiceCaptureViewModel` and a `.onChange(of: viewModel.isInteractiveDismissDisabled)` modifier on the `fullScreenCover` content view.

**Teardown path:** `onDismiss` on the `fullScreenCover` calls `viewModel.cancel()` which stops the transcriber, cancels both timers, and cancels any in-flight AI task. This is the single teardown path regardless of how the overlay was closed.

---

## Pre-Delivery Checklist [REVISED]

**Form factor and entry**
- [ ] `.fullScreenCover` presents from any tab without navigating away from the current page
- [ ] Tapping the AI button triggers recording immediately (no hold gesture required)
- [ ] Overlay covers status bar, nav bar, and tab bar
- [ ] Dismissing the overlay returns to the exact tab and scroll position

**Recording and auto-execute**
- [ ] Silence timer (1.5s) resets on each new partial result from `SpeechTranscriber`
- [ ] Non-empty transcript after 1.5s silence advances to State A1 (safety window)
- [ ] Empty transcript after 1.5s silence advances to State E
- [ ] Stop Now button forces State A1 immediately (no silence wait)
- [ ] Safety window shows progress bar sweeping over 1.5s before auto-executing
- [ ] Cancel during A1 stops execution and dismisses overlay
- [ ] Cancel during C is best-effort; overlay dismisses without crash

**InkOrb animation**
- [ ] Base diameter 120pt, active diameter up to 160pt
- [ ] Amplitude drives scale and opacity at 30fps (spring response 0.18)
- [ ] Outer ring lags inner circle by 80ms
- [ ] InkOrb settles to 0.88 scale when entering A1
- [ ] InkOrb pulses slowly (2.0s period) during State C
- [ ] InkOrb fades to 0.15 opacity in State D
- [ ] Reduce-motion: static filled circle, no animation

**Glass controls**
- [ ] All buttons use `.ultraThinMaterial` with `Color(Tokens.surface).opacity(0.5)` tint
- [ ] All buttons have 0.5pt `Color.white.opacity(0.35)` stroke border
- [ ] All buttons scale to 0.96 on press with light haptic
- [ ] All buttons minimum 44pt × 44pt tap target
- [ ] Glass labels pass 4.5:1 contrast against the overlay background

**State machine**
- [ ] All seven states (A, A1, C, D, E, F, G) implemented
- [ ] State transitions use 0.2s opacity cross-fade for status labels
- [ ] `interactiveDismissDisabled(true)` in States A, A1, C; `false` in D, E, F, G
- [ ] Permission denied routes to State F, not State G
- [ ] Success state auto-dismisses after 2.0s progress line completes

**Accessibility**
- [ ] VoiceOver: AI button announces "Voice capture. Tap to start."
- [ ] VoiceOver: Cancel announces "Cancel voice capture"
- [ ] VoiceOver: Stop Now announces "Stop and execute"
- [ ] VoiceOver: entering A1 announces "Executing in 1.5 seconds. Double tap Cancel to abort."
- [ ] VoiceOver: entering C announces "Processing your request."
- [ ] VoiceOver: each success row announced with 500ms stagger; then "Closing in 2 seconds."
- [ ] `accessibilityReduceMotion` respected: static InkOrb, opacity-only transitions, no stagger
- [ ] Dynamic Type tested at Accessibility Extra Extra Extra Large
- [ ] Audio level metering does not require microphone permission beyond what `SpeechTranscriber` already requests

**Robustness**
- [ ] Recording stops synchronously in `onDismiss` — dismiss never leaves the mic open
- [ ] Second tap on AI button while overlay is open does not crash or duplicate the transcriber
- [ ] App sent to background mid-recording: overlay dismisses and transcriber stops
- [ ] Re-record in State E cleanly stops and restarts the transcriber
- [ ] Open Settings (State F) correctly opens the app's Settings page
- [ ] Page behind the overlay is unchanged after dismiss in all terminal states
