import SwiftUI
import TetheringCore

/// Menu bar popover (the "V" in MVC). Reads the model, forwards actions to the controller.
struct MenuBarView: View {
    let controller: TetheringController
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Android USB Tethering").font(.headline)
            Divider()
            switch model.helperState {
            case .installed:
                statusSection
            case .requiresApproval:
                helperPrompt("Allow the helper in System Settings → General → Login Items.",
                             action: "Open System Settings", perform: controller.openApprovalSettings)
            case let .failed(message):
                helperPrompt("Helper installation failed: \(message)",
                             action: "Try Again", perform: controller.installHelper)
            case .notInstalled, .unknown:
                helperPrompt("A system helper is required to talk to the phone over USB.",
                             action: "Install Helper", perform: controller.installHelper)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Settings…", action: controller.openSettings)
                Spacer()
                Button("Quit", action: controller.quit)
            }
        }
        .padding()
        .frame(width: 300)
    }

    @ViewBuilder
    private var driverSection: some View {
        switch model.driverState {
        case .activated:
            Label("Network driver active", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .awaitingApproval:
            helperPrompt("Allow the network driver in System Settings → General → Login Items & Extensions → Driver Extensions.",
                         action: "Open System Settings", perform: controller.openApprovalSettings)
        case .activating:
            ProgressView("Installing network driver…").controlSize(.small)
        case .requiresApplicationsFolder:
            Text("Move the app to the Applications folder to install the network driver.")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .failed(message):
            helperPrompt("Network driver: \(message)", action: "Try Again", perform: controller.installDriver)
        case .notInstalled, .unknown:
            helperPrompt("Install the network driver to get a native Ethernet interface (recommended).",
                         action: "Install Network Driver", perform: controller.installDriver)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        driverSection
        Label(model.status.state.summary, systemImage: model.menuBarSymbol)
        if let native = model.nativeEthernet {
            Text("macOS manages \(native.interfaceName ?? "the interface") like any Ethernet adapter. See System Settings → Network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let info = model.connectionInfo {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { Text("Interface").foregroundStyle(.secondary); Text(info.interfaceName) }
                GridRow { Text("IP address").foregroundStyle(.secondary); Text(info.address.description) }
                GridRow { Text("Gateway").foregroundStyle(.secondary); Text(info.router.description) }
                if let ipv6 = info.ipv6 {
                    GridRow { Text("IPv6").foregroundStyle(.secondary); Text(ipv6.address.description) }
                }
                GridRow {
                    Text("DNS").foregroundStyle(.secondary)
                    Text((info.dnsServers.map(\.description) + (info.ipv6?.dnsServers.map(\.description) ?? []))
                        .joined(separator: "\n"))
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            Button("Disconnect", action: controller.disconnect)
        } else if model.status.state.isActive {
            ProgressView().controlSize(.small)
            Button("Cancel", action: controller.disconnect)
        } else if model.rndisDevices.isEmpty {
            Text("Connect your phone with a USB cable and turn on **USB tethering** in Android Settings → Network → Hotspot & tethering.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(model.rndisDevices) { device in
                Button("Connect \(device.name)") { controller.connect(device) }
            }
        }
        if !model.helperReachable {
            Text("Helper not responding…").font(.caption).foregroundStyle(.orange)
        }
    }

    private func helperPrompt(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform)
        }
    }
}
