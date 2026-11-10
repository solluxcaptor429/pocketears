import SwiftUI

@main
struct PocketEarsApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.didBecomeActive() }
        }
    }
}
