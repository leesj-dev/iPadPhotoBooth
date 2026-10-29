import SwiftUI

@main struct PhotoBoothApp: App {
    @State private var model = BoothModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BoothView(model: model)
                .preferredColorScheme(.dark)
                .task { await model.discover() }
                .onChange(of: scenePhase) { _, phase in
                    model.activityChanged(active: phase == .active)
                }
        }
    }
}
