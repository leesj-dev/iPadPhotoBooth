import Foundation

public struct BoothCustomization: Codable, Equatable, Sendable {
    public var headerTitle = "의림제 포토부스"
    public var welcomeTitle = "의림제\n할로윈 포토부스"
    public var welcomeInstructions = "10초 간격으로 8장을 촬영합니다.\n인쇄할 사진 4장을 선택하세요."
    public var capturePrompt = "카메라를 보세요"
    public var previewTitle = "인쇄 미리보기"
    public var overlayFile: String?
    public var revision = "bundled-uirimje-v1"

    public init() {}

    public func validate() throws {
        guard !headerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !welcomeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              headerTitle.count <= 60, welcomeTitle.count <= 120,
              welcomeInstructions.count <= 300, capturePrompt.count <= 100, previewTitle.count <= 100,
              !revision.isEmpty,
              overlayFile.map({ BoothSession.safeFilename($0) && $0.hasSuffix(".png") }) ?? true else {
            throw BoothError.unavailable("상단 이름·시작 제목을 입력하고 문구 길이를 확인하세요.")
        }
    }
}

/// Operator configuration has a separate lifetime from visitor photo sessions.
public struct CustomizationStore {
    public let root: URL
    private var settingsURL: URL { root.appendingPathComponent("settings.json") }
    public static let maxOverlayBytes = 40 * 1024 * 1024

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func load() throws -> BoothCustomization {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return BoothCustomization() }
        let value = try JSONDecoder().decode(BoothCustomization.self, from: Data(contentsOf: settingsURL))
        try value.validate()
        if let name = value.overlayFile,
           !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            throw BoothError.unavailable("저장된 템플릿 PNG를 찾을 수 없습니다.")
        }
        return value
    }

    public func save(_ draft: BoothCustomization, overlayData: Data? = nil) throws -> BoothCustomization {
        try draft.validate()
        let previous = try load()
        var value = draft
        var newImageURL: URL?
        if let overlayData {
            guard overlayData.count <= Self.maxOverlayBytes,
                  overlayData.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw BoothError.unavailable("40MB 이하 PNG 파일을 선택하세요.")
            }
            let name = "\(UUID().uuidString).png"
            let url = root.appendingPathComponent(name)
            try overlayData.write(to: url, options: .atomic)
            newImageURL = url
            value.overlayFile = name
        }
        value.revision = UUID().uuidString
        do {
            try value.validate()
            if let name = value.overlayFile,
               !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
                throw BoothError.unavailable("저장할 템플릿 PNG를 찾을 수 없습니다.")
            }
            try JSONEncoder().encode(value).write(to: settingsURL, options: .atomic)
        } catch {
            if let newImageURL { try? FileManager.default.removeItem(at: newImageURL) }
            throw error
        }
        // Remove the previous upload only after both the new PNG and settings are committed.
        if let oldName = previous.overlayFile, oldName != value.overlayFile {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(oldName))
        }
        return value
    }
}
