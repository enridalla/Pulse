import SwiftUI

@main
@MainActor
struct PulseApp: App {
    @State private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appViewModel)
        }
    }
}
