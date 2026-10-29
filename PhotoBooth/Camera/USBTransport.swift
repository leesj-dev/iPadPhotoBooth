import Foundation
import ImageCaptureCore
import CoreGraphics
import BoothCore

/// Session callbacks are on the main thread; PTP events can arrive on ICDeviceOperationQueue.
/// Each timeout invalidates the session. Late callbacks can never complete a newer request.
@MainActor final class USBTransport: NSObject, PTPTransport {
    var onChange: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var name = "카메라를 연결하세요"
    private(set) var isOpen = false
    private(set) var isBrowsing = false
    private(set) var connectionID: UUID?
    var canAutoConnect: Bool {
        guard let camera else { return false }
        return !needsReplug && camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
    }
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var opener: CheckedContinuation<Void, any Error>?
    private var pending: CheckedContinuation<Data, any Error>?
    private var pendingID: UUID?
    private var timer: Task<Void, Never>?
    private var openID: UUID?
    private var needsReplug = false

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
    }

    func start() async throws {
        guard !isBrowsing else { return }
        #if targetEnvironment(simulator)
        throw BoothError.unavailable("시뮬레이터에서는 데모만 사용할 수 있습니다.")
        #else
        #if os(iOS)
        let control = await browser.requestControlAuthorization()
        guard control == .authorized else {
            throw BoothError.unavailable("카메라 제어 권한이 필요합니다. iPad 설정에서 허용하세요.")
        }
        let contents = await browser.requestContentsAuthorization()
        guard contents == .authorized else {
            throw BoothError.unavailable("촬영 이미지 수신을 위한 카메라 콘텐츠 접근 권한이 필요합니다.")
        }
        #endif
        if !isBrowsing { browser.start(); isBrowsing = true }
        onChange?()
        #endif
    }

    func open() async throws {
        guard let camera else { throw BoothError.unavailable("A7 IV를 USB-C 데이터 케이블로 연결하세요.") }
        guard !needsReplug else { throw BoothError.unavailable("USB 세션이 불명확합니다. 케이블을 물리적으로 분리 후 다시 연결하세요.") }
        guard opener == nil, pending == nil else { throw BoothError.unavailable("USB 작업 중입니다.") }
        if isOpen { return }
        guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else {
            throw BoothError.unavailable("이 USB 연결은 PTP 명령을 지원하지 않습니다. Remote Shooting 모드를 확인하세요.")
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                opener = continuation; openID = id
                armTimeout(id: id, seconds: 15)
                camera.delegate = self
                camera.requestOpenSession()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func send(_ opcode: UInt16, parameters: [UInt32], outData: Data?) async throws -> Data {
        try Task.checkCancellation()
        guard let camera, isOpen else { throw BoothError.unavailable("USB 세션이 닫혔습니다. 케이블을 다시 연결하세요.") }
        guard pending == nil, opener == nil else { throw BoothError.unavailable("동시 PTP 명령을 거절했습니다.") }
        let id = UUID()
        // The inspected ImageCaptureCore iOS implementation uses transaction 0; ICC owns the PTP session.
        let command = PTP.command(opcode, parameters: parameters)
        let isLiveView = opcode == 0x1009 && parameters.first == 0xFFFFC002
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation; pendingID = id
                armTimeout(id: id, seconds: isLiveView ? 2 : (opcode == 0x1009 ? 30 : 8))
                if !isLiveView { onLog?(String(format: "PTP → 0x%04X", opcode)) }
                camera.requestSendPTPCommand(command, outData: outData) { @Sendable [weak self] data, response, error in
                    Task { @MainActor in
                        guard let self, self.pendingID == id else { return }
                        if let error { self.finish(id: id, result: .failure(error)); return }
                        do {
                            try PTP.validateResponse(response)
                            if !isLiveView { self.onLog?(String(format: "PTP ← 0x%04X · %d bytes", opcode, data.count)) }
                            self.finish(id: id, result: .success(data))
                        } catch { self.finish(id: id, result: .failure(error)) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func disconnect() {
        failAll(BoothError.unavailable("USB 연결을 종료했습니다."))
        camera?.requestCloseSession()
        isOpen = false
        needsReplug = true
        onDisconnect?(); onChange?()
    }

    private func cancel(id: UUID) {
        guard pendingID == id || openID == id else { return }
        failAll(CancellationError())
        isOpen = false
        needsReplug = true
        camera?.requestCloseSession()
        onDisconnect?(); onChange?()
    }

    private func armTimeout(id: UUID, seconds: Int) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.pendingID == id || self.openID == id else { return }
            self.failAll(BoothError.uncertainCapture("USB 응답 시간 초과. 자동 재전송하지 않습니다. 케이블을 분리 후 다시 연결하세요."))
            self.isOpen = false
            self.needsReplug = true
            self.closeSession()
            self.onDisconnect?(); self.onChange?()
        }
    }

    private func finish(id: UUID, result: Result<Data, any Error>) {
        guard pendingID == id else { return }
        timer?.cancel(); timer = nil
        let continuation = pending
        pending = nil; pendingID = nil
        continuation?.resume(with: result)
    }

    private func closeSession() { camera?.requestCloseSession() }

    private func failAll(_ error: any Error) {
        timer?.cancel(); timer = nil
        let command = pending; let opening = opener
        pending = nil; pendingID = nil; opener = nil; openID = nil
        command?.resume(throwing: error); opening?.resume(throwing: error)
    }

    private func removed(_ device: ICDevice) {
        guard device === camera else { return }
        failAll(BoothError.uncertainCapture("카메라 연결이 해제되었습니다. 받은 사진은 보존했습니다."))
        camera = nil; connectionID = nil; isOpen = false; needsReplug = false; name = "카메라 연결 해제"
        onLog?("USB disconnected")
        onDisconnect?(); onChange?()
    }
}

extension USBTransport: @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let found = device as? ICCameraDevice else { return }
        camera = found; connectionID = UUID(); found.delegate = self
        name = found.name ?? "USB 카메라"
        onLog?("USB camera discovered"); onChange?()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) { removed(device) }
    func didRemove(_ device: ICDevice) { removed(device) }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard device === camera else { return }
        guard let continuation = opener else {
            // A timed out open must not silently reopen a session.
            if error == nil { device.requestCloseSession() }
            return
        }
        timer?.cancel(); timer = nil; opener = nil; openID = nil
        isOpen = error == nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        onChange?()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        guard device === camera else { return }
        isOpen = false
        failAll(error ?? BoothError.unavailable("USB 세션이 닫혔습니다."))
        onDisconnect?(); onChange?()
    }

    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        guard device === camera, let error else { return }
        failAll(error); isOpen = false; onDisconnect?(); onChange?()
    }
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor [weak self] in self?.disconnect() }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // Events are diagnostic hints only. D215 full snapshots decide readiness, preventing stale events.
        let byteCount = eventData.count
        Task { @MainActor [weak self] in self?.onLog?("PTP event · \(byteCount) bytes") }
    }
}
