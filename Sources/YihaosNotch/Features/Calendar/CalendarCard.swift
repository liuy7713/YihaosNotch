import SwiftUI

/// A scrollable strip of days (a week either side of today) above the agenda for
/// the selected day. Selection resets to today each time the notch opens.
///
/// There's no title row: the panel header already shows today's date, and the strip
/// shows the selected day. When another day is selected, a slim line above the agenda
/// names it and offers a way back to today.
struct CalendarCard: View {
    @Environment(CalendarService.self) private var calendar
    @Environment(AppSettings.self) private var settings
    /// nil means today.
    @State private var selection: Date?
    /// Whether the agenda is taller than its space; only then is its bottom faded.
    @State private var agendaOverflows = false

    private var selectedDay: Date { selection ?? calendar.today }
    private var isTodaySelected: Bool { selectedDay == calendar.today }

    /// Shared left inset for everything in the column, so text and colour bars line up.
    static let inset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch calendar.access {
            case .granted:
                DayStrip(days: calendar.days,
                         selection: Binding(get: { selectedDay }, set: { selection = $0 }),
                         today: calendar.today,
                         haptics: settings.hapticsEnabled,
                         dots: dotColors(for:))
                if !isTodaySelected {
                    otherDayLine
                        .transition(.opacity)
                }
                agenda
                    .id(selectedDay)
                    .transition(.opacity)
            case .notDetermined:
                prompt(message: "See your week here and join meetings in one click.",
                       button: "Connect Calendar") { calendar.requestAccess() }
            case .denied:
                prompt(message: "Calendar access is turned off for Yihao's Notch.",
                       button: "Open Privacy Settings") { calendar.openPrivacySettings() }
            }
        }
        .animation(.easeOut(duration: 0.18), value: selectedDay)
        .onAppear { calendar.start() }
    }

    // MARK: Selected-day line

    private var otherDayLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title(for: selectedDay))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Text(selectedDay.formatted(.dateTime.day().month(.abbreviated)))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 4)
            Button { selection = nil } label: {
                HStack(spacing: 2) {
                    Text("Today")
                    Image(systemName: selectedDay > calendar.today ? "arrow.uturn.left" : "arrow.uturn.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.fillStrong))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Back to today")
        }
        .padding(.horizontal, Self.inset)
        .frame(height: 16)
    }

    private func title(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    /// One dot per calendar with events that day, up to three.
    private func dotColors(for day: Date) -> [Color] {
        var colors: [Color] = []
        for item in calendar.events(on: day) where !colors.contains(item.color) {
            colors.append(item.color)
            if colors.count == 3 { break }
        }
        return colors
    }

    // MARK: Agenda

    @ViewBuilder
    private var agenda: some View {
        let items = calendar.events(on: selectedDay)
        if items.isEmpty {
            Text(isTodaySelected ? "Nothing on today" : "No events")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, Self.inset)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            EventRow(item: item, day: selectedDay, now: calendar.now, isToday: isTodaySelected)
                                .id(item.id)
                        }
                    }
                    .padding(.bottom, agendaOverflows ? 10 : 0)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height > geometry.containerSize.height + 1
                } action: { _, overflows in
                    agendaOverflows = overflows
                }
                // When the list scrolls, fade the last row out rather than cutting it off
                // at the panel edge.
                .mask {
                    if agendaOverflows {
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: 0.84),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    } else {
                        Rectangle()
                    }
                }
                .onAppear {
                    // Today opens at the next event rather than ones already over.
                    guard isTodaySelected,
                          let next = items.first(where: { !$0.isAllDay && !$0.hasEnded(at: calendar.now) }),
                          next.id != items.first?.id
                    else { return }
                    proxy.scrollTo(next.id, anchor: .top)
                }
            }
        }
    }

    private func prompt(message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(button)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.fillStrong))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 4)
    }
}

// MARK: - Day strip

/// Five days in view, and the selected day always sits in the centre slot. Scrolling
/// slides the days underneath it and selects whichever lands in the middle, like a
/// picker wheel. Tapping a day slides it to the centre.
private struct DayStrip: View {
    let days: [Date]
    @Binding var selection: Date
    let today: Date
    let haptics: Bool
    let dots: (Date) -> [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let visibleDays = 5
    /// The day under the centre slot, as reported by (and used to drive) the scroll view.
    /// Starts nil and is set on appear: an initial value isn't applied to the first layout.
    @State private var centered: Date?
    /// Only scrolls the user makes may change the selection; position reports from the
    /// scroll view's own initial layout are ignored.
    @State private var userHasScrolled = false

    private var slide: Animation? { reduceMotion ? nil : .snappy(duration: 0.3) }

    var body: some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width / CGFloat(Self.visibleDays)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        Button {
                            selection = day
                        } label: {
                            DayCell(day: day, isSelected: day == selection, isToday: day == today,
                                    isPast: day < today, dots: dots(day))
                        }
                        .buttonStyle(PressableStyle())
                        .frame(width: cellWidth)
                        .id(day)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(day == selection ? .isSelected : [])
                    }
                }
                .scrollTargetLayout()
            }
            // Two cells of margin either side let the first and last day reach the centre,
            // and make snapping land each day in the middle slot.
            .contentMargins(.horizontal, cellWidth * 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centered, anchor: .center)
            .onScrollPhaseChange { _, phase in
                // Trackpad scrolls go through .interacting; a mouse wheel may only show
                // up as .decelerating. Programmatic scrolls are .animating.
                if phase == .interacting || phase == .decelerating { userHasScrolled = true }
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.14),
                                       .init(color: .black, location: 0.86),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
        }
        .frame(height: 46)
        .onAppear { centered = selection }
        // The detent tick plays only for days reached by scrolling, like a picker wheel;
        // taps and arrows move the selection without it.
        .onChange(of: centered) { _, day in
            guard userHasScrolled, let day, day != selection else { return }
            selection = day
            if haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        .onChange(of: selection) { _, day in
            guard centered != day else { return }
            withAnimation(slide) { centered = day }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let isPast: Bool
    let dots: [Color]

    var body: some View {
        VStack(spacing: 3) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(isToday ? Theme.today : Theme.tertiary)
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(numberColor)
                .frame(width: 25, height: 25)
                .background(Circle().fill(circleColor))
            HStack(spacing: 2.5) {
                ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
            .opacity(isPast ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var numberColor: Color {
        if isSelected { return isToday ? .white : .black }
        if isToday { return Theme.today }
        return isPast ? Theme.tertiary : Theme.primary
    }

    private var circleColor: Color {
        guard isSelected else { return .clear }
        return isToday ? Theme.today : Theme.primary
    }
}

// MARK: - Event row

private struct EventRow: View {
    let item: CalendarItem
    /// Start of the day this row is listed under (multi-day events appear on several).
    let day: Date
    let now: Date
    /// Countdowns and the urgent Join style only make sense for today.
    let isToday: Bool

    private var isOngoing: Bool { item.isOngoing(at: now) }
    private var hasEnded: Bool { item.hasEnded(at: now) }
    private var minutesUntilStart: Int { Int((item.start.timeIntervalSince(now) / 60).rounded(.up)) }
    private var showsCountdown: Bool { isToday && (1..<60).contains(minutesUntilStart) }
    /// The Join button becomes solid from 10 minutes before the start.
    private var joinIsUrgent: Bool { isToday && (isOngoing || (0...10).contains(minutesUntilStart)) }

    var body: some View {
        Button { item.open() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(item.color)
                    .frame(width: 3, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(isOngoing ? item.color : Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let meeting = item.meeting, !hasEnded {
                    JoinButton(provider: meeting.provider, urgent: joinIsUrgent)
                }
            }
            .padding(.horizontal, CalendarCard.inset)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .opacity(hasEnded && !item.isAllDay ? 0.42 : 1)
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(cornerRadius: 9)
        .help(item.meeting.map { "Join on \($0.provider.name)" } ?? "Open in Calendar")
    }

    private var subtitle: String {
        if item.isAllDay { return "All day" }
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let startsThisDay = item.start >= day
        let endsThisDay = item.end <= nextDay
        let start = item.start.formatted(date: .omitted, time: .shortened)
        // An end on a later day names that day, so "09:00 – Wed 17:00" can't be read as
        // a slot within this day.
        let end = endsThisDay
            ? item.end.formatted(date: .omitted, time: .shortened)
            : item.end.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        var text: String
        if isToday && isOngoing {
            text = "Now · until \(end)"
        } else if !startsThisDay {
            text = endsThisDay ? "Until \(end)" : "Continues · until \(end)"
        } else if showsCountdown {
            text = "\(start) · in \(minutesUntilStart)m"
        } else {
            text = "\(start) – \(end)"
        }
        // A plain location is useful context, but not when a countdown already fills the
        // line, and a meeting URL in the location field never is.
        if item.meeting == nil, !showsCountdown, !(isToday && isOngoing),
           let location = item.location, !location.contains("://") {
            text += " · \(location)"
        }
        return text
    }
}

/// Icon-only, so event titles keep the room; the tooltip and VoiceOver name the service.
private struct JoinButton: View {
    let provider: MeetingLink.Provider
    let urgent: Bool

    var body: some View {
        Image(systemName: "video.fill")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(urgent ? Color.black : Theme.primary)
            .frame(width: 28, height: 20)
            .background(Capsule().fill(urgent ? Theme.primary : Theme.fillStrong))
            .accessibilityLabel("Join on \(provider.name)")
    }
}
