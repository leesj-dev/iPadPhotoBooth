import UIKit
import ImageIO
import UniformTypeIdentifiers
import BoothCore

@main struct ImageOrientationCheck {
    @MainActor static func main() throws {
        let encoder = JSONEncoder()
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(BoothSession())) as! [String: Any]
        legacy.removeValue(forKey: "compositeLayoutVersion")
        let restored = try JSONDecoder().decode(BoothSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(restored.compositeLayoutVersion == nil)
        var current = restored
        current.compositeLayoutVersion = PhotoFraming.layoutVersion
        let roundTrip = try JSONDecoder().decode(BoothSession.self, from: encoder.encode(current))
        precondition(roundTrip.compositeLayoutVersion == PhotoFraming.layoutVersion)
        current.invalidateComposite()
        precondition(current.compositeLayoutVersion == nil)
        print("PASS legacy sessions decode without a layout version and new versions round-trip")
        let uploadedOverlay = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uirimje.png"))
        try PhotoRenderer.validateOverlay(uploadedOverlay)
        do {
            try PhotoRenderer.validateOverlay(Data("not png".utf8))
            preconditionFailure("Invalid upload accepted")
        } catch is BoothError {}
        print("PASS uploaded PNG validates and invalid file is rejected")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            UIColor.green.setFill(); context.fill(CGRect(x: 30, y: 0, width: 30, height: 20))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 20, width: 30, height: 20))
            UIColor.yellow.setFill(); context.fill(CGRect(x: 30, y: 20, width: 30, height: 20))
        }
        let jpeg = landscape.jpegData(compressionQuality: 1)!
        let originalDigest = PhotoRenderer.digest(jpeg)
        let original = PhotoRenderer.liveViewImage(jpeg, rotation: .original)!
        let left = PhotoRenderer.liveViewImage(jpeg, rotation: .portraitLeft)!
        let right = PhotoRenderer.liveViewImage(jpeg, rotation: .portraitRight)!
        precondition(original.size == CGSize(width: 52, height: 39))
        precondition(left.size == CGSize(width: 40, height: 30) && left.imageOrientation == .up)
        precondition(right.size == CGSize(width: 40, height: 30) && right.imageOrientation == .up)
        precondition(left.cgImage?.width == 40 && left.cgImage?.height == 30)
        let renderedLeft = UIGraphicsImageRenderer(size: left.size, format: format).image { _ in left.draw(at: .zero) }
        let renderedRight = UIGraphicsImageRenderer(size: right.size, format: format).image { _ in right.draw(at: .zero) }
        precondition(renderedLeft.cgImage?.width == 40 && renderedLeft.cgImage?.height == 30)
        precondition(renderedLeft.pngData() != renderedRight.pngData())
        precondition(PhotoRenderer.digest(jpeg) == originalDigest)
        print("PASS live view applies rotation then 4:3 crop without changing the source JPEG")

        let tagged = NSMutableData()
        let destination = CGImageDestinationCreateWithData(tagged, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, landscape.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        for rotation in LiveViewRotation.allCases {
            let oriented = PhotoRenderer.liveViewImage(tagged as Data, rotation: rotation)!
            precondition(oriented.size == CGSize(width: 40, height: 30) && oriented.imageOrientation == .up)
        }
        let demo = PhotoRenderer.liveViewImage(PhotoRenderer.demoJPEG(index: 0))!
        precondition(demo.size == CGSize(width: 1200, height: 900) && demo.imageOrientation == .up)
        print("PASS EXIF portrait is not rotated twice and landscape demo stays landscape")
        let suite = "dev.local.ipadphotobooth.orientation-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(LiveViewRotation.load(from: defaults) == .original)
        defaults.set(LiveViewRotation.portraitLeft.rawValue, forKey: "liveViewRotation")
        precondition(LiveViewRotation.load(from: defaults) == .portraitLeft)
        for existing in [LiveViewRotation.portraitLeft, .portraitRight, .original] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(existing.rawValue, forKey: "liveViewRotation")
            precondition(LiveViewRotation.load(from: defaults) == .original)
            defaults.set(existing.rawValue, forKey: "liveViewRotation")
            precondition(LiveViewRotation.load(from: defaults) == existing)
        }
        let corrected = PhotoRenderer.liveViewImage(jpeg)!
        precondition(corrected.imageOrientation == .up && corrected.size == CGSize(width: 52, height: 39))
        print("PASS landscape default replaces prior portrait settings once and preserves later manual choices")
        precondition(AirPrinter.orientation(for: jpeg) == .landscape)
        precondition(AirPrinter.orientation(for: tagged as Data) == .portrait)
        precondition(AirPrinter.pageSize(for: .landscape) == CGSize(width: 432, height: 288))
        precondition(AirPrinter.pageSize(for: .portrait) == CGSize(width: 288, height: 432))
        print("PASS AirPrint orientation follows the actual JPEG, including EXIF portrait")
        let photo = CGSize(width: 7500, height: 5000)
        let a4 = CGSize(width: 595, height: 842)
        let postcard = CGSize(width: 288, height: 432)
        let fiveBySeven = CGSize(width: 360, height: 504)
        precondition(AirPrinter.preferredPaperIndex(paperSizes: [a4, postcard, fiveBySeven], imageSize: photo) == 1)
        precondition(AirPrinter.preferredPaperIndex(paperSizes: [a4], imageSize: photo) == 0)
        precondition(AirPrinter.preferredPaperIndex(paperSizes: [fiveBySeven], imageSize: photo) == 0)
        precondition(AirPrinter.preferredPaperIndex(paperSizes: [CGSize(width: 576, height: 864), postcard], imageSize: photo) == 1)
        precondition(AirPrinter.preferredPaperIndex(paperSizes: [postcard, a4], imageSize: CGSize(width: 5000, height: 7500)) == 0)
        precondition(AirPrinter.preferredPaperIndex(paperSizes: [], imageSize: photo) == nil)
        precondition(AirPrinter.preferredPaperIndex(paperSizes: [.zero, postcard], imageSize: photo) == 1)
        print("PASS AirPrint selects only advertised paper sizes by image aspect, including non-4×6 printers")
        let native = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        precondition(PhotoRenderer.centerCrop(native).pngData() == native.pngData())
        print("PASS native 4:3 source remains unchanged")
        try checkLandscapeComposition(format: format)
    }

    @MainActor static func checkLandscapeComposition(format: UIGraphicsImageRendererFormat) throws {
        let templates = try JSONDecoder().decode([PhotoTemplate].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("booth-landscape-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = BoothSession(isDemo: true)
        let colors: [UIColor] = [.red, .green, .blue, .yellow]
        for index in 0..<4 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { context in
                colors[index].setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
                // A 3:2 source must lose these side bands when centered into 4:3.
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 60, height: 800))
                context.fill(CGRect(x: 1140, y: 0, width: 60, height: 800))
                UIColor.black.setFill()
                context.fill(CGRect(x: 580, y: 0, width: 40, height: 24))
                context.fill(CGRect(x: 580, y: 776, width: 40, height: 24))
            }
            let data = image.jpegData(compressionQuality: 1)!
            let pending = PendingShot(index: index); session.pendingShot = pending
            let name = "\(index).jpg"; _ = try store.saveImage(data, name: name, session: session)
            let shot = Shot(id: pending.id, index: index, file: name, sourceName: name, byteCount: data.count,
                            transferSeconds: 0, digest: PhotoRenderer.digest(data))
            try session.append(shot); session.toggle(shot.id)
        }
        for template in templates {
            let result = try PhotoRenderer.compose(session: session, store: store, template: template, overlayDirectory: URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent())
            let image = UIImage(data: result)!.cgImage!
            print("Rendered JPEG: \(image.width)×\(image.height)")
            precondition(image.width == 7500 && image.height == 5000)
            let outputWidth = Double(image.width)
            let outputHeight = Double(image.height)
            precondition(AirPrinter.orientation(for: result) == .landscape)
            for (index, slot) in template.slots.enumerated() {
                for x in [0.2, 0.8] { for y in [0.2, 0.8] {
                    let pixel = sample(image, x: (slot.x + slot.width * x) * outputWidth, y: (slot.y + slot.height * y) * outputHeight)
                    let expected: [[Int]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
                    precondition(zip(pixel.prefix(3), expected[index]).allSatisfy { abs(Int($0) - $1) < 30 }, "3:2 side bands were not cropped")
                } }
                if template.overlayFile == nil { for y in [0.01, 0.99] {
                    let edge = sample(image, x: (slot.x + slot.width * 0.5) * outputWidth, y: (slot.y + slot.height * y) * outputHeight)
                    precondition(edge.prefix(3).allSatisfy { $0 < 30 }, "Crop lost the source top or bottom")
                } }
                let sourceURL = try store.file(session.shots[index].file, in: session)
                let display = PhotoRenderer.framedThumbnail(url: sourceURL, maxPixel: 1200)!
                let live = PhotoRenderer.liveViewImage(try Data(contentsOf: sourceURL))!
                precondition(display.size.width / display.size.height == 4.0 / 3.0)
                precondition(display.pngData() == live.pngData(), "Live view and selection crop differ")
                for x in [0.25, 0.5, 0.75] { for y in [0.25, 0.5, 0.75] {
                    let preview = sample(display.cgImage!, x: x * display.size.width, y: y * display.size.height)
                    let printed = sample(image, x: (slot.x + slot.width * x) * outputWidth, y: (slot.y + slot.height * y) * outputHeight)
                    precondition(zip(preview.prefix(3), printed.prefix(3)).allSatisfy { abs(Int($0) - Int($1)) < 30 }, "Preview crop differs from print")
                } }
                let center = sample(image, x: (slot.x + slot.width * 0.5) * outputWidth, y: (slot.y + slot.height * 0.25) * outputHeight)
                let expected: [[Int]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
                precondition(zip(center.prefix(3), expected[index]).allSatisfy { abs(Int($0) - $1) < 30 }, "Selection order changed")
            }
            if template.id == "ivory" { try result.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
        }
        print("PASS bundled frame crops 3:2 sources to 4:3, preserves selection order and matches preview to print")
    }

    @MainActor static func sample(_ image: CGImage, x: Double, y: Double) -> [UInt8] {
        let cropped = image.cropping(to: CGRect(x: Int(x), y: Int(y), width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }

}
