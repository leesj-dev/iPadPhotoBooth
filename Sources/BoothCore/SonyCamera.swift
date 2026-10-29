import Foundation

@MainActor public protocol PTPTransport: AnyObject {
    func send(_ opcode: UInt16, parameters: [UInt32], outData: Data?) async throws -> Data
}

public struct CapturedJPEG: Sendable {
    public let data: Data
    public let filename: String
    public let transferSeconds: Double
}

/// Claims one automatic setup attempt per attachment. Busy/background events remain pending.
public struct CameraAutoConnect: Sendable {
    private var attemptedID: UUID?
    public init() {}

    public mutating func claim(deviceID: UUID?, available: Bool, busy: Bool, active: Bool,
                               retry: Bool = false) -> UUID? {
        guard let deviceID, available, !busy, active, retry || attemptedID != deviceID else { return nil }
        attemptedID = deviceID
        return deviceID
    }
}

/// Experimental A7 IV driver; every captured JPEG is validated before it is saved.
@MainActor public final class SonyCamera {
    private let transport: any PTPTransport
    private var connected = false
    private var running = false
    private var controls: Set<UInt16> = []
    public private(set) var identity: PTPDeviceInfo?

    public init(transport: any PTPTransport) { self.transport = transport }

    public func invalidate() { connected = false; identity = nil }

    public func connect() async throws {
        guard !running else { throw BoothError.unavailable("카메라 작업 중입니다.") }
        running = true
        defer { running = false }
        connected = false
        let info = try PTPDeviceInfo(data: await send(0x1001))
        guard info.manufacturer.lowercased().contains("sony"), info.model == "ILCE-7M4",
              info.operations.contains(0x9201), info.operations.contains(0x9202) else {
            throw BoothError.unavailable("이 개발판은 Sony ILCE-7M4만 허용합니다. 모델: \(info.model)")
        }
        _ = try await send(0x9201, [1, 0, 0])
        _ = try await send(0x9201, [2, 0, 0])
        var r = BinaryReader(try await send(0x9202, [0x012C, 1]))
        let version = try r.integer(2)
        guard version == 0x012C else { throw BoothError.unavailable("Sony PTP-V3 협상에 실패했습니다.") }
        _ = try r.wordArray()
        controls = try r.wordArray()
        guard controls.contains(0xD2C1), controls.contains(0xD2C2) else {
            throw BoothError.unavailable("카메라가 S1/S2 제어를 제공하지 않습니다.")
        }
        _ = try await send(0x9201, [3, 0, 0])
        identity = info
        // A7 IV startup settling: follows the observed requirement in libgphoto2.
        try await Task.sleep(for: .seconds(3))
        try await releaseButtons()
        try await checkSettings()
        connected = true
    }

    public func checkSettings() async throws {
        try validateSettings(await properties())
    }

    private func validateSettings(_ values: [UInt16: SonyProperty]) throws {
        guard values[0xD222]?.current == 0x11 else {
            throw BoothError.unavailable("Remote Shoot Setting의 저장 위치를 Dest.+Camera로 설정하세요.")
        }
        guard values[0xD215]?.current != nil else {
            throw BoothError.unavailable("촬영 파일 준비 상태(D215)를 읽을 수 없습니다.")
        }
        guard values[0x500A]?.current != nil else {
            throw BoothError.unavailable("카메라의 초점 모드를 읽을 수 없습니다.")
        }
    }

    public func hasPendingImage() async throws -> Bool {
        let props = try await properties()
        guard let state = props[0xD215]?.current else { throw BoothError.invalidPacket("D215 속성 없음") }
        return state >= 0x8000
    }

    public func liveViewFrame() async throws -> Data {
        guard connected, !running else { throw BoothError.unavailable("카메라 연결을 확인하거나 촬영이 끝난 뒤 다시 시도하세요.") }
        running = true
        defer { running = false }
        for attempt in 0..<10 {
            do { return try await readLiveViewFrame() }
            catch BoothError.response(0x2019) where attempt < 9 {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw BoothError.unavailable("카메라 라이브뷰가 아직 준비되지 않았습니다.")
    }

    public func capture(at deadline: ContinuousClock.Instant? = nil,
                        onExposure: (() -> Void)? = nil,
                        onLiveView: ((Data) throws -> Void)? = nil) async throws -> CapturedJPEG {
        guard connected, !running else { throw BoothError.exposureNotStarted("카메라 연결 또는 다른 촬영을 확인하세요.") }
        running = true
        defer { running = false }
        var halfPressed = false
        var deliveredFrame = false
        let displayFrame: ((Data) throws -> Void)?
        if let onLiveView {
            displayFrame = { data in try onLiveView(data); deliveredFrame = true }
        } else { displayFrame = nil }
        do {
            try Task.checkCancellation()
            let settings = try await properties()
            try validateSettings(settings)
            guard let buffer = settings[0xD215]?.current, buffer < 0x8000 else {
                throw BoothError.unavailable("이전 촬영 파일이 RAM에 남아 있습니다. 새 촬영은 하지 않았습니다. USB를 분리·재연결하고 이전 원본을 확인하세요.")
            }
            let clock = ContinuousClock()
            if let deadline, clock.now > deadline.advanced(by: .milliseconds(250)) {
                throw BoothError.unavailable("USB 사전 확인이 촬영 예약 시각을 넘겼습니다. 촬영하지 않았습니다.")
            }
            if settings[0x500A]?.current != 1 {
                // AF starts during the final three seconds, keeping the full-press on the countdown deadline.
                if let deadline {
                    try await waitWithLiveView(until: deadline.advanced(by: .seconds(-3)),
                                               exposure: deadline, onFrame: displayFrame)
                }
                halfPressed = true
                try await button(0xD2C1, 2)
                let focusDeadline = min(deadline ?? clock.now.advanced(by: .seconds(3)), clock.now.advanced(by: .seconds(3)))
                try await waitForFocus(until: focusDeadline, onFrame: displayFrame)
            }
            if let deadline {
                try await waitWithLiveView(until: deadline, exposure: deadline, onFrame: displayFrame)
                guard clock.now <= deadline.advanced(by: .milliseconds(250)) else {
                    throw BoothError.unavailable("USB 사전 확인이 촬영 예약 시각을 넘겼습니다. 촬영하지 않았습니다.")
                }
            }
            if onLiveView != nil, !deliveredFrame {
                throw BoothError.unavailable("라이브뷰 화면을 받지 못해 촬영을 멈췄습니다. 카메라 연결과 라이브뷰 수신을 다시 확인하세요.")
            }
            try Task.checkCancellation()
        } catch {
            if halfPressed { await releaseAfterFailure() }
            // No full press was sent, so a stale RAM object cannot satisfy this receipt.
            throw BoothError.exposureNotStarted(error.localizedDescription)
        }
        do {
            if !halfPressed { try await button(0xD2C1, 2) }
            onExposure?()
            try await button(0xD2C2, 2)
            try await Task.sleep(for: .milliseconds(100))
            try await releaseButtons()
            return try await receiveReadyJPEG()
        } catch {
            // Cleanup is best effort; transport timeouts demand physical reconnect.
            await releaseAfterFailure()
            throw error
        }
    }

    private func waitForFocus(until deadline: ContinuousClock.Instant,
                              onFrame: ((Data) throws -> Void)?) async throws {
        let clock = ContinuousClock()
        // Focus confirmation is advisory. Leave the shutter half-held for AF-C tracking,
        // but never make an unconfirmed/missing focus status prevent the full press.
        while clock.now < deadline.advanced(by: .milliseconds(-150)) {
            try Task.checkCancellation()
            let values = try await properties()
            let state = values[0xD213]?.current
            // Sony V3 sample identifies 2 as focused AF-S and 6 as focused AF-C.
            if state == 2 || state == 6 { return }
            if let onFrame, clock.now < deadline.advanced(by: .seconds(-1)) {
                try await deliverLiveView(to: onFrame)
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(100))))
        }
        try await clock.sleep(until: deadline)
    }

    private func waitWithLiveView(until deadline: ContinuousClock.Instant,
                                  exposure: ContinuousClock.Instant,
                                  onFrame: ((Data) throws -> Void)?) async throws {
        let clock = ContinuousClock()
        while clock.now < deadline {
            try Task.checkCancellation()
            guard let onFrame, clock.now < exposure.advanced(by: .seconds(-1)) else {
                try await clock.sleep(until: deadline)
                return
            }
            try await deliverLiveView(to: onFrame)
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(200))))
        }
    }

    private func readLiveViewFrame() async throws -> Data {
        try Task.checkCancellation()
        return try SonyLiveView.jpeg(from: await send(0x1009, [0xFFFFC002]))
    }

    private func deliverLiveView(to onFrame: (Data) throws -> Void) async throws {
        do { try onFrame(await readLiveViewFrame()) }
        catch BoothError.response(0x2019) { /* DeviceBusy: let the camera settle before the next bounded request. */ }
    }

    /// Recovery only: never presses the shutter. Caller must have an outstanding receipt.
    public func recoverJPEG() async throws -> CapturedJPEG {
        guard connected, !running else { throw BoothError.unavailable("USB 연결을 먼저 확인하세요.") }
        running = true
        defer { running = false }
        try await releaseButtons()
        return try await receiveReadyJPEG()
    }

    private func receiveReadyJPEG() async throws -> CapturedJPEG {
        let clock = ContinuousClock()
        let began = clock.now
        let deadline = began.advanced(by: .seconds(35))
        while clock.now < deadline {
            try Task.checkCancellation()
            if try await hasPendingImage() {
                // Never probe this virtual handle before D215 readiness; some Sony firmware can crash.
                let info = try PTPObjectInfo(data: await send(0x1008, [0xFFFFC001]))
                let data = try await send(0x1009, [0xFFFFC001])
                try info.validateJPEG(data)
                let elapsed = began.duration(to: clock.now).components
                return CapturedJPEG(data: data, filename: info.filename,
                                    transferSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BoothError.uncertainCapture("35초 동안 촬영 JPEG가 준비되지 않았습니다. 자동 재촬영하지 않습니다.")
    }

    private func properties() async throws -> [UInt16: SonyProperty] {
        try SonyProperties.decode(await send(0x9209, [0])) // full snapshot, not only changed values
    }

    private func button(_ code: UInt16, _ value: UInt64) async throws {
        _ = try await transport.send(0x9207, parameters: [UInt32(code), 1], outData: PTP.littleEndian(value, width: 2))
    }

    private func releaseButtons() async throws {
        try await button(0xD2C2, 1)
        try await button(0xD2C1, 1)
    }

    private func releaseAfterFailure() async {
        // A cancelled shooting task must still release a half-held shutter while USB remains usable.
        let cleanup = Task { @MainActor in try? await self.releaseButtons() }
        await cleanup.value
    }

    private func send(_ opcode: UInt16, _ parameters: [UInt32] = []) async throws -> Data {
        try await transport.send(opcode, parameters: parameters, outData: nil)
    }
}
