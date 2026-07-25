# macOS design language (DexterMac)

The one design language for the native macOS target. Written as rules a future agent can apply mechanically, without re-deriving intent.

Arbiter: Apple HIG for macOS, and the observable behaviour of Reminders, Notes, and Mail on macOS 14+. iOS HIG does not apply here.

Scope: the `DexterMac` target only. Every rule below is implemented behind `#if os(macOS)` or in a macOS-only file. iOS stays byte-for-byte unchanged. When a rule cannot be honoured without changing the shared iOS render path, it is raised as an iOS follow-up issue instead of applied.

---

## 0. What "minimal" means here, and what it does not

The app has a deliberate visual identity, "Editorial Calm": a warm paper/ink neutral spine, per-section accent hues, and three custom typefaces (Calistoga display serif, Inter sans, JetBrains Mono). It lives in `Design/Tokens.swift` and `Design/Typography.swift` and is shared with iOS.

**Minimal does not mean replacing that identity with system colors and system fonts.** Doing so would break the brand and break consistency with iOS, both of which are explicit goals. The palette and the typefaces stay.

Minimal means four specific things:

1. **Native structure.** The window toolbar, the sidebar, popovers, panels, focus rings, menu commands, and context menus are the system's job. Stop hand-rolling them in-view.
2. **Native metrics.** Control sizes, row heights, and type sizes follow macOS conventions, not iOS touch conventions.
3. **Less enclosure.** Typography and whitespace carry the hierarchy. Borders, cards, and dividers are the exception, not the default.
4. **Every affordance earns its pixels.** If an element is not doing work, delete it.

So: Editorial Calm colors and typefaces, rendered at macOS sizes, inside native macOS structure, with the boxes removed.

---

## 1. Type scale

**Rule: `Design/Typography.swift` gains a macOS branch. The token names, weights, and hierarchy do not change; only the point sizes do.**

The current scale is iOS-sized and shared verbatim, so every string in all 10 sections renders roughly 20 to 25 percent too large on the Mac. `edBody` is 16pt where the macOS system body is 13pt. This is the single highest-leverage fix in the overhaul: one file, all 10 sections.

| Token | iOS (keep) | macOS (target) | Notes |
|---|---|---|---|
| `edDisplay` | 28 | 22 | Calistoga. Section hero only. |
| `edTitle` | 22 | 17 | Calistoga. |
| `edHeading` | 17 semibold | 13 semibold | Inter. Matches macOS headline. |
| `edBody` | 16 | 13 | Inter. Matches macOS body. |
| `edBodyMedium` | 16 medium | 13 medium | Inter. |
| `edSubheadline` | 15 | 12 | Inter. |
| `edFootnote` | 13 medium | 11 medium | Inter. |
| `edFootnoteStrong` | 13 semibold | 11 semibold | Inter. |
| `edCaption` | 12 | 10 | Inter. |
| `edEyebrow` | 11 semibold | 10 semibold | Tracking drops 1.4 to 0.8. Tracking tuned for 11pt reads loose at 10pt. |
| `edMono` | 13 | 11 | JetBrains Mono. |

Keep `relativeTo:` on every token so Dynamic Type and the accessibility sizes still work.

Target numbers are the rule; a visual pass may adjust by at most 1pt. Any change beyond that updates this table.

## 2. Density

macOS shows more per screen. iOS touch targets are wrong here.

All "observed" figures below are measured off 2x retina screenshots of the app at its own default window size and **halved to points**. Measure this way or the numbers double. Reference targets are Reminders, Notes, and Mail on macOS 14+.

| Element | Observed | macOS target |
|---|---|---|
| Two-line row pitch (Tasks, Today, Finance) | **63pt** | 44 to 48 |
| Two-line row pitch (Today notes) | 61pt | 40 to 44 |
| Declared row `minHeight` in code | 40 (Tasks), 44 (Lists) | 28 single-line |
| Sidebar row pitch | 32pt | 24 to 28 |
| Row checkbox / bullet diameter | 21 | 16 |
| Category / list icon chip | 36 to 40 | 20 sidebar, 26 row |
| Icon-only button hit frame | 40x40 | 22x22 |
| Minimum control height | 44 | 22 |
| In-content search field height | 33pt | toolbar `.searchable` |
| Floating add button | 48pt circle, shadow radius 12 | toolbar `+` |
| Window opening size | 900x652, the enforced minimum | declare a `defaultSize` |
| Section content horizontal gutter | `Space.lg` (16) | `Space.md` (12) |

Rows are the main offender, not the sidebar.

### Measured baseline per section, at `a88b48e`

Pixel-scanned from the source PNGs and halved. This is the "before" for the density and flattening work.

| Section | Row pitch | Container | Notes |
|---|---|---|---|
| Notes | 54pt (45pt card + 9pt gap) | Gapped cards | Title cap height 10pt |
| Lists | 75pt (66pt card + 9pt gap) | Gapped cards | 39.5pt icon chip, progress track |
| Trips | 79pt (70pt card + 9pt gap) | Gapped cards | No leading icon |
| Vocabulary | 43.5pt card | Gapped cards | No empty state despite 85% dead space |
| Activity | 56.5 / 65.5 / 82.5pt by line count | **Flat, hairlines** | 31.5pt icon chip. Closest to the reference |
| Settings | 43.5pt | **One grouped card, internal hairlines** | The most macOS-native pattern present |
| Tasks / Today / Finance | 63pt | Rows and cards | |
| Chat | 36pt chip pitch, 56pt input bar | Flat page | Input bar is 2x a standard macOS field |

Three different container systems exist for what is structurally the same thing, a list of items: gapped per-item cards (Notes, Lists, Trips, Vocabulary), one grouped card with internal hairlines (Settings), and flat rows with hairlines (Activity). **Converge on Activity's flat rows for content lists and Settings' grouped card for settings-style forms.** Those two are already right; the gapped-card sections are the ones to change.

Card height spans 43.5pt to 70pt across the four carded sections, a 60 percent spread for the same pattern. Same-role text also drifts: item titles run 10pt cap height in Notes against 12pt in Lists, Trips and Vocabulary; uppercase section headers run 7.5pt cap in Notes and Settings against 10pt in Activity. The same colored rounded-square icon chip is 39.5pt in Lists and 31.5pt in Activity.

At the default window width roughly 55 to 60 percent of each row's width is empty, because rows are full-bleed single-column with the trailing control pinned to the far right edge. Measured content-width usage is 92 to 95 percent in the carded sections, so the pane is filled; it is the row's internal layout that strands the space.

`Space` and `Radius` keep their scales. What changes is which step a macOS layout reaches for. Where a macOS-specific value is needed, add a computed `#if os(macOS)` property to `Space`/`Radius` following the existing `rowTrailingGutter` and `Radius.card` precedent, rather than hardcoding numbers at the call site.

## 3. Chrome: one title, one place for actions

**Rule: the native window toolbar owns the title and the actions. In-view header rows are not permitted on macOS.**

This is already established and already applied to all 10 sections. Do not undo it. Use the existing helpers in `Design/MacChrome.swift`:

- `macSectionChrome(_ title:)` for a top-level section. Optional `trailing:` slot for one secondary control.
- `macDetailChrome(title:subtitle:onBack:actions:)` for a pushed detail (an open list, folder, note, or trip). `actions` is a `ToolbarItemGroup`, so macOS 26 draws the icons as one Liquid Glass pill, with the AS profile coin as a separate element to its right. This matches Reminders.
- Apply the chrome **per branch** (section list vs open detail), never on the outer container. Applying it once on the outer `ZStack` leaves the title stuck on the section name.
- `canvasIgnoresSafeArea()` for a section background. Never `ignoresSafeArea()` directly: on macOS that collapses the title-bar inset and slides content under the traffic lights.

Corollaries:

- A section renders its title exactly once, in the toolbar. No duplicate in-view title.
- The floating circular add button (`EdIconCircleButtonStyle`, 48pt, drop shadow) is a phone idiom. On macOS the create action is a toolbar `+`, wired to ⌘N.
- Do not disable the toolbar material globally. `.toolbarBackground(.hidden, for: .windowToolbar)` is currently applied in both chrome helpers; Reminders and Notes *do* show a material band once content scrolls under the title bar, and hiding it everywhere loses that separation. Revisit as its own change with a visual check.

## 4. Controls and enclosure

- **Buttons.** Toolbar and in-view icon buttons use `macPlainButtonStyle()` + `macHeaderIconChrome()`: bare glyph at rest, soft rounded highlight on hover. Never the default bordered square. Never a custom filled pill for a secondary action.
- **Text fields.** `plainFieldStyleOnMac()` inside any custom surface, so the field does not draw its own bordered box inside your box. For a transparent inline row editor use `MacClearTextField`, which suppresses the AppKit field-editor background.
- **Lists.** `macTamedListSelection()` to kill the hard full-bleed grey selection bar, paired with `macRowHover()` for the pointer affordance.
- **Add rows.** `MacAddRow` is the shared persistent add row for Tasks and Lists. It is always present, so a real mouse-down focuses it natively. Do not reintroduce the iOS ghost-to-draft swap on macOS: programmatic focus races the click.
- **Row collections use `List`.** A scrollable set of rows is a SwiftUI `List`, never `ScrollView { VStack { ForEach } }`. This is not a style preference. `.swipeActions` has no effect outside a `List` and fails silently, and `macRowHover()` / `macTamedListSelection()` are inapplicable. Three surfaces are currently built the wrong way (Finance expenses, Recurring Expenses, Trip expenses) and consequently have no working delete on macOS at all.
- **Enclosure budget.** `paperBorder(...)` appears at 93 call sites across the views. Most are a hairline box around content that needs no box. Default to no border. Reach for one only when two adjacent regions would otherwise be ambiguous, and never nest one bordered surface inside another.
- **Materials.** Use system materials for chrome layers (toolbar, sidebar, popover) and let the system draw them. Use `Tokens.paper` for the content canvas. Do not paint custom translucency over a system material.

## 5. Keyboard

**Rule: every action reachable by pointer is reachable by keyboard, and the menu bar advertises it.**

Current state: zero `.commands`, zero `keyboardShortcut`, no `Settings` scene, zero `.searchable`. The menu bar is stock defaults, so the app has no ⌘N, no ⌘F, and no ⌘, anywhere. This is the largest single "not a Mac app" gap.

Search deserves a precise note, because "no search" is not quite true. Finance and Parsed Files each hand-roll an in-content search `TextField` (33pt tall in Finance). What is missing is `.searchable`, so search is never in the toolbar, never keyboard-reachable, and absent from the other eight sections. Replace the hand-rolled fields with `.searchable` rather than adding a second search idiom next to them.

The contract:

| Shortcut | Action |
|---|---|
| ⌘N | New item in the active section |
| ⌘F | Focus the active section's search field |
| ⌘, | Settings |
| ⌘Delete | Delete the selected row |
| Return | Commit the active inline edit, then chain a new entry |
| Escape | Cancel the active inline edit or dismiss the popover, without creating |
| Tab / Shift-Tab | Move focus in visual order, with a visible focus ring |
| ⌘1…⌘9 | Jump to sidebar section |

Implementation shape, because ⌘N has to mean different things per section:

1. `DexterMacApp` declares a `Settings { }` scene (gets ⌘, for free) and a `.commands { }` block.
2. Each section publishes its own actions up to the scene via `focusedSceneValue`. The `.commands` block invokes whatever the focused section published, and the menu item disables itself when the focused section publishes nothing.
3. Do not scatter `keyboardShortcut` on in-view buttons to fake this. A shortcut that is not in the menu bar is undiscoverable, and duplicate shortcuts across sections conflict silently.

Escape must not create. `MacAddRow` already gets this right: Escape clears the text first, so the blur commit has nothing to create. Match that behaviour everywhere.

## 6. Pointer

- **Hover.** Every row and every control has a hover state. Rows use `macRowHover()`. Icon buttons use `macHeaderIconChrome()`.
- **Cursor.** An I-beam over click-to-edit text (`macRowHover()` does this). Default arrow elsewhere. Balance every `NSCursor.push()` with a `pop()`; the deployment target is macOS 14, so `.pointerStyle` (15+) is unavailable.
- **Context menus.** Every row that has actions has a right-click menu carrying them. Two `.contextMenu` call sites exist in the whole app today. Reminders has one on every row. A context menu is the macOS home for what iOS puts behind a swipe.
- **Tooltips.** `.help("…")` on every icon-only control. Eight exist today. An icon-only button with no tooltip and no menu equivalent is undiscoverable.
- **Swipe actions are not an affordance on macOS.** They need a trackpad, they are invisible to a mouse user, and outside a `List` they do nothing at all. Treat swipe as a bonus, never as the delivery mechanism.

**Rule: every destructive or secondary row action ships three ways.** A context-menu item, a menu-bar command with a shortcut (⌘Delete), and a control in the item's own editor. Swipe may exist on top of those. A row action that exists only as a swipe is unreachable on the Mac, and today that is the state of expense deletion across three surfaces.

## 7. Motion

- Every animation reads `@Environment(\.accessibilityReduceMotion)` and has a still fallback. `TypingIndicator` and `InkOrb` do this; `LogoBars` in Chat does not, and drives a continuous 60fps `TimelineView` for as long as the empty state is on screen. A Mac window stays open for hours, so an unbounded idle animation is a battery and attention cost that a phone screen never pays.
- Animate state changes, not decoration. 120ms to 200ms, ease-out. No looping ambient motion in a section view.

## 8. States

- **Empty.** Use `ContentUnavailableView` (macOS 14+). Zero call sites today; every empty state is hand-rolled, and several are a 40pt icon over centred text, which is phone-sized. The title says what is missing, the description says why, and it carries the primary action.
- **Loading.** A determinate or indeterminate system `ProgressView`, inline, at `.controlSize(.small)`. No custom spinners, no skeleton screens that mimic the row shape at the wrong density.
- **Error.** Errors are visible and recoverable in place, with a retry. A section that fails must not render an empty list that looks like "you have no data".
- **Server-bound surfaces.** Activity and the Dashboard stats still call a server that does not exist on the Mac. These must degrade to an explicit, honest state with no indefinite spinner. Behaviour here is Backend's call; the presentation is ours.

## 9. Window and layout

- `WindowGroup` declares a `defaultSize`. A `minWidth`/`minHeight` frame on the root content view sets a floor but never a sensible opening size.
- Sidebar width is declared with `navigationSplitViewColumnWidth(min:ideal:max:)`, not a bare `frame(minWidth:)`, so the column resizes and collapses predictably.
- The selected section persists across launches via `SceneStorage`. It currently resets to Tasks every launch.
- Content is width-tolerant: no fixed content widths, no single-column-only layouts that strand whitespace at 1600pt. Where a layout genuinely has an ideal reading width, centre it and cap it, do not stretch it.
- **Create versus edit.** Creating a new thing is a sheet. Editing an existing thing is a popover anchored to the row it belongs to. Tasks already splits these correctly; Vocabulary collapses both into one sheet and is the outlier.
- **Hairlines.** One technique for a rule: `Rectangle().fill(Tokens.divider).frame(height: 0.5)`. Do not mix in system `Divider()`, which resolves to a different, thicker line on macOS and will not match.
- **Containers.** 37 `.sheet` call sites against 3 `.popover`. On macOS a sheet is for a modal decision the user must resolve now. Everything else is a popover anchored to its trigger, or an inspector panel. A small edit form arriving as a full modal sheet is the most common iOS-shaped mistake in this codebase. Tasks already does this correctly with an editor popover.

## 10. Scene hooks and app lifecycle

The macOS shell currently has no `.task` and no `scenePhase` observer at all, where iOS wires both in `App/PersonalDashboardApp.swift:15-57`. Two shipped features are dead on the Mac as a result: automatic backup never fires, and recurring expenses never post on schedule. Both look functional, because the manual paths work.

When wiring lifecycle work into the macOS shell, three rules:

1. **`.task` on a `WindowGroup`'s root view runs once per WINDOW, not once per process.** `scenePhase` is per scene for the same reason. macOS restores multiple windows on relaunch, and `WindowGroup` provides File > New Window for free. So a shell cannot promise "exactly once per launch". Any once-per-process work must be latched inside the service it calls, or hoisted out of the window's view into the `App` body.
2. **`.active` on macOS is not `.active` on iOS.** It fires on window focus and app switching, many times a session, not on a rare foregrounding. Anything expensive or anything gated on "is it due" must be throttled and single-flighted by the service, never by the view.
3. **`.background` on macOS means all windows hidden, not a suspended process.** It is not a last-chance-to-save signal. Do not port iOS code that treats it as one.

Keep the shell dumb. It calls a no-argument async entry point and holds no policy. Throttling, due-checks, and single-flight guards belong in the service layer where they can be reasoned about once.

## 11. Do not do this

- Do not render an in-view header row with a title and action icons. The toolbar owns both.
- Do not put a floating circular add button on macOS. The toolbar owns creation.
- Do not use `ignoresSafeArea()` on macOS. Use `canvasIgnoresSafeArea()`.
- Do not apply section chrome and detail chrome on the same container. Apply per branch.
- Do not use iOS touch metrics: no 44pt minimum control height, no 40x40 icon buttons, no 48pt circular buttons.
- Do not ship iOS type sizes on macOS. Use the macOS branch of the scale.
- Do not wrap content in a bordered card by default. Justify every `paperBorder`.
- Do not nest a bordered surface inside another bordered surface.
- Do not add a drop shadow to content. Shadows belong to system-drawn layers only.
- Do not add a gradient for decoration. The ticket surfaces are the one sanctioned exception, and they are a deliberate physical-object metaphor.
- Do not present a small edit form as a sheet. Use a popover or an inspector.
- Do not leave an icon-only control without both a `.help()` tooltip and a menu or context-menu equivalent.
- Do not add a `keyboardShortcut` that is not also a menu item.
- Do not hand-roll an empty state. Use `ContentUnavailableView`.
- Do not give the same object two different looks in two sections. Tasks draws a task's checkbox as a circle, Today draws the same task's checkbox as a rounded square. One object, one representation.
- Do not hand-roll an in-content search field. Use `.searchable` so search lands in the toolbar and answers ⌘F.
- Do not use `.pointerStyle` (macOS 15+). The target is macOS 14.
- Do not assume a `.task` on a window's root view runs once per launch. It runs once per window.
- Do not treat macOS `.active` as equivalent to iOS foregrounding, or `.background` as process suspension.
- Do not put lifecycle policy (due-checks, throttles, single-flight guards) in the shell. It belongs in the service.
- Do not leave an `NSCursor.push()` without a matching `pop()`.
- Do not remove `App/DexterMacApp.swift` or `InfoMac.plist` from the iOS target's `excludes`. Two `@main` is a build failure.
- Do not add a shared source file without adding it to the `DexterMac` `sources:` list in `mobile/project.yml`. It will compile on iOS and be invisible on macOS.
- Do not change a shared view's iOS render path to fix a macOS problem. Gate it, or raise an iOS follow-up.
- **Do not add an ungated `.contextMenu` to a shared row.** On iOS `.contextMenu` binds to long-press, so an ungated one silently invents a new phone gesture. That directly violates the standing project correction `feedback_inline_edit_gestures.md` ("never use long-press / context-menu Rename"). Every context menu added for macOS goes behind `#if os(macOS)`.
- Do not leave `presentationDetents` or `presentationDragIndicator` ungated. They are iOS bottom-sheet affordances and meaningless on macOS. Gate with `#if os(iOS)`; do not delete them, or you change iOS snap heights.
- Do not build a row list as `ScrollView { VStack { ForEach } }`. Use `List`, or delete silently stops working.
- Do not rely on `.submitLabel` or `.refreshable` on macOS. Both are iOS-only and no-op, so any behaviour resting on them is dead on the Mac.

## 12. Verification for any change under this language

1. `xcodegen generate`, then build both targets: `DexterMac` on `platform=macOS` and `PersonalDashboard` on `generic/platform=iOS`.
2. `git diff` shows no change to any iOS-reachable render path outside a `#if` gate.
3. Launch and check the touched surface at two window widths, and in both light and dark.
4. Tab through the surface: focus order is visual order, and the ring is visible at every stop.
5. Every new icon-only control has a tooltip; every row action has a context-menu entry.
6. Static checks are build verification, not QA. Tap-gesture, List-selection, complete, edit, and delete paths ignore synthetic clicks on macOS and require the user's hands-on pass. Report those as pending, never as verified.
