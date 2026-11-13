import SwiftUI
import TetheringCore

struct SettingsView: View {
    let controller: TetheringController
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Connect automatically when a phone is plugged in", isOn: Binding(
                get: { model.status.autoConnect }, set: controller.setAutoConnect))
            Toggle("Route all internet traffic through the phone", isOn: Binding(
                get: { model.status.options.routeAllTraffic }, set: controller.setRouteAllTraffic))
            Toggle("Use the phone's DNS servers", isOn: Binding(
                get: { model.status.options.usePhoneDNS }, set: controller.setUsePhoneDNS))
            Text("Changes to routing and DNS apply to the next connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}
