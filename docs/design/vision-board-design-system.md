# Vision Board: visual and interaction design system

Status: design spec, pre-implementation
Surface: macOS (`DexterMac`) first, iOS projection second
Date: 2026-08-06
Companion to: `docs/design/vision-board-concept.md` (object model, product decisions)

This document specifies the visual and interaction-state layer only. The object
model, the state list, and the projection strategy are settled in the concept doc
and are not revisited here.

Everything below derives from the existing Editorial Calm token system in
`Design/Tokens.swift`, `Design/Spacing.swift`, `Design/Typography.swift`, and
`Design/PriorityWash.swift`. Five new colour tokens and one new metrics enum are
proposed. Nothing else is invented.

**Revised 2026-08-06 after review of the built surface.** Two sections were
reversed rather than refined: §4 (the canvas ground) now specifies an always-on
lattice, and the resize handle in §7 now tracks the pointer continuously and
snaps on release. Both carry a dated supersedes note and keep the argument they
replaced, so the cost of each reversal stays legible.

---

## 0. The spine: three colour roles, three owners, no overlap

Every colour decision in this spec follows from one rule. The board carries three
independent signals, and each one owns a distinct **region** of the block as well
as a distinct **hue family**. They are separated twice, so a failure in either
separation still leaves the board readable.

| Signal | Question it answers | Region it owns | Hue family |
|---|---|---|---|
| **State** | What am I doing about this? | The block's **top edge** (3pt rail) and one 10pt header glyph | Neutral + cool (ink, muted, cyan, periwinkle). Never red, amber, or green |
| **Urgency** | What is the calendar doing to me? | A capsule at the block header's **trailing edge** | Neutral for the common case; warm (amber, red) only at the top two rungs, where warm is correct |
| **Priority** | How much does this one task matter? | The **interior of a tile**, as a ≤6.3% alpha wash | Red / yellow / green, inherited verbatim from Tasks |

The section accent has a fourth, non-overlapping job: **"the system is responding
to you."** Selection, focus, snap targets, and drop feedback. It never encodes
data.

State colour and priority colour cannot land on the same pixel, because state
lives on the block perimeter and priority lives inside a tile. On a 2×4 block
they are separated by at least 16pt of vertical space.

---

## 1. Section accent

```swift
static let accentVision = Color.paper(0x456F0D, 0xA9C46B)   // deep moss / sage
```

`AppSection.visionBoard`, SF Symbol `rectangle.3.group` (three rectangles at
different sizes: literally the board).

### Why this hue

Plot the eleven taken accents on the hue wheel (light variants):

```
  0°  today red        #B91C1C
 32°  notes amber      #B45309
 33°  vocabulary stone #57534E  (5% saturation, effectively neutral)
145°  priorityGreen    #16A34A  (semantic, not a section)
162°  finance emerald  #047857
176°  lists teal       #0F766E
192°  info             #0E7490  (semantic, not a section)
215°  settings slate   #475569  (20% saturation)
246°  tasks indigo     #4338CA
263°  trips violet     #6D28D9
294°  wallet fuchsia   #A21CAF
336°  activity mauve   #7C3F58
```

There is exactly one large unoccupied arc: **33° to 145°**, and the only reason
its upper half is unusable is `priorityGreen` at 145° and `success` at 145°. That
leaves **60° to 100°**, the yellow-green / moss band, genuinely free. Nothing in
the app uses it.

`#456F0D` is HSL(86°, 79%, 24%). A deep, saturated moss.

**Distance from the two accents most at risk of confusion:**

| Against | Hue delta | Also differs by |
|---|---|---|
| tasks indigo `#4338CA` (246°) | **160°** | Cool vs warm; near-complementary |
| trips violet `#6D28D9` (263°) | **177°** | Effectively the opposite side of the wheel |
| finance emerald `#047857` (162°) | 76° | Emerald is blue-green, moss is yellow-green |
| notes amber `#B45309` (32°) | 54° | Amber has no green channel dominance; moss's max channel is G |
| priorityGreen `#16A34A` (145°) | 59° | priorityGreen is 45% lighter and appears only as a ≤6.3% tint |

**Why it is right beyond the arithmetic:** the palette is warm paper. A moss green
sits on cream the way ink sits on it, as a natural pairing rather than a colour
laid over the top. The board is where Ongoing work lives (health, reading, admin),
things you tend rather than finish, and a botanical hue carries that without a
metaphor anyone has to be told.

**Contrast** (see §10 for the full table): 5.94:1 on `surface` light, 8.73:1 on
`surface` dark. Comfortable headroom at `edEyebrow` 10pt.

---

## 2. State encoding

### The problem, restated precisely

`PriorityWash` puts a red / yellow / green gradient behind every task row with a
priority set (`Design/PriorityWash.swift`, alphas 0.09 lead → 0.02 trail in light,
0.10 → 0.025 in dark). Board tiles are those same tasks. If block state were also
a red-amber-green family, a Waiting block full of P1 tasks would be amber on
amber, and the two would be indistinguishable at board zoom.

### The resolution

**State moves to a different encoding channel entirely, and within that channel
it is carried by four sub-signals, only one of which is hue.**

The channel is the **block's edge**: a 3pt top rail plus the border style plus a
10pt glyph in the header. Priority never touches the edge. State never touches a
tile interior.

Within the edge channel, state is distinguished by:

1. **Rail pattern** (solid / dashed / hairline / absent), readable in greyscale
2. **Glyph shape** (five distinct SF Symbols), readable in greyscale
3. **Body fill** (`surface` vs `paper2`), readable in greyscale
4. **Hue**, restricted to neutral + cool, never the priority family

Two states carry no hue at all. **Active is `Tokens.ink`**: the loudest state is
encoded by *weight*, not colour, which means the single most important signal on
the board never competes with anything and never fails a colour-vision test.

### The state table

| State | Hue token | Top rail (3pt) | Block border | Body fill | Glyph (10pt) | Eyebrow (large only) |
|---|---|---|---|---|---|---|
| **Idea** | `Tokens.muted` | **absent** (slot holds a 0.5pt `Tokens.border` hairline so height never shifts) | **dashed** `Tokens.borderStrong`, dash `[4,3]`, 0.5pt | `Tokens.surface` | `lightbulb` | `IDEA` |
| **Active** | `Tokens.ink` | **solid, full width** | solid `Tokens.ink.opacity(0.22)`, 0.5pt | `Tokens.surface` | `circle.fill` | `ACTIVE` |
| **Ongoing** | `Tokens.stateOngoing` | **solid, full width** | solid `Tokens.border`, 0.5pt | `Tokens.surface` | `infinity` | `ONGOING` |
| **Waiting** | `Tokens.stateWaiting` | **dashed**, dash `[6,4]` | solid `Tokens.border`, 0.5pt | `Tokens.surface` | `hourglass` | `WAITING` |
| **Done** | `Tokens.muted` | **absent** (same hairline slot as Idea) | solid `Tokens.border`, 0.5pt | `Tokens.paper2` | `checkmark` | `DONE` |

The rail is clipped by the card shape, so it takes the top corner radius and reads
as part of the block rather than a bar sitting on it.

### New tokens

```swift
/// Vision Board section accent. Moss green: the one large unoccupied arc of the
/// hue wheel (60 to 100 degrees), 160° from tasks indigo and 177° from trips violet.
/// Owns "the system is responding to you": selection, focus, snap, drop.
static let accentVision   = Color.paper(0x456F0D, 0xA9C46B)

/// Block state: Ongoing. Steel cyan (192°). Cool family, deliberately outside
/// the red/amber/green priority family so a block's state can never be mistaken
/// for the priority wash on the tasks inside it.
static let stateOngoing   = Color.paper(0x0E6F87, 0x5FC6DE)

/// Block state: Waiting. Periwinkle (257°). 65° from `stateOngoing`, which is
/// the smallest hue gap in the state set and still discriminable on a 3pt rail.
/// The rail is dashed as well, so the two never rely on hue alone.
static let stateWaiting   = Color.paper(0x6D4BC4, 0xAB9BF0)
```

Idea, Active, and Done reuse existing tokens (`muted`, `ink`, `muted`). Expose
them through one function, mirroring `Tokens.accent(for:)`:

```swift
static func state(for s: BlockState) -> Color {
    switch s {
    case .idea:    return muted
    case .active:  return ink
    case .ongoing: return stateOngoing
    case .waiting: return stateWaiting
    case .done:    return muted
    }
}
```

Idea and Done share `muted`. That is deliberate and safe: they are separated by
glyph (`lightbulb` vs `checkmark`), by border style (dashed vs solid), and by body
fill (`surface` vs `paper2`). Nobody has to tell them apart by colour, because
neither has one.

### Worked example: a Waiting block holding a P0 and a P1

The case the brief flags as the one that must not turn to mush. A 2 col × 4 row
Waiting block, 356 × 260pt:

```
┌────────────────────────────────────────────┐  ← 3pt DASHED rail, #6D4BC4
│                                            │     dash [6,4], full width
│  ⧗  Kitchen renovation          [ today ]  │  ← hourglass 10pt #6D4BC4
│     waiting on the plumber's quote         │  ← intent, edSubheadline, muted
│     ▓▓▓▓▓▓░░░░░░░░░░░░  2/7                │  ← progress, MONOCHROME
│                                            │
│  ┌──────────────────────────────────────┐  │
│  │ ○  Chase the plumber        2d ago   │  │  ← P0: red wash, 6.3% → 2%
│  └──────────────────────────────────────┘  │
│  ┌──────────────────────────────────────┐  │
│  │ ○  Pick the tile              Fri    │  │  ← P1: yellow wash, 6.3% → 2%
│  └──────────────────────────────────────┘  │
│  ┌──────────────────────────────────────┐  │
│  │ ○  Measure the alcove                │  │  ← no priority: no wash at all
│  └──────────────────────────────────────┘  │
│  + 4 more                                  │
└────────────────────────────────────────────┘
```

Why it reads:

- **Spatial separation.** Periwinkle occupies the top 3pt and one 10pt glyph.
  Red and yellow begin 44pt lower, inside bordered `surface2` tiles. There is no
  pixel where both are present.
- **Saturation separation.** The rail is 100% `#6D4BC4`. The washes are 6.3%
  alpha at their strongest point and 2% by the middle of the tile. One is a
  colour; the others are a texture. The existing `PriorityWash` doc comment
  already establishes that alpha budget as "registers at a glance, disappears
  when you actually read the row."
- **Hue-family separation.** Periwinkle is cool. Both washes are warm. Even at
  matched saturation they would not be confused.
- **Area budget.** Rail = 356 × 3 = 1,068pt². Block = 92,560pt². State colour
  occupies **1.15% of the block**. The washes occupy about 6% alpha over roughly
  30% of the block. Neither can dominate the other because they are not competing
  for the same budget.
- **Greyscale fallback.** Desaturate the whole thing and the block is still
  Waiting: dashed rail, hourglass glyph. The washes vanish entirely, which is
  correct, because priority's authoritative carrier has always been the task
  detail and the accessibility label, not the tint.

### How Done recedes without vanishing

Done blocks stay on the board at the size you gave them (the concept doc leaves
auto-collapse open; this spec says do not auto-collapse, because a block's size is
a claim the user made and the app should not quietly retract it).

Recession is by **treatment**, not opacity:

- Body fill drops `surface` → `paper2`. The block settles toward the canvas
  without becoming it.
- Rail is absent; the slot holds the same 0.5pt hairline as Idea so nothing
  reflows.
- Glyph becomes `checkmark` in `Tokens.muted`.
- Urgency chip is **suppressed entirely**. A finished block has no urgency, and
  showing `overdue by 3` on a Done block would be a lie.
- Progress reads `8/8`, bar fully filled in `Tokens.inkSoft`.
- Title stays `Tokens.inkSoft`, **not** `Tokens.muted`.

That last point is not a style preference, it is a contrast requirement.
`Tokens.muted` on `paper2` light is **4.17:1**, below the 4.5:1 floor. The
codebase already learned this: `TripCoverMetrics.pastVeilOpacity` carries a
comment saying Past recedes by treatment and never by card-wide opacity,
"which would dim the text with it and drop `Tokens.muted` below 4.5:1." Same
trap, same answer. **Never apply opacity to a whole Done block.**

The Done glyph may stay `Tokens.muted` on `paper2` (4.17:1) because a glyph is a
non-text graphic and its floor is 3:1.

---

## 3. Urgency encoding

Derived from the soonest due date among the block's **incomplete** tiles. Nothing
to maintain, so it cannot go stale.

It never competes with state for a pixel: state owns the top edge and the leading
glyph, urgency owns the header's trailing edge. Different corner, different shape
language (bar and glyph vs capsule and words).

### The escalation ladder

| Rung | Trigger | Text | Text colour | Container | Icon (9pt) | Type |
|---|---|---|---|---|---|---|
| **0** | no incomplete tile has a due date | *chip absent* | n/a | n/a | n/a | n/a |
| **1** | soonest due > 7 days | `in 3 weeks` | `Tokens.muted` | none | none | `.edCaption` |
| **2** | 2 to 7 days | `in 4 days` | `Tokens.inkSoft` | none | none | `.edCaption` |
| **3** | tomorrow | `tomorrow` | `Tokens.ink` | Capsule, `Tokens.surface2` fill, `Tokens.border` 0.5pt hairline | none | `.edFootnote` |
| **4** | today | `today` | `Tokens.ink` | Capsule, `Tokens.warningSoft` fill, `Tokens.warning` 0.5pt hairline | `clock` in `Tokens.warning` | `.edFootnote` |
| **5** | overdue | `overdue by 3` | `Tokens.ink` | Capsule, `Tokens.dangerSoft` fill, `Tokens.danger` 0.5pt hairline | `exclamationmark.triangle.fill` in `Tokens.danger` | `.edFootnote` |

Capsule metrics for rungs 3 to 5: `.padding(.horizontal, Space.sm)`,
`.padding(.vertical, 2)`, `Capsule()`. Identical to `TagPill`, so a board chip and
a tag pill are the same physical object at different sizes.

Rungs 1 and 2 have no container and no padding, only text.

### Why the ladder is shaped this way

**Rungs 0 to 3 are entirely hueless.** That is the whole design. On a board of
twenty blocks, most are weeks out. If every one of them carried a coloured chip,
the board would be a wall of pastel and the two blocks that actually need you
would be invisible. The board only turns warm where something is genuinely wrong.

**Warmth arrives exactly where warmth is correct.** At rungs 4 and 5, the block's
tiles are likely carrying red and yellow washes too. That is agreement, not
conflict: the chip and the tiles are saying the same thing about the same day.
The failure mode the brief warns about is state and priority disagreeing in the
same hue family, and urgency is not state.

**Text stays `Tokens.ink` at rungs 3 to 5, and the hue is carried by fill, hairline,
and icon.** This buys real contrast headroom. `Tokens.warning` on
`Tokens.warningSoft` measures **4.51:1**, which passes 4.5:1 by 0.01 and is the
tightest pair the app owns. `Tokens.ink` on `Tokens.warningSoft` measures
**15.4:1**. The chip still reads unmistakably amber, because three of its four
elements are amber, and the one element you have to *read* is maximally legible.

**Five axes escalate at once**, so no single perceptual channel carries the ladder:

```
text colour   muted ──── inkSoft ──── ink ──── ink ──── ink
container     none ───── none ─────── neutral ─ amber ── red
icon          none ───── none ─────── none ──── clock ── triangle
type          10 reg ─── 10 reg ───── 11 med ── 11 med ─ 11 med
words         "in 3 weeks" ─────────────────── "overdue by 3"
```

Rungs 3, 4, and 5 are distinguishable in **pure greyscale by icon shape alone**:
nothing, a circle, a triangle.

### What overdue deliberately does *not* get

No red ring on the block perimeter. No pulsing. No shadow tint. All three were
considered and all three are rejected for the same reason: the perimeter belongs
to state, and putting `Tokens.danger` there would break the one rule the whole
system rests on. A chip with a red fill, a red hairline, a warning triangle, and
the literal words `overdue by 3` is sufficient. This is a tool, not an alarm
panel.

### Small blocks

At **small** (1 col), rungs 1 and 2 are suppressed. There is 172pt of width and
the title needs it, and "in 3 weeks" is not worth a truncated title. Rungs 3, 4,
and 5 are always shown at every size, because those are the ones you scan for.

---

## 4. The canvas ground

> **Superseded 2026-08-06.** This section originally argued that placeability is
> revealed by attention and never printed on the ground: no grid at idle, a full
> lattice only during a drag or resize. Reviewed against the built surface and
> reversed. The always-on lattice below is the specified behaviour; the
> reveal-on-attention argument is recorded at the end of the section so the
> reasoning that was traded away is not lost.

### The principle

**The board is a place, and a place you arrange things in shows you its floor.**

A faint lattice is on the canvas at all times. It strengthens while a block is
being dragged or resized, and it never disappears.

Two things the reveal-on-attention version could not do:

- A grid that exists only once you are already committed to a drag tells you
  where a block will land, but it never helps you decide to move one. The moment
  it is most useful for judging *whether* a block is aligned is the moment it is
  absent.
- An empty board with no grid reads as an empty document rather than as a surface
  with slots in it. The lattice is what says "things go here", before any block
  exists to demonstrate it.

Strengthening rather than fading in also buys something a reveal cannot: the grid
a drag snaps to is visibly the same grid that was there before the block was
picked up.

### Grid metrics

```swift
/// Snap lattice for the board. A "cell" INCLUDES its gutter, so a block
/// occupying `c × r` cells renders at `c*cellWidth - gutter` by
/// `r*cellHeight - gutter`. Expressing it this way means the gutter cannot
/// drift out of sync with the snap unit, which is the failure the
/// `RowMetrics` doc comment warns about for related numbers held apart.
enum VisionGrid {
    static let gutter:     CGFloat = Space.md   // 12
    static let cellWidth:  CGFloat = 184        // 172pt of block + 12pt gutter
    static let cellHeight: CGFloat = 68         //  56pt of block + 12pt gutter

    /// Minimum block: 1 col × 2 rows = 172 × 124pt. Fits rail, header,
    /// meta line, and nothing else, which is exactly the small presentation.
    static let minColumns = 1
    static let minRows    = 2
}
```

Small = 172pt wide. Medium (2 col) = 356pt. Large (3 col) = 540pt.

### Two lattice levels, plus the ghost cell

**1. Idle: the faint lattice.** Dots at every cell corner, on `Tokens.paper`.

- 1.4pt diameter circles, `Tokens.visionLattice`
- Pitch = `VisionGrid.cellWidth × VisionGrid.cellHeight`. On a 3000 × 2000
  canvas that is roughly 470 dots, one cheap `Shape` path — now a permanently
  retained one, which is why it must stay a single path and not become a view
  per cell

**2. Dragging or resizing: the strong lattice.** Same dots, grown and warmed.

- 1.8pt diameter, `Tokens.visionLatticeActive`
- Crossfades over 120ms `.easeOut`, both ways. Under reduced motion it is
  instant: this is a change of emphasis, not a piece of information

**3. Pointer over empty canvas: one ghost cell.** A single `Radius.card` rounded
rect at the snapped cell under the pointer, sized `newColumns × newRows`
(2 × 3, the size a block is actually created at):

- Fill: `Tokens.surface.opacity(0.5)`
- Border: **dashed** `Tokens.borderStrong`, dash `[4,3]`, 0.5pt
- Centred `plus` glyph, 14pt, `Tokens.mutedSoft`
- Fades in over 140ms `.easeOut`, out over 90ms `.easeIn`
- Follows the pointer by jumping between cells, never sliding
- Suppressed entirely while a block is in hand, where the strong lattice has
  taken over the job
- Suppressed where a 2 × 3 block does not fit, which is the only place on empty
  canvas a click deselects rather than creates

**Revised 2026-08-07.** Two things changed together, and they are the same
change. The ghost is now sized at the created footprint rather than at
`minColumns × minRows`, and a **single** click on it creates the block
(double-click still works, and the two are collapsed so one interaction makes at
most one block).

The plus was reading as a button and was not one — clicking it did nothing,
because creation was bound to the double-click alone. Making it a button then
raises the bar on the preview: at the minimum size it could sit happily inside a
gap the real 2 × 3 block does not fit in, and creation would nudge the block
somewhere else, so the plus would have been pointing at a cell the block never
lands in. Preview, hit test and creation all read the same `creationSlot` now,
and where it has no answer there is no plus.

### Tuning the idle lattice so it is not graph paper

This is the whole risk in the reversal, and the values are pitched at the
threshold rather than at "clearly visible".

Measured against `Tokens.paper`, the rendered idle dot lands about 20 levels
darker in light mode and about 20 levels lighter in dark. Two separate token
pairs rather than one colour at two opacities: the same alpha over cream and
over near-black does not read as the same whisper, because a light dot on a dark
ground gains apparent contrast faster than a dark dot on a light one, and it is
the dark-mode dot that turns into static first.

```swift
static let visionLattice       = Color.paper(0xE4DCC6, 0x252019)
static let visionLatticeActive = Color.paper(0xC9BE9E, 0x4E4639)
```

Warm, never grey. The lattice belongs to the paper it is printed on; a neutral
grey dot at this size reads as dirt on the screen rather than as texture.

Dot size matters more than it looks. Below about 1.2pt the antialiasing eats
most of the delta and the dot goes from faint to absent, which then tempts a
correction in the wrong direction: a dot that is too small has to be made too
dark to register at all, and a too-dark dot at a small size reads as grit. 1.4pt
at a modest delta is calmer than 1.0pt at a large one.

**Acceptance check:** a board with no blocks on it must read as one calm surface
at a normal viewing distance, in both themes. You should notice the lattice when
you look for it, not before.

### Drag slots

Unchanged, and drawn over the lattice:

- **Target slot**: `Tokens.accentVision.opacity(0.10)` fill, **dashed**
  `Tokens.accentVision` 0.5pt hairline (dash `[5,4]`), `Radius.card`
- **Origin slot**: dashed `Tokens.border` 0.5pt hairline, no fill. Not
  `Tokens.divider`: divider disappears on light surfaces in light mode, which is
  the known trap this codebase has already hit

### The argument this replaced

Recorded rather than deleted, because it is a real cost and it is the thing to
re-read if the board ever starts to feel busy.

> Placeability is revealed by attention, not printed on the ground. A permanent
> dot lattice or line grid turns a warm-paper surface into graph paper and adds
> visual noise to every square point of a 3000pt canvas in exchange for
> information the user needs at exactly one moment. So the idle canvas has no
> grid at all. It is `Tokens.paper`, and nothing else.

What was traded: some permanent visual noise, in exchange for a board that
announces its own structure before you commit to a gesture. The trade is only
sound while the idle values stay at the threshold above. If the lattice is ever
strengthened for its own sake, this argument wins again.

---

## 5. Block anatomy

### Shared shell (every size)

| Element | Spec |
|---|---|
| Shape | `RoundedRectangle(cornerRadius: Radius.card, style: .continuous)` (16pt on macOS) |
| Fill | `Tokens.surface`; `Tokens.paper2` when Done |
| Border | `paperBorder(_:radius:lineWidth:)` at 0.5pt, colour and dash per the state table in §2 |
| Shadow | `shadowSm()` at rest, `shadowMd()` on hover, `shadowLg()` while dragging |
| Padding | `Space.md` (12) on all four sides, applied **below** the rail |
| State rail | 3pt tall, full width, clipped by the card shape |
| Ellipsis slot | 24 × 24 reserved at the header's trailing edge, `opacity 0` until hover. **Always reserved**, never inserted on hover, so hovering shifts nothing |

### Header (every size)

```
[glyph 10pt] [eyebrow, large only] [title] ····· [urgency chip] [ellipsis slot]
     ↑            ↑                    ↑              ↑
  state hue   state hue           Tokens.ink      §3 ladder
```

- Glyph and eyebrow: `Space.xs` (4) apart, then `Space.sm` (8) before the title
- Title: `.edHeading` (Inter semibold 13), `Tokens.ink`
  - small: `lineLimit(1)`, `.truncationMode(.tail)`
  - medium / large: `lineLimit(2)`
- Eyebrow: `.edEyebrow` via the existing `.eyebrow()` modifier, but overriding
  `foregroundStyle` to the state colour. Large only
- `Spacer(minLength: Space.sm)` between title and chip

### Progress indicator

Derived: completed tiles over total tiles. **Monochrome, always.** Progress is not
state and must not borrow state's colour, or the block would carry the same signal
three times and the eye would start reading progress as urgency.

| Size | Treatment |
|---|---|
| **Small** | Numerals only. `3/8`, `.edCaption` (Inter 10), `Tokens.muted` |
| **Medium / Large** | A 3pt-tall `Capsule` bar, max width 88pt, flexing to fill available space. Track `Tokens.border`, fill `Tokens.inkSoft` (`Tokens.muted` when Done). Then `Space.sm`, then `3/8` in `.edCaption` `Tokens.muted` |

Empty block: suppress the indicator entirely. `0/0` is noise, not information.

Apply `.contentTransition(.numericText())` to the numerals so a completion does
not pop the digit. Disabled under reduced motion.

### Small (1 col, 172pt wide, ≥2 rows)

```
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔   3pt rail
 ● Rewrite the deck
 3/8              [!]
```

- Rail, `Space.md` padding
- Header: glyph + title (1 line). No eyebrow, no ellipsis until hover
- `Space.xs` (4)
- Meta line: progress numerals, `Spacer`, urgency chip (rungs 3 to 5 only)
- **Suppressed**: intent line, progress bar, all tiles, `+N more`, add row

### Medium (2 col, 356pt wide)

- Everything above, plus:
- **Intent line** under the title, if set: `.edSubheadline` (Inter 12),
  `Tokens.muted`, `lineLimit(1)`. `Space.xxs` (2) below the title
- Progress becomes bar + numerals
- `Space.md` (12) gap, then the **tile stack**
- Tiles shown = `min(fitsInHeight, 3)`, `Space.xs` (4) between
- Then `+5 more`, `.edCaption`, `Tokens.muted`, `Space.xs` above,
  left-aligned. It is a **button**: clicking opens an `NSPopover`-backed anchored
  popover listing every tile (the app already ships `MacAnchoredPopover` from
  #416; anchor to the window `contentView`, never a row)
- The cap of 3 holds even on a tall medium block. A 2 × 8 block showing twelve
  tiles is exactly the "300 lines of task text" failure the concept doc rules out.
  The `+N more` row anchors to the block's foot and the space between is left
  empty, which is the honest rendering of "you made this tall, and medium blocks
  do not list everything"
- **Suppressed**: add row

### Large (3+ col, 540pt+ wide)

- Everything above, plus:
- **State eyebrow** appears next to the glyph (`ACTIVE`, `WAITING`). This is the
  explicit text carrier for state at the size where there is room for it
- No tile cap. Tiles shown = `fitsInHeight`; overflow still shows `+N more`
- A 0.5pt `Tokens.border` rule above the add row, full block width minus padding.
  `Tokens.border`, not `Tokens.divider`: the block body is `surface`, and divider
  is unreliable on light surfaces in light mode
- **Add row** pinned at the foot (see §7)

The tier is a function of the **block's own column count**, never the window's.
Recomputed live during resize.

---

## 6. Tile anatomy

A tile is one real `LocalTodo`. It is a nested object: a bordered `surface2` tile
inside a `surface` card, which is the construction this codebase has already
established as reading correctly in both themes.

| Element | Spec |
|---|---|
| Shape | `RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)` (6pt) |
| Fill | `Tokens.surface2`; `Tokens.paper2` when completed |
| Border | `paperBorder(Tokens.border, radius: Radius.sm)` |
| Min height | 26pt (matches `RowMetrics.iconChip` on macOS) |
| Padding | `.horizontal Space.sm` (8), `.vertical Space.xs` (4) |
| Layout | `HStack(spacing: Space.sm)` |

### Priority wash inside a tile

Reuse `PriorityWash`, at a **reduced alpha budget**, via a new `compact` flag
rather than a new token:

```swift
PriorityWash(priority: todo.priority, dimmed: completed, compact: true)
// compact: leadAlpha × 0.7  →  0.063 light / 0.070 dark
//          trailAlpha unchanged at 0.02 / 0.025
//          horizontal inset 0 (not RowMetrics.priorityWashInset)
```

Two reasons the existing budget is wrong here:

1. The shipped alphas were tuned against a full-pane-width row on `paper`. Inside
   a 156pt-wide tile the gradient's `0 → 0.55` ramp compresses to roughly a third
   of the distance, so the same alpha reads noticeably stronger.
2. The tile backdrop is `surface2`, not `paper`, and it already has a border. The
   wash has less work to do because the tile already has a defined shape.

The inset goes to zero because a tile does not sit on a pane seam. That inset
exists on Tasks specifically to keep colour off the macOS sidebar boundary
(`RowMetrics.priorityWashInset`), a condition that does not apply inside a block.

`.none` priority still gets no wash. That rule is load-bearing: if every tile were
tinted, priority would stop being a signal.

### Contents, leading to trailing

- **Checkbox**: 14pt SF Symbol. `circle` in `Tokens.mutedSoft` unchecked,
  `checkmark.circle.fill` in `Tokens.success` checked. Hit target 26 × 26 (see
  the touch-target note in §10). `.contentTransition(.symbolEffect(.replace))`
- **Title**: `.edBody` (Inter 13), `Tokens.ink`, `lineLimit(1)`, tail truncation
- `Spacer(minLength: Space.xs)`
- **Due text**: shown only when the task has a due date and the block is medium or
  large. Short relative form: `Fri`, `12 Aug`, `2d ago`. `.edCaption` (Inter 10).
  Colour follows `TasksView.dueColor(for:)` verbatim: overdue → `Tokens.danger`,
  before tomorrow → `Tokens.warning`, otherwise `Tokens.inkSoft`

**Bare text, no capsule.** This is the deliberate difference from the block's
urgency chip, which *is* a capsule at rungs 3 to 5. Two objects, two shapes, never
confused: block urgency is a pill in the header, tile due is loose text in a row.

### Completed tile

- Fill `Tokens.paper2`, border unchanged
- Title `Tokens.muted` with `.strikethrough(true, color: Tokens.mutedSoft)`
- Due text drops to `Tokens.mutedSoft`. A completed task is not overdue any more,
  and leaving it red would be false
- Wash applied with `dimmed: true` (the existing 0.4× multiplier)
- Sinks to the bottom of the tile stack, after every incomplete tile, so the three
  tiles a medium block shows stay meaningful

### Dragging tile

- `scale(1.03)`, `shadowMd()`
- Fill flips to `Tokens.surface` (not `surface2`), so it reads as lifted off the
  block's interior
- Border `Tokens.borderStrong`
- **No rotation.** A tilted card is a novelty and this is a tool
- Origin leaves a 26pt dashed `Tokens.border` ghost so the stack does not collapse
  and jump under the pointer
- The destination block opens a 30pt gap at the insertion index and its own border
  goes `Tokens.accentVision.opacity(0.45)`

---

## 7. Interaction states

### Block hover

| Property | Rest | Hover | Transition |
|---|---|---|---|
| Border | per state table | `Tokens.borderStrong` (Active keeps its ink border) | 120ms `.easeOut` |
| Shadow | `shadowSm()` | `shadowMd()` | 120ms `.easeOut` |
| Ellipsis | `opacity 0` in a reserved 24 × 24 slot | `opacity 1` | 120ms `.easeOut` |
| Resize handle | `opacity 0` | `opacity 1` | 120ms `.easeOut` |
| Scale | 1.0 | **1.0** | none |

**No hover scale.** On this board, size is meaning. A block that grows on hover is
making a claim it does not mean, and on a dense board the growth would overlap its
neighbours.

**Nothing is inserted on hover.** Both hover-revealed controls occupy reserved
space at rest. Layout never shifts.

Cursor: `NSCursor.openHand` over the block header and body, `.arrow` over
interactive children.

### Block selected

Single click anywhere on the block's chrome (not on a tile, not on the title):

- Border becomes `Tokens.accentVision` at **1pt**. The one deliberate departure
  from the 0.5pt hairline rule in the whole app, because selection has to be
  unambiguous at board zoom and a hairline is not
- Plus a halo: `RoundedRectangle(Radius.card + 2).stroke(Tokens.accentVision.opacity(0.16), lineWidth: 3).padding(-2)`
- Fill and shadow unchanged. Selection is an outline, not a highlight

**Keyboard focus uses the identical treatment**, and the system focus ring is
suppressed. One visual language for "this is the block you are acting on",
whether you got there by pointer or by Tab.

### Block dragging

- `scale(1.02)`, `opacity(0.92)`, `shadowLg()`
- Border `Tokens.accentVision.opacity(0.6)`
- Cursor `NSCursor.closedHand`
- Grid lattice strengthens (§4). It was already there; it does not appear
- The block follows the pointer **1:1 and continuously**
- The target slot **jumps** discretely between legal cells

### Snap feedback

The pairing above is the snap feedback, and it needs no extra flourish: the block
floats free under your hand while the slot clicks into place beneath it. The
contrast between continuous and discrete is what communicates snapping.

- Slot jump animates `.snappy(duration: 0.12)`
- On each jump, fire
  `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`.
  `.alignment` is precisely the semantic Apple defines for this, and it works on
  Force Touch trackpads and Magic Trackpads. Silently no-ops elsewhere
- On drop, the block springs into the slot:
  `.spring(response: 0.28, dampingFraction: 0.86)`

### Invalid / occupied drop

The concept doc is explicit: a drop that would overlap **nudges to the nearest free
slot** rather than refusing. So in normal operation the target slot always shows a
legal destination and there is no invalid state to render.

The one genuinely unresolvable case is "no free slot of this size within the
canvas." Then:

- Target slot renders `Tokens.mutedSoft.opacity(0.14)` fill with a dashed
  `Tokens.mutedSoft` 0.5pt hairline. **No accent, and no red**
- On release the block returns to origin,
  `.spring(response: 0.28, dampingFraction: 0.86)`

Grey rather than red on purpose. Red means "you did something wrong." Nothing is
wrong; there is simply nowhere to put it. The canvas grows on demand in any case,
so this state should be nearly unreachable.

### Resize handle

> **Superseded 2026-08-06.** This section originally left the block itself
> quantised while the grip was held: the card jumped a whole cell at a time as
> the pointer crossed each boundary. Reviewed against the built surface and
> reversed. The block now tracks the pointer continuously and snaps on release,
> which is the same continuous-versus-discrete pairing the drag already uses.

- Bottom-right corner, inset `Space.sm` (8) from both edges
- Two diagonal strokes, 1.5pt wide, 10pt and 6pt long, `Tokens.mutedSoft`.
  The Mac scroller-grip idiom
- `opacity 0` at rest, `1` on block hover, 120ms `.easeOut`
- Hit target 20 × 20
- Cursor: **ship `NSCursor.arrow`.** AppKit exposes no public diagonal resize
  cursor, and `.crosshair` is wrong (it means "precise point", not "drag corner").
  The visible grip glyph carries the affordance. Do not reach for the private
  `_windowResizeNorthWestSouthEastCursor`

The grip's `DragGesture` must use `coordinateSpace: .global`. The grip is pinned
to the corner the resize is moving, so in local space the pointer appears to stop
moving as the card grows and the gesture fights itself.

While resizing:

- **The edge follows the pointer continuously and unquantised.** The card renders
  at a size in points, not in cells. This is what makes the resize feel like a
  handle rather than a stepper
- **A dashed target outline** shows the cell-quantised size the block will land
  in: `Tokens.accentVision`, 1pt, dash `[5,4]`, `Radius.card`, drawn **on top of
  the block**. On top because shrinking would otherwise hide the outline behind
  the very block it describes, and **unfilled** for the same reason: the 10%
  accent wash the drag target slot carries would tint the card's own content.
  The pairing is deliberately the drag's: the thing in your hand moves
  continuously, the preview clicks between cells
- Grid lattice strengthens (§4)
- The block's body **re-lays-out live**, off the **quantised** width, never the
  continuous one. Growing from 1 col to 2 makes tiles appear under your hand as
  you drag, which is the point of the exercise and must not be deferred to drop
  — but tiering off the continuous width would re-tier twice per boundary as the
  pointer wobbles across it, and the interior would flicker
- A **dimension readout** appears centred in the block: `3 × 4`, `.edMono`
  (JetBrains Mono 11), `Tokens.muted`, on a `Tokens.surface.opacity(0.9)` capsule
  with `Tokens.border` hairline. Mono because it is a measurement, and mono keeps
  the capsule from jittering in width as the digits change. It reads the
  quantised size, so it changes once per cell
- The **alignment haptic** fires on each cell change, never continuously. A
  haptic on every pointer sample is a buzz, not a signal
- Minimum enforced at `VisionGrid.minColumns × minRows` (1 × 2). Below that the
  edge simply stops following, with no error state
- **Neighbour collision stops the edge too**, on the axis the neighbour is
  actually on. Growth cannot displace a block the user placed deliberately, so
  the continuous edge is capped at the last legal cell boundary. The cap is
  applied only where a neighbour cut the size short: apply it unconditionally and
  the edge also sticks on every ordinary rounding boundary

On release:

- The block **springs into the quantised size**:
  `.spring(response: 0.28, dampingFraction: 0.86)` — the same spring the drag
  settles with, so a drop and a resize release read as one physical event
- The dashed outline and the readout disappear at the moment of release; the
  spring is the block landing in the outline it was showing you
- The commit is awaited before the live size is dropped. Drop it first and the
  card renders for a frame at its pre-drag size, so it springs backwards and then
  jumps forwards

### Inline title edit

Single click on the title text. The caret lands at the clicked character. Never a
long press, never a context-menu Rename.

Use the existing `MacClearTextField`.

**One trap to flag explicitly.** `MacClearTextField` reads
`EdMetrics.bodyPointSize` and configures an `NSFont`. The block title is
`.edHeading`, which is Inter **SemiBold** 13 on macOS, while `.edBody` is Inter
**Regular** 13. Same point size, different weight. If the field is left at the
default the text will change weight the instant you click it. Configure the field
with `NSFont(name: "Inter-SemiBold", size: EdMetrics.bodyPointSize)`. This is
exactly the bug class the `EdMetrics` doc comment was written about (#301), where
a numeric relationship asserted in a comment silently inverted.

- Field chrome: none. No background, no border, no focus ring. The block is
  already selected, so the caret is sufficient signal
- Return commits. Escape reverts. Click-away commits
- Committing an empty title reverts to the previous title. A block is never
  untitled

### The add-task row (large only)

Pinned at the block's foot, below a 0.5pt `Tokens.border` rule.

- `plus` glyph 10pt `Tokens.mutedSoft`, then `Space.sm`, then a
  `MacClearTextField` with placeholder `Add task` in `.edBody` `Tokens.mutedSoft`
- Leading edge aligns with the tile checkboxes above it
- On focus the row's background becomes `Tokens.surface2` at `Radius.sm`: it
  takes the shape of a tile, previewing what it is about to create
- Return creates a real `LocalTodo` filed to the block, clears the field, and
  **keeps focus**, so you can keep going
- Escape blurs
- **Always visible at large**, never hover-revealed. Hiding the create affordance
  on the primary authoring surface would be wrong

### Tile context menu

Two destructive-adjacent actions that the concept doc requires be visually
distinct:

- `Remove from board` with `minus.circle`, `Tokens.inkSoft`, no destructive role.
  Takes the task off the board and leaves the task alone
- `Delete task` with `trash`, `.destructive` role, `Tokens.danger`. Separated from
  the item above by a menu divider

---

## 8. Empty states

### Empty board

Centred in the **viewport**, not the canvas, so it stays put if the canvas is
scrolled.

```
        Nothing on the board yet
      Click anywhere to add the first
        thing you're carrying.

        ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
        │                     │
        │          +          │
        │                     │
        └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
```

- Headline: `.edDisplay` (Calistoga 22), `Tokens.ink`
- Body: `.edBody` (Inter 13), `Tokens.muted`, `Space.sm` below the headline
- `Space.xl` (24) gap
- **Ghost block** at 2 × 3 cells (356 × 192pt): no fill, dashed
  `Tokens.borderStrong` 0.5pt hairline at `Radius.card`, centred `plus` 16pt in
  `Tokens.mutedSoft`. Clicking it creates a real block in that position

No illustration, no icon in a circle. The ghost block teaches the object model
(this is what a block is, this is roughly how big) in a way copy cannot, and it is
also the primary action.

### Empty block

| Size | Treatment |
|---|---|
| **Small** | Progress indicator suppressed. Title, glyph, and state only |
| **Medium** | One line where the tiles would be: `No tasks yet`, `.edSubheadline` (Inter 12), `Tokens.mutedSoft`, left-aligned. Progress suppressed |
| **Large** | Same line, with the add row directly beneath it and already the obvious next move |

**Never render an empty tile skeleton.** A bordered empty rectangle reads as a
broken tile, not as an invitation.

---

## 9. Motion

Restrained by policy. This is a tool. The complete list of what moves:

| Event | Duration | Curve |
|---|---|---|
| Hover: border, shadow, handle, ellipsis | 120ms | `.easeOut` |
| Ghost cell in / out | 140 / 90ms | `.easeOut` / `.easeIn` |
| Grid lattice strengthens / relaxes | 120ms | `.easeOut` |
| Snap slot jumps to a new cell | 120ms | `.snappy(duration: 0.12)` |
| Block settles into slot on drop | ~280ms | `.spring(response: 0.28, dampingFraction: 0.86)` |
| Block returns to origin (no legal slot) | ~280ms | same spring |
| Tile insert / remove | 180ms | `.easeOut`, `.opacity` + `.move(edge: .top)` |
| Checkbox toggle | 140ms | `.easeOut`, symbol only, `.contentTransition(.symbolEffect(.replace))` |
| Completed tile sinks to the bottom | 200ms, **after a 400ms delay** | `.easeInOut` |
| Progress numerals change | 180ms | `.contentTransition(.numericText())` |
| New block appears | 140ms | `.easeOut`, opacity only |
| **Block content tier change during resize** | **0ms** | **none** |

Two of those are decisions, not defaults:

**The 400ms delay before a completed tile sinks.** Without it, the tile
disappears out from under the pointer at the moment of the click and the click
feels like it did something else. The delay lets you see the check land on the row
you actually clicked, then the row leaves.

**Content tier changes during resize do not animate.** Crossfading a tile stack in
while the pointer is dragging a corner puts a 200ms lag between your hand and the
result, and it reads as jank rather than as polish. Content appears and disappears
instantly.

Explicitly **not** animated: block hover scale, chip pulse, any overdue attention
loop, canvas parallax, block entry bounce, any looping animation whatsoever.

### Reduced motion

Read `@Environment(\.accessibilityReduceMotion)`:

- Every spring becomes `.easeOut(duration: 0.15)`
- The snap-slot jump becomes instant
- The grid lattice strengthens and relaxes instantly
- The completed-tile delay drops to 0 and the sink becomes a crossfade
- `.contentTransition(.numericText())` is dropped
- Ghost cell and hover transitions stay (they are 120 to 140ms opacity fades, well
  inside what reduced motion permits, and removing them would remove feedback)

**Reduced motion removes movement, never information.** Every state that was
communicated by an animation is still communicated by its endpoint.

---

## 10. Accessibility

### Contrast: state colours

All ratios computed with the WCAG 2.1 relative-luminance formula. Backdrops:
`surface` = `#FFFFFF` / `#1F1C16`, `surface2` = `#F8F5EE` / `#25211A`,
`paper2` = `#F4F0E6` / `#1B1813`.

| State | Light hex | on `surface` L | on `surface2` L | Dark hex | on `surface` D | on `surface2` D |
|---|---|---|---|---|---|---|
| Idea (`muted`) | `#7B7263` | **4.74:1** ✓ | 4.35:1 ⚠ | `#A89E8A` | **6.41:1** ✓ | **6.04:1** ✓ |
| Active (`ink`) | `#1F1B16` | **17.1:1** ✓ | **15.7:1** ✓ | `#F2EBDA` | **14.3:1** ✓ | **13.5:1** ✓ |
| Ongoing | `#0E6F87` | **5.76:1** ✓ | **5.30:1** ✓ | `#5FC6DE` | **8.59:1** ✓ | **8.10:1** ✓ |
| Waiting | `#6D4BC4` | **6.08:1** ✓ | **5.59:1** ✓ | `#AB9BF0` | **7.02:1** ✓ | **6.62:1** ✓ |
| Done (`muted`) | `#7B7263` | 4.17:1 on `paper2` ⚠ | n/a | `#A89E8A` | **6.68:1** on `paper2` ✓ | n/a |
| Accent (`accentVision`) | `#456F0D` | **5.94:1** ✓ | **5.46:1** ✓ | `#A9C46B` | **8.73:1** ✓ | **8.23:1** ✓ |

Two entries are marked ⚠ and both are handled:

1. **`Tokens.muted` on `surface2` light is 4.35:1.** State colour never lands on
   `surface2`. `surface2` is the tile fill, and state lives on the block edge.
   Recorded here so nobody later moves a state glyph onto a tile.
2. **`Tokens.muted` on `paper2` light is 4.17:1.** This is the Done block. It is
   why **Done's title and meta text use `Tokens.inkSoft`** (8.57:1 on `paper2`
   light, 11.89:1 dark), not `muted`. The Done *glyph* may stay `muted`, because
   a glyph is a non-text graphic with a 3:1 floor. See §2.

### Contrast: urgency chip

| Rung | Foreground | Backdrop | Light | Dark |
|---|---|---|---|---|
| 1 | `Tokens.muted` | `surface` | 4.74:1 ✓ | 6.41:1 ✓ |
| 2 | `Tokens.inkSoft` | `surface` | 8.57:1 ✓ | 11.9:1 ✓ |
| 3 | `Tokens.ink` | `surface2` | 15.7:1 ✓ | 13.5:1 ✓ |
| 4 text | `Tokens.ink` | `warningSoft` | **15.4:1** ✓ | **12.3:1** ✓ |
| 4 icon | `Tokens.warning` | `warningSoft` | 4.51:1 ✓ (graphic floor 3:1) | 6.79:1 ✓ |
| 5 text | `Tokens.ink` | `dangerSoft` | **14.0:1** ✓ | **13.6:1** ✓ |
| 5 icon | `Tokens.danger` | `dangerSoft` | 5.30:1 ✓ | 5.83:1 ✓ |

The `Tokens.warning` on `Tokens.warningSoft` pair measures 4.51:1, the tightest in
the app. It appears here **only as an icon and a hairline**, never as text, which
is why the chip's text colour is `ink`. If a future change puts warning-coloured
text on warningSoft anywhere on the board, it is passing by 0.01 and should be
re-measured.

### Contrast: tile text

| Element | Light | Dark |
|---|---|---|
| Title `ink` on `surface2` | 15.7:1 ✓ | 13.5:1 ✓ |
| Due `danger` on `surface2` | 5.94:1 ✓ | 5.79:1 ✓ |
| Due `warning` on `surface2` | 4.61:1 ✓ | 7.46:1 ✓ |
| Due `inkSoft` on `surface2` | 8.96:1 ✓ | 11.9:1 ✓ |
| Intent `muted` on `surface` | 4.74:1 ✓ | 6.41:1 ✓ |

The priority wash sits between the tile fill and this text. At its strongest
(6.3% alpha) it shifts the backdrop luminance by under 1.5%, which moves the
worst pair (`warning`, 4.61:1) to roughly 4.55:1. Still above the floor. This is
the reason the compact wash budget is 0.7× rather than the shipped 1.0×.

### State is never colour-only

| Signal | Colour carrier | Non-colour carriers |
|---|---|---|
| **State** | rail hue, glyph tint | rail **pattern** (solid / dashed / absent), **glyph shape** (`circle.fill` / `infinity` / `hourglass` / `lightbulb` / `checkmark`), **border style** (solid / dashed), **body fill** (`surface` / `paper2`), **eyebrow text** at large, `.help()` tooltip at every size, `accessibilityLabel` at every size |
| **Urgency** | chip fill, icon tint | **container presence**, **icon shape** (none / clock / triangle), **type size and weight**, and the **literal words** |
| **Priority** | wash hue | inherited from Tasks. The wash is decorative; the authoritative carrier is the task detail and the tile's `accessibilityLabel` |
| **Progress** | none | numerals `3/8`, plus bar length |
| **Selection** | accent border | 1pt vs 0.5pt line weight, plus a halo |

**Greyscale test**: desaturate the board and every state is still identifiable
from rail pattern and glyph shape alone. Every urgency rung from 3 upward is still
identifiable from icon shape alone. This is the acceptance criterion, and it should
be checked with a screenshot run through a greyscale filter before the feature
ships.

### Keyboard and VoiceOver

- **Tab** moves between blocks in reading order: top to bottom, then left to
  right. The same order the iOS projection uses for its single column, so the two
  surfaces agree about sequence
- **Arrow keys** with a block focused move it one cell. **⌥ + arrows** resize it
  by one cell. This is the accessible route to both drag and resize
- **Space** or **Return** enters the block, moving focus to its first tile.
  **Escape** returns focus to the board
- Focus ring is the selection treatment (accent 1pt + halo), never removed

Labels:

- Block: `"<title>. <State>. <urgency phrase>. <done> of <total> tasks. Column <c>,
  row <r>, <w> by <h> cells."` Position and size are read aloud because on this
  board they *are* content, not layout
- Tile: `accessibilityLabel` `"<title>. Priority <P0|P1|P2|none>. Due <date>."`,
  `accessibilityValue` completed or not completed,
  `.accessibilityAddTraits(.isToggle)`
- Resize handle: `.accessibilityHidden(true)`. The ⌥-arrow path is the accessible
  route, surfaced as an `accessibilityHint` on the block
- Grid lattice, ghost cell, dimension readout, target and resize slots:
  `.accessibilityHidden(true)`. All are pointer feedback

### Pointer target sizes

This is a macOS, pointer-first surface. AppKit's comfortable minimum for pointer
targets is 24 × 24pt, not the 44 × 44pt iOS touch minimum.

| Control | macOS | Note |
|---|---|---|
| Tile checkbox | 26 × 26 | ✓ |
| Block ellipsis menu | 24 × 24 | ✓ |
| Resize handle | 20 × 20 | Below 24. Justified by the visible grip glyph, the whole-corner hover reveal, and the ⌥-arrow alternative |
| Add-row field | full block width × 26 | ✓ |

**Hard constraint for the iOS projection.** Every one of these must become
44 × 44pt on the phone. The iOS board is read-and-tick only (no drag, no resize),
so the resize handle disappears entirely, but the checkbox and the ellipsis both
need `hitSlop`-equivalent expansion. Do not carry a macOS pointer number onto the
phone.

---

## 11. Token additions, summarised

Everything this spec adds. Nothing else is new.

```swift
// Design/Tokens.swift
static let accentVision  = Color.paper(0x456F0D, 0xA9C46B)
static let stateOngoing  = Color.paper(0x0E6F87, 0x5FC6DE)
static let stateWaiting  = Color.paper(0x6D4BC4, 0xAB9BF0)

// Added 2026-08-06 with the always-on lattice (§4).
static let visionLattice       = Color.paper(0xE4DCC6, 0x252019)
static let visionLatticeActive = Color.paper(0xC9BE9E, 0x4E4639)

static func state(for s: BlockState) -> Color { /* §2 */ }

// AppSection
case visionBoard   // displayName "Vision Board", icon "rectangle.3.group"
// Tokens.accent(for:) → accentVision

// Design/Spacing.swift
enum VisionGrid { /* §4 */ }

// Design/PriorityWash.swift
// add `var compact: Bool = false` → leadAlpha × 0.7, inset 0
```

Existing tokens carrying new roles, with no change to their definitions:
`ink` (Active state), `muted` (Idea and Done state), `inkSoft` (progress fill,
Done text), `surface2` (tile fill, rung-3 chip), `paper2` (Done body, completed
tile), `warningSoft` / `dangerSoft` (rung 4 / 5 chips), `border` (every hairline
and the tile-to-add-row rule), `borderStrong` (hover border, ghost outlines), `mutedSoft` (unchecked box, placeholder, resize grip).

---

## 12. Pre-delivery checklist

Visual quality
- [ ] No emoji anywhere; every glyph is an SF Symbol
- [ ] Every icon in the SF Symbols family at a consistent weight
- [ ] Hover and pressed states shift no layout (ellipsis and resize handle occupy reserved space at rest)
- [ ] Every colour comes from a `Tokens` member; no inline hex in a view

Interaction
- [ ] Every interactive element has a hover state
- [ ] Pointer targets ≥ 24 × 24 on macOS, with the resize-handle exception documented
- [ ] Micro-interaction timings between 120 and 300ms
- [ ] Drag is interruptible; Escape during a drag returns the block to origin
- [ ] **A drag cannot be left open.** Ending it must not depend on SwiftUI's
      `onEnded` alone: a gesture torn down by a view update never delivers it.
      Verify with the pointer-up path, not just by dragging successfully
- [ ] No modifier on an ancestor of a block changes value while a gesture is in
      flight (this is what tore the gesture down the first time)
- [ ] A block cannot render outside the canvas bounds in any state
- [ ] Resize edge tracks the pointer between cells; the dashed outline shows
      where it lands; the interior re-tiers on the boundary and does not flicker

Light and dark
- [ ] Every state colour verified against `surface`, `surface2`, and `paper2` in both themes
- [ ] Screenshot both themes at small, medium, and large block sizes before sign-off
- [ ] Verify `divider` was not used on any light surface (use `border`)

Accessibility
- [ ] Greyscale screenshot test: every state and every urgency rung ≥ 3 still identifiable
- [ ] Tab order matches visual reading order
- [ ] ⌥-arrow move and resize work with no pointer
- [ ] Reduced motion verified: nothing loops, no information is lost
- [ ] Block labels announce position and size

macOS build hygiene (per `.claude/CLAUDE.md`)
- [ ] Every new file added to the curated `DexterMac` `sources:` list in `mobile/project.yml`
- [ ] `xcodegen generate` run, both targets built
- [ ] iOS target still builds after any shared-file change (`PriorityWash`, `Tokens`, `Spacing` are all shared)
- [ ] `MacClearTextField` for the block title configured with Inter-SemiBold at `EdMetrics.bodyPointSize`, not the default regular weight
