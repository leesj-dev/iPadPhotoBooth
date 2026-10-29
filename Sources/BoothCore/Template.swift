import Foundation

public enum PhotoFraming {
    public static let aspectRatio: Double = 4.0 / 3.0
    public static let layoutVersion = 4
    public static let outputScale: Double = 25.0 / 6.0
    public static let previewMaxPixel = 3200
}

public struct PhotoSlot: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct PhotoTemplate: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
    public let backgroundHex: String
    public let textHex: String
    public let caption: String
    public let overlayFile: String?
    public let photoBleed: Double?
    public let slots: [PhotoSlot]

    public func replacingOverlay(with filename: String) -> PhotoTemplate {
        PhotoTemplate(id: id, name: name, width: width, height: height,
                      backgroundHex: backgroundHex, textHex: textHex, caption: caption,
                      overlayFile: filename, photoBleed: photoBleed, slots: slots)
    }

    public func validate() throws {
        guard !id.isEmpty, width >= 300, height >= 300, width <= 6000, height <= 6000,
              slots.count == 4, validHex(backgroundHex), validHex(textHex),
              photoBleed.map({ $0.isFinite && $0 >= 0 && $0 <= 10 }) ?? true,
              overlayFile.map(BoothSession.safeFilename) ?? true,
              slots.allSatisfy({
                  [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite)
                  && $0.x >= 0 && $0.y >= 0 && $0.width > 0 && $0.height > 0
                  && $0.x + $0.width <= 1 && $0.y + $0.height <= 1
              }) else { throw BoothError.invalidPacket("템플릿 좌표·크기·색상 오류") }
    }

    private func validHex(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

/// Pure deadline policy: never compress a countdown to catch up after a late transfer.
public enum CaptureCadence {
    public static let count = 8
    public static let interval: Double = 10

    public static func remaining(now: Double, deadline: Double) throws -> Double {
        guard now <= deadline + 0.25 else {
            throw BoothError.unavailable("JPEG 수신이 10초 촬영 간격을 넘겼습니다. 저장된 사진은 보존했습니다. 재개하면 새 카운트다운으로 시작합니다.")
        }
        return max(0, deadline - now)
    }
}
