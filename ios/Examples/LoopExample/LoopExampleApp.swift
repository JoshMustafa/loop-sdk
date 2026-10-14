import SwiftUI
import LoopCore

@main
struct LoopExampleApp: App {
    init() {
        // Replace with a project key from the Loop dashboard's Setup page.
        // For local development against the Phoenix backend, pass
        // `LoopOptions(serverUrl: URL(string: "http://localhost:4000")!)`
        // and allow plain HTTP in Info.plist (see ../README.md).
        Loop.configure(apiKey: "loop_pk_pebble_REPLACE_ME")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
