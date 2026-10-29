import Foundation

public struct Shot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let file: String
    public let capturedAt: Date
    public let sourceName: String
    public let byteCount: Int
    public let transferSeconds: Double
    public let digest: String

    public init(id: UUID, index: Int, file: String, sourceName: String, byteCount: Int,
                transferSeconds: Double, digest: String) {
        self.id = id; self.index = index; self.file = file; self.sourceName = sourceName
        self.byteCount = byteCount; self.transferSeconds = transferSeconds; self.digest = digest
        capturedAt = Date()
    }
}

public struct PendingShot: Codable, Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let requestedAt: Date
    public init(index: Int) { id = UUID(); self.index = index; requestedAt = Date() }
}

public enum PrintState: String, Codable, Sendable {
    case notSent, presenting, submitted, cancelled, failed, uncertain
}

public struct BoothSession: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var isDemo: Bool
    public private(set) var shots: [Shot] = []
    public private(set) var selection: [UUID] = []
    public var pendingShot: PendingShot?
    public var templateID = "ivory"
    public var compositeFile: String?
    public var compositeLayoutVersion: Int?
    public var compositeCustomizationRevision: String?
    public var printState: PrintState = .notSent

    public init(isDemo: Bool = false) { id = UUID(); createdAt = Date(); self.isDemo = isDemo }

    public mutating func append(_ shot: Shot) throws {
        guard shots.count < 8, shot.index == shots.count, !shots.contains(where: { $0.id == shot.id }),
              pendingShot?.id == shot.id, pendingShot?.index == shot.index else {
            throw BoothError.unavailable("촬영 영수증 또는 저장 순서가 일치하지 않습니다.")
        }
        shots.append(shot)
        pendingShot = nil
        invalidateComposite()
    }

    public mutating func toggle(_ id: UUID) {
        guard shots.contains(where: { $0.id == id }) else { return }
        if let index = selection.firstIndex(of: id) { selection.remove(at: index) }
        else if selection.count < 4 { selection.append(id) }
        invalidateComposite()
    }

    public mutating func invalidateComposite() { compositeFile = nil; compositeLayoutVersion = nil; compositeCustomizationRevision = nil; printState = .notSent }

    public func validate() throws {
        guard shots.count <= 8, Set(shots.map(\.id)).count == shots.count,
              shots.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              selection.count <= 4, Set(selection).count == selection.count,
              selection.allSatisfy({ id in shots.contains(where: { $0.id == id }) }),
              pendingShot == nil || (pendingShot?.index == shots.count && shots.count < 8),
              shots.allSatisfy({ Self.safeFilename($0.file) }),
              compositeFile.map(Self.safeFilename) ?? true else {
            throw BoothError.invalidPacket("저장된 세션 계약이 손상되었습니다.")
        }
    }

    public static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}

/// Metadata is committed only after the image has been atomically written.
/// An interrupted transfer leaves a pending receipt, never a silently repeated exposure.
public struct SessionStore {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    public func directory(for session: BoothSession) -> URL { root.appendingPathComponent(session.id.uuidString) }

    public func file(_ name: String, in session: BoothSession) throws -> URL {
        guard BoothSession.safeFilename(name) else { throw BoothError.invalidPacket("안전하지 않은 파일명") }
        return directory(for: session).appendingPathComponent(name)
    }

    public func save(_ session: BoothSession) throws {
        try session.validate()
        let folder = directory(for: session)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        try Data(session.id.uuidString.utf8).write(to: root.appendingPathComponent("current"), options: .atomic)
    }

    public func load() throws -> BoothSession? {
        let pointer = root.appendingPathComponent("current")
        guard fm.fileExists(atPath: pointer.path) else { return nil }
        let text = String(decoding: try Data(contentsOf: pointer), as: UTF8.self)
        guard let id = UUID(uuidString: text) else { throw BoothError.invalidPacket("세션 포인터 손상") }
        let folder = root.appendingPathComponent(id.uuidString)
        let data = try Data(contentsOf: folder.appendingPathComponent("session.json"))
        var session = try JSONDecoder().decode(BoothSession.self, from: data)
        try session.validate()
        guard session.id == id else { throw BoothError.invalidPacket("세션 id 불일치") }
        for shot in session.shots {
            let attributes = try fm.attributesOfItem(atPath: file(shot.file, in: session).path)
            guard (attributes[.size] as? NSNumber)?.intValue == shot.byteCount else {
                throw BoothError.invalidPacket("저장된 JPEG가 없거나 잘렸습니다.")
            }
        }
        if session.printState == .presenting { session.printState = .uncertain }
        if let composite = session.compositeFile, !fm.fileExists(atPath: try file(composite, in: session).path) {
            session.compositeFile = nil
        }
        return session
    }

    public func saveImage(_ data: Data, name: String, session: BoothSession) throws -> URL {
        let folder = directory(for: session)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try file(name, in: session)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func delete(_ session: BoothSession) throws {
        let directory = directory(for: session)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        let pointer = root.appendingPathComponent("current")
        if fm.fileExists(atPath: pointer.path),
           String(decoding: try Data(contentsOf: pointer), as: UTF8.self) == session.id.uuidString {
            try fm.removeItem(at: pointer)
        }
    }
}
