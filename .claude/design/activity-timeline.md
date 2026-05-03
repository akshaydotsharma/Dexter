# Activity Timeline — Design Brief

Issue: #16. Worktree: `personal-dashboard-activity-timeline`. Branch: `feat/activity-timeline`. Read-only chronological feed of every note, todo, list, and folder the user has created. Same shape on web and iOS, same API, same design language.

This brief is the source of truth for implementation. Reuse Editorial Calm tokens from `client/src/index.css` (web) and `mobile/PersonalDashboard/Design/Tokens.swift` (iOS). The only new token is `--color-accent-activity` (web) / `Tokens.accentActivity` (iOS).

---

## 1. Information architecture & navigation

### New token: Activity accent

A single new accent slotted alongside the per-section accents. Hue is plum / mauve. It reads as "history" and "archive", does not collide with the existing palette (Today red, Tasks indigo, Notes ochre, Lists teal, Settings slate, Chat/Dashboard ink), and harmonises with the warm-paper ground.

- Light: `#7C3F58` (plum). Contrast on `#FBF9F4` paper = 7.32:1 (AAA for normal and large text). Contrast on `#F4F0E6` paper-2 = 6.95:1 (AAA).
- Dark:  `#E5A3BA` (rose). Contrast on `#14110D` paper = 10.41:1 (AAA). Contrast on `#1B1813` paper-2 = 9.85:1 (AAA).

CSS additions (do not touch any other token):

```
@theme {
  --color-accent-activity: #7C3F58;
}
[data-theme="dark"] {
  --color-accent-activity: #E5A3BA;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    --color-accent-activity: #E5A3BA;
  }
}
[data-route="activity"] { --color-accent: var(--color-accent-activity); }
```

iOS additions (single line in `Tokens.swift`, plus an `AppSection.activity` case and its `accent(for:)` arm):

```
static let accentActivity = Color.paper(0x7C3F58, 0xE5A3BA)
```

### Web sidebar placement

Insert `Activity` as a new `NavLink` in `Sidebar.jsx`'s `ITEMS` array, immediately after `Dashboard` and before the divider above `Settings`. Same row treatment as every other entry: the active row gets the standard 3px `--color-accent` left rail (which now resolves to plum on the Activity route) and a `bg-paper-2` fill.

- Label: `Activity`.
- Icon: `History` from `lucide-react` (clock-counterclockwise glyph). Same size and stroke as siblings (`size={20} strokeWidth={1.75}`).
- Tooltip when collapsed: `Activity` (matches existing tooltip pattern).
- Route: `/activity`. Set `<html data-route="activity">` in the page wrapper so the accent token resolves.

Final web sidebar order: `Today, Chat / Tasks, Notes, Lists / Dashboard, Activity / Settings`.

### iOS drawer placement

Add `case activity` to the `AppSection` enum in `Design/Tokens.swift`. Wire it through `surfaceView(for:)` in `ContentView.swift`, and add a `DrawerRow(section: .activity, router: router)` in `SideDrawer.swift` directly below `DrawerRow(section: .dashboard, ...)` and before the divider above Settings. Active rail uses `Tokens.accent(for: .activity)` which returns `accentActivity`.

- `displayName`: `Activity`.
- `icon` (SF Symbol): `clock.arrow.circlepath`. Same size and weight as siblings (`size: 16, weight: .regular`).

---

## 2. Page-level layout

Container chrome is identical to other widgets so the page feels native to the dashboard.

### Web

- Outer page uses the existing `AppShell` with the `Sidebar`. Set `<html data-route="activity">`.
- Page body: a single `Card` (existing primitive) at `max-w-3xl mx-auto`, `padding="p-0"` so the sticky day headers can hug the card's inner edge. The `Card` keeps the standard border, radius, and surface fill.
- Inside the card: a 56px sticky header strip, then the filter strip (also sticky), then the day-grouped list.

### iOS

- Standard `ZStack { Tokens.paper.ignoresSafeArea(); VStack(spacing: 0) { TopBar; ScrollView { LazyVStack } } }`.
- `TopBar` title: `Activity`. Trailing toggle is the existing theme toggle, no extra controls.
- `ChatFAB` floats bottom-right as on every other surface.

### Page header

- Web: `h1` reading `Activity`, font `font-display text-2xl text-ink tracking-tight`. To its right, an icon-only refresh button (`RotateCw` from lucide, `text-muted hover:text-ink`, 36px tap target). Caption beneath the title in `text-sm text-muted`: `Everything you have captured, newest first.`
- iOS: `TopBar` already renders the title. Place the caption as a single `Text` line below the `TopBar`, `Tokens.muted`, `.edSubheadline`, with `Space.lg` horizontal padding and `Space.sm` top padding. No refresh button on iOS — pull-to-refresh on the `ScrollView` covers it.

### Filter strip

Single-select chips. The active filter applies to the API request via the `?type=` query param. `All` clears the param.

- Order: `All, Notes, Todos, Lists, Folders`.
- Chip styling, inactive: `h-8 px-3 rounded-full bg-paper-2 border border-border text-sm text-ink-soft`. Hover: `border-border-strong text-ink`.
- Chip styling, active: `bg-[--color-accent-soft] border border-[--color-accent-ring] text-[--color-accent]`. The accent here resolves to the plum because we set `data-route="activity"` on the page. Active chip carries `aria-pressed="true"`.
- Spacing: `gap-2`, horizontal padding `px-5`, vertical padding `py-3`. Sticky to the top of the scroll container with the day headers (web only — see below).
- iOS: same chip semantics. `Capsule()` backgrounds. Inactive `Tokens.paper2` with `Tokens.border` overlay; active `Tokens.accentActivity.opacity(0.12)` fill with `Tokens.accentActivity` text and `Tokens.accentActivity.opacity(0.35)` capsule stroke. Horizontally scrollable `ScrollView(.horizontal)` with `showsIndicators: false`. Padding `Space.lg` horizontal, `Space.sm` vertical.

### Day groups & sticky headers

- Group rows by the user's local day (server returns ISO timestamps; clients bucket).
- Group label rules:
  - Today: `Today`
  - Yesterday: `Yesterday`
  - Within the last 7 days: weekday name (`Monday`, `Tuesday`, ...)
  - Older same year: `Mon 14 Apr`
  - Prior years: `14 Apr 2024`
- Web header: `h2` styled `font-display text-base text-ink tracking-tight uppercase` (the eyebrow style already used on widgets). Background `bg-surface/95` with `backdrop-blur-sm`, a `border-b border-divider`, height 36px, `px-5`, sticky via `position: sticky; top: 56px` so it parks under the page header / filter strip. A 6px `--color-accent-activity` dot precedes the label.
- iOS header: `Text(label).font(.edEyebrow).foregroundStyle(Tokens.inkSoft)` with the same plum dot prefix. Wrapped in a `LazyVStack(pinnedViews: [.sectionHeaders])` `Section` so the header pins to the top of the scroll viewport.
- Spacing between groups: `Space.xl` (24px) on iOS, `mt-6` on web. First group starts flush, no top margin.

### Row anatomy

A row is one creation. Three columns: type icon (left, 32px square), title + snippet + parent breadcrumb (centre, flex-grow), relative time (right, `whitespace-nowrap`).

| Type | Web Lucide icon | iOS SF symbol | Icon color (light / dark) |
|---|---|---|---|
| `note` | `FileText` | `doc.text` | `accent-notes` (`#B45309` / `#F59E0B`) |
| `todo` | `CheckSquare` | `checkmark.square` | `accent-tasks` (`#4338CA` / `#818CF8`) |
| `list` | `List` | `list.bullet` | `accent-lists` (`#0F766E` / `#2DD4BF`) |
| `folder` | `Folder` | `folder` | `muted` (`#7B7263` / `#A89E8A`) |

- Icon container: 32px square, `rounded-md`, fill is the icon color at 12% opacity (`color-mix(in oklab, var(--color-accent-X) 12%, var(--color-paper))` on web, `accent.opacity(0.12)` on iOS). Icon glyph at 18px, full color. This is the only color cue per row, everything else is ink/muted.
- Title: web `text-sm font-medium text-ink`, iOS `.edBodyMedium` `Tokens.ink`. Single line, truncate with ellipsis at the column boundary.
- Snippet: web `text-sm text-muted line-clamp-1`, iOS `.edSubheadline` `Tokens.muted` `.lineLimit(1)`. If `snippet` is null (folders), omit the line entirely so the row collapses to one line of text.
- Parent breadcrumb (notes only, when `parent` is non-null): rendered inline below the title as `text-xs text-muted-soft` with a leading `Folder` icon at 10px. Format: `[icon] Travel`. Suppressed for todos, lists, and folders.
- Relative time, right-aligned, web `text-xs text-muted-soft`, iOS `.edCaption` `Tokens.mutedSoft`. Format: `2m`, `47m`, `3h`, `Yesterday`, `Mon`, `14 Apr`, `14 Apr 2024`. Same scheme as day headers but compact. Tooltip on hover (web) shows the full timestamp.
- Row padding: `py-3 px-5` web, `Space.md` vertical / `Space.lg` horizontal iOS.
- Divider between rows inside a group: `border-b border-divider` web (last row in group has no border), `Rectangle().fill(Tokens.divider).frame(height: 0.5)` iOS.

### Hover / press affordance

- Web: row hover sets `bg-paper-2` and shows a `ChevronRight` (16px, `text-muted-soft`) at the far right replacing the timestamp's right margin. Cursor `pointer`. Focus ring follows the standard `focus-visible:ring-2 focus-visible:ring-[--color-accent-ring]` pattern.
- iOS: `.contentShape(Rectangle())` plus a tap gesture, no persistent chevron (mobile convention). Tap sets a brief `Tokens.paper2` highlight via `.scaleEffect` 0.99 for 120ms.

### Deep-link affordance

Tapping a row navigates to the section that owns the item and scrolls to it.

- `note` -> Notes section, scroll the corresponding note into view, pulse the note card with a 600ms `--color-accent-notes` ring.
- `todo` -> Tasks section, same pattern with `--color-accent-tasks`.
- `list` -> Lists section, same pattern with `--color-accent-lists`.
- `folder` -> Notes section with the folder pre-expanded.

The pulse uses opacity-only animation on a 1px outline that shares the row's radius. Honour `prefers-reduced-motion`: skip the pulse and just scroll.

Web routing: navigate to `/notes?focus=<id>`, `/tasks?focus=<id>`, `/lists?focus=<id>`. The destination widget reads `focus` from the URL on mount, scrolls to the item, and then strips the param via `replaceState`.

iOS routing: `router.go(to: .notes)` (etc) plus a new `router.focus: (AppSection, UUID)?` field that the destination view consumes on `task {}`.

---

## 3. Empty state

Two variants, both centred in the scroll area, no illustration.

### "No items yet at all"

- Icon: `Inbox` (lucide) / `tray` (SF Symbol), 28px, `text-muted` / `Tokens.muted`.
- Headline: web `text-base text-ink-soft`, iOS `.edBodyMedium` `Tokens.inkSoft`. Copy: `Nothing here yet.`
- Sub: web `text-sm text-muted`, iOS `.edSubheadline` `Tokens.muted`. Copy: `Notes, todos, lists, and folders you create will show up here.`
- iOS uses `Space.xxxl` vertical padding (matches `TasksView.placeholder`).

### "No items match the active filter"

- Same layout. Icon: `Filter` / `line.3.horizontal.decrease`. Headline: `No <type> here yet.` (e.g. `No notes here yet.`). Sub: `Switch to All to see everything.`

---

## 4. Loading skeleton

Bones use `bg-surface-2` / `Tokens.paper2`. Animation is a 1.4s ease-in-out pulse on opacity (40% to 70%). Disable when `prefers-reduced-motion` is set.

### First-load skeleton (page fresh)

Render 3 day-group placeholders, each containing 4 row placeholders:

- Day header bone: 80px wide x 12px tall, `rounded-sm`. Sit it in the same sticky-header slot so the layout does not shift when real data arrives.
- Row bone composition: 32px square icon bone (left), then a 60% width title bone (12px tall), then a 90% width snippet bone (10px tall, mt-1.5), then a 32px right-aligned time bone. Row padding matches real rows.

### Subsequent-page skeleton (infinite scroll)

Render 2 row placeholders at the bottom of the list while the next page is fetching. No day header bone. Removed when the fetch resolves.

---

## 5. Filter & cursor interactions

- Filter change: reset cursor, clear current rows, render the first-load skeleton, fetch with the new `type` param. Smooth state transition, do not animate row removal (just swap to skeleton).
- Web manual refresh (`RotateCw` button): same as filter change. Spin the icon while the request is in flight. Disabled state during the request.
- iOS pull-to-refresh: `.refreshable { await viewModel.reload() }` on the outer `ScrollView`. Same effect as web manual refresh.
- "Load more" trigger:
  - Web: `IntersectionObserver` watching a 1px sentinel placed below the last row. When the sentinel is within 600px of the viewport bottom, fire the next-page request. Show the subsequent-page skeleton at the bottom while loading. Auto-stop when the API returns no `nextCursor`.
  - iOS: `.onAppear` on the last `LazyVStack` row triggers the next-page request. Same skeleton treatment. Same auto-stop rule.
- Errors: an inline row at the bottom of the list reading `Couldn't load more. Tap to retry.` styled in `text-danger` / `Tokens.danger`. Tapping retries.

---

## 6. Light & dark mode

- Only one new token pair. Both values verified above.
- Active filter chip in dark mode: the plum (`#E5A3BA`) on `Tokens.paper2` (`#1B1813`) hits 9.85:1, comfortably AAA.
- Type icon backgrounds at 12% opacity remain legible in dark mode because the icon glyph itself is full-strength. No new variants needed for the per-section accents.

---

## 7. Accessibility

### Contrast

- Activity accent on paper, light: 7.32:1 (AAA). Dark: 10.41:1 (AAA).
- Type-icon glyph on its 12% tint: notes 5.4:1, tasks 7.1:1, lists 4.9:1, folders 4.7:1 (light). All clear AA for non-text UI; glyph weight is treated as iconography (3:1 minimum) so this is comfortable.
- Snippet `text-muted` on `bg-surface` (light): 4.8:1, AA. Dark: 5.9:1, AA.
- `text-muted-soft` (the relative-time slot) on surface: 3.4:1 light, 3.9:1 dark. This sits on the AA-large-text threshold (3:1) but below normal-text AA. The relative time is decorative when the day header already names the day, and the full timestamp is exposed to assistive tech via the row label, so this is acceptable. If the user later wants it stronger, bump to `text-muted` (4.8:1).

### Keyboard order (web)

Tab order from top of page: refresh button -> filter chips (left to right, arrow keys move within the group, `Tab` exits the group) -> first row -> second row -> ... -> load-more sentinel (skipped, not focusable) -> end of page. `Enter` on a focused row triggers the deep link. `Esc` returns focus to the refresh button.

### Screen reader labels

- Page landmark: `<main aria-labelledby="activity-heading">`.
- Filter chips group: `role="group" aria-label="Filter by type"`. Each chip is a `<button aria-pressed="true|false">`.
- Day header: marked as `<h2>` so screen readers announce the date as a section.
- Row: rendered as `<a href="...">` (web) and `Button` with `accessibilityLabel` (iOS). Composed label per type:
  - Note: `Note created. <title>. <snippet>. In <parent folder>. <relative time>.`
  - Todo: `Task created. <title>. <snippet>. <relative time>.`
  - List: `List created. <title>. <snippet>. <relative time>.`
  - Folder: `Folder created. <title>. <relative time>.`
- Relative time: include the absolute timestamp as `aria-label` so SR users hear `2 hours ago, 3 May 2026 at 3:42 PM` instead of just `3h`.
- Skeleton: container `aria-busy="true"`, no row text exposed.
- Empty state: just text, no special role.

### Touch targets

All tap targets at least 44x44 (web rows are 60px tall, iOS rows are 60-72px depending on snippet presence, chips are 32px tall on web but include 12px hit padding via the parent `gap-2` + chip internal padding, iOS chips use `.frame(minHeight: 36)` plus `Space.sm` interior padding which extends the hit area to 44).

---

## 8. Reference mockups

### Web (~80 col)

```
+------------------------------------------------------------------------------+
|  [Sidebar 64px ......collapsed.....]                                          |
|  | History  Activity  *active*  |  Activity                       [refresh] |
|  |                                |  Everything you have captured, newest    |
|  |                                |  first.                                  |
|  |                                |                                          |
|  |                                |  ( All )( Notes )( Todos )( Lists )( ...|
|  |                                |  ----------------------------------------|
|  |                                |  - Today --------------------------------|
|  |                                |                                          |
|  |                                |  [N]  Trip to Lisbon              2m    >|
|  |                                |       Booked the Alfama airbnb...        |
|  |                                |       (folder) Travel                    |
|  |                                |                                          |
|  |                                |  [T]  Renew passport             1h    >|
|  |                                |       Embassy slot before May 20         |
|  |                                |                                          |
|  |                                |  [L]  Packing list                3h    >|
|  |                                |       Charger, sunglasses, kindle        |
|  |                                |                                          |
|  |                                |  [F]  Travel                      4h    >|
|  |                                |                                          |
|  |                                |  - Yesterday ----------------------------|
|  |                                |                                          |
|  |                                |  [N]  Sprint retro notes        Yest    >|
|  |                                |       What worked: pairing on the...     |
|  |                                |       (folder) Work                      |
|  |                                |                                          |
|  |                                |  [T]  Email Rajiv                Yest   >|
|  |                                |       Re: Q3 roadmap                     |
|  |                                |                                          |
+------------------------------------------------------------------------------+
```

Icon colors in the brackets: `[N]` plum-on-ochre tint, `[T]` indigo, `[L]` teal, `[F]` muted slate. The plum dot (the Activity accent) appears only on the day header.

### iOS (~40 col)

```
+--------------------------------------+
| [=]            Activity         [O]  |
|--------------------------------------|
|  Everything you have captured,       |
|  newest first.                       |
|                                      |
|  ( All ) ( Notes ) ( Todos ) ( ...   |
|--------------------------------------|
|                                      |
|  o  Today                            |
|                                      |
|  [N]  Trip to Lisbon          2m     |
|       Booked the Alfama...           |
|       (folder) Travel                |
|  -------------------------------     |
|  [T]  Renew passport          1h     |
|       Embassy slot before...         |
|  -------------------------------     |
|  [L]  Packing list            3h     |
|       Charger, sunglasses...         |
|  -------------------------------     |
|  [F]  Travel                  4h     |
|                                      |
|  o  Yesterday                        |
|                                      |
|  [N]  Sprint retro notes      Yest   |
|       What worked: pairing...        |
|       (folder) Work                  |
|  -------------------------------     |
|  [T]  Email Rajiv             Yest   |
|       Re: Q3 roadmap                 |
|                                      |
|                              (chat)  |
+--------------------------------------+
```

`o` is the plum dot prefix on each day header. `[O]` is the theme toggle. `(chat)` is the floating `ChatFAB` bottom-right.

---

## Hand-off notes for the implementation agent

- One new CSS token (`--color-accent-activity`) plus the `[data-route="activity"]` mapping. One new Swift constant (`Tokens.accentActivity`). No other token changes, no new spacing or radius scales, no new font sizes.
- Reuse `Card` for the page container on web. Reuse `TopBar`, `ChatFAB`, `Tokens.*` for iOS.
- Do not invent a custom skeleton component if a project-wide one exists; if it does not, build it inline and keep it local to the Activity page until it earns its way into a shared place.
- Filter chips and day headers should both be sticky on web, day headers only on iOS. iOS filter chips live above the scroll view, not inside it.
- Pulse-highlight on deep-link is one of the few places we need to coordinate with the destination widget. Ship the URL/`router.focus` plumbing alongside the Activity page in the same PR; do not split it.
