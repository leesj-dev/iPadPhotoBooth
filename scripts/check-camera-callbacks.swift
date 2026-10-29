import Foundation
import ImageCaptureCore

/// Reproduces the device's background PTP event delivery without requiring USB hardware.
@main struct CameraCallbackCheck {
    @MainActor static func main() async {
        let transport = USBTransport()
        let received: String = await withCheckedContinuation { continuation in
            transport.onLog = { line in
                MainActor.preconditionIsolated()
                continuation.resume(returning: line)
            }
            Task.detached {
                let camera = ICCameraDevice()
                let delegate: any ICCameraDeviceDelegate = transport
                delegate.cameraDevice(camera, didReceivePTPEvent: Data(repeating: 0, count: 12))
            }
        }
        precondition(received == "PTP event · 12 bytes")
        print("PASS background ImageCaptureCore event reaches MainActor without an executor trap")
        transport.onLog = nil
        var changes = 0
        transport.onChange = { MainActor.preconditionIsolated(); changes += 1 }
        let browser = ICDeviceBrowser()
        let attached = ICCameraDevice()
        transport.deviceBrowser(browser, didAdd: attached, moreComing: false)
        guard let originalID = transport.connectionID else { preconditionFailure("Missing attachment ID") }
        precondition(changes == 1)
        transport.deviceBrowser(browser, didAdd: attached, moreComing: false)
        precondition(transport.connectionID == originalID && changes == 1)
        transport.didRemove(attached)
        precondition(transport.connectionID == nil && changes == 2)
        transport.deviceBrowser(browser, didAdd: attached, moreComing: false)
        precondition(transport.connectionID != nil && transport.connectionID != originalID && changes == 3)
        print("PASS discovery/removal callbacks keep a unique identity for each USB attachment")
    }
}
