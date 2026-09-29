import SwiftUI

@main
struct sAIdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model, settings: delegate.model.settings, history: delegate.model.history,
                     showHistory: delegate.showHistory, showSettings: delegate.showSettings, showPermissions: delegate.showPermissions)
        } label: {
            MenuStatusLabel(model: delegate.model, settings: delegate.model.settings)
        }
    }
}
