import SwiftUI

struct RootView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app

        TabView(selection: $app.selectedTab) {
            HomeView(viewModel: app.home, onStart: app.presentMeasurement)
                .tabItem { Label("tab.home", systemImage: "house") }
                .tag(AppTab.home)

            HistoryView(viewModel: app.history)
                .tabItem { Label("tab.history", systemImage: "clock") }
                .tag(AppTab.history)

            TrendsView(viewModel: app.trends, onStart: app.presentMeasurement)
                .tabItem { Label("tab.trends", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.trends)

            InformationView(viewModel: app.information)
                .tabItem { Label("tab.info", systemImage: "info.circle") }
                .tag(AppTab.info)
        }
        .tint(AppColor.brand)
        .toolbarBackground(AppColor.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(\.font, AppTypography.body)
        .sheet(isPresented: $app.isMeasuring, onDismiss: app.cancelMeasurement) {
            MeasurementFlowView(
                viewModel: app.measurement,
                onFinish: app.finishMeasurement,
                onCancel: app.cancelMeasurement
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .task { app.load() }
        .onChange(of: scenePhase) { _, phase in
            app.handleScenePhase(phase)
        }
    }
}
