import UIKit
import ImageIO
import CryptoKit
import BoothCore

enum LiveViewRotation: Int, CaseIterable, Identifiable {
    case original = 0, portraitLeft = 1, portraitRight = 2
    var id: Int { rawValue }

    static func load(from defaults: UserDefaults = .standard) -> LiveViewRotation {
        let key = "liveViewRotation"
        let migration = "liveViewLandscapeDefaultApplied"
        if !defaults.bool(forKey: migration) {
            defaults.set(LiveViewRotation.original.rawValue, forKey: key)
            defaults.set(true, forKey: migration)
        }
        return (defaults.object(forKey: key) as? Int).flatMap(LiveViewRotation.init(rawValue:)) ?? .original
    }
    var name: String {
        switch self {
        case .portraitLeft: "세로 (왼쪽 회전)"
        case .portraitRight: "세로 (오른쪽 회전)"
        case .original: "원본 방향"
        }
    }
}

enum PhotoRenderer {
    static func liveViewImage(_ data: Data, rotation: LiveViewRotation = .original) -> UIImage? {
        guard let image = thumbnail(data: data, maxPixel: 1280) else { return nil }
        // ImageIO already applies EXIF. Only rotate an otherwise-landscape preview:
        // no unverified Sony orientation byte is inferred from the PTP header.
        if rotation != .original, image.size.width > image.size.height, let cg = image.cgImage {
            return centerCrop(UIImage(cgImage: cg, scale: image.scale, orientation: rotation == .portraitLeft ? .left : .right))
        }
        return centerCrop(image)
    }
    static func validate(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 600, height >= 600, width <= 16000, height <= 16000,
              thumbnail(data: data, maxPixel: 1200) != nil else {
            throw BoothError.invalidPacket("수신 JPEG를 디코딩할 수 없거나 해상도가 너무 작습니다.")
        }
    }

    static func validateOverlay(_ data: Data) throws {
        guard data.count <= CustomizationStore.maxOverlayBytes,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 1800, height >= 1200, width <= 15000, height <= 10000,
              width * height <= 75_000_000, width * 2 == height * 3,
              properties[kCGImagePropertyHasAlpha] as? Bool == true,
              thumbnail(data: data, maxPixel: 1800) != nil else {
            throw BoothError.unavailable("사진 칸이 투명한 가로 3:2 PNG를 선택하세요. 최소 1800×1200px, 최대 40MB입니다.")
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func thumbnail(url: URL, maxPixel: Int = 700) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    private static func thumbnail(data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    private static func thumbnail(source: CGImageSource, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                       kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Display the same central 4:3 region as the print slots; never rewrite source JPEGs.
    static func framedThumbnail(url: URL, maxPixel: Int = 700) -> UIImage? {
        thumbnail(url: url, maxPixel: maxPixel).map { centerCrop($0) }
    }

    static func aspectFillRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        let ratio = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func centerCrop(_ image: UIImage) -> UIImage {
        let units = max(1, floor(min(image.size.width / 4, image.size.height / 3)))
        let size = CGSize(width: units * 4, height: units * 3)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: aspectFillRect(imageSize: image.size, bounds: CGRect(origin: .zero, size: size)))
        }
    }

    static func compose(session: BoothSession, store: SessionStore, template: PhotoTemplate, overlayDirectory: URL? = nil) throws -> Data {
        try template.validate()
        guard session.selection.count == 4 else { throw BoothError.unavailable("사진 4장을 골라 주세요.") }
        let images = try session.selection.map { id -> UIImage in
            guard let shot = session.shots.first(where: { $0.id == id }),
                  let image = thumbnail(url: try store.file(shot.file, in: session), maxPixel: 4000) else {
                throw BoothError.unavailable("선택한 사진을 읽을 수 없습니다.")
            }
            return image
        }
        var overlay: UIImage?
        if let filename = template.overlayFile {
            guard let url = overlayDirectory?.appendingPathComponent(filename)
                    ?? Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "Templates"),
                  let loaded = UIImage(contentsOfFile: url.path) else {
                throw BoothError.unavailable("템플릿 오버레이 파일이 없습니다: \(filename)")
            }
            overlay = loaded
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let size = CGSize(width: template.width, height: template.height)
        let outputSize = CGSize(width: (Double(template.width) * PhotoFraming.outputScale).rounded(),
                                height: (Double(template.height) * PhotoFraming.outputScale).rounded())
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let result = renderer.image { context in
            context.cgContext.scaleBy(x: outputSize.width / size.width, y: outputSize.height / size.height)
            UIColor(hex: template.backgroundHex).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (slot, image) in zip(template.slots, images) {
                let rect = CGRect(x: slot.x * size.width, y: slot.y * size.height,
                                  width: slot.width * size.width, height: slot.height * size.height)
                // Extend beneath the overlay to cover subpixel Illustrator export differences.
                let bleed = overlay == nil ? 0 : CGFloat(template.photoBleed ?? 0)
                let photoRect = rect.insetBy(dx: -bleed * rect.width / rect.height, dy: -bleed)
                context.cgContext.saveGState()
                context.cgContext.clip(to: photoRect)
                image.draw(in: aspectFillRect(imageSize: image.size, bounds: photoRect))
                context.cgContext.restoreGState()
            }
            if overlay == nil {
                let landscape = size.width > size.height
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = landscape ? .left : .center
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size.width * (landscape ? 0.04 : 0.034), weight: .medium),
                                                           .foregroundColor: UIColor(hex: template.textHex), .paragraphStyle: paragraph]
                let captionRect = landscape
                    ? CGRect(x: size.width * 0.84, y: size.height * 0.12, width: size.width * 0.12, height: size.height * 0.6)
                    : CGRect(x: 40, y: size.height * 0.91, width: size.width - 80, height: size.height * 0.07)
                (template.caption as NSString).draw(in: captionRect, withAttributes: attrs)
                if landscape {
                    let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size.width * 0.012, weight: .medium),
                                                               .foregroundColor: UIColor(hex: template.textHex)]
                    ("PHOTO BOOTH" as NSString).draw(at: CGPoint(x: size.width * 0.84, y: size.height * 0.84), withAttributes: small)
                }
            }
            overlay?.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = result.jpegData(compressionQuality: 0.96) else { throw BoothError.unavailable("합성 JPEG 생성 실패") }
        return data
    }

    static func demoJPEG(index: Int) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900), format: format).image { ctx in
            UIColor(hue: CGFloat(index) / 10, saturation: 0.2, brightness: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 80, weight: .semibold), .foregroundColor: UIColor.darkGray]
            let label = "DEMO  \(index + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: (1200 - size.width) / 2, y: (900 - size.height) / 2), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
