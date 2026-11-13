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
            Toggle("Enable IPv6 (when the phone's network provides it)", isOn: Binding(
                get: { model.status.options.enableIPv6 }, set: controller.setEnableIPv6))
            if model.driverState == .activated {
                Button("Uninstall Network Driver", action: controller.uninstallDriver)
            }
            Text("Changes to routing and DNS apply to the next connection. With the network driver, macOS manages routing, DNS and IPv6 itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}
