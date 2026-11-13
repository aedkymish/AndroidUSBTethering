import SwiftUI

@main
struct AndroidUSBTetheringApp: App {
    @StateObject private var controller = TetheringController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller, model: controller.model)
        } label: {
            MenuBarLabel(model: controller.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller, model: controller.model)
        }
    }
}

/// Menu bar icon; observes the model so it updates with the connection state.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
    }
}
