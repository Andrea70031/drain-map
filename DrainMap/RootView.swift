import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Scansione", systemImage: "viewfinder") }

            SettingsView()
                .tabItem { Label("Manuale", systemImage: "book.closed") }

            HistoryView()
                .tabItem { Label("Libreria", systemImage: "square.stack.3d.up") }
        }
        .tint(.cyan)
    }
}
