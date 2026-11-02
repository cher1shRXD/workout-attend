import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var alert: (title: String, message: String)?
    @State private var confirmLogout = false
    @State private var selectedDay: SelectedDay?

    private var monitor: GymMonitor { .shared }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.loadError {
                    Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red) }
                }
                WorkoutSection(alert: $alert)
                Section {
                    CalendarView(selectedDay: $selectedDay)
                }
                todaySection
                autoSection
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("로그아웃", role: .destructive) { confirmLogout = true }
                    } label: {
                        Label(model.me?.name ?? "", systemImage: "person.crop.circle")
                    }
                }
            }
            .refreshable { await model.refresh() }
            #if DEBUG
            // 시뮬레이터 확인용: -debugOpenDay 2026-11-01
            .task {
                if let d = UserDefaults.standard.string(forKey: "debugOpenDay") {
                    try? await Task.sleep(for: .seconds(2))
                    selectedDay = SelectedDay(id: d)
                }
            }
            #endif
            .sheet(item: $selectedDay) { day in
                DaySheet(date: day.id)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog("로그아웃할까요?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("로그아웃", role: .destructive) { Task { await model.logout() } }
            }
            .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("확인") {}
            } message: {
                Text(alert?.message ?? "")
            }
        }
    }

    private var title: String {
        guard let today = model.today else { return "헬스 출첵" }
        let done = today.members.filter { $0.checkedInAt != nil }.count
        return "오늘 \(done)/\(today.members.count)명 출석"
    }

    // MARK: 오늘 현황

    private var todaySection: some View {
        Section {
            if let today = model.today {
                ForEach(today.members) { m in
                    HStack(spacing: 12) {
                        MemberAvatar(name: m.name, color: m.activeSince != nil ? .orange : m.visits > 0 ? .green : Color.gray.opacity(0.4))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(m.name).font(.body.weight(.semibold))
                                if m.id == model.me?.id { Text("나").font(.caption).foregroundStyle(.secondary) }
                            }
                            if let at = m.checkedInAt {
                                Text("출석 \(Format.time(at))" + (m.visits > 1 ? " · \(m.visits)번 입실" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if m.activeSince != nil {
                            Label("운동 중", systemImage: "figure.strengthtraining.traditional")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.orange.opacity(0.15), in: .capsule)
                        } else if m.visits > 0 {
                            Label(Format.duration(seconds: m.seconds), systemImage: "checkmark")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.green.opacity(0.15), in: .capsule)
                        } else {
                            Text("아직").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else if model.loadError == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            if let today = model.today { Text("오늘 출석 · \(Format.day(today.date).label)") }
        } footer: {
            if let t = model.today {
                Text("\(t.gym.name) 반경 \(Int(t.gym.radiusMeters))m 안에 들어가면 출석과 함께 운동이 시작되고, 나오면 끝나요. 하루에 여러 번 가도 모두 기록돼요.")
            }
        }
    }

    // MARK: 자동 기록

    private var autoSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("자동 기록").font(.headline)
                    Text(autoDescription).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if monitor.autoStatus == .on {
                    Text("ON").bold().foregroundStyle(.green)
                } else {
                    Button("켜기") { monitor.requestPermission() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var autoDescription: String {
        switch monitor.autoStatus {
        case .on: "헬스장에 들어가면 출석·운동 시작이, 나오면 운동 종료가 자동으로 기록돼요."
        case .whenInUseOnly: "위치를 \"항상\"으로 바꾸면 앱을 안 열어도 입실·퇴실이 자동으로 기록돼요."
        case .notDetermined, .off: "위치 권한을 \"항상\" 허용하면 입실·퇴실이 자동으로 기록돼요."
        }
    }
}

// MARK: - 운동 시작/종료

private struct WorkoutSection: View {
    @Environment(AppModel.self) private var model
    @Binding var alert: (title: String, message: String)?
    @State private var busy = false
    @State private var confirmEnd = false

    var body: some View {
        Section {
            VStack(spacing: 14) {
                if let since = model.myActiveSince, let start = Format.date(since) {
                    VStack(spacing: 4) {
                        Label("운동 중", systemImage: "figure.strengthtraining.traditional")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Format.clock(since: start, now: ctx.date))
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        Text("\(Format.time(since)) 입실").font(.footnote).foregroundStyle(.secondary)
                    }
                    button(title: "운동 종료", systemImage: "stop.fill", tint: .red) { confirmEnd = true }
                } else {
                    VStack(spacing: 4) {
                        Text("오늘도 운동하러 가볼까요?").font(.headline)
                        Text("헬스장에 들어가면 출석과 함께 자동으로 시작돼요").font(.footnote).foregroundStyle(.secondary)
                    }
                    button(title: "운동 시작", systemImage: "play.fill", tint: .accentColor, action: start)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .confirmationDialog("운동을 종료할까요?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("운동 종료", role: .destructive, action: end)
        }
    }

    private func button(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(.white) } else { Label(title, systemImage: systemImage).bold().foregroundStyle(.white) }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .disabled(busy)
    }

    private func start() {
        busy = true
        Task {
            defer { busy = false }
            let monitor = GymMonitor.shared
            guard monitor.autoStatus == .on || monitor.autoStatus == .whenInUseOnly else {
                monitor.requestPermission()
                if monitor.autoStatus == .off {
                    alert = ("위치 권한 필요", "헬스장에 있는지 확인하려면 위치 권한이 필요해요. 설정에서 허용해주세요.")
                }
                return
            }
            do { try await model.startWorkout() } catch { alert = ("운동 시작 실패", error.localizedDescription) }
        }
    }

    private func end() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if let s = try await model.endWorkout() {
                    alert = ("운동 종료 👋", "\(Format.duration(from: s.startedAt, to: s.endedAt)) 운동했어요.")
                }
            } catch {
                alert = ("운동 종료 실패", error.localizedDescription)
            }
        }
    }
}

// MARK: - 달력

struct SelectedDay: Identifiable {
    let id: String // "YYYY-MM-DD"
}

/// 멤버별 고정 색 (id 순서대로)
func memberColor(_ id: Int, in members: [Member]) -> Color {
    let palette: [Color] = [.orange, .blue, .purple, .pink, .teal]
    let index = members.firstIndex { $0.id == id } ?? 0
    return palette[index % palette.count]
}

private struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedDay: SelectedDay?

    /// 7칸씩 끊은 주 단위 행 (마지막 주는 빈칸으로 채움)
    private func weeks(_ month: String) -> [[String?]] {
        var cells = Format.calendarCells(month)
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    var body: some View {
        let month = model.calendarMonth
        let todayYMD = Format.ymd(Date())
        let cal = model.calendar?.month == month ? model.calendar : nil
        let members = cal?.members ?? []

        VStack(spacing: 12) {
            HStack {
                Button { Task { await model.showMonth(offset: -1) } } label: {
                    Image(systemName: "chevron.left").padding(8)
                }
                Spacer()
                Text(Format.monthTitle(month)).font(.headline)
                Spacer()
                Button { Task { await model.showMonth(offset: 1) } } label: {
                    Image(systemName: "chevron.right").padding(8)
                }
                .disabled(month >= Format.currentMonth())
            }
            .buttonStyle(.borderless)

            // List 안에서는 LazyVGrid 가 레이아웃 루프를 일으켜서 일반 HStack 행으로 그린다
            HStack(spacing: 0) {
                ForEach(Array(Format.weekdays.enumerated()), id: \.offset) { i, wd in
                    Text(wd)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(i == 0 ? .red : i == 6 ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 6) {
                ForEach(Array(weeks(month).enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, ymd in
                            if let ymd {
                                DayCell(
                                    day: Format.day(ymd).day,
                                    isToday: ymd == todayYMD,
                                    isFuture: ymd > todayYMD,
                                    dots: (cal?.days[ymd] ?? [])
                                        .filter { $0.seconds > 0 || $0.attendedAt != nil }
                                        .map { memberColor($0.memberId, in: members) }
                                )
                                .onTapGesture { if ymd <= todayYMD { selectedDay = SelectedDay(id: ymd) } }
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                    }
                }
            }

            if !members.isEmpty {
                HStack(spacing: 12) {
                    ForEach(members) { m in
                        HStack(spacing: 4) {
                            Circle().fill(memberColor(m.id, in: members)).frame(width: 8, height: 8)
                            Text(m.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DayCell: View {
    let day: Int
    let isToday: Bool
    let isFuture: Bool
    let dots: [Color]

    var body: some View {
        VStack(spacing: 3) {
            Text("\(day)")
                .font(.callout.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : isFuture ? Color.secondary.opacity(0.5) : Color.primary)
                .frame(width: 30, height: 30)
                .background(isToday ? Color.accentColor : .clear, in: .circle)
            HStack(spacing: 2) {
                ForEach(Array(dots.prefix(5).enumerated()), id: \.offset) { _, c in
                    Circle().fill(c).frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(.rect)
    }
}

// MARK: - 날짜 바텀시트

private struct DaySheet: View {
    @Environment(AppModel.self) private var model
    let date: String

    var body: some View {
        let cal = model.calendar
        let members = cal?.members ?? []
        let entries = cal?.days[date] ?? []

        NavigationStack {
            List {
                ForEach(members) { m in
                    let e = entries.first { $0.memberId == m.id }
                    Section {
                        HStack(spacing: 12) {
                            MemberAvatar(name: m.name, color: memberColor(m.id, in: members))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.headline)
                                if let at = e?.attendedAt {
                                    Text("출석 \(Format.time(at))").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            if let e, !e.sessions.isEmpty {
                                Text(Format.duration(seconds: totalSeconds(e)))
                                    .font(.title3.bold())
                                    .monospacedDigit()
                            } else {
                                Text("기록 없음").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array((e?.sessions ?? []).enumerated()), id: \.offset) { _, s in
                            HStack {
                                Text("\(Format.time(s.startedAt)) – \(s.endedAt.map(Format.time) ?? "진행 중")")
                                Spacer()
                                Text(Format.duration(from: s.startedAt, to: s.endedAt))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle(Format.day(date).label)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 진행 중인 운동은 지금까지로 계산
    private func totalSeconds(_ e: CalendarEntry) -> Int {
        e.sessions.reduce(0) { sum, s in
            guard let start = Format.date(s.startedAt) else { return sum }
            let end = s.endedAt.flatMap(Format.date) ?? Date()
            return sum + max(0, Int(end.timeIntervalSince(start)))
        }
    }
}

struct MemberAvatar: View {
    let name: String
    let color: Color

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(color, in: .circle)
    }
}
