import Foundation

public enum BoothError: Error, LocalizedError, Equatable, Sendable {
    case invalidPacket(String)
    case response(UInt16)
    case unavailable(String)
    case uncertainCapture(String)
    case exposureNotStarted(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPacket(let message), .unavailable(let message), .uncertainCapture(let message), .exposureNotStarted(let message): message
        case .response(let code): String(format: "카메라 PTP 응답 오류: 0x%04X", code)
        }
    }
}

public struct BinaryReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0
    public var remaining: Int { bytes.count - offset }

    public init(_ data: Data) { bytes = Array(data) }

    public mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw BoothError.invalidPacket("잘린 PTP 데이터") }
        offset += count
    }

    public mutating func integer(_ width: Int) throws -> UInt64 {
        guard (1...8).contains(width), width <= remaining else {
            throw BoothError.invalidPacket("잘린 PTP 정수")
        }
        var value: UInt64 = 0
        for i in 0..<width { value |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += width
        return value
    }

    public mutating func string() throws -> String {
        let count = Int(try integer(1))
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        for _ in 0..<count { units.append(UInt16(try integer(2))) }
        guard units.last == 0 else { throw BoothError.invalidPacket("PTP 문자열 종결자 없음") }
        return String(decoding: units.dropLast(), as: UTF16.self)
    }

    public mutating func wordArray() throws -> Set<UInt16> {
        let count = Int(try integer(4))
        guard count <= remaining / 2 else { throw BoothError.invalidPacket("PTP 배열 길이 오류") }
        var values: Set<UInt16> = []
        for _ in 0..<count { values.insert(UInt16(try integer(2))) }
        return values
    }
}

public enum PTP {
    public static func littleEndian(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    public static func command(_ opcode: UInt16, parameters: [UInt32], transaction: UInt32 = 0) -> Data {
        precondition(parameters.count <= 5)
        var data = littleEndian(UInt64(12 + parameters.count * 4), width: 4)
        data += littleEndian(1, width: 2)
        data += littleEndian(UInt64(opcode), width: 2)
        data += littleEndian(UInt64(transaction), width: 4)
        for p in parameters { data += littleEndian(UInt64(p), width: 4) }
        return data
    }

    public static func validateResponse(_ data: Data) throws {
        var reader = BinaryReader(data)
        let length = Int(try reader.integer(4))
        guard length == data.count, length >= 12, length <= 32, (length - 12) % 4 == 0,
              try reader.integer(2) == 3 else {
            throw BoothError.invalidPacket("잘못된 PTP 응답 컨테이너")
        }
        let code = UInt16(try reader.integer(2))
        guard code == 0x2001 else { throw BoothError.response(code) }
    }
}

public enum SonyLiveView {
    /// Sony V3 regions may include alignment bytes after the JPEG's EOI marker.
    public static func jpeg(from packet: Data) throws -> Data {
        guard packet.count >= 4, packet.count <= 8_000_000 else {
            throw BoothError.invalidPacket("라이브뷰 프레임 크기가 올바르지 않습니다.")
        }
        var reader = BinaryReader(packet)
        let bytes = reader.bytes
        if bytes.starts(with: [0xFF, 0xD8]) {
            return packet.subdata(in: try completeJPEG(in: bytes, region: 0..<bytes.count))
        }
        guard packet.count >= 16 else { throw BoothError.invalidPacket("라이브뷰 헤더가 잘렸습니다.") }
        let offset = Int(try reader.integer(4))
        let size = Int(try reader.integer(4))
        guard offset >= 16, offset <= packet.count, size >= 4, size <= packet.count - offset else {
            throw BoothError.invalidPacket("라이브뷰 JPEG 범위가 잘렸습니다.")
        }
        do {
            return packet.subdata(in: try completeJPEG(in: bytes, region: offset..<(offset + size)))
        } catch {
            // Only structural lengths are exposed, never frame bytes or embedded image metadata.
            throw BoothError.invalidPacket("\(error.localizedDescription) [전체 \(packet.count)B · 시작 \(offset) · 영역 \(size)B]")
        }
    }

    private static func completeJPEG(in bytes: [UInt8], region: Range<Int>) throws -> Range<Int> {
        var start = region.lowerBound
        // Search only within the declared image region: Sony metadata can contain a false SOI.
        while start + 1 < region.upperBound, !(bytes[start] == 0xFF && bytes[start + 1] == 0xD8) { start += 1 }
        guard start + 1 < region.upperBound else { throw BoothError.invalidPacket("라이브뷰 영역에 JPEG 시작이 없습니다.") }
        var cursor = start + 2
        var sawFrame = false
        var sawScan = false
        while cursor < region.upperBound {
            guard bytes[cursor] == 0xFF else { throw BoothError.invalidPacket("라이브뷰 JPEG 마커가 올바르지 않습니다.") }
            while cursor < region.upperBound, bytes[cursor] == 0xFF { cursor += 1 }
            guard cursor < region.upperBound else { break }
            let marker = bytes[cursor]; cursor += 1
            if marker == 0xD9 {
                guard sawFrame, sawScan else { throw BoothError.invalidPacket("라이브뷰 JPEG의 영상 구간이 없습니다.") }
                return start..<cursor
            }
            guard marker != 0, marker != 0xD8 else { throw BoothError.invalidPacket("라이브뷰 JPEG 마커 순서 오류") }
            if marker == 1 || (0xD0...0xD7).contains(marker) { continue }
            guard region.upperBound - cursor >= 2 else { break }
            let length = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
            guard length >= 2, length <= region.upperBound - cursor else {
                throw BoothError.invalidPacket("라이브뷰 JPEG 세그먼트가 잘렸습니다.")
            }
            // Skip APP/EXIF/COM segments by length so nested thumbnails cannot terminate the outer JPEG.
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) { sawFrame = true }
            cursor += length
            if marker == 0xDA {
                sawScan = true
                while cursor + 1 < region.upperBound {
                    if bytes[cursor] != 0xFF { cursor += 1; continue }
                    var next = cursor + 1
                    while next < region.upperBound, bytes[next] == 0xFF { next += 1 }
                    guard next < region.upperBound else { break }
                    if bytes[next] == 0 || (0xD0...0xD7).contains(bytes[next]) { cursor = next + 1; continue }
                    break // The outer loop handles EOI, another scan, or a segment between scans.
                }
            }
        }
        throw BoothError.invalidPacket("라이브뷰 JPEG의 끝이 없습니다. 수신이 잘렸는지 확인하세요.")
    }
}

public struct PTPDeviceInfo: Sendable {
    public let manufacturer: String
    public let model: String
    public let firmware: String
    public let operations: Set<UInt16>

    public init(data: Data) throws {
        var reader = BinaryReader(data)
        try reader.skip(8) // StandardVersion, VendorExtensionID, VendorExtensionVersion
        _ = try reader.string()
        try reader.skip(2) // FunctionalMode
        operations = try reader.wordArray()
        for _ in 0..<4 { _ = try reader.wordArray() }
        manufacturer = try reader.string()
        model = try reader.string()
        firmware = try reader.string()
        // Deliberately do not retain/log the serial number.
    }
}

public struct PTPObjectInfo: Sendable {
    public let format: UInt16
    public let byteCount: Int
    public let filename: String

    public init(data: Data) throws {
        var reader = BinaryReader(data)
        try reader.skip(4)
        format = UInt16(try reader.integer(2))
        try reader.skip(2)
        byteCount = Int(try reader.integer(4))
        try reader.skip(40)
        filename = try reader.string()
        guard format == 0x3801, byteCount > 4, byteCount <= 80_000_000 else {
            throw BoothError.unavailable("JPEG 전용·Original 전송으로 설정하세요. 지원하지 않는 촬영 파일입니다.")
        }
    }

    public func validateJPEG(_ data: Data) throws {
        guard data.count == byteCount, data.starts(with: [0xFF, 0xD8]),
              data.suffix(2) == Data([0xFF, 0xD9]) else {
            throw BoothError.invalidPacket("JPEG 수신 길이 또는 파일 끝이 잘렸습니다. 원본을 확인하세요.")
        }
    }
}
