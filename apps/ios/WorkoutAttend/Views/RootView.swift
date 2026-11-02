import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
            case .loggedOut:
                JoinView()
            case .loggedIn:
                HomeView()
            }
        }
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.me != nil {
                Task { await model.onForeground() }
            }
        }
    }
}
