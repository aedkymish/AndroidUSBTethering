import Foundation
import TetheringCore

// Privileged launchd daemon: owns the USB device, the utun interface, routes and DNS.
// Registered by the app with SMAppService and reached over XPC.
let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = service
listener.resume()
service.start()
dispatchMain()
