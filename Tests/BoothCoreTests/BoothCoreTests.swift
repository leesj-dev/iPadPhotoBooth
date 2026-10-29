import Foundation
import ImageIO
#if !PORTABLE_TEST_RUNNER
import Testing
@testable import BoothCore
#endif

private enum CheckFailure: Error { case failed(String) }
private func expect(_ condition: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition else { throw CheckFailure.failed("\(file):\(line)") }
}
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure.failed("Expected non-nil value") }; return value
}
private func expectError<T>(_ operation: () throws -> T) throws {
    do { _ = try operation() } catch is BoothError { return }
    throw CheckFailure.failed("Expected BoothError")
}
@MainActor private func expectAsyncError<T>(_ operation: () async throws -> T) async throws {
    do { _ = try await operation() } catch is BoothError { return }
    throw CheckFailure.failed("Expected async BoothError")
}

private func le(_ value: UInt64, _ width: Int) -> Data { PTP.littleEndian(value, width: width) }
private func ptpString(_ text: String) -> Data {
    var data = Data([UInt8(text.utf16.count + 1)])
    for unit in text.utf16 { data += le(UInt64(unit), 2) }
    return data + le(0, 2)
}
private func wordArray(_ words: [UInt16]) -> Data {
    words.reduce(le(UInt64(words.count), 4)) { $0 + le(UInt64($1), 2) }
}
private func descriptor(_ code: UInt16, _ value: UInt64, form: UInt8 = 0) -> Data {
    var data = le(UInt64(code), 2) + le(4, 2) + Data([1, 1]) + le(value, 2) + le(value, 2) + Data([form])
    if form == 2 { data += le(2, 2) + le(1, 2) + le(2, 2) + le(1, 2) + le(2, 2) }
    return data
}
private func properties(buffer: UInt64, mode: UInt64 = 1, focus: UInt64? = 1) -> Data {
    var data = le(focus == nil ? 3 : 4, 4) + le(0, 4)
    data += descriptor(0x500A, mode, form: 2) + descriptor(0xD222, 0x11)
    data += descriptor(0xD215, buffer)
    if let focus { data += descriptor(0xD213, focus) }
    return data
}

private func liveViewPacket(_ jpeg: Data) -> Data {
    le(16, 4) + le(UInt64(jpeg.count), 4) + le(0, 4) + le(0, 4) + jpeg
}

private func realLiveViewJPEG() throws -> Data {
    #if PORTABLE_TEST_RUNNER
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/liveview.jpg")
    #else
    let url = try require(Bundle.module.url(forResource: "liveview", withExtension: "jpg", subdirectory: "Fixtures"))
    #endif
    return try Data(contentsOf: url)
}

func liveViewRejectsMalformedRangesAndTruncatedJPEG() throws {
    let jpeg = try realLiveViewJPEG()
    try expect(try SonyLiveView.jpeg(from: liveViewPacket(jpeg)) == jpeg)
    try expectError { try SonyLiveView.jpeg(from: Data(repeating: 0, count: 15)) }
    let overflow = le(0xFFFFFFFF, 4) + le(0xFFFFFFFF, 4) + le(0, 8)
    try expectError { try SonyLiveView.jpeg(from: overflow) }
    try expectError { try SonyLiveView.jpeg(from: liveViewPacket(jpeg).dropLast()) }
    try expectError { try SonyLiveView.jpeg(from: liveViewPacket(jpeg.dropLast(2))) }
    try expectError { try SonyLiveView.jpeg(from: liveViewPacket(Data(repeating: 0, count: 6))) }
}

func liveViewExtractsJPEGFromPaddedRegions() throws {
    let jpeg = try realLiveViewJPEG()
    var offsetPacket = le(48, 4) + le(UInt64(jpeg.count + 20), 4) + le(0, 8)
    offsetPacket += Data([0xFF, 0xD8, 0xFF, 0xD9]) + Data(repeating: 0, count: 28)
    offsetPacket += jpeg + Data(repeating: 0, count: 20)
    for packet in [jpeg, liveViewPacket(Data([0, 0]) + jpeg + Data(repeating: 0, count: 64)), offsetPacket] {
        let extracted = try SonyLiveView.jpeg(from: packet)
        try expect(extracted == jpeg)
        let source = try require(CGImageSourceCreateWithData(extracted as CFData, nil))
        try expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }
}

func liveViewDoesNotCutAtJPEGMarkersInsideMetadata() throws {
    let jpeg = try realLiveViewJPEG()
    let comment = Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9])
    let metadata = Data([0xFF, 0xFE, 0, UInt8(comment.count + 2)]) + comment
    let outer = Data(jpeg.prefix(2)) + metadata + jpeg.dropFirst(2)
    let extracted = try SonyLiveView.jpeg(from: liveViewPacket(outer + Data(repeating: 0, count: 32)))
    try expect(extracted == outer)
    let source = try require(CGImageSourceCreateWithData(extracted as CFData, nil))
    try expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
}

func malformedPTPResponsesAndTruncatedDescriptorsAreRejected() throws {
    var response = le(12, 4) + le(3, 2) + le(0x2019, 2) + le(0, 4)
    try expectError { try PTP.validateResponse(response) }
    response[6] = 1; response[7] = 0x20
    try PTP.validateResponse(response)
    for n in 0..<12 { try expectError { try PTP.validateResponse(response.prefix(n)) } }
    let packet = properties(buffer: 0x8001)
    try expect(try SonyProperties.decode(packet)[0xD215]?.current == 0x8001)
    for n in 0..<packet.count { try expectError { try SonyProperties.decode(packet.prefix(n)) } }
}

func jpegLengthAndFormatProtectAgainstPartialTransfer() throws {
    let jpeg = Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9])
    let infoData = le(0, 4) + le(0x3801, 2) + le(0, 2) + le(UInt64(jpeg.count), 4) + Data(repeating: 0, count: 40) + ptpString("image.jpg")
    let info = try PTPObjectInfo(data: infoData)
    try info.validateJPEG(jpeg)
    try expectError { try info.validateJPEG(jpeg.dropLast()) }
    try expectError { try info.validateJPEG(Data(repeating: 0, count: jpeg.count)) }
}

@MainActor private final class CameraFixture: PTPTransport {
    var buffer: UInt64 = 0
    var presses = 0
    var readBeforeReady = false
    var failDownload = false
    var calls: [UInt16] = []
    var focusMode: UInt64 = 1
    var focusState: UInt64 = 1
    var includesFocusState = true
    var lockedState: UInt64 = 2
    var lockAfterPolls: Int? = 2
    var focusPolls = 0
    var halfPressed = false
    var fullPressFocus: UInt64?
    var liveViewReads = 0
    var busyLiveViewReplies = 0
    var liveViewUnsupported = false
    var previewAfterExposure = false
    var inFlight = 0
    var peakInFlight = 0
    let jpeg = Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9])

    func send(_ opcode: UInt16, parameters: [UInt32], outData: Data?) async throws -> Data {
        inFlight += 1; peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        calls.append(opcode)
        switch opcode {
        case 0x1001:
            var data = le(100, 2) + le(17, 4) + le(100, 2)
            data += ptpString("Sony") + le(0, 2)
            data += wordArray([0x9201, 0x9202])
            for _ in 0..<4 { data += wordArray([]) }
            data += ptpString("Sony Corporation") + ptpString("ILCE-7M4") + ptpString("6.00")
            return data
        case 0x9202: return le(0x012C, 2) + wordArray([0x500A, 0xD222, 0xD215]) + wordArray([0xD2C1, 0xD2C2])
        case 0x9209:
            if halfPressed, focusMode != 1 {
                focusPolls += 1
                if let lockAfterPolls, focusPolls >= lockAfterPolls { focusState = lockedState }
            }
            return properties(buffer: buffer, mode: focusMode, focus: includesFocusState ? focusState : nil)
        case 0x9207:
            try Task.checkCancellation()
            if parameters.first == 0xD2C1 { halfPressed = outData == le(2, 2) }
            if parameters.first == 0xD2C2, outData == le(2, 2) {
                presses += 1; fullPressFocus = focusState; buffer = 0x8001
            }
            return Data()
        case 0x1008:
            readBeforeReady = readBeforeReady || buffer < 0x8000
            return le(0, 4) + le(0x3801, 2) + le(0, 2) + le(UInt64(jpeg.count), 4)
                + Data(repeating: 0, count: 40) + ptpString("image.jpg")
        case 0x1009:
            if parameters.first == 0xFFFFC002 {
                liveViewReads += 1
                previewAfterExposure = previewAfterExposure || buffer >= 0x8000
                if liveViewUnsupported { throw BoothError.response(0x2005) }
                if busyLiveViewReplies > 0 { busyLiveViewReplies -= 1; throw BoothError.response(0x2019) }
                return liveViewPacket(try realLiveViewJPEG())
            }
            if failDownload { throw BoothError.unavailable("USB transfer failed") }
            buffer = 0; return jpeg
        default: return Data()
        }
    }
}

func automaticConnectionDefersAndDeduplicatesAttachments() throws {
    var policy = CameraAutoConnect()
    let first = UUID(), replacement = UUID()
    try expect(policy.claim(deviceID: nil, available: true, busy: false, active: true) == nil)
    try expect(policy.claim(deviceID: first, available: false, busy: false, active: true) == nil)
    try expect(policy.claim(deviceID: first, available: true, busy: true, active: true) == nil)
    try expect(policy.claim(deviceID: first, available: true, busy: false, active: false) == nil)
    try expect(policy.claim(deviceID: first, available: true, busy: false, active: true) == first)
    // Repeated session/capability notifications must not reopen or renegotiate the camera.
    try expect(policy.claim(deviceID: first, available: true, busy: false, active: true) == nil)
    try expect(policy.claim(deviceID: replacement, available: true, busy: true, active: true) == nil)
    try expect(policy.claim(deviceID: replacement, available: true, busy: false, active: true) == replacement)
    try expect(policy.claim(deviceID: replacement, available: true, busy: false, active: true) == nil)
    try expect(policy.claim(deviceID: replacement, available: true, busy: false, active: true, retry: true) == replacement)
}

@MainActor func connectionAndLiveViewNeverTakeDiagnosticPhoto() async throws {
    let fixture = CameraFixture()
    fixture.busyLiveViewReplies = 3
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    let frame = try await camera.liveViewFrame()
    try expect(frame == (try realLiveViewJPEG()))
    try expect(fixture.presses == 0 && !fixture.halfPressed && fixture.buffer == 0)
    try expect(fixture.liveViewReads == 4 && fixture.peakInFlight == 1)
    try expect(!fixture.calls.contains(0x1008))
    // A later unplug must make the old camera unusable without sending another command.
    camera.invalidate()
    let count = fixture.calls.count
    try await expectAsyncError { try await camera.liveViewFrame() }
    try expect(fixture.calls.count == count)
}

@MainActor func busyLiveViewSetupStopsAfterBoundedRetries() async throws {
    let fixture = CameraFixture()
    fixture.busyLiveViewReplies = 100
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    try await expectAsyncError { try await camera.liveViewFrame() }
    try expect(fixture.liveViewReads == 10 && fixture.presses == 0)
}

@MainActor func captureWaitsForReadyBufferAndDoesNotRepeatShutterAfterTransferFailure() async throws {
    let fixture = CameraFixture()
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    fixture.failDownload = true
    try await expectAsyncError { try await camera.capture() }
    try expect(fixture.presses == 1)
    try expect(!fixture.readBeforeReady)
    fixture.failDownload = false
    let recovered = try await camera.recoverJPEG()
    try expect(recovered.data == fixture.jpeg)
    try expect(fixture.presses == 1)
}

@MainActor func staleBufferIsNotMisidentifiedAsANewCapture() async throws {
    let fixture = CameraFixture()
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    fixture.buffer = 0x8001
    try await expectAsyncError { try await camera.capture() }
    try expect(fixture.presses == 0)
    try expect(!fixture.calls.contains(0x1009))
}

@MainActor func missedExposureDeadlineNeverPressesShutter() async throws {
    let fixture = CameraFixture()
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    let past = ContinuousClock().now.advanced(by: .seconds(-1))
    try await expectAsyncError { try await camera.capture(at: past) }
    try expect(fixture.presses == 0)
}

@MainActor func autofocusLocksBeforeFullPress(lockedState: UInt64) async throws {
    let fixture = CameraFixture()
    fixture.focusMode = 2; fixture.lockedState = lockedState
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    _ = try await camera.capture()
    try expect(fixture.fullPressFocus == lockedState && fixture.focusPolls >= 2)
    try expect(!fixture.halfPressed)
}

@MainActor func unconfirmedAutofocusStillTakesPhoto(includesFocusState: Bool) async throws {
    let fixture = CameraFixture()
    fixture.focusMode = 2; fixture.lockAfterPolls = nil
    fixture.includesFocusState = includesFocusState
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    let shot = try await camera.capture(at: ContinuousClock().now.advanced(by: .milliseconds(400)))
    try expect(shot.data == fixture.jpeg)
    try expect(fixture.presses == 1 && fixture.fullPressFocus == 1 && !fixture.halfPressed)
}

@MainActor func cancellingAutofocusReleasesHalfPress() async throws {
    let fixture = CameraFixture()
    fixture.focusMode = 2; fixture.lockAfterPolls = nil
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    let capture = Task { try await camera.capture() }
    while !fixture.halfPressed { await Task.yield() }
    capture.cancel()
    try await expectAsyncError { try await capture.value }
    try expect(fixture.presses == 0 && !fixture.halfPressed)
}

@MainActor func liveViewAndCaptureStaySerialAndPauseForPhotoTransfer() async throws {
    let fixture = CameraFixture(); fixture.focusMode = 2
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    let preview = try realLiveViewJPEG()
    try expect(try await camera.liveViewFrame() == preview)
    fixture.busyLiveViewReplies = 1
    var delivered = 0
    let photo = try await camera.capture(at: ContinuousClock().now.advanced(by: .seconds(2)), onLiveView: { data in
        try expect(data == preview); delivered += 1
    })
    try expect(delivered > 0 && fixture.peakInFlight == 1 && !fixture.previewAfterExposure)
    try expect(photo.data == fixture.jpeg && fixture.presses == 1)
}

@MainActor func failedLiveViewStopsBeforeExposure() async throws {
    let fixture = CameraFixture(); fixture.liveViewUnsupported = true
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    try await expectAsyncError {
        try await camera.capture(at: ContinuousClock().now.advanced(by: .seconds(2)), onLiveView: { _ in })
    }
    try expect(fixture.presses == 0)
}

@MainActor func persistentlyBusyLiveViewCannotTakeABlindPhoto() async throws {
    let fixture = CameraFixture(); fixture.busyLiveViewReplies = 100
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    try await expectAsyncError {
        try await camera.capture(at: ContinuousClock().now.advanced(by: .seconds(2)), onLiveView: { _ in })
    }
    try expect(fixture.presses == 0)
}

@MainActor func cancellingLiveViewCannotLeavePreviewCommandsRunning() async throws {
    let fixture = CameraFixture()
    let camera = SonyCamera(transport: fixture)
    try await camera.connect()
    let capture = Task {
        try await camera.capture(at: ContinuousClock().now.advanced(by: .seconds(5)), onLiveView: { _ in })
    }
    while fixture.liveViewReads == 0 { await Task.yield() }
    capture.cancel()
    try await expectAsyncError { try await capture.value }
    try expect(fixture.presses == 0 && fixture.inFlight == 0)
}

func receiptPersistenceSelectionAndPrintUncertaintySurviveRelaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore(root: root)
    var session = BoothSession()
    let pending = PendingShot(index: 0)
    session.pendingShot = pending
    try store.save(session)
    try expect(try store.load()?.pendingShot == pending)
    let data = Data([1, 2, 3])
    _ = try store.saveImage(data, name: "first.jpg", session: session)
    let first = Shot(id: pending.id, index: 0, file: "first.jpg", sourceName: "source.jpg", byteCount: 3, transferSeconds: 0.1, digest: "first")
    try session.append(first)
    for index in 1..<8 {
        let receipt = PendingShot(index: index); session.pendingShot = receipt
        let name = "\(index).jpg"; _ = try store.saveImage(data, name: name, session: session)
        try session.append(Shot(id: receipt.id, index: index, file: name, sourceName: name, byteCount: 3, transferSeconds: 0.1, digest: name))
    }
    session.shots.forEach { session.toggle($0.id) }
    try expect(session.selection.count == 4)
    let ids = session.selection
    try expect(ids == Array(session.shots.prefix(4).map(\.id)))
    session.toggle(ids[1])
    session.toggle(session.shots[6].id)
    try expect(session.selection == [ids[0], ids[2], ids[3], session.shots[6].id])
    session.printState = .presenting
    try store.save(session)
    let restored = try require(store.load())
    try expect(restored.printState == .uncertain)
    try expect(restored.selection == session.selection)
    try expectError { try store.file("../outside.jpg", in: session) }
    try store.delete(session)
    try expect(try store.load() == nil)
}

func mismatchedReceiptCannotCommitAndLateTransfersCannotCompressCadence() throws {
    var session = BoothSession()
    session.pendingShot = PendingShot(index: 0)
    try expectError {
        try session.append(Shot(id: UUID(), index: 0, file: "test.jpg", sourceName: "test.jpg", byteCount: 5, transferSeconds: 1, digest: "x"))
    }
    try expectError { try CaptureCadence.remaining(now: 21, deadline: 20) }
    try expect(try CaptureCadence.remaining(now: 11, deadline: 20) == 9)
}

func bundledTemplatesRespectPrintCanvas() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("PhotoBooth/Resources/Templates/templates.json"))
    let templates = try JSONDecoder().decode([PhotoTemplate].self, from: data)
    for template in templates {
        try template.validate()
        try expect(template.width == 1800 && template.height == 1200)
        let leftMargin = template.slots[0].x * 1800
        let topMargin = template.slots[0].y * 1200
        let bottomMargin = (1 - template.slots[2].y - template.slots[2].height) * 1200
        try expect(abs(leftMargin - 69) < 0.000001)
        try expect(abs(leftMargin - topMargin) < 0.000001)
        try expect(abs(leftMargin - bottomMargin) < 0.000001)
        let horizontalGap = (template.slots[1].x - template.slots[0].x - template.slots[0].width) * 1800
        let verticalGap = (template.slots[2].y - template.slots[0].y - template.slots[0].height) * 1200
        try expect(abs(horizontalGap - 24) < 0.000001)
        try expect(abs(verticalGap - 24) < 0.000001)
        let centers: [(Double, Double)] = [(415, 328.5), (1131, 328.5), (415, 871.5), (1131, 871.5)]
        for (slot, center) in zip(template.slots, centers) {
            try expect(abs(slot.width * 1800 - 692) < 0.000001)
            try expect(abs(slot.height * 1200 - 519) < 0.000001)
            try expect(abs((slot.x + slot.width / 2) * 1800 - center.0) < 0.000001)
            try expect(abs((slot.y + slot.height / 2) * 1200 - center.1) < 0.000001)
            let aspect = slot.width * Double(template.width) / (slot.height * Double(template.height))
            try expect(abs(aspect - PhotoFraming.aspectRatio) < 0.000001)
        }
    }
}

func customizationPersistsUploadsAndSurvivesGuestReset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("booth-customization-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsRoot = root.appendingPathComponent("settings")
    let store = try CustomizationStore(root: settingsRoot)
    try expect(try store.load() == BoothCustomization())
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: project.appendingPathComponent("PhotoBooth/Resources/Templates/uirimje.png"))
    var draft = BoothCustomization()
    draft.headerTitle = "다음 행사 포토부스"
    draft.welcomeTitle = "가을 행사\n포토부스"
    draft.welcomeInstructions = ""
    draft.capturePrompt = "카메라를 보세요"
    let saved = try store.save(draft, overlayData: data)
    let filename = try require(saved.overlayFile)
    try expect(saved.revision != draft.revision)
    let relaunched = try CustomizationStore(root: settingsRoot)
    try expect(try relaunched.load() == saved)
    try expect(try Data(contentsOf: settingsRoot.appendingPathComponent(filename)) == data)

    var updated = saved
    updated.headerTitle = "다음 행사"
    let updatedValue = try store.save(updated)
    try expect(updatedValue.overlayFile == filename)
    try expect(updatedValue.revision != saved.revision)
    var invalid = updatedValue
    invalid.headerTitle = "  "
    try expectError { try store.save(invalid, overlayData: data) }
    invalid = updatedValue; invalid.overlayFile = "../outside.png"
    try expectError { try store.save(invalid) }
    try expectError { try store.save(updatedValue, overlayData: Data("not a PNG".utf8)) }
    try expect(try relaunched.load() == updatedValue)
    try expect(try FileManager.default.contentsOfDirectory(atPath: settingsRoot.path).filter { $0.hasSuffix(".png") }.count == 1)

    let photos = try SessionStore(root: root.appendingPathComponent("photos"))
    let guest = BoothSession(isDemo: true)
    try photos.save(guest)
    try photos.delete(guest)
    try expect(try relaunched.load() == updatedValue)
    let reset = try store.save(BoothCustomization())
    try expect(reset.overlayFile == nil)
    try expect(try relaunched.load() == reset)
    try expect(!FileManager.default.fileExists(atPath: settingsRoot.appendingPathComponent(filename).path))

    let missing = try store.save(draft, overlayData: data)
    try FileManager.default.removeItem(at: settingsRoot.appendingPathComponent(try require(missing.overlayFile)))
    try expectError { try relaunched.load() }
}

#if PORTABLE_TEST_RUNNER
@main struct PortableCoreChecks {
    @MainActor static func main() async throws {
        try malformedPTPResponsesAndTruncatedDescriptorsAreRejected()
        print("PASS malformedPTPResponsesAndTruncatedDescriptorsAreRejected")
        try jpegLengthAndFormatProtectAgainstPartialTransfer()
        print("PASS jpegLengthAndFormatProtectAgainstPartialTransfer")
        try await captureWaitsForReadyBufferAndDoesNotRepeatShutterAfterTransferFailure()
        print("PASS captureWaitsForReadyBufferAndDoesNotRepeatShutterAfterTransferFailure")
        try await staleBufferIsNotMisidentifiedAsANewCapture()
        print("PASS staleBufferIsNotMisidentifiedAsANewCapture")
        try await missedExposureDeadlineNeverPressesShutter()
        print("PASS missedExposureDeadlineNeverPressesShutter")
        for state: UInt64 in [2, 6] { try await autofocusLocksBeforeFullPress(lockedState: state) }
        for hasState in [true, false] { try await unconfirmedAutofocusStillTakesPhoto(includesFocusState: hasState) }
        try await cancellingAutofocusReleasesHalfPress()
        print("PASS AF focus, failure and cancellation")
        try liveViewRejectsMalformedRangesAndTruncatedJPEG()
        try liveViewExtractsJPEGFromPaddedRegions()
        try liveViewDoesNotCutAtJPEGMarkersInsideMetadata()
        try await liveViewAndCaptureStaySerialAndPauseForPhotoTransfer()
        try await failedLiveViewStopsBeforeExposure()
        try await persistentlyBusyLiveViewCannotTakeABlindPhoto()
        try await cancellingLiveViewCannotLeavePreviewCommandsRunning()
        print("PASS live-view packet boundaries, command serialization and cancellation")
        try receiptPersistenceSelectionAndPrintUncertaintySurviveRelaunch()
        print("PASS receiptPersistenceSelectionAndPrintUncertaintySurviveRelaunch")
        try mismatchedReceiptCannotCommitAndLateTransfersCannotCompressCadence()
        print("PASS mismatchedReceiptCannotCommitAndLateTransfersCannotCompressCadence")
        try customizationPersistsUploadsAndSurvivesGuestReset()
        print("PASS customization persists across relaunch, validates writes, and survives guest reset")
        try bundledTemplatesRespectPrintCanvas()
        print("PASS bundledTemplatesRespectPrintCanvas")
        try automaticConnectionDefersAndDeduplicatesAttachments()
        try await connectionAndLiveViewNeverTakeDiagnosticPhoto()
        try await busyLiveViewSetupStopsAfterBoundedRetries()
        print("PASS automatic connection, no shutter during setup, bounded live-view retries")
    }
}
#else
@Suite struct CoreChecks {
    @Test func customizationPersistence() throws { try customizationPersistsUploadsAndSurvivesGuestReset() }
    @Test func automaticConnection() throws { try automaticConnectionDefersAndDeduplicatesAttachments() }
    @Test @MainActor func noSetupExposure() async throws { try await connectionAndLiveViewNeverTakeDiagnosticPhoto() }
    @Test @MainActor func boundedSetupRetries() async throws { try await busyLiveViewSetupStopsAfterBoundedRetries() }
    @Test func paddedLiveView() throws { try liveViewExtractsJPEGFromPaddedRegions() }
    @Test func liveViewMetadataBoundaries() throws { try liveViewDoesNotCutAtJPEGMarkersInsideMetadata() }
    @Test func liveViewPacketBounds() throws { try liveViewRejectsMalformedRangesAndTruncatedJPEG() }
    @Test @MainActor func liveViewCaptureSerialization() async throws { try await liveViewAndCaptureStaySerialAndPauseForPhotoTransfer() }
    @Test @MainActor func unavailableLiveView() async throws { try await failedLiveViewStopsBeforeExposure() }
    @Test @MainActor func persistentlyBusyLiveView() async throws { try await persistentlyBusyLiveViewCannotTakeABlindPhoto() }
    @Test @MainActor func liveViewCancellation() async throws { try await cancellingLiveViewCannotLeavePreviewCommandsRunning() }
    @Test @MainActor func packetBoundaries() throws { try malformedPTPResponsesAndTruncatedDescriptorsAreRejected() }
    @Test @MainActor func truncatedJPEG() throws { try jpegLengthAndFormatProtectAgainstPartialTransfer() }
    @Test @MainActor func transferRecovery() async throws { try await captureWaitsForReadyBufferAndDoesNotRepeatShutterAfterTransferFailure() }
    @Test @MainActor func staleBuffer() async throws { try await staleBufferIsNotMisidentifiedAsANewCapture() }
    @Test @MainActor func missedDeadline() async throws { try await missedExposureDeadlineNeverPressesShutter() }
    @Test(arguments: [UInt64(2), UInt64(6)]) @MainActor func autofocus(lockedState: UInt64) async throws { try await autofocusLocksBeforeFullPress(lockedState: lockedState) }
    @Test(arguments: [true, false]) @MainActor func unconfirmedAutofocus(includesFocusState: Bool) async throws { try await unconfirmedAutofocusStillTakesPhoto(includesFocusState: includesFocusState) }
    @Test @MainActor func autofocusCancellation() async throws { try await cancellingAutofocusReleasesHalfPress() }
    @Test @MainActor func durableSession() throws { try receiptPersistenceSelectionAndPrintUncertaintySurviveRelaunch() }
    @Test @MainActor func receiptAndCadence() throws { try mismatchedReceiptCannotCommitAndLateTransfersCannotCompressCadence() }
    @Test @MainActor func printTemplateBounds() throws { try bundledTemplatesRespectPrintCanvas() }
}
#endif
