import SwiftUI

// MARK: - Metrics

/// One height per hour, every hour of every day (#687 round 2), the Google
/// Calendar shape: a 30 minute booking fills half an hour row.
enum PlannerGridMetrics {
    static var hourHeight: CGFloat {
        #if os(macOS)
        50
        #else
        54
        #endif
    }
    /// Keeps a 15 minute tile tappable.
    static let minTileHeight: CGFloat = 20
    static let labelWidth: CGFloat = 44
    /// Below this a tile shows its title only.
    static let twoLineHeight: CGFloat = 32
}

// MARK: - Tile

/// The ONE tile every item uses: work and personal events, planned tasks,
/// timed tasks, manual blocks (#687 round 2). Same shape, fill and type; only
/// the source colour changes (the left stripe and a light tint of it). A task
/// adds a small glyph inside the same shape. A conflict adds a thin danger
/// ring, which is state, not type.
struct PlannerTile: View {
    let item: PlannerItem
    var inConflict: Bool = false
    var height: CGFloat = 40

    var body: some View {
        let c = PlannerStyle.color(item.source)
        // Top-aligned: the full-height stripe makes the row as tall as the
        // tile, and a centred text column put a long block's title mid-tile.
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(c).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if item.source == .task {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(c)
                    }
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Tokens.ink)
                        .strikethrough(item.completed || item.isDeclined, color: Tokens.muted)
                        .lineLimit(height >= PlannerGridMetrics.twoLineHeight * 1.6 ? 2 : 1)
                }
                if height >= PlannerGridMetrics.twoLineHeight, let s = item.start, let e = item.end {
                    Text(PlannerStyle.range(s, e))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Tokens.inkSoft)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, height < 26 ? 1 : 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                Tokens.surface
                c.opacity(0.16)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if inConflict {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Tokens.danger, lineWidth: 1.2)
            }
        }
        // Declined (#689): faded and struck through, as Google Calendar does.
        .opacity(item.isDeclined ? 0.45 : (item.completed ? 0.6 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.title]
        if let s = item.start, let e = item.end { parts.append(PlannerStyle.range(s, e)) }
        parts.append(item.detail)
        if item.isDeclined { parts.append("declined") }
        if inConflict { parts.append("overlaps another item") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - One day column

/// Tiles for one day, placed by time, with a now line. A tap on empty space
/// reports the tapped time, snapped to 15 minutes.
struct PlannerDayColumn: View {
    let day: PlannerDay
    let visible: Set<PlannerSource>
    let now: Date
    var hourHeight: CGFloat = PlannerGridMetrics.hourHeight
    /// A single click or tap: the quick view.
    let onTapItem: (PlannerItem) -> Void
    let draft: PlannerDraftHandlers
    /// A double click (Mac): the full editor.
    var onOpenItem: (PlannerItem) -> Void = { _ in }
    @Environment(\.plannerTileActions) private var tileActions
    @Environment(\.plannerTaskDrag) private var taskDrag
    /// The tile whose bottom edge is being dragged, and its live end.
    @State private var resize: (id: String, end: Date)?
    /// iPhone (#693): the tile picked up and moved, and its live start.
    @State private var move: (id: String, start: Date)?

    /// Dexter owns manual blocks and task tiles, so those resize. Calendar
    /// events are read-only and get no handle.
    static func isResizable(_ item: PlannerItem) -> Bool {
        guard item.occupiesTime, !item.isFixed else { return false }
        if item.isBlock { return true }
        if case .taskDue = item.origin { return true }
        return false
    }

    /// Dexter tiles also MOVE (#693), by the same rule as resize: a manual
    /// block or a task tile, never a calendar event.
    static func isMovable(_ item: PlannerItem) -> Bool { isResizable(item) }

    /// The start a tile dragged by `delta` points lands on. Its own start,
    /// to the second, when the drag is too short to count.
    private func movedStart(_ item: PlannerItem, delta: CGFloat) -> Date {
        let dayStart = day.day
        let start = PlannerDragGeometry.minutes(of: item.start!, dayStart: dayStart)
        let length = PlannerDragGeometry.minutes(of: item.end!, dayStart: dayStart) - start
        // The start shown a moment ago, for the snap's hysteresis.
        let shown = move?.id == item.id ? move.map { PlannerDragGeometry.minutes(of: $0.start, dayStart: dayStart) } : nil
        let m = PlannerDragGeometry.movedStart(start: start, length: length, deltaY: delta,
                                               hourHeight: hourHeight, previous: shown)
        return m == start ? item.start! : dayStart.addingTimeInterval(TimeInterval(m * 60))
    }

    /// Write a move: the same length at the new start.
    private func commitMove(_ item: PlannerItem, to start: Date) {
        guard start != item.start, let s = item.start, let e = item.end else { return }
        draft.onMove(item, start, start.addingTimeInterval(e.timeIntervalSince(s)))
    }

    private func resizeHandle(_ item: PlannerItem) -> some View {
        let dayStart = day.day
        let start = PlannerDragGeometry.minutes(of: item.start!, dayStart: dayStart)
        let originalEnd = PlannerDragGeometry.minutes(of: item.end!, dayStart: dayStart)
        func end(for delta: CGFloat) -> Date {
            // The end shown a moment ago, for the snap's hysteresis.
            let shown = resize?.id == item.id ? resize.map { PlannerDragGeometry.minutes(of: $0.end, dayStart: dayStart) } : nil
            let m = PlannerDragGeometry.resizedEnd(start: start, originalEnd: originalEnd, deltaY: delta,
                                                   hourHeight: hourHeight, previous: shown)
            return dayStart.addingTimeInterval(TimeInterval(m * 60))
        }
        return ZStack(alignment: .bottom) {
            #if os(iOS)
            // A visible grab bar, so the edge reads as draggable.
            Capsule().fill(PlannerStyle.color(item.source).opacity(0.55))
                .frame(width: 22, height: 3)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
            #endif
            PlannerResizeHandle(
                identifier: "planner.resize.\(item.title)",
                onChange: { delta in resize = (item.id, end(for: delta)) },
                onCommit: { delta in
                    let e = end(for: delta)
                    resize = nil
                    if e != item.end { draft.onResize(item, e) }
                }
            )
            // The strip straddles the bottom edge (half in, half below), so
            // even a 30 minute tile keeps most of its body for a tap that
            // opens details.
            #if os(macOS)
            .frame(height: 6)
            .offset(y: 2)
            #else
            .frame(height: 14)
            .offset(y: 6)
            #endif
        }
        .frame(maxWidth: .infinity)
    }

    /// One tile (#687 round 6). Mac: an AppKit layer reads the click count, so
    /// one click opens the quick view anchored to the tile and a double click
    /// opens the editor; right click gives the same menu. iPhone: a tap opens
    /// the quick view card, and touch and hold gives the menu.
    @ViewBuilder
    private func tile(_ item: PlannerItem, inConflict: Bool, height: CGFloat, width: CGFloat, tileHeight: CGFloat) -> some View {
        let face = PlannerTile(item: item, inConflict: inConflict, height: height)
            .frame(width: width, height: tileHeight, alignment: .topLeading)
        #if os(macOS)
        face
            .overlay {
                PlannerTileClickLayer(
                    label: item.title,
                    onClick: { onTapItem(item) },
                    onDoubleClick: { onOpenItem(item) },
                    menuEntries: { tileActions?.menu(for: item) ?? [] },
                    onCommand: { tileActions?.run($0, item) }
                )
            }
            .macAnchoredPopover(
                isPresented: Binding(
                    get: { tileActions?.quickViewID == item.id },
                    set: { shown in if !shown, tileActions?.quickViewID == item.id { tileActions?.dismissQuickView() } }
                ),
                // The Planner owns dismissal: a click outside closes it, a click
                // on the tile itself does not, so a double click reaches the tile.
                behavior: .applicationDefined,
                preferredEdge: .maxX
            ) {
                PlannerQuickView(
                    item: item,
                    event: tileActions?.event(item),
                    run: { tileActions?.run($0, item) },
                    onClose: { tileActions?.dismissQuickView() }
                )
            }
            .frame(width: width, height: tileHeight)
        #else
        if Self.isMovable(item) {
            // A Dexter tile (#693): one UIKit layer owns tap (quick view) and
            // touch and hold (lift and move). The hold replaces the context
            // menu here; Edit and Delete are on the quick view a tap opens.
            face
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("planner.tile.\(item.title)")
                .accessibilityAction { onTapItem(item) }
                .accessibilityAction(named: "Move 15 minutes earlier") {
                    commitMove(item, to: movedStart(item, delta: -hourHeight / 4))
                }
                .accessibilityAction(named: "Move 15 minutes later") {
                    commitMove(item, to: movedStart(item, delta: hourHeight / 4))
                }
                .overlay {
                    PlannerTileMoveLayer(
                        identifier: "planner.move.\(item.title)",
                        onTap: { onTapItem(item) },
                        onChange: { delta in move = (item.id, movedStart(item, delta: delta)) },
                        onCommit: { delta in
                            let start = movedStart(item, delta: delta)
                            move = nil
                            commitMove(item, to: start)
                        },
                        onBegin: { draft.onMoveBegin() }
                    )
                }
                .frame(width: width, height: tileHeight)
        } else {
            Button { onTapItem(item) } label: { face }
                .buttonStyle(.plain)
                .plannerTileMenu(item, actions: tileActions)
                .frame(width: width, height: tileHeight)
                .accessibilityIdentifier("planner.tile.\(item.title)")
        }
        #endif
    }

    var body: some View {
        let items = day.timed.filter { visible.contains($0.source) }
        let lanes = Dictionary(PlannerEngine.lanes(items).map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                // Where a To-plan task can be dropped (#687 fix). Never takes
                // a click itself.
                PlannerDropZone(dayStart: day.day, hourHeight: hourHeight)
                // Empty space is the free time. Drag across it (or click, or
                // tap) to make a draft block (#687 round 3).
                PlannerGridPointerLayer(
                    hourHeight: hourHeight,
                    onChange: { r in
                        let d = PlannerDragGeometry.dates(r, dayStart: day.day)
                        draft.onChange(d.start, d.end)
                    },
                    onCommit: { r in
                        let d = PlannerDragGeometry.dates(r, dayStart: day.day)
                        draft.onCommit(d.start, d.end)
                    }
                )
                ForEach(items) { item in
                    // While its edge is dragged, a tile shows the new end live;
                    // while it is moved (#693), its new start, same length.
                    let moving = move?.id == item.id
                    let start = moving ? move!.start : item.start!
                    let end = moving
                        ? move!.start.addingTimeInterval(item.end!.timeIntervalSince(item.start!))
                        : (resize?.id == item.id ? resize!.end : item.end!)
                    let g = PlannerEngine.tileGeometry(
                        start: start, end: end, dayStart: day.day,
                        hourHeight: hourHeight, minHeight: PlannerGridMetrics.minTileHeight
                    )
                    let lane = lanes[item.id]
                    let count = CGFloat(max(1, lane?.count ?? 1))
                    let laneW = w / count
                    // The label gets the tile's exact size. A plain Button on iOS
                    // otherwise centres a smaller label inside a taller frame,
                    // which put a long block's title in its middle.
                    let tileW = max(8, laneW - 3)
                    let tileH = max(PlannerGridMetrics.minTileHeight, g.height - 1)
                    tile(item, inConflict: lane?.inConflict ?? false, height: g.height - 1, width: tileW, tileHeight: tileH)
                    .overlay(alignment: .bottom) {
                        if Self.isResizable(item) {
                            resizeHandle(item)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if resize?.id == item.id || moving {
                            Text(PlannerStyle.range(start, end))
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Tokens.paper)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Tokens.ink, in: Capsule())
                                .padding(4)
                                .allowsHitTesting(false)
                        }
                    }
                    // Lifted: a little larger, with a shadow, above its neighbours.
                    .scaleEffect(moving ? 1.03 : 1, anchor: .center)
                    .shadow(color: .black.opacity(moving ? 0.22 : 0), radius: moving ? 10 : 0, y: moving ? 5 : 0)
                    .animation(.easeOut(duration: 0.15), value: moving)
                    .zIndex(moving ? 1 : 0)
                    .offset(x: laneW * CGFloat(lane?.index ?? 0) + 1, y: g.y)
                }
                if let payload = taskDrag.payload, let t = taskDrag.target, t.dayStart == day.day {
                    let g = PlannerEngine.tileGeometry(
                        start: t.start, end: t.end, dayStart: day.day,
                        hourHeight: hourHeight, minHeight: PlannerGridMetrics.minTileHeight
                    )
                    PlannerTaskGhost(title: payload.title, start: t.start, end: t.end, height: g.height - 1)
                        .frame(width: max(8, w - 3), height: max(PlannerGridMetrics.minTileHeight, g.height - 1))
                        .offset(x: 1, y: g.y)
                }
                if let d = draft.draft, Calendar.current.isDate(d.start, inSameDayAs: day.day) {
                    let g = PlannerEngine.tileGeometry(
                        start: d.start, end: d.end, dayStart: day.day,
                        hourHeight: hourHeight, minHeight: PlannerGridMetrics.minTileHeight
                    )
                    PlannerDraftTile(draft: d, height: g.height - 1)
                        .frame(width: max(8, w - 3), height: max(PlannerGridMetrics.minTileHeight, g.height - 1))
                        #if os(macOS)
                        .popover(isPresented: draft.popoverPresented, arrowEdge: .trailing) {
                            draft.quickCreate()
                        }
                        #endif
                        .offset(x: 1, y: g.y)
                }
                if Calendar.current.isDate(now, inSameDayAs: day.day) {
                    let y = PlannerEngine.tileGeometry(start: now, end: now, dayStart: day.day, hourHeight: hourHeight, minHeight: 0).y
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Tokens.accentToday).frame(height: 1.5)
                        Circle().fill(Tokens.accentToday).frame(width: 8, height: 8).offset(x: -4)
                    }
                    .frame(width: w)
                    .offset(y: y - 0.75)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: hourHeight * 24)
    }
}

// MARK: - Ruler and lines

/// Hour labels on the left, one invisible anchor per hour for auto-scroll.
struct PlannerHourRuler: View {
    var hourHeight: CGFloat = PlannerGridMetrics.hourHeight

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                // The label sits just BELOW its hour line, so it is never
                // clipped when the grid scrolls an hour to the top.
                ZStack(alignment: .topTrailing) {
                    Color.clear
                    Text(label(h))
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.muted)
                        .padding(.top, 2)
                        .padding(.trailing, 6)
                }
                .frame(height: hourHeight)
                .id(h)
            }
        }
        // The hours are the scroll targets for `scrollPosition(id:)`.
        .scrollTargetLayout()
        .frame(width: PlannerGridMetrics.labelWidth)
        .accessibilityHidden(true)
    }

    private func label(_ h: Int) -> String {
        let hr = h % 12 == 0 ? 12 : h % 12
        return "\(hr) \(h < 12 ? "AM" : "PM")"
    }
}


/// A hairline per hour, behind the columns.
struct PlannerHourLines: View {
    var hourHeight: CGFloat = PlannerGridMetrics.hourHeight

    var body: some View {
        Canvas { ctx, size in
            for h in 0...24 {
                let y = CGFloat(h) * hourHeight
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(Tokens.divider), lineWidth: 1)
            }
        }
        .frame(height: hourHeight * 24)
        .allowsHitTesting(false)
    }
}

/// The hour to scroll to: an hour before now on today, else the workday start.
enum PlannerGridScroll {
    static func targetHour(for day: Date, now: Date, settings: WorkdaySettings, calendar: Calendar = .current) -> Int {
        if calendar.isDate(day, inSameDayAs: now) {
            return max(0, min(23, calendar.component(.hour, from: now) - 1))
        }
        return max(0, min(23, settings.startMinute / 60))
    }
}

// MARK: - Day grid

/// The Day view (#687 round 2): the all-day row pinned above a 24-hour grid
/// that scrolls, and auto-scrolls to the current hour on today.
struct PlannerDayTimeGrid: View {
    let day: PlannerDay
    let visible: Set<PlannerSource>
    let now: Date
    let settings: WorkdaySettings
    var bottomInset: CGFloat = 0
    let onTapItem: (PlannerItem) -> Void
    let draft: PlannerDraftHandlers
    var onOpenItem: (PlannerItem) -> Void = { _ in }

    @State private var topHour: Int?

    var body: some View {
        let allDay = day.allDay.filter { visible.contains($0.source) }
        VStack(spacing: 0) {
            if !allDay.isEmpty {
                PlannerAllDayRow(
                    items: allDay, onTap: onOpenItem,
                    dragMinutes: draft.allDayTaskMinutes,
                    onDropTask: draft.onDropAllDayTask
                )
                Rectangle().fill(Tokens.border).frame(height: 1)
            }
            // `scrollPosition(id:)`, not a `ScrollViewReader`. On macOS a
            // reader's `scrollTo` scrolled EVERY scroll view in the window
            // (the sidebar list, the inspector and the detail pane) on the
            // #687 round 2 build, which pushed the whole window off screen.
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    PlannerHourRuler()
                    PlannerDayColumn(day: day, visible: visible, now: now, onTapItem: onTapItem, draft: draft, onOpenItem: onOpenItem)
                        .background(alignment: .top) { PlannerHourLines() }
                        .overlay(alignment: .leading) { Rectangle().fill(Tokens.divider).frame(width: 1) }
                        .padding(.trailing, Space.sm)
                }
                .padding(.bottom, bottomInset)
            }
            .scrollPosition(id: $topHour, anchor: .top)
            .onAppear { topHour = PlannerGridScroll.targetHour(for: day.day, now: now, settings: settings) }
            .onChange(of: day.day) { _, d in topHour = PlannerGridScroll.targetHour(for: d, now: now, settings: settings) }
        }
        .plannerCard()
    }
}

// MARK: - Week grid (macOS)

/// Seven columns of the same grid and the same tiles (#687 round 2).
struct PlannerWeekTimeGrid: View {
    struct Column: Identifiable {
        let day: PlannerDay
        let summary: CapacitySummary
        var id: Date { day.day }
    }

    let columns: [Column]
    let visible: Set<PlannerSource>
    let now: Date
    let settings: WorkdaySettings
    let onOpenDay: (Date) -> Void
    let onTapItem: (PlannerItem) -> Void
    let draft: PlannerDraftHandlers
    var onOpenItem: (PlannerItem) -> Void = { _ in }
    @Environment(\.plannerTileActions) private var tileActions

    @State private var topHour: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: PlannerGridMetrics.labelWidth, height: 1)
                ForEach(columns) { col in
                    header(col)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .leading) { Rectangle().fill(Tokens.divider).frame(width: 1) }
                }
            }
            Rectangle().fill(Tokens.border).frame(height: 1)
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    PlannerHourRuler()
                    ForEach(columns) { col in
                        PlannerDayColumn(day: col.day, visible: visible, now: now, onTapItem: onTapItem, draft: draft, onOpenItem: onOpenItem)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .leading) { Rectangle().fill(Tokens.divider).frame(width: 1) }
                    }
                }
                .background(alignment: .top) {
                    PlannerHourLines().padding(.leading, PlannerGridMetrics.labelWidth)
                }
            }
            .scrollPosition(id: $topHour, anchor: .top)
            .onAppear {
                let today = columns.first { Calendar.current.isDate($0.day.day, inSameDayAs: now) }
                topHour = PlannerGridScroll.targetHour(for: today?.day.day ?? columns.first?.day.day ?? now, now: now, settings: settings)
            }
        }
        .plannerCard()
    }

    private func header(_ col: Column) -> some View {
        let isToday = Calendar.current.isDate(col.day.day, inSameDayAs: now)
        let allDay = col.day.allDay.filter { visible.contains($0.source) }
        let s = col.summary
        return VStack(alignment: .leading, spacing: 4) {
            Button { onOpenDay(col.day.day) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(PlannerStyle.shortDayFormatter.string(from: col.day.day))
                        .font(.edFootnoteStrong)
                        .foregroundStyle(isToday ? Tokens.accentToday : Tokens.ink)
                    Text(s.isOver ? "\(PlannerFormat.duration(s.bookedMinutes)) · over \(PlannerFormat.duration(s.overflowMinutes))"
                         : (s.isWorkday ? "\(PlannerFormat.duration(s.bookedMinutes)) of \(PlannerFormat.duration(s.capacityMinutes))"
                            : PlannerFormat.duration(s.bookedMinutes)))
                        .font(.edCaption.weight(s.isOver ? .semibold : .regular))
                        .foregroundStyle(s.isOver ? Tokens.danger : Tokens.muted)
                        .lineLimit(1)
                    PlannerMeterBar(summary: s, scaleMinutes: settings.lengthMinutes, height: 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(PlannerStyle.weekdayFormatter.string(from: col.day.day))")
            ForEach(allDay.prefix(2)) { item in
                Button { onOpenItem(item) } label: {
                    PlannerTile(item: item, height: 18).frame(height: 18)
                }
                .buttonStyle(.plain)
                .plannerTileMenu(item, actions: tileActions)
            }
            if allDay.count > 2 {
                Text("+\(allDay.count - 2) more").font(.edCaption).foregroundStyle(Tokens.muted)
            }
        }
        .padding(6)
        .background(isToday ? Tokens.accentToday.opacity(0.05) : Color.clear)
    }
}


// MARK: - Draft

/// A block being made on the grid (#687 round 3): while the pointer drags,
/// then while it is being named.
struct PlannerDraft: Equatable {
    var start: Date
    var end: Date
    /// False while dragging; true once released and waiting for a title.
    var isNaming: Bool
}

/// What a day column needs to draw and drive the draft.
struct PlannerDraftHandlers {
    var draft: PlannerDraft?
    var onChange: (Date, Date) -> Void
    var onCommit: (Date, Date) -> Void
    /// Mac: the quick-create popover anchored to the draft tile.
    var popoverPresented: Binding<Bool>
    var quickCreate: () -> AnyView
    /// A Dexter tile's bottom edge was dragged to a new end (#687 fix).
    var onResize: (PlannerItem, Date) -> Void = { _, _ in }
    /// A Dexter tile was picked up and moved to a new start and end (#693).
    var onMove: (PlannerItem, Date, Date) -> Void = { _, _, _ in }
    /// A tile was just lifted (#693).
    var onMoveBegin: () -> Void = {}
    /// iPhone (#693): the length an All Day task takes on the grid. Nil keeps
    /// the All Day row's pills as plain buttons.
    var allDayTaskMinutes: ((PlannerItem) -> Int)? = nil
    /// iPhone (#693): an All Day task was dropped on a slot.
    var onDropAllDayTask: (PlannerItem, PlannerTaskDragCoordinator.Target) -> Void = { _, _ in }
}

/// The translucent draft tile, with its live time range.
struct PlannerDraftTile: View {
    let draft: PlannerDraft
    var height: CGFloat

    var body: some View {
        let c = PlannerStyle.color(.manual)
        VStack(alignment: .leading, spacing: 1) {
            Text(PlannerStyle.range(draft.start, draft.end))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            if height >= PlannerGridMetrics.twoLineHeight {
                Text(PlannerFormat.duration(PlannerEngine.minutes(from: draft.start, to: draft.end)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Tokens.inkSoft)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, height < 26 ? 1 : 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(c.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(c.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New block, \(PlannerStyle.range(draft.start, draft.end))")
    }
}

/// Name the draft (#687 round 3): Mac popover content and iPhone bottom card.
/// Return or Save writes a manual block; Esc or Cancel discards it.
struct PlannerQuickCreate: View {
    let draft: PlannerDraft
    @Binding var title: String
    let onSave: () -> Void
    let onCancel: () -> Void
    let onMoreOptions: () -> Void
    let onPlaceTask: () -> Void

    @FocusState private var focused: Bool

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(PlannerStyle.shortDayFormatter.string(from: draft.start)) · \(PlannerStyle.range(draft.start, draft.end))")
                    .font(.edCaption.weight(.semibold))
                    .foregroundStyle(Tokens.muted)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.muted)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Discard")
            }
            HStack(spacing: 8) {
                TextField("Add a title", text: $title)
                    .font(.edBody)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if canSave { onSave() } }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .accessibilityIdentifier("planner.quickcreate.title")
                Button("Save", action: onSave)
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 14) {
                Button("More options", action: onMoreOptions)
                Button("Place a task here", action: onPlaceTask)
            }
            .buttonStyle(.plain)
            .font(.edFootnote)
            .foregroundStyle(Tokens.accentTasks)
        }
        .padding(12)
        #if os(macOS)
        .frame(width: 320)
        .onExitCommand(perform: onCancel)
        #endif
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
