import Foundation

public struct SonyProperty: Sendable {
    public let code: UInt16
    public let type: UInt16
    public let writable: Bool
    public let current: UInt64?
}

/// Sony PTP-V3 descriptors. Unknown types/forms are rejected, never skipped by guessing offsets.
public enum SonyProperties {
    public static func decode(_ data: Data) throws -> [UInt16: SonyProperty] {
        var r = BinaryReader(data)
        let count = Int(try r.integer(4))
        try r.skip(4)
        guard count <= 4096 else { throw BoothError.invalidPacket("Sony 속성 개수 오류") }
        var result: [UInt16: SonyProperty] = [:]
        for _ in 0..<count {
            let code = UInt16(try r.integer(2))
            let type = UInt16(try r.integer(2))
            let getSet = try r.integer(1)
            let enabled = try r.integer(1)
            _ = try value(type, reader: &r)
            let current = try value(type, reader: &r)
            let form = try r.integer(1)
            switch form {
            case 0: break
            case 1:
                for _ in 0..<3 { _ = try value(type, reader: &r) }
            case 2:
                // V3 has supported and selectable enumerations, as in the inspected iOS sample.
                for _ in 0..<2 {
                    let n = Int(try r.integer(2))
                    guard n <= 16384 else { throw BoothError.invalidPacket("Sony enum 크기 오류") }
                    for _ in 0..<n { _ = try value(type, reader: &r) }
                }
            default: throw BoothError.invalidPacket("미지원 Sony 속성 form \(form)")
            }
            guard result[code] == nil else { throw BoothError.invalidPacket("Sony 속성 중복") }
            result[code] = SonyProperty(code: code, type: type, writable: getSet == 1 && enabled == 1, current: current)
        }
        guard r.remaining == 0 else { throw BoothError.invalidPacket("Sony V3 속성 길이 불일치") }
        return result
    }

    private static func value(_ type: UInt16, reader r: inout BinaryReader) throws -> UInt64? {
        switch type {
        case 1, 2: return try r.integer(1)
        case 3, 4: return try r.integer(2)
        case 5, 6: return try r.integer(4)
        case 7, 8: return try r.integer(8)
        case 9, 10: try r.skip(16); return nil
        case 0xFFFF: _ = try r.string(); return nil
        case 0x4001...0x400A:
            let widths = [1, 1, 2, 2, 4, 4, 8, 8, 16, 16]
            let width = widths[Int(type - 0x4001)]
            let count = Int(try r.integer(4))
            guard count <= r.remaining / width else { throw BoothError.invalidPacket("Sony 배열 잘림") }
            try r.skip(count * width)
            return nil
        default: throw BoothError.invalidPacket(String(format: "미지원 Sony 자료형 0x%04X", type))
        }
    }
}
