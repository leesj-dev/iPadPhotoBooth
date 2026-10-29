import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import BoothCore

private enum BoothPalette {
    static let background = Color(white: 0.035)
    static let surface = Color(white: 0.10)
    static let line = Color.white.opacity(0.16)
}

private struct BoothPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(enabled ? .black : .white.opacity(0.4))
            .background(enabled ? Color.white.opacity(configuration.isPressed ? 0.8 : 1) : BoothPalette.surface,
                        in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct BoothSecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 64)
            .foregroundStyle(enabled ? .white : .white.opacity(0.4))
            .background(configuration.isPressed ? Color(white: 0.18) : BoothPalette.surface,
                        in: RoundedRectangle(cornerRadius: compact ? 14 : 20))
    }
}

struct BoothView: View {
    @Bindable var model: BoothModel
    @State private var equipment = false
    @State private var reset = false
    @State private var demo = false
    @State private var reprint = false
    @State private var inspectedShot: Shot?
    @State private var anchor: UIView?

    private var progress: Int {
        switch model.stage { case .welcome, .capture: 0; case .selection: 1; case .preview: 2 }
    }

    var body: some View {
        GeometryReader { geometry in
            if model.stage == .capture {
                capture
            } else {
                VStack(spacing: 0) {
                    header
                    if let message = model.message { notice(message) }
                    if model.session.isDemo {
                        Text("데모 · 인쇄 불가")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 12)
                    }
                    switch model.stage {
                    case .welcome: welcome
                    case .capture: EmptyView()
                    case .selection: selection(wide: geometry.size.width > geometry.size.height)
                    case .preview: preview
                    }
                    footer
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(BoothPalette.background.ignoresSafeArea())
        .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
        .statusBarHidden(model.stage == .capture)
        .persistentSystemOverlays(model.stage == .capture ? .hidden : .automatic)
        .sheet(isPresented: $equipment) { EquipmentView(model: model).preferredColorScheme(.dark) }
        .fullScreenCover(item: $inspectedShot) { shot in
            PhotoInspectionView(model: model, initialShot: shot)
        }
        .confirmationDialog("현재 사진을 삭제하고 새로 촬영할까요?", isPresented: $reset, titleVisibility: .visible) {
            Button("사진 삭제 후 새로 시작", role: .destructive) { model.newGuest(demo: false) }
        } message: { Text("촬영한 사진과 인쇄 이미지가 삭제됩니다.") }
        .confirmationDialog("현재 세션을 삭제하고 데모를 시작할까요?", isPresented: $demo, titleVisibility: .visible) {
            Button("데모 시작", role: .destructive) { model.newGuest(demo: true) }
        }
        .confirmationDialog("다시 인쇄할까요?", isPresented: $reprint, titleVisibility: .visible) {
            Button("출력 확인 후 다시 인쇄") { sendPrint() }
        } message: { Text("이미 출력됐는지 확인한 뒤 진행하세요.") }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Label(model.customization.headerTitle, systemImage: "viewfinder").font(.title3.weight(.bold))
            Spacer()
            Text(["01  촬영", "02  사진 선택", "03  인쇄"][progress])
                .font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            Button { equipment = true } label: {
                Image(systemName: model.cameraReady && model.liveViewReady ? "checkmark.circle.fill" : "slider.horizontal.3")
                    .font(.title3).frame(width: 48, height: 48)
                    .background(BoothPalette.surface, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("운영 설정")
                .disabled(model.capturing)
        }.padding(.horizontal, 28).padding(.vertical, 12)
    }

    private func notice(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle")
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            Button { model.message = nil } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("안내 닫기")
        }.padding(.leading, 16).padding(.vertical, 4)
            .background(BoothPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 28).padding(.bottom, 12)
    }

    private var welcome: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            ScrollView {
                Group {
                    if wide {
                        HStack(spacing: 32) {
                            welcomeText.frame(maxWidth: .infinity, alignment: .leading)
                            welcomeCard.frame(width: max(260, min(geometry.size.width * 0.54, geometry.size.width - 416)))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 32) {
                            welcomeText
                            welcomeCard.frame(maxWidth: .infinity)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }.padding(32).frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    private var welcomeText: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(model.customization.welcomeTitle)
                .font(.system(size: 68, weight: .bold, design: .rounded)).tracking(-3)
                .fixedSize(horizontal: false, vertical: true)
            Text("10초 간격으로 8장을 촬영합니다.\n이후 인쇄할 사진 4장을 선택하세요.")
                .font(.title3).foregroundStyle(.secondary).lineSpacing(6)
            VStack(alignment: .leading, spacing: 12) {
                if model.session.shots.count < 8 {
                    Button(action: model.start) {
                        HStack { Text(model.session.shots.isEmpty ? "촬영 시작" : "촬영 이어서"); Spacer(); Image(systemName: "arrow.up.right") }
                            .padding(.horizontal, 24)
                    }.buttonStyle(BoothPrimaryButtonStyle()).disabled(!model.canStart)
                } else {
                    Button("사진 고르기") { model.stage = .selection }.buttonStyle(BoothPrimaryButtonStyle())
                }
                if !model.session.shots.isEmpty && model.session.shots.count < 8 {
                    Text("\(model.session.shots.count)장 촬영됨").font(.callout).foregroundStyle(.secondary)
                } else if !model.session.isDemo && !model.canStart {
                    Text(model.cameraStatus == "카메라 연결 대기" ? "카메라 케이블을 연결해 주세요." : model.cameraStatus).font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 480)
        }
    }

    private var welcomeCard: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(white: 0.10)
                ForEach(Array((model.templates.first?.slots ?? []).enumerated()), id: \.offset) { index, slot in
                    Rectangle().fill(Color(white: 0.18 + Double(index) * 0.015))
                        .frame(width: geometry.size.width * slot.width,
                               height: geometry.size.height * slot.height)
                        .overlay {
                            Text(["①", "②", "③", "④"][index])
                                .font(.system(size: geometry.size.width * 0.06, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .position(x: geometry.size.width * (slot.x + slot.width / 2),
                                  y: geometry.size.height * (slot.y + slot.height / 2))
                }
                if let image = model.templatePreview {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
        }.aspectRatio(3.0 / 2.0, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("인쇄 프레임 예시. 사진은 1번부터 왼쪽 위, 오른쪽 위, 왼쪽 아래, 오른쪽 아래 순서로 배치됩니다.")
    }

    private var capture: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let numberSize = min(330, min(geometry.size.width, geometry.size.height) * 0.352)
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let seconds = model.countdownDate.map { max(0, Int(ceil($0.timeIntervalSince(context.date)))) }
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image = model.liveViewImage {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        VStack(spacing: 16) {
                            ProgressView().tint(.white).controlSize(.large)
                            Text("카메라 연결 중").font(.title2)
                        }
                    }
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.5), location: 0),
                        .init(color: .clear, location: 0.22),
                        .init(color: .clear, location: 0.6),
                        .init(color: .black.opacity(0.65), location: 1)
                    ], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                    VStack(spacing: 0) {
                        HStack {
                            Label(liveViewLabel(at: context.date, seconds: seconds), systemImage: "video.fill")
                                .font(.callout.weight(.semibold)).padding(12)
                                .background(.black.opacity(0.45), in: Capsule())
                            Spacer()
                            Text("\(min(model.session.shots.count + 1, 8)) / 8")
                                .font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit()
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                .background(.black.opacity(0.45), in: Capsule())
                                .accessibilityLabel("\(min(model.session.shots.count + 1, 8))번째 촬영")
                        }
                        Spacer(minLength: 0)
                        HStack(alignment: .bottom, spacing: 16) {
                            VStack(alignment: .leading, spacing: 16) {
                                if model.receiving || !model.customization.capturePrompt.isEmpty {
                                    Text(model.receiving ? "사진 저장 중" : model.customization.capturePrompt)
                                        .font(.system(size: wide ? 34 : 30, weight: .semibold))
                                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                                }
                                HStack(spacing: 10) {
                                    ForEach(0..<8) { index in
                                        Capsule().fill(index < model.session.shots.count ? .white : .white.opacity(0.25))
                                            .frame(width: wide ? 30 : 22, height: 6)
                                    }
                                }.accessibilityLabel("8장 중 \(model.session.shots.count)장 저장됨")
                                Button(action: model.stop) {
                                    Label("촬영 중단", systemImage: "xmark").font(.callout.weight(.medium))
                                        .padding(.horizontal, 18).frame(minHeight: 48)
                                        .background(.black.opacity(0.45), in: Capsule())
                                }.buttonStyle(.plain)
                            }.padding(.bottom, 8)
                            Spacer(minLength: 0)
                            VStack(spacing: 0) {
                                Text(seconds.map { String($0) } ?? "…")
                                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                                    .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
                                    .frame(width: numberSize * 1.38, height: numberSize * 1.12)
                                    .accessibilityLabel("다음 촬영까지 \(seconds ?? 0)초")
                            }
                        }
                    }.padding(wide ? 28 : 24)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .foregroundStyle(.white)
            }
        }
    }

    private func liveViewLabel(at date: Date, seconds: Int?) -> String {
        if model.session.isDemo { return "데모" }
        if model.receiving { return "사진 저장 중" }
        guard let updated = model.liveViewUpdatedAt else { return "라이브뷰 연결 중" }
        if let seconds, seconds <= 1 { return "촬영 준비" }
        return date.timeIntervalSince(updated) > 1.3 ? "화면 갱신 대기" : "LIVE"
    }

    private func selection(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 12 : 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("사진 4장 선택")
                    .font(.system(size: wide ? 30 : 36, weight: .bold, design: .rounded)).tracking(-1)
                Spacer()
                Text("\(model.session.selection.count) / 4")
                    .font(.system(size: wide ? 30 : 36, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            gallery(wide: wide)
            HStack(spacing: 24) {
                Spacer(minLength: 0)
                Button("선택 완료", action: model.compose)
                    .buttonStyle(BoothPrimaryButtonStyle())
                    .disabled(model.session.selection.count != 4)
                    .frame(maxWidth: 420)
            }
        }.padding(.horizontal, wide ? 20 : 28).padding(.top, 4).padding(.bottom, 8)
            .disabled(model.busy)
    }

    private var galleryAspectRatio: CGFloat { CGFloat(PhotoFraming.aspectRatio) }

    private func gallery(wide: Bool) -> some View {
        GeometryReader { geometry in
            let gap: CGFloat = 12
            let aspect = galleryAspectRatio
            let columns = wide ? 4 : bestGalleryColumns(size: geometry.size, aspect: aspect)
            let rows = (8 + columns - 1) / columns
            let width = max(0, min((geometry.size.width - CGFloat(columns - 1) * gap - 8) / CGFloat(columns),
                                   (geometry.size.height - CGFloat(rows - 1) * gap - 8) / CGFloat(rows) * aspect))
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if model.session.shots.indices.contains(index) {
                                galleryPhoto(model.session.shots[index], aspect: aspect)
                                    .frame(width: width, height: width / aspect)
                            } else {
                                Color.clear.frame(width: width, height: width / aspect)
                            }
                        }
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func bestGalleryColumns(size: CGSize, aspect: CGFloat) -> Int {
        // Keep all eight visible in portrait too, choosing the largest 4:3 image area.
        (2...4).max { left, right in
            func imageWidth(columns: Int) -> CGFloat {
                let rows = (8 + columns - 1) / columns
                return min((size.width - CGFloat(columns - 1) * 12 - 8) / CGFloat(columns),
                           (size.height - CGFloat(rows - 1) * 12 - 8) / CGFloat(rows) * aspect)
            }
            return imageWidth(columns: left) < imageWidth(columns: right)
        } ?? 4
    }

    private func galleryPhoto(_ shot: Shot, aspect: CGFloat) -> some View {
        let position = model.session.selection.firstIndex(of: shot.id)
        return ZStack {
            Button { model.toggle(shot.id) } label: {
                photo(shot).aspectRatio(aspect, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        if let position {
                            Text("\(position + 1)").font(.title2.weight(.bold)).foregroundStyle(.black)
                                .frame(width: 44, height: 44).background(.white, in: Circle()).padding(12)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(position == nil ? BoothPalette.line : .white, lineWidth: position == nil ? 1 : 4))
            }.buttonStyle(.plain)
                .accessibilityLabel("사진 \(shot.index + 1) 선택")
                .accessibilityValue(position.map { "선택됨, 선택 순서 \($0 + 1)" } ?? "선택 안 함")
            VStack {
                HStack {
                    Spacer()
                    Button { inspectedShot = shot } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.headline).frame(width: 48, height: 48)
                            .background(.black.opacity(0.65), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("사진 \(shot.index + 1) 크게 보기")
                }
                Spacer(minLength: 0)
            }.padding(10)
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            if wide {
                HStack(spacing: 44) {
                    compositePreview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { previewControls }.frame(width: min(420, geometry.size.width * 0.38))
                }.padding(28)
            } else {
                VStack(spacing: 24) {
                    compositePreview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { previewControls }.frame(maxHeight: 350)
                }.padding(28)
            }
        }
    }

    private var compositePreview: some View {
        Group {
            if let image = model.composite { Image(uiImage: image).resizable().scaledToFit() }
            else { ContentUnavailableView("사진을 다시 선택하세요", systemImage: "photo") }
        }.accessibilityLabel("선택한 네 장을 합성한 인쇄 미리보기")
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !model.customization.previewTitle.isEmpty {
                Text(model.customization.previewTitle)
                    .font(.system(size: 44, weight: .bold, design: .rounded)).tracking(-1.5)
            }
            Button {
                if [.submitted, .uncertain, .failed].contains(model.session.printState) { reprint = true }
                else { sendPrint() }
            } label: { Label("인쇄", systemImage: "printer") }
                .buttonStyle(BoothPrimaryButtonStyle()).disabled(model.busy || model.session.isDemo || model.composite == nil)
                .background(PrintAnchor { anchor = $0 }.frame(width: 1, height: 1))
            Button("사진 다시 선택") { model.stage = .selection }
                .buttonStyle(BoothSecondaryButtonStyle()).disabled(model.busy)
            if model.session.printState == .submitted { Label("인쇄 요청됨", systemImage: "checkmark.circle").font(.callout) }
            if model.session.printState == .uncertain { Label("이전 출력 확인 필요", systemImage: "exclamationmark.triangle").font(.callout) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button("데모") { demo = true }
                .buttonStyle(BoothSecondaryButtonStyle(compact: true)).frame(width: 100)
                .disabled(model.busy || model.restoreFailed || model.session.pendingShot != nil || model.diagnosticPending)
            Button("새 촬영") { reset = true }
                .buttonStyle(BoothSecondaryButtonStyle(compact: true)).frame(width: 120)
                .disabled(model.busy || model.restoreFailed || model.session.pendingShot != nil || model.diagnosticPending)
        }.padding(.horizontal, 28).padding(.vertical, 8)
    }

    private func photo(_ shot: Shot) -> some View {
        ZStack {
            BoothPalette.surface
            if let image = model.thumbnails[shot.id] { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
    }

    private func sendPrint() { if let anchor { model.printPhoto(from: anchor) } }
}

private struct PhotoInspectionView: View {
    @Bindable var model: BoothModel
    @State private var currentID: UUID
    @Environment(\.dismiss) private var dismiss

    init(model: BoothModel, initialShot: Shot) {
        self.model = model
        _currentID = State(initialValue: initialShot.id)
    }

    private var position: Int? { model.session.selection.firstIndex(of: currentID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\((model.session.shots.first(where: { $0.id == currentID })?.index ?? 0) + 1) / 8")
                    .font(.title3.monospacedDigit().weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Label("닫기", systemImage: "xmark").padding(14)
                        .background(BoothPalette.surface, in: Capsule())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 24).padding(.top, 16)
            TabView(selection: $currentID) {
                ForEach(model.session.shots) { shot in
                    InspectionPhoto(model: model, shot: shot).tag(shot.id)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            VStack(spacing: 12) {
                PhotoPageControl(count: model.session.shots.count, page: Binding(
                    get: { model.session.shots.firstIndex(where: { $0.id == currentID }) ?? 0 },
                    set: { index in
                        if model.session.shots.indices.contains(index) { currentID = model.session.shots[index].id }
                    }
                )).frame(height: 20).padding(.bottom, 4)
                Button { model.toggle(currentID) } label: {
                    Label(position.map { "\($0 + 1)번으로 선택됨" } ?? "이 사진 선택",
                          systemImage: position == nil ? "plus" : "checkmark")
                }.buttonStyle(BoothPrimaryButtonStyle())
                    .disabled(position == nil && model.session.selection.count == 4)
                Text("\(model.session.selection.count) / 4장 선택")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 600)
        }.background(BoothPalette.background.ignoresSafeArea()).foregroundStyle(.white)
            .preferredColorScheme(.dark).tint(.white)
    }
}

private struct PhotoPageControl: UIViewRepresentable {
    let count: Int
    @Binding var page: Int

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.pageIndicatorTintColor = .white.withAlphaComponent(0.3)
        control.currentPageIndicatorTintColor = .white
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.parent = self
        control.numberOfPages = count
        control.currentPage = page
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: PhotoPageControl
        init(_ parent: PhotoPageControl) { self.parent = parent }
        @objc func changed(_ control: UIPageControl) { parent.page = control.currentPage }
    }
}

private struct InspectionPhoto: View {
    let model: BoothModel
    let shot: Shot
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let displayed = image ?? model.thumbnails[shot.id] {
                Image(uiImage: displayed).resizable().scaledToFit()
            } else { ProgressView() }
        }.padding(.horizontal, 12).padding(.bottom, 28)
            .onAppear { image = model.inspectionImage(for: shot) }
            .onDisappear { image = nil }
            .accessibilityLabel("사진 \(shot.index + 1) 확대 보기")
    }
}

private struct PrintAnchor: UIViewRepresentable {
    let resolve: (UIView) -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async { resolve(view) }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct EquipmentView: View {
    @Bindable var model: BoothModel
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledge = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CustomizationView(model: model)
                    } label: {
                        Label("커스터마이징", systemImage: "paintpalette")
                    }.disabled(model.busy || model.restoreFailed)
                }
                Section("Sony A7 IV · USB") {
                    if let cameraName = model.cameraName {
                        Label(cameraName, systemImage: "cable.connector")
                    }
                    Text("정지사진 · 단일 촬영 · AF-S / AF-C · JPEG 전용 · Dest.+Camera · Original\nUSB Remote Shooting · USB Power Supply OFF").font(.footnote)
                    Label(model.cameraStatus, systemImage: model.cameraReady && model.liveViewReady ? "checkmark.circle.fill" : "cable.connector")
                    if !model.cameraReady || !model.liveViewReady {
                        Button("연결 다시 시도", action: model.connect).disabled(model.busy)
                    }
                    Picker("라이브뷰 방향", selection: Binding(
                        get: { model.liveViewRotation }, set: { model.chooseLiveViewRotation($0) }
                    )) {
                        ForEach(LiveViewRotation.allCases) { rotation in Text(rotation.name).tag(rotation) }
                    }.disabled(model.busy)
                    if model.cameraName != nil {
                        Label(model.liveViewStatus, systemImage: model.liveViewReady ? "video.fill" : "video.slash")
                            .font(.footnote)
                    }
                    if let image = model.liveViewImage {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                    }
                    DisclosureGroup("진단 도구") {
                        Button("라이브뷰 다시 확인", action: model.checkLiveView).disabled(model.busy || !model.cameraReady)
                        Button("JPEG 점검 촬영 1장", action: model.testJPEG).disabled(model.busy || !model.cameraReady || model.diagnosticPending || model.session.pendingShot != nil)
                        Label(model.transferSummary, systemImage: model.usbProof ? "checkmark.seal.fill" : "camera")
                            .font(.footnote)
                        if let image = model.diagnosticImage { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220) }
                    }
                }
                if model.session.pendingShot != nil || model.diagnosticPending {
                    Section("촬영 복구") {
                        Text("카메라를 연결하고 사진 수신을 재시도하세요. 복구되지 않으면 SD 카드를 확인하세요.").font(.footnote)
                        Button("JPEG 수신만 복구", action: model.recover).disabled(model.busy || !model.cameraReady)
                        Button("운영자 확인 후 미확인 촬영 정리", role: .destructive) { acknowledge = true }.disabled(model.busy)
                    }
                }
                Section("프린터 · AirPrint") {
                    Text("AirPrint 지원 프린터와 iPad를 같은 네트워크에 연결하세요. 인쇄 화면에서 프린터·용지·매수를 확인하세요.")
                }
                if let message = model.message { Section("안내") { Text(message).foregroundStyle(.orange) } }
                Section {
                    DisclosureGroup("진단 기록") {
                        if model.logs.isEmpty { Text("기록 없음").foregroundStyle(.secondary) }
                        ForEach(Array(model.logs.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    DisclosureGroup("오픈소스 고지") {
                        Text(licenseNotice).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("운영 설정")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .confirmationDialog("미확인 촬영을 정리할까요?", isPresented: $acknowledge, titleVisibility: .visible) {
                Button("SD 카드와 출력 확인 후 정리", role: .destructive, action: model.acknowledgeUncertainCapture)
            } message: { Text("이 작업은 사진을 복구하지 않습니다. USB를 물리적으로 분리·재연결해 RAM의 이전 파일을 확인하세요.") }
        }.interactiveDismissDisabled(model.busy)
    }

    private var licenseNotice: String {
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: "md", subdirectory: "Licenses"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "CrCmd.DPCC.ios · sohtamei · Apache-2.0. 라이선스 사본은 프로젝트 Licenses 폴더에 있습니다."
        }
        return text
    }
}


private struct CustomizationView: View {
    @Bindable var model: BoothModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BoothCustomization
    @State private var overlayData: Data?
    @State private var importedPreview: UIImage?
    @State private var importedFilename: String?
    @State private var importing = false
    @State private var errorMessage: String?

    init(model: BoothModel) {
        self.model = model
        _draft = State(initialValue: model.customization)
    }

    private var previewImage: UIImage? {
        importedPreview ?? (draft.overlayFile == nil ? model.bundledTemplatePreview : model.templatePreview)
    }

    private var hasChanges: Bool { draft != model.customization || overlayData != nil }

    private func customizationField(_ title: String, text: Binding<String>, hint: String, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if multiline {
                TextField(title, text: text, axis: .vertical).lineLimit(2...4)
                    .accessibilityLabel(title)
            } else {
                TextField(title, text: text).accessibilityLabel(title)
            }
            Text(hint).font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    var body: some View {
        Form {
            Section("문구") {
                customizationField("상단 이름", text: $draft.headerTitle,
                                   hint: "앱 화면 왼쪽 위와 프린터 작업 이름에 사용됩니다.")
                customizationField("시작 제목", text: $draft.welcomeTitle,
                                   hint: "촬영 시작 화면에 크게 표시됩니다. 줄바꿈할 수 있습니다.", multiline: true)
                customizationField("시작 안내 (선택)", text: $draft.welcomeInstructions,
                                   hint: "시작 제목 아래, 촬영 시작 버튼 위에 표시됩니다. 비우면 숨깁니다.", multiline: true)
                customizationField("촬영 중 안내 (선택)", text: $draft.capturePrompt,
                                   hint: "카운트다운 화면 왼쪽 아래에 표시됩니다. 비우면 숨깁니다.")
                customizationField("완료 화면 제목 (선택)", text: $draft.previewTitle,
                                   hint: "완성 화면의 인쇄 버튼 위에 표시됩니다. 비우면 숨깁니다.")
            }
            Section {
                if let image = previewImage {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxHeight: 300).background(.white)
                        .accessibilityLabel("템플릿 미리보기")
                }
                Button("PNG 가져오기") { importing = true }
                Text(importedFilename ?? (draft.overlayFile == nil ? "기본 템플릿 사용 중" : "저장된 템플릿"))
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("인쇄 템플릿")
            } footer: {
                Text("시작 화면의 예시 이미지와 최종 인쇄물에 사용됩니다. 사진 4칸의 위치와 크기는 고정입니다. 사진 칸이 투명한 가로 3:2 PNG를 사용하세요. 권장 크기 7500×5000px, 최대 40MB.")
            }
            Section {
                Button("기본값 불러오기") {
                    draft = BoothCustomization()
                    overlayData = nil; importedPreview = nil; importedFilename = nil
                }
            } footer: {
                Text("저장한 설정과 PNG는 앱을 다시 열거나 새 촬영을 시작해도 유지됩니다. 저장 후에는 현재 사진으로 인쇄 이미지를 다시 만듭니다.")
            }
        }
        .navigationTitle("커스터마이징")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") {
                    do {
                        try model.saveCustomization(draft, overlayData: overlayData)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }.disabled(!hasChanges || model.busy)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= CustomizationStore.maxOverlayBytes else {
                    throw BoothError.unavailable("40MB 이하 PNG 파일을 선택하세요.")
                }
                let data = try Data(contentsOf: url)
                try PhotoRenderer.validateOverlay(data)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw BoothError.unavailable("PNG를 읽을 수 없습니다.")
                }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                               kCGImageSourceThumbnailMaxPixelSize: 1800]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    throw BoothError.unavailable("PNG 미리보기를 만들 수 없습니다.")
                }
                overlayData = data
                importedPreview = UIImage(cgImage: image)
                importedFilename = url.lastPathComponent
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("설정을 적용할 수 없습니다", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
