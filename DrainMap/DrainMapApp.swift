import SwiftUI

@main
struct DrainMapApp: App {
    @StateObject private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
