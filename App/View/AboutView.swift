import AppKit
import SwiftUI

/// About window: app identity, component status, author, license and links.
struct AboutView: View {
    static let windowID = "about"

    let info: AboutInfo
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text(info.name).font(.title2.weight(.semibold))
                Text("Version \(info.version) (\(info.build)) · \(info.edition)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(AboutInfo.summary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Helper").foregroundStyle(.secondary)
                    Text(model.helperVersion.map { "\($0) · running" } ?? helperText)
                }
                GridRow {
                    Text("Network driver").foregroundStyle(.secondary)
                    Text(model.driverState.summary)
                }
                GridRow {
                    Text("ADB").foregroundStyle(.secondary)
                    Text(model.adbAvailable ? "platform-tools found" : "platform-tools not installed")
                }
                GridRow {
                    Text("Author").foregroundStyle(.secondary)
                    Text(AboutInfo.author)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(spacing: 16) {
                Link("Source code", destination: AboutInfo.repositoryURL)
                Link("Apache License 2.0", destination: AboutInfo.licenseURL)
            }
            .font(.callout)

            Text(info.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 380)
    }

    private var helperText: String {
        switch model.helperState {
        case .installed: return "Installed, not responding"
        case .requiresApproval: return "Waiting for approval"
        case .notInstalled, .unknown: return "Not installed"
        case let .failed(message): return "Error: \(message)"
        }
    }
}
