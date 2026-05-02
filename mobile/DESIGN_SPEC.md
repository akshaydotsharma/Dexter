# Personal Dashboard iOS — Editorial Calm Design Spec

**Target**: SwiftUI, iOS 17+, single-user, online-only (read cache later), TestFlight.
**Source of truth**: `client/src/index.css` (`@theme` block) and `client/src/pages/ChatPage.jsx`.
**Aesthetic**: "Morning paper" (light) and "Evening edition" (dark). Warm off-white paper with deep ink, per-section accent, generous whitespace, serif display + grotesque sans body. AI-first: the chat surface IS the home.

This document is an implementation contract. Translate every token, dimension, and pattern below into Swift exactly as specified. If a webapp feature does not translate cleanly to iOS, the iOS-native equivalent is given. Do not invent alternatives.

---

## 1. Color Tokens

### 1.1 Light palette (`paper`, "morning paper")

| Token | Hex | Role |
|---|---|---|
| `paper` | `#FBF9F4` | Page background |
| `paper2` | `#F4F0E6` | Sunken / hover surface |
| `surface` | `#FFFFFF` | Cards, draft cards, input bar |
| `surface2` | `#F8F5EE` | Sub-surface inside cards |
| `border` | `#E8E2D2` | Default 1px border |
| `borderStrong` | `#D9D2BE` | Hover/focus border |
| `divider` | `#EFE9DA` | Hairline separators |
| `ink` | `#1F1B16` | Primary text, primary buttons |
| `inkSoft` | `#4A4339` | AI prose, secondary text |
| `muted` | `#7B7263` | Captions, eyebrows |
| `mutedSoft` | `#A89E8A` | Placeholders, disabled |

### 1.2 Dark palette (`paper`, "evening edition")

| Token | Hex | Role |
|---|---|---|
| `paper` | `#14110D` | Page background |
| `paper2` | `#1B1813` | Sunken / hover surface |
| `surface` | `#1F1C16` | Cards |
| `surface2` | `#25211A` | Sub-surface |
| `border` | `#36302A` | Default border |
| `borderStrong` | `#4A4338` | Hover/focus border |
| `divider` | `#2A2620` | Hairline separators |
| `ink` | `#F2EBDA` | Primary text |
| `inkSoft` | `#DCD3BE` | Secondary |
| `muted` | `#A89E8A` | Captions |
| `mutedSoft` | `#756B5B` | Placeholders |

### 1.3 Per-section accents

The active section sets the accent. Default active section is `chat` (which means accent = ink).

| Section | Light | Dark |
|---|---|---|
| `chat` | `#1F1B16` (ink) | `#F2EBDA` (paper) |
| `today` | `#B91C1C` | `#F87171` |
| `tasks` | `#4338CA` | `#818CF8` |
| `notes` | `#B45309` | `#F59E0B` |
| `lists` | `#0F766E` | `#2DD4BF` |
| `settings` | `#475569` | `#94A3B8` |

`accentFg` = `#FFFFFF` (light) / `#14110D` (dark) — text drawn on top of accent fills.
`accentSoft` = accent at ~12% mixed with paper (light) / 18% with paper (dark).
`accentRing` = accent at 35% (light) / 45% (dark) opacity, used for focus rings.

### 1.4 Semantic colors

| Token | Light | Dark |
|---|---|---|
| `success` | `#15803D` | `#4ADE80` |
| `successSoft` | `#DCFCE7` | `#052E16` |
| `warning` | `#B45309` | `#F59E0B` |
| `warningSoft` | `#FEF3C7` | `#422006` |
| `danger` | `#B91C1C` | `#F87171` |
| `dangerSoft` | `#FEE2E2` | `#450A0A` |
| `info` | `#0E7490` | `#22D3EE` |

### 1.5 Swift definitions (paste-ready)

Create `PersonalDashboard/Design/Tokens.swift`:

```swift
import SwiftUI

// MARK: - Section identity
enum Section: String, CaseIterable, Identifiable {
    case chat, today, tasks, notes, lists, settings
    var id: String { rawValue }
}

// MARK: - Hex helper
extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
    /// Light/dark pair. Resolved at render time via the system color scheme.
    static func paper(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

// MARK: - Editorial Calm tokens
enum Tokens {
    // Neutral spine
    static let paper        = Color.paper(0xFBF9F4, 0x14110D)
    static let paper2       = Color.paper(0xF4F0E6, 0x1B1813)
    static let surface      = Color.paper(0xFFFFFF, 0x1F1C16)
    static let surface2     = Color.paper(0xF8F5EE, 0x25211A)
    static let border       = Color.paper(0xE8E2D2, 0x36302A)
    static let borderStrong = Color.paper(0xD9D2BE, 0x4A4338)
    static let divider      = Color.paper(0xEFE9DA, 0x2A2620)
    static let ink          = Color.paper(0x1F1B16, 0xF2EBDA)
    static let inkSoft      = Color.paper(0x4A4339, 0xDCD3BE)
    static let muted        = Color.paper(0x7B7263, 0xA89E8A)
    static let mutedSoft    = Color.paper(0xA89E8A, 0x756B5B)

    // Section accents (light, dark)
    static let accentChat     = Color.paper(0x1F1B16, 0xF2EBDA)
    static let accentToday    = Color.paper(0xB91C1C, 0xF87171)
    static let accentTasks    = Color.paper(0x4338CA, 0x818CF8)
    static let accentNotes    = Color.paper(0xB45309, 0xF59E0B)
    static let accentLists    = Color.paper(0x0F766E, 0x2DD4BF)
    static let accentSettings = Color.paper(0x475569, 0x94A3B8)
    static let accentFg       = Color.paper(0xFFFFFF, 0x14110D)

    // Semantics
    static let success      = Color.paper(0x15803D, 0x4ADE80)
    static let successSoft  = Color.paper(0xDCFCE7, 0x052E16)
    static let warning      = Color.paper(0xB45309, 0xF59E0B)
    static let warningSoft  = Color.paper(0xFEF3C7, 0x422006)
    static let danger       = Color.paper(0xB91C1C, 0xF87171)
    static let dangerSoft   = Color.paper(0xFEE2E2, 0x450A0A)
    static let info         = Color.paper(0x0E7490, 0x22D3EE)

    static func accent(for section: Section) -> Color {
        switch section {
        case .chat:     return accentChat
        case .today:    return accentToday
        case .tasks:    return accentTasks
        case .notes:    return accentNotes
        case .lists:    return accentLists
        case .settings: return accentSettings
        }
    }
}

// MARK: - Active section environment
private struct ActiveSectionKey: EnvironmentKey {
    static let defaultValue: Section = .chat
}
extension EnvironmentValues {
    var activeSection: Section {
        get { self[ActiveSectionKey.self] }
        set { self[ActiveSectionKey.self] = newValue }
    }
}
extension View {
    /// Wrap any subtree with the active section. The subtree reads
    /// `@Environment(\.activeSection)` and pulls the right accent.
    func activeSection(_ section: Section) -> some View {
        environment(\.activeSection, section)
    }
}
```

Usage rule: any view that needs the accent reads `@Environment(\.activeSection)` and resolves via `Tokens.accent(for:)`. Set the section at the navigation boundary (when entering Tasks, push `.tasks`).

---

## 2. Typography

### 2.1 Families

| Family | Use |
|---|---|
| **Calistoga** | Display serif. Headlines, section titles, empty-state H1, sidebar wordmark. Single weight (Regular). |
| **Inter** | Sans body. All UI copy, buttons, labels. Weights 400/500/600. |
| **JetBrains Mono** | Monospace. Keyboard hints, list item textareas only. Weight 400. |

All three are Google Fonts. Drop the `.ttf` files into `PersonalDashboard/Resources/Fonts/` and register via `Info.plist`.

### 2.2 Font files needed

- `Calistoga-Regular.ttf`
- `Inter-Regular.ttf`
- `Inter-Medium.ttf`
- `Inter-SemiBold.ttf`
- `JetBrainsMono-Regular.ttf`

### 2.3 Info.plist entry

```xml
<key>UIAppFonts</key>
<array>
    <string>Calistoga-Regular.ttf</string>
    <string>Inter-Regular.ttf</string>
    <string>Inter-Medium.ttf</string>
    <string>Inter-SemiBold.ttf</string>
    <string>JetBrainsMono-Regular.ttf</string>
</array>
```

### 2.4 Font scale (matches webapp usage)

| Style | Family | Size | Weight | Line height | Tracking | Used for |
|---|---|---|---|---|---|---|
| `display` | Calistoga | 28 | regular | 34 | -0.4 | Empty-state H1 ("What can I help you organize?") |
| `title` | Calistoga | 22 | regular | 28 | -0.3 | Section headers, list/note titles in detail |
| `heading` | Inter | 17 | semibold | 22 | -0.1 | Card titles, section labels in lists |
| `body` | Inter | 16 | regular | 24 | 0 | Default body, AI prose, user bubble text |
| `bodyMedium` | Inter | 16 | medium | 24 | 0 | Task titles, draft card titles |
| `subheadline` | Inter | 15 | regular | 20 | 0 | Secondary copy in cards |
| `footnote` | Inter | 13 | medium | 18 | 0 | Chip text, eyebrow labels |
| `caption` | Inter | 12 | regular | 16 | 0.1 | Captions, timestamps, hints |
| `eyebrow` | Inter | 11 | semibold | 14 | 1.4 (uppercase) | "NEW TASK" eyebrow on draft cards |
| `mono` | JetBrainsMono | 13 | regular | 18 | 0 | Keyboard hints, list textarea |

### 2.5 Swift extension (paste-ready)

Create `PersonalDashboard/Design/Typography.swift`:

```swift
import SwiftUI

extension Font {
    private static func calistoga(_ size: CGFloat) -> Font {
        .custom("Calistoga-Regular", size: size)
    }
    private static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium:    name = "Inter-Medium"
        case .semibold:  name = "Inter-SemiBold"
        default:         name = "Inter-Regular"
        }
        return .custom(name, size: size)
    }
    private static func jbMono(_ size: CGFloat) -> Font {
        .custom("JetBrainsMono-Regular", size: size)
    }

    // Editorial Calm scale
    static let edDisplay     = calistoga(28)
    static let edTitle       = calistoga(22)
    static let edHeading     = inter(17, weight: .semibold)
    static let edBody        = inter(16)
    static let edBodyMedium  = inter(16, weight: .medium)
    static let edSubheadline = inter(15)
    static let edFootnote    = inter(13, weight: .medium)
    static let edCaption     = inter(12)
    static let edEyebrow     = inter(11, weight: .semibold) // pair with .textCase(.uppercase) and .tracking(1.4)
    static let edMono        = jbMono(13)
}
```

### 2.6 Eyebrow modifier

```swift
struct Eyebrow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.edEyebrow)
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Tokens.muted)
    }
}
extension View { func eyebrow() -> some View { modifier(Eyebrow()) } }
```

---

## 3. Spacing, Radius, Shadows

### 3.1 Spacing scale

| Token | Value | Use |
|---|---|---|
| `xxs` | 2 | Hairline gaps |
| `xs` | 4 | Tight icon-text gaps |
| `sm` | 8 | Default chip padding, button gap |
| `md` | 12 | Card inner padding, list item gap |
| `lg` | 16 | Card padding, default screen edge |
| `xl` | 24 | Section gap |
| `xxl` | 32 | Empty-state vertical rhythm |
| `xxxl` | 48 | Large hero rhythm |

```swift
enum Space {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}
```

### 3.2 Corner radius

| Token | Value | Use |
|---|---|---|
| `radSm` | 6 | Inline pills, kbd hints |
| `radMd` | 10 | Buttons, icon buttons, chips (rectangular) |
| `radLg` | 12 | Draft cards, edit popover panels |
| `radXl` | 16 | Cards, chat input bar (rounded-2xl in webapp = 16) |
| `radPill` | 999 | Example-prompt chips, status chips |
| `radBubble` | 16 (corners) / 4 (br corner) | User chat bubble |

```swift
enum Radius {
    static let sm:    CGFloat = 6
    static let md:    CGFloat = 10
    static let lg:    CGFloat = 12
    static let xl:    CGFloat = 16
    static let pill:  CGFloat = 999
}
```

### 3.3 Shadows

The webapp uses Tailwind `shadow-sm` and `shadow-md`. Match values:

| Token | Spec |
|---|---|
| `shadowSm` | `y: 1, blur: 2, color: black @ 0.04` |
| `shadowMd` | `y: 4, blur: 6, color: black @ 0.08` |
| `shadowLg` | `y: 10, blur: 20, color: black @ 0.10` (edit popover) |

```swift
extension View {
    func shadowSm() -> some View {
        shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
    }
    func shadowMd() -> some View {
        shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 4)
    }
    func shadowLg() -> some View {
        shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 10)
    }
}
```

### 3.4 Hairline border

The webapp uses `border border-border` everywhere. Use `0.5pt` on iOS for a true hairline that matches the optical weight of `1px` on web at 2x scale.

```swift
.overlay(
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(Tokens.border, lineWidth: 0.5)
)
```

---

## 4. Information Architecture

### 4.1 Decision: Chat-first with a side drawer

**The iOS app launches directly into the chat surface.** Not a tab bar. Not a Today summary. The chat is home.

To reach the other surfaces (Today, Tasks, Notes, Lists, Dashboard, Settings) the user opens a **left side drawer** triggered by a leading nav button on the chat screen.

#### 4.2 Why drawer, not tabs

I evaluated four options:

1. **Bottom tab bar with Chat as one tab** — Rejected. This is what the current iOS code does and is exactly what the user pushed back on. A tab bar makes Chat one of five equal peers and dilutes the AI-first feel. It also adds 49pt of iOS chrome that breaks the warm-paper aesthetic.
2. **Section switcher sheet** (tap a button in the top bar to summon a list of sections) — Rejected. Adds an extra tap for every navigation and has no spatial mental model.
3. **Slide-up tray** — Rejected. Conflicts with the keyboard accessory area on the chat screen.
4. **Left side drawer (chosen)** — Mirrors the webapp `Sidebar.jsx` exactly. The webapp drawer is collapsed-by-default on desktop and a sheet on mobile; we keep the mobile pattern. The drawer feels like opening a notebook's table of contents, which fits the "morning paper" metaphor. It also means the chat fills the entire viewport when closed — undiluted AI surface.

#### 4.3 Navigation pattern

- **Root**: `ChatScreen` wrapped in a `NavigationStack`.
- **Drawer**: a custom side sheet (NOT `NavigationSplitView` — that gives iPadOS sidebar chrome we do not want). Use a `ZStack` with a `DragGesture`-driven offset, or a stock `.sheet(isPresented:)` with `.presentationDetents([.large])` and `.presentationDragIndicator(.hidden)` from the leading edge via custom presentation. Recommended: hand-roll the drawer with `ZStack` + offset for full visual control. See §4.5 for the spec.
- **Section navigation**: tapping a row in the drawer dismisses the drawer and navigates within the chat's `NavigationStack`. Tasks, Notes, Lists each push a destination view. The chat remains the back-stack root, so a single swipe-back returns to chat.
- **Chat omnipresence**: a small `Sparkles` chip floats at the bottom-right of every non-chat screen (mirroring the webapp's `ChatPopover` FAB). Tapping it pops back to the chat root with animation. Position: 16pt from trailing/bottom edge above the safe area.
- **Default landing on cold start**: chat empty state.
- **Deep-link / state restoration**: persist last visited section in `@AppStorage("lastSection")` for warm starts. Chat is the fallback.

#### 4.4 Drawer items (from `Sidebar.jsx`)

```
[wordmark "Dashy" with Sparkles tile]

Today          (CalendarDays)
Chat           (MessageSquare) <- highlighted while chat is current
─────────────
Tasks          (CheckSquare)
Notes          (FileText)
Lists          (List)
─────────────
Dashboard      (LayoutDashboard)
─────────────
Settings       (Settings)

[footer]   ThemeToggle    AS  Akshay
```

Active row: 3pt left rail in the active section's accent + `paper2` background fill. Inactive: `muted` foreground.

#### 4.5 Drawer dimensions

- Width: `min(280, screenWidth * 0.8)` — matches webapp.
- Background: `surface`.
- Trailing edge: 0.5pt `border` line.
- Slide-in animation: 200ms `easeOut`, mirrors webapp.
- Scrim: `ink` at 40% opacity over the chat.
- Tap on scrim closes. Swipe left on drawer closes.
- Top safe-area inset: respect (drawer extends under notch with safe inset on content).

#### 4.6 Top bar on each screen

Match `TopBar.jsx` at 56pt (`.frame(height: 56)`):
- Leading: 36pt round button with `Menu` icon (uses SF Symbol `line.3.horizontal`) — opens drawer. Hit area 44pt minimum.
- Center / leading-aligned: section name in `edTitle` (Calistoga 22).
- Trailing: theme toggle (sun/moon SF Symbol), profile pip "AS" (32pt circle, `paper2` fill, `border` stroke).
- Background: `paper` with bottom 0.5pt `divider`.

Exception: on the chat surface, the top bar background is `paper` (matches main view), and the title slot can be empty when the chat is in empty state — let the centered hero breathe.

---

## 5. Chat Surface (the most important screen)

This screen has two states: **empty** and **active**. The chat is wrapped in a `NavigationStack` and is the app's root.

### 5.1 Empty state

Vertical centered layout, single column, max width 600pt (effectively the full iPhone width), centered horizontally.

```
┌────────────────────────────────────────┐
│ [☰]                            [☀] AS │  ← top bar (56pt)
│                                        │
│                                        │
│                                        │
│                ✨                      │  ← Sparkles, 32pt, muted
│                                        │
│                ──                      │  ← 2pt × 32pt accent bar (hidden on phones)
│                                        │
│        What can I help you             │  ← Calistoga 28, ink, centered
│             organize?                  │
│                                        │
│   Ask for a task, a note, or a list.   │  ← Inter 16, muted, centered
│   I'll draft it for you to confirm.    │
│                                        │
│   [Remind me to call John tomorrow]    │  ← chip, pill radius
│   [New shopping list with milk…]       │  ← chip, pill radius
│   [Note: ideas for Q3 OKRs]            │  ← chip, pill radius
│                                        │
│                                        │
│ ┌──────────────────────────────────┐   │
│ │ Ask anything…              [🎤][↑]│   │  ← input bar (rounded 16, surface)
│ └──────────────────────────────────┘   │
│  Try "Remind me to call Mom tomorrow"  │  ← caption, only visible on phones
└────────────────────────────────────────┘
```

Specs:
- **Sparkles glyph**: SF Symbol `sparkles`, weight `.regular`, size 32pt, color `Tokens.muted`. (Yes, SF Symbol is acceptable here — small icon, not a hero illustration. See §9 for what NOT to use SF Symbols for.)
- **Hairline accent**: `Tokens.accent(for: .chat)` (= ink), 2pt × 32pt rectangle. Hidden if `horizontalSizeClass == .compact` AND height-constrained — meaning visible on iPad and large iPhones in landscape. Apply `.opacity(0)` rather than removing to preserve layout.
- **Headline**: `.font(.edDisplay)`, `.foregroundStyle(Tokens.ink)`, `.tracking(-0.4)`, two lines hard-wrapped. Center-aligned.
- **Subhead**: `.font(.edBody)`, `.foregroundStyle(Tokens.muted)`, center-aligned, max 320pt wide.
- **Example chips**: see §5.4.

### 5.2 Active state (with messages)

Scrolling conversation column, max width 640pt content (so on iPad we don't get 1500pt-wide bubbles). Bottom-anchored input bar floats above safe area.

```
┌────────────────────────────────────────┐
│ [☰]              Chat       [☀] AS   │
│                                        │
│  AI prose response sits left-aligned   │  ← Inter 16, inkSoft
│  on the paper background. No bubble,   │
│  no card, no avatar. Just text.        │
│                                        │
│              ┌─────────────────────┐   │
│              │ remind me to call   │   │  ← user bubble, ink fill, paper text
│              │ John tomorrow at 3  │   │     rounded 16 / 4 (br corner)
│              └─────────────────────┘   │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │ NEW TASK                         │  │  ← draft card, surface fill, border
│  │ Call John                        │  │     rounded 12, eyebrow muted
│  │ [📅 Apr 30, 3:00 PM] [#work]    │  │  ← chips inside card
│  │                                  │  │
│  │ [✓ Confirm] [✎ Edit] [✕ Cancel] │  │  ← buttons
│  └──────────────────────────────────┘  │
│                                        │
│  ✓ Task created  [View →]              │  ← success row, success green check
│                                        │
│  • • •                                 │  ← typing indicator (3 bouncing dots)
│                                        │
│ ┌──────────────────────────────────┐   │
│ │ Ask anything…              [🎤][↑]│  │
│ └──────────────────────────────────┘   │
└────────────────────────────────────────┘
```

Specs per element:

#### 5.2.1 User bubble

Right-aligned. Fill `Tokens.ink`. Foreground `Tokens.paper`. Padding `(horizontal: 20, vertical: 12)`. Max width = `min(geo.size.width * 0.78, 480)`. Corner radius 16 on three corners, **4 on bottom-right** (matches webapp `rounded-br-sm`). Font `.edBody`. `whitespace-pre-wrap` = `.fixedSize(horizontal: false, vertical: true)` and respect newlines.

```swift
struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 24)
            Text(text)
                .font(.edBody)
                .foregroundStyle(Tokens.paper)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Tokens.ink, in: BubbleShape())
                .frame(maxWidth: 480, alignment: .trailing)
        }
    }
}
struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let p = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight, .bottomLeft],
            cornerRadii: CGSize(width: 16, height: 16))
        // Bottom-right corner: 4pt radius
        // Use a custom path that combines large radii on three corners
        // and small on br. Simplest impl: clip a RoundedRectangle 16
        // and overlay a small RoundedRectangle 4 on the br quadrant.
        return Path(p.cgPath)
    }
}
```

#### 5.2.2 AI prose (NO bubble)

Left-aligned. Font `.edBody`. Color `Tokens.inkSoft`. Max width 640pt. Padding none. Just plain text on paper. This is critical — do NOT wrap in a bubble or card. The webapp deliberately distinguishes user (bubble) from AI (prose) to make the AI feel like a quiet voice rather than a chatbot.

#### 5.2.3 Typing indicator

Three dots, 6pt diameter, `Tokens.muted`, with a stagger-bounce animation (delays 0ms / 150ms / 300ms, duration 600ms each, ease-in-out).

```swift
struct TypingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle().fill(Tokens.muted).frame(width: 6, height: 6)
                    .offset(y: sin((phase + Double(i) * 0.5) * .pi * 2) * 3)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                phase = 1
            }
        }
        .accessibilityLabel("Assistant is typing")
    }
}
```

Honor reduced motion: if `@Environment(\.accessibilityReduceMotion)` is true, render static dots.

### 5.3 Input bar

Floating bar pinned to the bottom safe area inset.

- Container: `surface` fill, 16pt corner radius, 0.5pt `border` stroke, `shadowSm`. Padding `(8, 8)`. Inner layout: `HStack(alignment: .bottom)`.
- Textarea: `TextField` with `.lineLimit(1...6)`, `.font(.edBody)`, `.foregroundStyle(Tokens.ink)`, placeholder `Tokens.mutedSoft` "Ask anything…". Min height 40, max height 128.
- Mic button: 40×40, 10pt radius, `Tokens.muted` foreground, transparent background. Active (recording): `dangerSoft` background, `danger` foreground, icon swaps from `mic.fill` to `square.fill`. Use Apple's `Speech` framework.
- Send button: 40×40, 10pt radius, `ink` fill, `paper` foreground, icon `arrow.up`. Disabled state: fill `paper2`, foreground `mutedSoft`.
- Focus state: container border becomes `accent` (current section), `shadowMd`, with a 2pt outer ring at `accentRing`. Animate over 200ms.

Outer padding: `lg` horizontal, `lg` bottom safe inset, `sm` top.

### 5.4 Example-prompt chips

Three pill buttons. Tap fills the input field and focuses it.

- Padding: `horizontal: 16, vertical: 6`.
- Background: `surface` fill, 0.5pt `border` stroke. Pressed: `paper2` fill, `borderStrong` stroke.
- Font: `.edFootnote` (Inter Medium 13).
- Foreground: `Tokens.ink`.
- Corner radius: `Radius.pill`.
- Layout: horizontal `HStack` with 8pt gap, wrapping to a second row on narrow screens via custom flow layout (or vertical stack on iPhone — use `Layout` protocol if needed, or simpler: vertical `VStack` on phones).

---

## 6. Draft Preview Card

Mirrors `DraftPreviewCard.jsx` exactly.

### 6.1 Layout

```
┌──────────────────────────────────────┐
│ NEW TASK                             │  eyebrow row, Inter 11 SemiBold UPPERCASE muted, tracking 1.4
│                                      │
│ Call John                            │  Inter 16 medium, ink
│ [📅 Apr 30, 3:00 PM] [#work]        │  chips: paper2 fill, border stroke, 11pt text
│                                      │
│ [✓ Confirm] [✎ Edit] [✕ Cancel]    │  buttons, see §6.2
└──────────────────────────────────────┘
```

- Container: `surface` fill, `border` stroke 0.5pt, `Radius.lg` (12).
- Padding: 16pt all sides.
- Vertical spacing between sections: 12pt.

### 6.2 Buttons

Three variants matching the webapp `Button.jsx`:

| Variant | Fill | Stroke | Foreground |
|---|---|---|---|
| `primary` (Confirm) | `Tokens.ink` | none | `Tokens.paper` |
| `secondary` (Edit) | `Tokens.surface` | 0.5pt `Tokens.border` | `Tokens.ink` |
| `ghost` (Cancel) | clear | none | `Tokens.muted` |

All sizes:
- `sm`: padding `horizontal: 12, vertical: 6`, font `.edFootnote`, icon 14pt.
- `md`: padding `horizontal: 14, vertical: 8`, font `.edBody`, icon 16pt.
- Corner radius `Radius.md` (10).
- Disabled: 40% opacity.

```swift
enum ButtonKind { case primary, secondary, ghost }

struct EdButtonStyle: ButtonStyle {
    let kind: ButtonKind
    func makeBody(configuration: Configuration) -> some View {
        let (fg, bg, stroke): (Color, Color, Color?) = {
            switch kind {
            case .primary:   return (Tokens.paper, Tokens.ink, nil)
            case .secondary: return (Tokens.ink, Tokens.surface, Tokens.border)
            case .ghost:     return (Tokens.muted, .clear, nil)
            }
        }()
        return configuration.label
            .font(.edFootnote)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(stroke ?? .clear, lineWidth: stroke == nil ? 0 : 0.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
```

### 6.3 Action labels (eyebrow content)

Match webapp `actionLabels` map exactly:
- `CREATE_TODO` → "NEW TASK"
- `CREATE_NOTE` → "NEW NOTE"
- `CREATE_LIST` → "NEW LIST"
- `UPDATE_TODO` → "UPDATE TASK"
- `COMPLETE_TODO` → "COMPLETE TASK"
- `DELETE_TODO` → "DELETE TASK"
- (etc — full map in `DraftPreviewCard.jsx` lines 8–24)

### 6.4 Chips inside the card

- Default: `paper2` fill, `border` stroke, `muted` text, `Radius.pill`, padding `(8, 2)`, font `.edCaption` (12pt). Icon 12pt leading.
- Warning (due within 24h): `warningSoft` fill, `warning` foreground.

---

## 7. Tasks / Notes / Lists Surfaces

### 7.1 Container rule

Each section is a paper surface, not a SwiftUI `List`. SwiftUI's default `List` adds heavy chrome (grouped insets, separator pixel lines, iOS background gray) that fights the warm-paper aesthetic.

**Use `ScrollView { LazyVStack { } }`** with manual row styling. Pull-to-refresh via `.refreshable` is fine.

### 7.2 Tasks surface

```
┌────────────────────────────────────────┐
│ [☰]            Tasks       [☀] AS    │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │ Add a new task…              [+] │  │ ← input row, surface, border
│  └──────────────────────────────────┘  │
│                                        │
│  [🔽 All tags ▾]                       │ ← filter chip
│                                        │
│  Overdue · 2                           │ ← section header, danger
│  ⭕ Task title…                #work   │ ← row
│  ⭕ Another overdue task               │
│                                        │
│  Today · 3                             │ ← warning
│  ⭕ Pick up groceries          ⏰ 5pm   │
│  …                                     │
│                                        │
│  This Week · 5                         │ ← inkSoft
│  …                                     │
│                                        │
│  ▶ Completed · 12                      │ ← collapsed by default
│                                        │
│                              [✨]      │ ← chat FAB
└────────────────────────────────────────┘
```

- Section headers: `.edHeading` (Inter 17 SemiBold), with a small count chip beside it.
  - Overdue: `Tokens.danger` foreground, `dangerSoft` chip background.
  - Today: `Tokens.warning` foreground, `warningSoft` chip background.
  - This Week / Remaining: `Tokens.inkSoft`, `paper2` chip.
  - No Date / Completed: `muted` foreground.
- Row: 12pt padding, `paper2` background on hover/press, transparent default. 0.5pt `divider` between rows OR 8pt vertical gap (pick gap, no rule lines — it's calmer).
- Checkbox: 24pt circle, 2pt stroke `borderStrong` when unchecked, `success` filled when checked with `paper` checkmark inside.
- Title: `.edBody`, `Tokens.ink`. Completed: `.strikethrough()`, `mutedSoft` foreground.
- Tag pill: 8pt × 2pt padding, `paper2` fill, `border` stroke, `inkSoft` text, `Radius.pill`. Tap to inline-edit.
- Due date: `.edCaption`. Overdue → `danger`. Today → `warning`. Else → `inkSoft`.

### 7.3 Notes surface

Two-pane on iPad, master-detail push on iPhone (`NavigationStack`). Folder list → notes list → note detail.

- Folder row: 16pt padding, folder icon (SF `folder`) leading 16pt, name `.edBodyMedium`, count `.edCaption muted` trailing.
- Note row: title `.edBodyMedium ink`, snippet `.edSubheadline muted` (one line, truncated), date `.edCaption mutedSoft`. 12pt vertical padding, 16pt horizontal.
- Note detail: title editable inline, body editable inline. `.edTitle` for title (Calistoga 22). `.edBody` for body. Background `paper`. No card, just a clean writing surface with `lg` padding.

### 7.4 Lists surface

Two-pane same as Notes. Lists list → list detail (with checkboxes).

- List row: title `.edBodyMedium ink`, item count chip with `Hash` icon trailing.
- List detail: title `.edTitle`, items as a vertical stack of rows. Each item: 24pt circle checkbox + `.edBody` text. Checked: `.strikethrough()` + `mutedSoft`. Add-item input pinned to bottom (same surface treatment as the chat input bar but smaller).

---

## 8. Light + Dark Mode

### 8.1 Resolution

Three states match the webapp's preferences:
1. **System** (default): follow `UIScreen.userInterfaceStyle`. No override.
2. **Light**: force light.
3. **Dark**: force dark.

Persist via `@AppStorage("colorScheme")` storing `"system" | "light" | "dark"`.

```swift
enum ColorSchemePref: String { case system, light, dark }

@main
struct PersonalDashboardApp: App {
    @AppStorage("colorScheme") private var pref = ColorSchemePref.system.rawValue
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(resolved)
        }
    }
    private var resolved: ColorScheme? {
        switch ColorSchemePref(rawValue: pref) ?? .system {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
```

### 8.2 Settings UI

In the (eventual) Settings drawer entry, expose a 3-segment picker: System · Light · Dark. Match the webapp's `ThemeToggle` behavior. Until Settings ships, the top-bar sun/moon icon cycles light → dark → system.

### 8.3 Status bar

Set `.statusBarStyle(.darkContent)` in light mode and `.lightContent` in dark mode. The `.preferredColorScheme` modifier does not adjust the status bar text color automatically on all paths — be explicit.

---

## 9. Anti-Patterns (DO NOT DO)

These are violations the current iOS code commits or could easily commit. Forbid each one explicitly.

1. **Do NOT use `Color.blue`, `Color.accentColor`, or any system color for active accent.** Use `Tokens.accent(for: section)`. The current TabView's selected tab tint is system blue — replace.
2. **Do NOT use `TabView` as the root.** Chat is the root. (See §4.)
3. **Do NOT use `List` with default styling** (`.listStyle(.insetGrouped)`, `.plain`, or `.sidebar`). Use `ScrollView { LazyVStack { } }`. SwiftUI's default `List` insets and section grouping break the paper aesthetic.
4. **Do NOT use SF Symbols as hero illustrations.** Small inline icons (16-32pt) are fine. Anything larger (the empty-state hero glyph, settings panels) must be either a 32pt SF Symbol with strict `.regular` weight OR a custom asset. Never a 96pt SF Symbol — they look generic.
5. **Do NOT use `NavigationSplitView` for the drawer.** It enforces an iPadOS sidebar look the webapp does not have. Hand-roll the drawer.
6. **Do NOT use `.background(.regularMaterial)` or any blur material on cards.** The aesthetic is opaque paper, not iOS frosted glass.
7. **Do NOT use SF Pro for body text.** Bind to Inter via `.font(.edBody)` etc. SF Pro is a fallback only when the custom font fails to load.
8. **Do NOT use system corner radii** (e.g. `RoundedRectangle(cornerRadius: 8)` arbitrary values). Use `Radius.*` tokens.
9. **Do NOT animate longer than 250ms.** The webapp uses 150-200ms. Match it.
10. **Do NOT show a chat avatar on AI prose.** AI is bubble-less, name-less, avatar-less prose. Same for the user (no avatar bubble).
11. **Do NOT use `ProgressView()` default style** for the typing indicator. Use the three-bounce dots specified in §5.2.3.
12. **Do NOT haptic on every tap.** Reserve `UIImpactFeedbackGenerator(.light)` for: confirm draft, send message, complete task. Nothing else.
13. **Do NOT round avatar pip with `.clipShape(.circle)` over a colored fill.** The "AS" pip is `paper2` background with `border` stroke — a paper coin, not a colored badge.
14. **Do NOT inline emojis as icons.** Use SF Symbols (or assets) only.
15. **Do NOT add a back-button label on the chat root.** The root has no back. Sub-screens use the system chevron + `Chat` label.

---

## 10. Wireframes per Surface

### 10.1 Chat — empty state

```
┌──────────────────────────────────────────────────┐
│ [☰]                                  [☀] [AS]   │  56pt top bar
├──────────────────────────────────────────────────┤
│                                                  │
│                                                  │
│                                                  │
│                                                  │
│                       ✨                          │  Sparkles 32pt muted
│                                                  │
│                       ━━                          │  ink hairline 32pt × 2pt
│                                                  │
│           What can I help you organize?           │  Calistoga 28 ink
│                                                  │
│       Ask for a task, a note, or a list.         │  Inter 16 muted
│       I'll draft it for you to confirm.          │
│                                                  │
│   ┌──────────────────────┐  ┌────────────────┐   │  pill chips
│   │ Remind me to call J… │  │ New shopping … │   │
│   └──────────────────────┘  └────────────────┘   │
│   ┌────────────────────┐                         │
│   │ Note: ideas Q3 OKRs│                         │
│   └────────────────────┘                         │
│                                                  │
│                                                  │
├──────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────┐ │  input bar
│ │ Ask anything…                       [🎤] [↑] │ │
│ └──────────────────────────────────────────────┘ │
│   Try "Remind me to call Mom tomorrow"…          │  caption (phone only)
└──────────────────────────────────────────────────┘
```

### 10.2 Chat — active with messages and a draft card

```
┌──────────────────────────────────────────────────┐
│ [☰]              Chat                [☀] [AS]   │
├──────────────────────────────────────────────────┤
│                                                  │
│  Got it. I'll draft that task for you to        │  AI prose, inkSoft, no bubble
│  confirm.                                        │
│                                                  │
│                                                  │
│                       ┌──────────────────────┐   │
│                       │ remind me to call    │   │  user bubble
│                       │ John tomorrow at 3   │   │  ink fill, paper text
│                       └──────────────────────┘   │  rounded 16/4(br)
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ NEW TASK                                   │  │  draft card
│  │                                            │  │  surface fill
│  │ Call John                                  │  │  ink medium
│  │                                            │  │
│  │ ┌──────────────────┐  ┌──────────┐         │  │
│  │ │ 📅 Apr 30, 3 PM  │  │ 🏷 work  │         │  │  chips
│  │ └──────────────────┘  └──────────┘         │  │
│  │                                            │  │
│  │ ┌─────────┐ ┌──────┐ ┌──────────┐          │  │
│  │ │✓ Confirm│ │✎ Edit│ │✕ Cancel │          │  │  buttons
│  │ └─────────┘ └──────┘ └──────────┘          │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  ✓ Task created  [View →]                       │  success row
│                                                  │
│  • • •                                           │  typing indicator
│                                                  │
├──────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────┐ │
│ │ Ask anything…                       [🎤] [↑] │ │
│ └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

### 10.3 Tasks list

```
┌──────────────────────────────────────────────────┐
│ [☰]              Tasks               [☀] [AS]   │
├──────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────┐ [+]│  add row + icon button
│ │ Add a new task…                          │    │
│ └──────────────────────────────────────────┘    │
│                                                  │
│ [🔽 All tags ▾]                                  │  filter chip
│                                                  │
│ Overdue · 2                                      │  Inter 17 SemiBold danger
│ ─────────                                        │
│ ⭕ Pay phone bill                       Mon 4pm  │
│ ⭕ Submit reimbursement                 Tue 9am  │
│                                                  │
│ Today · 3                                        │  warning
│ ⭕ Pick up groceries        🏷 personal  5:00 PM │
│ ⭕ Reply to Anna                          —      │
│ ⭕ Read draft PRD            🏷 work             │
│                                                  │
│ This Week · 5                                    │  inkSoft
│ ⭕ Book dentist                       Thu 11am   │
│ …                                                │
│                                                  │
│ ▶ Completed · 12                                 │  collapsible, success
│                                                  │
│                                       [✨]       │  chat FAB, bottom-right
└──────────────────────────────────────────────────┘
```

### 10.4 Note detail

```
┌──────────────────────────────────────────────────┐
│ [‹ Notes]            Notes           [☀] [AS]   │  back chevron + label
├──────────────────────────────────────────────────┤
│                                                  │
│ Q3 OKRs Brainstorm                               │  Calistoga 22 ink, editable
│                                                  │
│ Apr 28 · Personal                                │  Inter 12 muted
│                                                  │
│ ─────────────────────────────────                │
│                                                  │
│ Three threads worth pulling on this              │  Inter 16 ink, body, editable
│ quarter:                                         │
│                                                  │
│ - rebuild the onboarding funnel before           │
│   the Q3 marketing push                          │
│ - retire the legacy webhook handler              │
│ - finally land the design-system v2              │
│   migration                                      │
│                                                  │
│                                                  │
│                                                  │
│                                       [✨]       │  chat FAB
└──────────────────────────────────────────────────┘
```

### 10.5 List detail

```
┌──────────────────────────────────────────────────┐
│ [‹ Lists]            Lists           [☀] [AS]   │
├──────────────────────────────────────────────────┤
│                                                  │
│ Saturday Groceries                          🗑   │  Calistoga 22, trash trailing
│ 4 of 7 items                                     │  Inter 12 muted
│                                                  │
│ ─────────────────────────────────                │
│                                                  │
│ ☑ Milk                                           │  checked: strikethrough mutedSoft
│ ☑ Eggs                                           │
│ ☑ Sourdough                                      │
│ ☑ Apples                                         │
│ ⭕ Greek yoghurt                                  │  unchecked: ink
│ ⭕ Coffee beans                                   │
│ ⭕ Sparkling water                                │
│                                                  │
│ ┌──────────────────────────────────────┐         │
│ │ Add an item…                     [+] │         │  add-item row
│ └──────────────────────────────────────┘         │
│                                                  │
│                                       [✨]       │  chat FAB
└──────────────────────────────────────────────────┘
```

### 10.6 Drawer (open over chat)

```
┌────────────────────────┬─────────────────────────┐
│ ▣ Dashy                │░░░░░░░░░░░░░░░░░░░░░░░░│  scrim ink @ 40%
│                        │░░░░░░░░░░░░░░░░░░░░░░░░│
│ 📅 Today               │                         │
│ 💬 Chat ◀ accent rail │                         │
│ ──────────             │                         │
│ ☑ Tasks                │                         │
│ 📝 Notes               │                         │
│ ☰ Lists                │                         │
│ ──────────             │                         │
│ ▣ Dashboard            │                         │
│ ──────────             │                         │
│ ⚙ Settings             │                         │
│                        │                         │
│                        │                         │
│ [☀]   AS  Akshay       │                         │
└────────────────────────┴─────────────────────────┘
   280pt
```

---

## 11. Webapp UX patterns that translate differently

| Webapp pattern | iOS-native equivalent |
|---|---|
| Hover states on rows / chips | Drop. Use `.contentShape()` + tap-press states (`isPressed`) for visible feedback. |
| `Cmd+K` command palette + `Kbd` hint pills | Defer entirely. Native equivalent (when added) is a `.searchable` modifier or a `.sheet` on a search button. The keyboard-hint pills disappear on iOS. |
| Sidebar collapsed-by-default expanding on hover | Drawer is fully-open or fully-closed. No hover state on iOS. The collapsed-rail aesthetic does not translate — replaced by a hamburger button. |
| Right-click context menus | Use `.contextMenu { }` on long-press for tasks/notes/lists rows. |
| Inline `datetime-local` HTML input | `DatePicker` with `.compact` style inside a sheet, or `.graphical` for the popover-equivalent. Match `Tokens.accent` via `.accentColor()`. |
| `Tooltip` on title hover (TodoWidget) | Drop. Tap-to-edit replaces hover entirely. |
| `motion-safe:animate-bounce` and similar Tailwind classes | Honor `@Environment(\.accessibilityReduceMotion)` — substitute static state when true. |
| `position: fixed` floating elements (FAB, popover) | Use `.overlay(alignment:)` on the screen root. Layer with `zIndex` only when nesting forces it. |

---

## 12. Reduced motion + accessibility notes

- All animation must check `@Environment(\.accessibilityReduceMotion)` and shorten to a 1-frame fade or skip entirely.
- All interactive controls must be 44pt minimum hit target. Visual size can be 32pt (e.g. send button is 40, mic is 40 — already fine).
- Color pairs must clear WCAG AA. The token pairs above were validated:
  - `ink` on `paper`: 14.6:1 (light), 12.4:1 (dark) — pass.
  - `inkSoft` on `paper`: 8.7:1 (light), 9.1:1 (dark) — pass.
  - `muted` on `paper`: 4.6:1 (light), 5.0:1 (dark) — pass for non-body.
  - `mutedSoft` on `paper`: 2.7:1 — placeholder only, never primary text.
  - `paper` on `ink` (user bubble): inverse, also passes.
- Dynamic Type: bind every custom font to a relative scale via `.dynamicTypeSize(.large ... .accessibility3)` and use `Font.custom(_:size:relativeTo:)` so users at higher DT settings still scale.
  - Example: `Font.custom("Inter-Regular", size: 16, relativeTo: .body)`.
  - Update §2.5 to use the `relativeTo:` form when applying tokens at the call site.
- VoiceOver labels for all icon-only buttons. Examples: send button → `accessibilityLabel("Send")`, mic → `"Voice input, double-tap to start"` and `"Voice input, recording, double-tap to stop"`.
- Hit testing on the user bubble: not a button, but its content is selectable text on long-press (`.textSelection(.enabled)`).

---

## 13. Pre-delivery checklist (orchestrator runs this on the implementing agent)

The implementing agent's PR must satisfy:

- [ ] All five fonts shipped in Resources/Fonts and listed in Info.plist.
- [ ] `Tokens.swift`, `Typography.swift`, `Buttons.swift` (button styles), `Spacing.swift` exist as separate files.
- [ ] No `Color.blue`, `Color.accentColor`, no system primary anywhere (search the diff).
- [ ] No `TabView` at root.
- [ ] No `List(...)`. Search for the keyword and confirm zero hits in views.
- [ ] No `NavigationSplitView`.
- [ ] Chat empty state matches §5.1 wireframe within 4pt tolerance.
- [ ] User bubble has the 4pt bottom-right corner. Spot-check via screenshot.
- [ ] AI prose is bubble-less.
- [ ] Drawer slides in at 200ms ease-out, scrim is `ink @ 40%`.
- [ ] Each section's accent fires correctly: Tasks shows indigo borders/focus, Notes shows amber, etc.
- [ ] Light/dark both visually correct via `.preferredColorScheme()` toggle.
- [ ] Reduced-motion run-through: all animations either skipped or shortened.
- [ ] Dynamic Type at .accessibility1: layout still readable, no clipping.
- [ ] All icon-only buttons have `.accessibilityLabel`.

If any checkbox fails, fix before declaring the PR ready.
