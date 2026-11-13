import Darwin
import Foundation
import os
import Security

/// Decides whether an XPC client may drive the privileged helper.
///
/// Releases are ad-hoc signed (no Apple Developer ID), so a certificate-based requirement such as
/// `anchor apple generic` cannot be used. Instead the client must be *exactly* the app this helper
/// belongs to:
/// 1. its running code has a valid signature,
/// 2. it was loaded from the expected app bundle path, and
/// 3. its code directory hash (cdhash) equals that of the app bundle on disk.
///
/// The client is identified by its XPC audit token (falling back to its PID), so the check is
/// about the process that actually sent the message.
struct ClientValidator {
    let appBundleURL: URL
    private let log = Logger(subsystem: HelperConstants.machServiceName, category: "client-validation")

    /// - Parameter appBundleURL: the app allowed to connect. Defaults to the bundle that contains this
    ///   helper (`<App>.app/Contents/MacOS/<helper>`), or the `--app <path>` launch argument used when the
    ///   helper was installed manually outside the bundle.
    init(appBundleURL: URL? = nil, arguments: [String] = CommandLine.arguments) {
        if let appBundleURL {
            self.appBundleURL = appBundleURL
        } else if let index = arguments.firstIndex(of: "--app"), index + 1 < arguments.count {
            self.appBundleURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            self.appBundleURL = Self.ownExecutableURL()
                .deletingLastPathComponent() // MacOS
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // <App>.app
        }
    }

    func isValid(_ connection: NSXPCConnection) -> Bool {
        guard let code = guestCode(for: connection) else {
            return reject("could not identify the client process")
        }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return reject("client signature is invalid")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return reject("no static code for client")
        }
        var clientURL: CFURL?
        guard SecCodeCopyPath(staticCode, [], &clientURL) == errSecSuccess,
              let clientPath = (clientURL as URL?).map(Self.canonicalPath),
              clientPath == Self.canonicalPath(appBundleURL) else {
            return reject("client is not \(appBundleURL.path)")
        }
        var diskCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appBundleURL as CFURL, [], &diskCode) == errSecSuccess, let diskCode,
              let clientHash = Self.cdhash(of: staticCode), let diskHash = Self.cdhash(of: diskCode),
              clientHash == diskHash else {
            return reject("client code does not match the installed app")
        }
        return true
    }

    // MARK: Private

    private func reject(_ reason: String) -> Bool {
        log.error("Rejected XPC client: \(reason, privacy: .public)")
        return false
    }

    private func guestCode(for connection: NSXPCConnection) -> SecCode? {
        var attributes: [String: Any] = [kSecGuestAttributePid as String: connection.processIdentifier]
        // The audit token is not public API on NSXPCConnection but is widely used through KVC; it is
        // immune to PID reuse. Fall back to the PID if it is unavailable.
        if let value = connection.value(forKey: "auditToken") as? NSValue {
            var token = audit_token_t()
            value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
            attributes = [kSecGuestAttributeAudit as String: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)]
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func cdhash(of code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func ownExecutableURL() -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        if length > 0 { return URL(fileURLWithPath: String(cString: buffer)) }
        return URL(fileURLWithPath: CommandLine.arguments[0])
    }
}
