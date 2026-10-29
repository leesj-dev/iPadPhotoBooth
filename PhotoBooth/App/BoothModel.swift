import SwiftUI
import Observation
import BoothCore

enum BoothStage { case welcome, capture, selection, preview }

@MainActor @Observable final class BoothModel {
    var session = BoothSession()
    var stage: BoothStage = .welcome
    var templates: [PhotoTemplate] = []
    private(set) var customization = BoothCustomization()
    private(set) var templatePreview: UIImage?
    private(set) var bundledTemplatePreview: UIImage?
    var cameraName: String?
    var cameraReady = false
    var cameraStatus = "카메라 연결 대기"
    var usbProof = false
    var busy = false
    var capturing = false
    var receiving = false
    var countdownDate: Date?
    var nextShot = 1
    var message: String?
    var logs: [String] = []
    var thumbnails: [UUID: UIImage] = [:]
    var composite: UIImage?
    var diagnosticImage: UIImage?
    var liveViewRotation = LiveViewRotation.load()
    var liveViewImage: UIImage?
    var liveViewUpdatedAt: Date?
    var liveViewReady = false
    var liveViewStatus = "라이브뷰 확인 전"
    var diagnosticPending = UserDefaults.standard.bool(forKey: "diagnosticPending")
    var restoreFailed = false
    var transferSummary = "JPEG 점검 촬영 전"
    @ObservationIgnored private var lastLiveViewData: Data?
    @ObservationIgnored private var store: SessionStore?
    @ObservationIgnored private var customizationStore: CustomizationStore?
    @ObservationIgnored private let transport = USBTransport()
    @ObservationIgnored private var camera: SonyCamera!
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var autoConnect = CameraAutoConnect()
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var discovering = false
    @ObservationIgnored let printer = AirPrinter()

    init() {
        camera = SonyCamera(transport: transport)
        transport.onChange = { [weak self] in
            guard let self else { return }
            if !self.cameraReady {
                self.cameraName = self.transport.connectionID == nil ? nil : self.transport.name
            }
            self.connectAutomatically()
        }
        transport.onLog = { [weak self] in self?.log($0) }
        transport.onDisconnect = { [weak self] in
            guard let self else { return }
            self.cameraReady = false; self.usbProof = false; self.camera.invalidate()
            self.cameraName = nil
            self.liveViewReady = false; self.liveViewImage = nil; self.liveViewUpdatedAt = nil; self.lastLiveViewData = nil
            self.liveViewStatus = "카메라 연결을 확인하세요"
            self.cameraStatus = "카메라 연결 대기"
            if self.capturing { self.stop() }
        }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            store = try SessionStore(root: support.appendingPathComponent("BoothSessions"))
            let operatorStore = try CustomizationStore(root: support.appendingPathComponent("BoothCustomization"))
            customizationStore = operatorStore
            customization = try operatorStore.load()
            guard let url = Bundle.main.url(forResource: "templates", withExtension: "json", subdirectory: "Templates") else {
                throw BoothError.unavailable("템플릿 리소스를 찾을 수 없습니다.")
            }
            templates = try JSONDecoder().decode([PhotoTemplate].self, from: Data(contentsOf: url))
            for template in templates { try template.validate() }
            guard !templates.isEmpty, Set(templates.map(\.id)).count == templates.count else {
                throw BoothError.invalidPacket("템플릿 목록 오류")
            }
            if let filename = templates[0].overlayFile,
               let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "Templates") {
                bundledTemplatePreview = PhotoRenderer.thumbnail(url: url, maxPixel: 1800)
            }
            reloadTemplatePreview()
            if var saved = try store?.load() {
                if !templates.contains(where: { $0.id == saved.templateID }) {
                    saved.templateID = templates[0].id
                    saved.compositeFile = nil
                    saved.compositeLayoutVersion = nil
                    // Keep source shots, selection and print history when replacing a retired frame.
                    try store?.save(saved)
                }
                session = saved
                stage = saved.compositeFile == nil ? (saved.shots.count == 8 ? .selection : .welcome) : .preview
                for shot in saved.shots { thumbnails[shot.id] = image(shot) }
                if let file = saved.compositeFile, let store,
                   let image = PhotoRenderer.thumbnail(url: try store.file(file, in: saved), maxPixel: PhotoFraming.previewMaxPixel),
                   let template = templates.first(where: { $0.id == saved.templateID }) {
                    if saved.compositeLayoutVersion == PhotoFraming.layoutVersion,
                       saved.compositeCustomizationRevision == customization.revision,
                       (image.size.width > image.size.height) == (template.width > template.height) {
                        composite = image
                    } else {
                        // Keep the old file and print history; ask for a fresh composition using the new layout.
                        stage = .selection
                    }
                }
                if saved.pendingShot != nil { message = "미확인 촬영이 남아 있습니다. 장비 패널에서 JPEG 수신 복구를 먼저 확인하세요." }
            } else { try persist() }
        } catch { restoreFailed = true; message = "초기화·복원 실패: \(error.localizedDescription). 기존 파일은 보존했습니다." }
    }

    var canStart: Bool {
        !busy && !restoreFailed && session.pendingShot == nil && !diagnosticPending
        && session.shots.count < 8 && (session.isDemo || (cameraReady && liveViewReady))
    }

    var selectedTemplate: PhotoTemplate? {
        guard let template = templates.first(where: { $0.id == session.templateID }) else { return nil }
        return customization.overlayFile.map { template.replacingOverlay(with: $0) } ?? template
    }

    private var customOverlayDirectory: URL? {
        customization.overlayFile == nil ? nil : customizationStore?.root
    }

    private func reloadTemplatePreview() {
        if let name = customization.overlayFile, let root = customizationStore?.root {
            templatePreview = PhotoRenderer.thumbnail(url: root.appendingPathComponent(name), maxPixel: 1800)
        } else {
            templatePreview = bundledTemplatePreview
        }
    }

    func saveCustomization(_ draft: BoothCustomization, overlayData: Data?) throws {
        guard !busy, !restoreFailed, let customizationStore else {
            throw BoothError.unavailable("현재 작업을 마친 뒤 설정을 저장하세요.")
        }
        if let overlayData { try PhotoRenderer.validateOverlay(overlayData) }
        customization = try customizationStore.save(draft, overlayData: overlayData)
        reloadTemplatePreview()
        // A completed image belongs to the exact configuration used to create it.
        session.compositeFile = nil
        session.compositeLayoutVersion = nil
        session.compositeCustomizationRevision = nil
        composite = nil
        stage = session.shots.count == 8 ? .selection : .welcome
        saveReportingError()
    }

    private func connectAutomatically() {
        guard !restoreFailed,
              let id = autoConnect.claim(deviceID: transport.connectionID,
                                         available: transport.canAutoConnect, busy: busy, active: isActive) else { return }
        prepareCamera(attachment: id)
    }

    func connect() {
        guard !restoreFailed, !busy, isActive else { return }
        guard let id = autoConnect.claim(deviceID: transport.connectionID,
                                        available: transport.canAutoConnect, busy: busy,
                                        active: isActive, retry: true) else {
            message = "카메라의 USB Remote Shooting 설정과 케이블을 확인하세요."
            return
        }
        prepareCamera(attachment: id)
    }

    private func prepareCamera(attachment id: UUID) {
        cameraStatus = "카메라 연결 중"
        operate {
            self.usbProof = false; self.cameraReady = false
            self.liveViewReady = false; self.liveViewImage = nil; self.liveViewUpdatedAt = nil; self.lastLiveViewData = nil
            do {
                try self.requireAttachment(id, sessionOpen: false)
                try await self.transport.open()
                try self.requireAttachment(id)
                try await self.camera.connect()
                try self.requireAttachment(id)
                self.cameraReady = true
                self.cameraName = "Sony A7 IV · \(self.camera.identity?.firmware ?? "")"
                self.log("Sony PTP-V3 connected; checking live view without shutter")
                self.cameraStatus = "라이브뷰 확인 중"
                let frame = try await self.camera.liveViewFrame()
                try self.requireAttachment(id)
                try self.acceptLiveView(frame)
                self.cameraStatus = "촬영 준비 완료"
            } catch {
                // A detached camera must never publish readiness for its replacement.
                if self.transport.connectionID == id {
                    self.cameraStatus = "카메라 연결 확인 필요"
                    self.liveViewReady = false
                    self.liveViewStatus = "라이브뷰 확인 전"
                }
                throw error
            }
        }
    }

    private func requireAttachment(_ id: UUID, sessionOpen: Bool = true) throws {
        try Task.checkCancellation()
        guard transport.connectionID == id, !sessionOpen || transport.isOpen else {
            throw BoothError.unavailable("카메라 연결이 바뀌었습니다.")
        }
    }

    func activityChanged(active: Bool) {
        isActive = active
        if active {
            Task { await self.discover() }
        } else {
            stop()
        }
    }

    func checkLiveView() {
        guard cameraReady else { return }
        operate {
            self.liveViewReady = false
            self.liveViewStatus = "라이브뷰 확인 중"
            do {
                try self.acceptLiveView(await self.camera.liveViewFrame())
                self.cameraStatus = "촬영 준비 완료"
            }
            catch { self.liveViewStatus = "라이브뷰 확인 실패"; throw error }
        }
    }

    func discover() async {
        guard !discovering else { return }
        discovering = true
        defer { discovering = false }
        do {
            try await transport.start()
            connectAutomatically()
        } catch { message = error.localizedDescription }
    }

    func testJPEG() {
        guard cameraReady, !diagnosticPending, session.pendingShot == nil else {
            message = "USB 연결과 미확인 촬영 기록을 먼저 확인하세요."; return
        }
        operate {
            self.diagnosticImage = nil
            try? FileManager.default.removeItem(at: self.diagnosticURL)
            self.setDiagnosticPending(true)
            let shot = try await self.camera.capture()
            try self.acceptDiagnostic(shot)
        }
    }

    func recover() {
        guard cameraReady, session.pendingShot != nil || diagnosticPending else { return }
        operate {
            if let pending = self.session.pendingShot, let store = self.store {
                // A crash after the atomic image write can be repaired without reading the camera again.
                let name = "\(pending.id.uuidString).jpg"
                if let data = try? Data(contentsOf: store.file(name, in: self.session)) {
                    try self.accept(data: data, sourceName: "recovered-local.jpg", seconds: 0, pending: pending)
                    return
                }
            }
            let shot = try await self.camera.recoverJPEG()
            if self.diagnosticPending { try self.acceptDiagnostic(shot) }
            else if let pending = self.session.pendingShot {
                try self.accept(data: shot.data, sourceName: shot.filename, seconds: shot.transferSeconds, pending: pending)
                self.usbProof = true
            }
        }
    }

    /// Explicit operator action after physical inspection; never an automatic retry.
    func acknowledgeUncertainCapture() {
        guard !busy else { return }
        do {
            session.pendingShot = nil
            try persist()
            setDiagnosticPending(false)
            usbProof = false
            transport.disconnect()
            message = "미확인 촬영을 정리했습니다. USB를 다시 연결하면 자동으로 준비합니다."
        } catch { message = error.localizedDescription }
    }

    func start() {
        guard canStart else { return }
        busy = true; capturing = true; stage = .capture; message = nil
        liveViewImage = nil; liveViewUpdatedAt = nil; lastLiveViewData = nil
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer {
                self.capturing = false; self.receiving = false
                self.countdownDate = nil
                UIApplication.shared.isIdleTimerDisabled = false
                self.finishOperation()
            }
            do {
                let clock = ContinuousClock()
                let began = clock.now
                var ordinal = 1
                while self.session.shots.count < CaptureCadence.count {
                    try Task.checkCancellation()
                    let deadline = began.advanced(by: .seconds(Double(ordinal) * CaptureCadence.interval))
                    let now = began.duration(to: clock.now).secondsValue
                    let remaining = try CaptureCadence.remaining(now: now, deadline: Double(ordinal) * CaptureCadence.interval)
                    self.nextShot = self.session.shots.count + 1
                    self.countdownDate = Date().addingTimeInterval(remaining)
                    let pending = PendingShot(index: self.session.shots.count)
                    self.session.pendingShot = pending
                    try self.persist() // Must succeed before pressing the shutter.
                    let showExposure: () -> Void = {
                        self.receiving = true
                        self.countdownDate = self.session.shots.count < 7 ? Date().addingTimeInterval(10) : nil
                    }
                    if self.session.isDemo {
                        self.liveViewImage = PhotoRenderer.liveViewImage(PhotoRenderer.demoJPEG(index: pending.index), rotation: self.liveViewRotation)
                        try await clock.sleep(until: deadline)
                        try Task.checkCancellation()
                        _ = try CaptureCadence.remaining(now: began.duration(to: clock.now).secondsValue,
                                                        deadline: Double(ordinal) * CaptureCadence.interval)
                        showExposure()
                        let data = PhotoRenderer.demoJPEG(index: pending.index)
                        try self.accept(data: data, sourceName: "DEMO.jpg", seconds: 0, pending: pending)
                    } else {
                        let shot = try await self.camera.capture(at: deadline, onExposure: showExposure,
                                                               onLiveView: { data in try self.acceptLiveView(data) })
                        try self.accept(data: shot.data, sourceName: shot.filename, seconds: shot.transferSeconds, pending: pending)
                    }
                    self.receiving = false
                    ordinal += 1
                }
                self.stage = .selection
            } catch is CancellationError {
                if self.session.isDemo { self.session.pendingShot = nil; self.saveReportingError() }
                self.message = self.session.pendingShot == nil ? "촬영을 멈췄습니다. 남은 사진부터 재개할 수 있습니다." : "촬영 중단: 미확인 촬영의 수신 상태를 먼저 확인하세요."
                self.stage = .welcome
            } catch {
                if case BoothError.exposureNotStarted = error {
                    self.session.pendingShot = nil
                    self.saveReportingError()
                }
                self.message = error.localizedDescription
                self.log("Capture stopped: \(error.localizedDescription)")
                self.usbProof = false
                self.liveViewReady = false
                self.stage = .welcome
            }
        }
    }

    func stop() { task?.cancel() }

    func toggle(_ id: UUID) { session.toggle(id); composite = nil; saveReportingError() }
    func compose() {
        guard !busy, let store, let template = selectedTemplate else { return }
        do {
            let data = try PhotoRenderer.compose(session: session, store: store, template: template, overlayDirectory: customOverlayDirectory)
            _ = try store.saveImage(data, name: "composite.jpg", session: session)
            session.compositeFile = "composite.jpg"
            session.compositeLayoutVersion = PhotoFraming.layoutVersion
            session.compositeCustomizationRevision = customization.revision
            if ![.submitted, .uncertain, .failed].contains(session.printState) { session.printState = .notSent }
            try persist()
            composite = PhotoRenderer.thumbnail(url: try store.file("composite.jpg", in: session), maxPixel: PhotoFraming.previewMaxPixel)
            stage = .preview
        } catch { message = error.localizedDescription }
    }

    func printPhoto(from view: UIView) {
        guard !busy, !session.isDemo, let store, let file = session.compositeFile else { return }
        do {
            let data = try Data(contentsOf: store.file(file, in: session))
            session.printState = .presenting; try persist(); busy = true
            printer.present(data: data, from: view, jobName: customization.headerTitle) { [weak self] state, error in
                guard let self else { return }
                self.session.printState = state; self.busy = false; self.saveReportingError()
                self.message = error ?? (state == .submitted ? "인쇄 요청됨" : "인쇄 취소됨")
                self.connectAutomatically()
            }
        } catch { message = error.localizedDescription }
    }

    func newGuest(demo: Bool) {
        guard !busy, !restoreFailed, session.pendingShot == nil, !diagnosticPending else { return }
        do {
            if let store { try store.delete(session) }
            session = BoothSession(isDemo: demo)
            try persist()
            thumbnails = [:]; composite = nil; stage = .welcome; message = nil
        } catch { message = error.localizedDescription }
    }

    private func accept(data: Data, sourceName: String, seconds: Double, pending: PendingShot) throws {
        guard let store else { throw BoothError.unavailable("로컬 저장소 없음") }
        try PhotoRenderer.validate(data)
        let digest = PhotoRenderer.digest(data)
        guard !session.shots.contains(where: { $0.digest == digest }) else {
            throw BoothError.uncertainCapture("이전에 받은 것과 동일한 JPEG입니다. 중복 또는 과거 파일 여부를 확인하세요.")
        }
        let name = "\(pending.id.uuidString).jpg"
        let url = try store.saveImage(data, name: name, session: session)
        let shot = Shot(id: pending.id, index: pending.index, file: name, sourceName: sourceName,
                        byteCount: data.count, transferSeconds: seconds, digest: digest)
        var updated = session
        try updated.append(shot)
        try store.save(updated)
        session = updated
        thumbnails[shot.id] = PhotoRenderer.framedThumbnail(url: url, maxPixel: 1200)
        transferSummary = String(format: "%d bytes · %.2f초 · JPEG 저장 완료", data.count, seconds)
        log("JPEG \(shot.index + 1) saved · \(data.count) bytes · \(String(format: "%.2fs", seconds))")
    }

    private var diagnosticURL: URL {
        (store?.root ?? FileManager.default.temporaryDirectory).appendingPathComponent("diagnostic.jpg")
    }

    private func acceptDiagnostic(_ shot: CapturedJPEG) throws {
        try PhotoRenderer.validate(shot.data)
        try shot.data.write(to: diagnosticURL, options: .atomic)
        diagnosticImage = PhotoRenderer.framedThumbnail(url: diagnosticURL)
        setDiagnosticPending(false)
        usbProof = true
        transferSummary = String(format: "%d bytes · %.2f초 · USB JPEG 검증 통과", shot.data.count, shot.transferSeconds)
        log(transferSummary)
    }

    private func setDiagnosticPending(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "diagnosticPending"); diagnosticPending = value
    }

    func chooseLiveViewRotation(_ rotation: LiveViewRotation) {
        guard !busy else { return }
        liveViewRotation = rotation
        UserDefaults.standard.set(rotation.rawValue, forKey: "liveViewRotation")
        if let data = lastLiveViewData {
            do { try acceptLiveView(data) } catch { message = error.localizedDescription }
        }
    }

    private func acceptLiveView(_ data: Data) throws {
        guard let image = PhotoRenderer.liveViewImage(data, rotation: liveViewRotation) else {
            liveViewReady = false
            liveViewStatus = "라이브뷰 이미지 오류"
            throw BoothError.invalidPacket("카메라 라이브뷰 JPEG를 디코딩하지 못했습니다.")
        }
        lastLiveViewData = data
        liveViewImage = image
        liveViewUpdatedAt = Date()
        liveViewReady = true
        liveViewStatus = "라이브뷰 수신 확인됨"
    }
    func inspectionImage(for shot: Shot) -> UIImage? {
        guard let store, let url = try? store.file(shot.file, in: session) else { return nil }
        return PhotoRenderer.framedThumbnail(url: url, maxPixel: 2400)
    }

    private func image(_ shot: Shot) -> UIImage? {
        guard let store, let url = try? store.file(shot.file, in: session) else { return nil }
        return PhotoRenderer.framedThumbnail(url: url, maxPixel: 1200)
    }
    private func persist() throws {
        guard let store else { throw BoothError.unavailable("로컬 저장소 초기화 실패") }
        try store.save(session)
    }
    private func saveReportingError() {
        do { try persist() } catch { message = "저장 실패: \(error.localizedDescription)" }
    }
    private func log(_ text: String) {
        logs.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
    private func finishOperation() {
        busy = false; task = nil
        connectAutomatically()
    }

    private func operate(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !restoreFailed else { return }
        busy = true; message = nil
        task = Task {
            defer { self.finishOperation() }
            do { try await operation() }
            catch {
                if case BoothError.exposureNotStarted = error { self.setDiagnosticPending(false) }
                self.message = error.localizedDescription; self.log(error.localizedDescription)
            }
        }
    }
}

private extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
