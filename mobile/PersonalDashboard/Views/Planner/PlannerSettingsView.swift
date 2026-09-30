import SwiftUI

/// The Planner's settings (#687): the workday, and per calendar whether it is
/// shown and whether it counts as Work or Personal. Deliberately small.
struct PlannerSettingsView: View {
    @State private var calendars = PlannerCalendarService.shared
    @AppStorage(PlannerSettings.Key.workdayStartMinute) private var startMinute: Int = PlannerSettings.defaultStartMinute
    @AppStorage(PlannerSettings.Key.workdayLengthMinutes) private var lengthMinutes: Int = PlannerSettings.defaultLengthMinutes

    private var startBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(startMinute * 60)) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                startMinute = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            }
        )
    }

    var body: some View {
        PlannerSheetScaffold(title: "Planner settings") {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    workday
                    calendarList
                }
                .padding(.bottom, Space.lg)
            }
        }
        .task { await calendars.requestAccessIfNeeded() }
    }

    private var workday: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Workday").eyebrow()
            VStack(spacing: 0) {
                HStack {
                    Text("Starts").font(.edBody).foregroundStyle(Tokens.ink)
                    Spacer()
                    DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                Rectangle().fill(Tokens.divider).frame(height: 0.5)
                Stepper(value: $lengthMinutes, in: 60...(16 * 60), step: 30) {
                    HStack {
                        Text("Length").font(.edBody).foregroundStyle(Tokens.ink)
                        Spacer()
                        Text(PlannerFormat.duration(lengthMinutes)).font(.edBodyMedium).foregroundStyle(Tokens.ink)
                    }
                }
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            }
            .plannerCard()
            Text("The meter measures booked time against this window, Monday to Friday.")
                .font(.edCaption).foregroundStyle(Tokens.muted)
        }
    }

    @ViewBuilder
    private var calendarList: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Calendars").eyebrow()
            switch calendars.access {
            case .granted:
                if calendars.calendars.isEmpty {
                    Text("No calendars found. Add an account in the Calendar app.")
                        .font(.edFootnote).foregroundStyle(Tokens.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(calendars.calendars.enumerated()), id: \.element.id) { index, cal in
                            if index > 0 { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
                            calendarRow(cal)
                        }
                    }
                    .plannerCard()
                    Text("Dexter only reads these calendars. It never adds or changes an event.")
                        .font(.edCaption).foregroundStyle(Tokens.muted)
                }
            default:
                PlannerAccessCard(access: calendars.access, isRequesting: calendars.isRequesting, promptDidNotAppear: calendars.promptDidNotAppear) {
                    Task { await calendars.requestAccessFromButton() }
                }
            }
        }
    }

    private func calendarRow(_ cal: PlannerCalendar) -> some View {
        HStack(spacing: Space.sm) {
            Toggle("", isOn: Binding(
                get: { cal.isShown },
                set: { calendars.setShown($0, for: cal.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(PlannerStyle.color(cal.tag))
            .accessibilityLabel("Show \(cal.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(cal.title).font(.edBody).foregroundStyle(Tokens.ink).lineLimit(1)
                if !cal.accountTitle.isEmpty {
                    Text(cal.accountTitle).font(.edCaption).foregroundStyle(Tokens.muted).lineLimit(1)
                }
            }
            Spacer(minLength: Space.sm)
            Picker("", selection: Binding(
                get: { cal.tag },
                set: { calendars.setTag($0, for: cal.id) }
            )) {
                Text("Work").tag(PlannerSource.work)
                Text("Personal").tag(PlannerSource.personal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel("\(cal.title) counts as")
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .opacity(cal.isShown ? 1 : 0.6)
    }
}

/// What the Planner shows when it cannot read calendars (#687).
struct PlannerAccessCard: View {
    let access: PlannerCalendarService.Access
    var isRequesting: Bool = false
    /// The system refused without showing its prompt (#687 round 2).
    var promptDidNotAppear: Bool = false
    let onRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tokens.inkSoft)
                Text(title).font(.edHeading).foregroundStyle(Tokens.ink)
            }
            Text(message).font(.edFootnote).foregroundStyle(Tokens.inkSoft)
            if promptDidNotAppear {
                Text("The system did not show its permission prompt. In System Settings, open Privacy & Security > Calendars, turn on Dexter, then come back.")
                    .font(.edFootnote.weight(.medium))
                    .foregroundStyle(Tokens.danger)
            }
            HStack(spacing: Space.sm) {
                if access == .notDetermined && promptDidNotAppear {
                    Button("Allow calendar access", action: onRequest)
                        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                        .disabled(isRequesting)
                    Button("Open Settings") { PlannerCalendarService.openSystemSettings() }
                        .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                } else if access == .notDetermined {
                    Button(isRequesting ? "Asking…" : "Allow calendar access", action: onRequest)
                        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                        .disabled(isRequesting)
                } else if access != .restricted {
                    Button("Open Settings") { PlannerCalendarService.openSystemSettings() }
                        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plannerCard()
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch access {
        case .notDetermined: return "Show your calendars here"
        case .restricted:    return "Calendar access is restricted"
        case .writeOnly:     return "Dexter cannot read your calendars"
        default:             return "Calendar access is off"
        }
    }

    private var message: String {
        switch access {
        case .notDetermined:
            return "Dexter reads the calendars in Apple Calendar, work and personal, so meetings sit beside your tasks. It never changes an event."
        case .restricted:
            return "A device policy blocks calendar access. Tasks and blocks still show here."
        case .writeOnly:
            return "Access is set to add events only. Choose Full Access in Settings so Dexter can read your meetings. Tasks and blocks still show here."
        default:
            return "Turn on Full Access for Dexter in Settings to see your meetings beside your tasks. Tasks and blocks still show here."
        }
    }
}
