import SwiftUI
import LoopSDK

@main
struct LoopSDKExampleApp: App {
    init() {
        // Replace this with one of your seeded keys, e.g. the value from
        //   curl http://localhost:4000/api/projects/pebble/api-key  (logged in)
        // For local dev against the Phoenix backend, point apiBase at
        // http://localhost:4000 — make sure ATS is configured below.
        LoopSDK.start(
            apiKey: "loop_pk_pebble_REPLACE_ME",
            apiBase: URL(string: "http://localhost:4000")!
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
