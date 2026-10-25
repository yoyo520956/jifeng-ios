import SwiftUI

@main
struct JifengApp: App {
    @StateObject private var app = AppState()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
        }
    }
}
