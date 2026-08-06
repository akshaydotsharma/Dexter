# Vision Board — conceptual design

Status: concept, pre-implementation
Surface: macOS (`DexterMac`) first, iOS second
Date: 2026-08-06

## The problem

Dexter can already tell you what is due today and what is on a list. It cannot tell you
what you are *carrying*. The big pieces of work in a life do not live in a task list: they
live in the head, and the task list is only their debris. There is no surface in the app
where the whole load is visible at once.

A vision board is that surface. One screen, everything in flight, sized by how big it
actually is.

## The object model

Three nouns, only one of which is new.

**Board** — a single canvas. Generic, no time filter. Ships as exactly one board; the model
allows more later without a migration.

**Block** — a big piece of work. Net-new concept. Has a title, an optional one-line intent,
a position, a size, a state, and an accent. This is the thing you resize.

**Tile** — a task inside a block. Two flavours from day one:
- a *linked* tile, pointing at an existing `LocalTodo`
- a *loose* tile, created inline on the board and backed by a real `LocalTodo` too

Both are the same underlying object. The difference is only where it was born. That matters:
if a board tile is a second-class scribble, the board rots the moment you complete something
in Tasks and the board keeps claiming it is open. One task, one truth, two places to see it.

A task may appear in at most one block. Membership is a property of the block, not the task,
so nothing is added to `LocalTodo` and nothing on the board can strand a task.

## State versus urgency

The obvious move is one enum: *in progress / ongoing / has a deadline / done*. That is the
mistake. "Has a deadline" is not a state a piece of work is in, it is a fact about the
calendar, and jamming it into the same field means a block that is both in progress and due
Friday has to pick one — so it picks the wrong one.

So: two independent channels, encoded differently so they never compete for the same pixel.

**State** is manual, set by you, carried by the block's colour.

| State | Meaning |
|---|---|
| Idea | Parked. Real, not started. |
| Active | Being worked on now. |
| Ongoing | Continuous, no finish line. Health, reading, admin. |
| Waiting | Blocked on someone or something else. |
| Done | Finished. Fades, does not disappear. |

**Urgency** is derived, never typed, carried by a chip and a rising temperature. It reads the
soonest incomplete due date among the block's tasks and says the true thing: `in 2 days`,
`tomorrow`, `overdue by 3`. Nothing to maintain, so it cannot go stale.

A block therefore says two things at once without ambiguity: *what I am doing about it*
(colour) and *what the calendar is doing to me* (chip).

## Layout: canvas, snapped

Free position and free size, snapped to a grid. Not a packed masonry, not a Kanban
column.

(The grid was originally invisible at rest. Reversed in review on 2026-08-06: it is now
faintly visible at all times and strengthens while something is in hand. See §4 of the
design system for the argument on both sides.)

The reason is spatial memory. A board earns its keep when "the heavy one" is always
top-left and you stop reading the titles. Auto-packing destroys that: add one block and
everything else moves. Snapping keeps the grid honest without taking the placement away
from you.

Blocks may not overlap. A drop that would overlap nudges to the nearest free slot rather
than refusing, so it never feels like a fight.

Resize is a bottom-right corner handle with a minimum of one column by two rows. The edge
follows the pointer continuously and lands on a grid unit when you let go (revised
2026-08-06; it used to jump a whole cell at a time under the hand). Size is the whole point of the exercise: a block you made large is a claim about how
much of you it is taking, and the board should let that claim be wrong and visible.

## What a block shows at each size

Blocks are read from across the room at some sizes and worked in at others, so the content
is responsive to the block's own size, not the window's.

- **Small** (1 col): title, state colour, urgency chip, `3/8` count. No tiles.
- **Medium** (2 col): the above plus the next three tiles, then `+5 more`.
- **Large** (3+ col, tall): the above plus every tile, plus the inline add row.

This is what stops a 30-block board from being 300 lines of task text.

## Interactions

- **New block**: double-click empty canvas. Creates at that point, title in edit mode.
- **New task in a block**: an add row at the block's foot. Type, return, it exists. Return
  again keeps going. Creating here creates a real task, filed to the block.
- **Attach an existing task**: a search field in the block's menu that finds any `LocalTodo`
  not already on the board.
- **Complete a task**: click its checkbox on the tile. Same effect as completing in Tasks.
- **Move a task between blocks**: drag the tile.
- **Edit a title**: click it, cursor lands in it. Never a long-press, never a context-menu
  Rename.
- **Remove from board**: takes the task off the board and leaves the task alone. Distinct,
  and visually distinct, from deleting it.

## How this reaches iOS

The board is not portable as a canvas. A 3000pt canvas on a 393pt screen is a pan-and-zoom
toy, and Dexter's iOS app is used one-handed and in a hurry.

So iOS renders the *same* board with a different projection: blocks in a single column,
ordered by their canvas position read top-to-bottom then left-to-right, each one collapsed
to its small or medium presentation, expanding on tap. Position and size are still
meaningful on the phone — they set the order and the prominence — they are just not
directly editable there. Authoring stays on the Mac, where a pointer and a large screen
make it pleasant; the phone is for reading the board and ticking things off.

That also means the shared model needs no phone-specific fields, and the phone build never
has to implement drag-resize.

## Deliberately out of scope for v1

- Multiple boards
- Time filters or date-scoped views
- Dependencies or arrows between blocks
- Notes, images, or free text on the canvas
- Sharing or export
- iOS authoring of position and size

## Open questions for review

- Does a block ever need to map onto an existing `LocalList`, or is it always its own thing?
- Should a completed block auto-collapse to small, or stay the size you gave it?
- Is "Ongoing" a distinct state, or just "Active" with no due dates anywhere?
