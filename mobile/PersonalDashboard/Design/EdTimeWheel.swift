import SwiftUI

#if os(macOS)
/// The Mac's time wheel (#675): hour, minute and AM/PM columns that scroll and
/// snap to a highlighted centre row, the shape the iPhone's wheel has.
///
/// macOS has no `.wheel` date picker style. The system offers a stepper field
/// and a graphical clock face, so the Mac panel used to show `8:00 AM` with a
/// pair of arrows pinned to the left edge while the phone showed a centred
/// wheel. This draws the wheel instead, so the same field reads the same on
/// both.
///
/// Each column is a snapping `ScrollView`, so a trackpad, a mouse wheel and a
/// click on a row all move it. The columns follow the system 12/24-hour
/// setting; in 24-hour mode the AM/PM column is not drawn.
struct EdTimeWheel: View {

    @Binding var date: Date
    var tint: Color = Tokens.accentTasks
    var accessibilityLabel: String = "Time"

    @State private var hour: Int?
    @State private var minute: Int?
    @State private var period: Int?

    private let rowHeight: CGFloat = 28
    private let visibleRows = 5

    private var calendar: Calendar { Calendar.current }

    /// Whether the system shows a 12-hour clock. Read off the formatter
    /// template, which is what the user's region and the 24-hour switch in
    /// System Settings both feed.
    private var uses12Hour: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a"
        return format.contains("a")
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            column(
                values: uses12Hour ? Array(1...12) : Array(0...23),
                selection: $hour,
                width: 48,
                name: "Hour"
            ) { uses12Hour ? "\($0)" : String(format: "%02d", $0) }
            Text(":")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Tokens.muted)
            column(values: Array(0...59), selection: $minute, width: 48, name: "Minute") {
                String(format: "%02d", $0)
            }
            if uses12Hour {
                column(values: [0, 1], selection: $period, width: 52, name: "AM or PM") {
                    $0 == 0 ? calendar.amSymbol : calendar.pmSymbol
                }
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: rowHeight * CGFloat(visibleRows))
        // The band sits behind the columns and spans them, as the phone's does.
        .background {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Tokens.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .stroke(Tokens.border, lineWidth: 0.5)
                )
                .frame(height: rowHeight)
        }
        // Rows fade out towards the edges, so the wheel reads as a drum and
        // not as a clipped list.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.3),
                    .init(color: .black, location: 0.7),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear(perform: load)
        .onChange(of: date) { _, _ in load() }
        .onChange(of: hour) { _, _ in commit() }
        .onChange(of: minute) { _, _ in commit() }
        .onChange(of: period) { _, _ in commit() }
    }

    // MARK: - One column

    private func column(
        values: [Int],
        selection: Binding<Int?>,
        width: CGFloat,
        name: String,
        label: @escaping (Int) -> String
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(values, id: \.self) { value in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selection.wrappedValue = value
                        }
                    } label: {
                        // Light and small on purpose: the wheel sits inside a
                        // form card, and at the phone's size and weight it
                        // outshouted every label around it.
                        Text(label(value))
                            .font(.system(size: 16, weight: selection.wrappedValue == value ? .regular : .light).monospacedDigit())
                            .foregroundStyle(selection.wrappedValue == value ? Tokens.ink : Tokens.mutedSoft)
                            .frame(width: width, height: rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
        }
        // Two rows of margin top and bottom, so the first and last values can
        // sit in the centre band.
        .contentMargins(.vertical, rowHeight * CGFloat(visibleRows / 2), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: selection, anchor: .center)
        .frame(width: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(selection.wrappedValue.map(label) ?? "")
        .accessibilityAdjustableAction { direction in
            guard let current = selection.wrappedValue,
                  let index = values.firstIndex(of: current) else { return }
            switch direction {
            case .increment: selection.wrappedValue = values[min(index + 1, values.count - 1)]
            case .decrement: selection.wrappedValue = values[max(index - 1, 0)]
            @unknown default: break
            }
        }
    }

    // MARK: - Date ⇄ columns

    /// Columns from the date. Only writes a column that differs, so a commit
    /// that round-trips back through `date` does not move the wheel again.
    private func load() {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let h24 = comps.hour ?? 0
        let newHour = uses12Hour ? (h24 % 12 == 0 ? 12 : h24 % 12) : h24
        let newPeriod = h24 < 12 ? 0 : 1
        if hour != newHour { hour = newHour }
        if minute != comps.minute { minute = comps.minute ?? 0 }
        if uses12Hour, period != newPeriod { period = newPeriod }
    }

    /// Date from the columns, on the same day. Skipped until every column has
    /// a value, which is the case for a moment while the scroll views settle.
    private func commit() {
        guard let hour, let minute else { return }
        let h24: Int
        if uses12Hour {
            guard let period else { return }
            h24 = (hour % 12) + (period == 1 ? 12 : 0)
        } else {
            h24 = hour
        }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard comps.hour != h24 || comps.minute != minute else { return }
        if let next = calendar.date(bySettingHour: h24, minute: minute, second: 0, of: date) {
            date = next
        }
    }
}
#endif
