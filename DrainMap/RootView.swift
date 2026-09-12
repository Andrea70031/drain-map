import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Scansione", systemImage: "viewfinder") }

            HistoryView()
                .tabItem { Label("Rilievi", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .tint(.cyan)
    }
}
