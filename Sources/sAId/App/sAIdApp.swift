import SwiftUI

@main
struct sAIdApp: App {
    var body: some Scene {
        MenuBarExtra("sAId", systemImage: "mic") {
            Text("sAId — skeleton")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
