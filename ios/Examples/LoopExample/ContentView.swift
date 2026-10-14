import SwiftUI
import LoopCore
import LoopFeedback

struct ContentView: View {
    @State private var presentingLoop = false

    var body: some View {
        NavigationStack {
            List {
                Section("App") {
                    Text("Welcome to your demo host app.")
                        .foregroundStyle(.secondary)
                }

                Section("Help") {
                    Button {
                        presentingLoop = true
                    } label: {
                        Label("Report a bug or request a feature", systemImage: "ladybug")
                    }

                    Text("Reporter id: \(Loop.reporterId)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $presentingLoop) {
                LoopFeedbackView()
            }
        }
    }
}
