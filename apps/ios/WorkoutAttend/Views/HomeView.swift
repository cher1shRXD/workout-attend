import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false
    @State private var alert: (title: String, message: String)?
    @State private var confirmLogout = false

    private var monitor: GymMonitor { .shared }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.loadError {
                    Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red) }
                }
                todaySection
                checkinSection
                autoSection
                if let history = model.history {
                    Section("최근 2주") {
                        HistoryGrid(history: history, meID: model.me?.id)
                            .padding(.vertical, 4)
                    }
                }
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
                        Text(String(m.name.prefix(1)))
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(m.checkedInAt == nil ? Color.gray.opacity(0.4) : .green, in: .circle)
                        Text(m.name).font(.body.weight(.semibold))
                        if m.id == model.me?.id { Text("나").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let at = m.checkedInAt {
                            Label(Format.time(at), systemImage: "checkmark")
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
            if let today = model.today { Text(Format.day(today.date).label) }
        }
    }

    // MARK: 출석 버튼

    private var checkinSection: some View {
        Section {
            Button(action: checkin) {
                HStack {
                    Spacer()
                    if checking {
                        ProgressView().tint(.white)
                    } else if let at = model.myTodayCheckin {
                        Text("오늘 출석 완료 · \(Format.time(at))").bold()
                    } else {
                        Text("지금 출석 체크").bold()
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.myTodayCheckin == nil ? .accentColor : .green)
            .disabled(checking || model.myTodayCheckin != nil)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            if let t = model.today {
                Text("아침 \(t.window.startHour)시~\(t.window.endHour)시 · \(t.gym.name) 반경 \(Int(t.gym.radiusMeters))m 안에서 인정")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func checkin() {
        switch monitor.autoStatus {
        case .notDetermined, .off:
            monitor.requestPermission()
            if monitor.autoStatus == .off {
                alert = ("위치 권한 필요", "설정에서 헬스 출첵의 위치 권한을 허용해주세요.")
            }
            return
        default: break
        }
        checking = true
        Task {
            defer { checking = false }
            do {
                let res = try await model.checkinNow()
                alert = res.alreadyCheckedIn
                    ? ("이미 출석했어요", "\(Format.time(res.checkedInAt)) 출석")
                    : ("출석 완료 💪", "\(Format.time(res.checkedInAt)) 출석 · 친구들에게 알렸어요")
            } catch {
                alert = ("출석 실패", error.localizedDescription)
            }
        }
    }

    // MARK: 자동 출석

    private var autoSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("자동 출석").font(.headline)
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
        case .on: "헬스장에 도착하면 앱을 안 열어도 출석돼요."
        case .whenInUseOnly: "지금은 앱을 열 때만 자동 출석돼요. 위치를 \"항상\"으로 바꾸면 완전 자동."
        case .notDetermined, .off: "위치 권한을 \"항상\" 허용하면 도착 시 자동으로 출석돼요."
        }
    }
}

struct HistoryGrid: View {
    let history: HistoryResponse
    let meID: Int?

    private var dates: [String] { history.dates.reversed() } // 오래된 날 → 오늘

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 10) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(dates, id: \.self) { d in
                    let info = Format.day(d)
                    Text("\(info.day)")
                        .font(.system(size: 10))
                        .foregroundStyle(info.weekday == "일" || info.weekday == "토" ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(history.members) { m in
                GridRow {
                    HStack(spacing: 4) {
                        Text(m.name).fontWeight(m.id == meID ? .bold : .regular).lineLimit(1)
                        Text("\(dates.filter { m.attended[$0] != nil }.count)").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .frame(width: 72, alignment: .leading)
                    ForEach(dates, id: \.self) { d in
                        Circle()
                            .fill(m.attended[d] != nil ? Color.green : Color.gray.opacity(0.2))
                            .frame(width: 12, height: 12)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
