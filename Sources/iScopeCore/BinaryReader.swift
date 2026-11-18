import Foundation

struct BinaryReader {
    let data: Data
    let base: Int
    let count: Int
    let swapped: Bool

    init(data: Data, base: Int = 0, count: Int? = nil, swapped: Bool = false) throws {
        let size = count ?? (data.count - base)
        guard base >= 0, size >= 0, base <= data.count, size <= data.count - base else {
            throw ScopeError.invalid("Mach-O 数据范围无效。")
        }
        self.data = data; self.base = base; self.count = size; self.swapped = swapped
    }

    func contains(_ offset: Int, _ size: Int) -> Bool {
        offset >= 0 && size >= 0 && offset <= count && size <= count - offset
    }

    func uint<T: FixedWidthInteger & UnsignedInteger>(_ offset: Int, as: T.Type = T.self) throws -> T {
        guard contains(offset, MemoryLayout<T>.size) else { throw ScopeError.invalid("Mach-O 数据截断（偏移 \(offset)）。") }
        let value: T = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + offset, as: T.self) }
        return swapped ? T(bigEndian: value) : T(littleEndian: value)
    }

    func u16(_ offset: Int) throws -> UInt16 { try uint(offset) }
    func u32(_ offset: Int) throws -> UInt32 { try uint(offset) }
    func u64(_ offset: Int) throws -> UInt64 { try uint(offset) }
    func i32(_ offset: Int) throws -> Int32 { Int32(bitPattern: try u32(offset)) }

    func string(_ offset: Int, limit: Int = 4096) -> String? {
        guard contains(offset, 1) else { return nil }
        let end = offset + min(limit, count - offset)
        var cursor = offset
        while cursor < end && data[base + cursor] != 0 { cursor += 1 }
        guard cursor < end else { return nil }
        return String(data: data.subdata(in: (base + offset)..<(base + cursor)), encoding: .utf8)
    }

    func fixedString(_ offset: Int, size: Int) throws -> String {
        guard contains(offset, size) else { throw ScopeError.invalid("Mach-O 节名称已截断。") }
        let bytes = data[(base + offset)..<(base + offset + size)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    func uleb(_ offset: inout Int, end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard offset < end, contains(offset, 1) else { throw ScopeError.invalid("ULEB128 数据截断。") }
            let byte = data[base + offset]; offset += 1
            guard shift != 63 || byte <= 1 else { throw ScopeError.invalid("ULEB128 溢出。") }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
        }
        throw ScopeError.invalid("ULEB128 数据无效。")
    }
}

struct MachSlice {
    let offset: Int
    let size: Int
    let cpu: UInt32
    let subtype: UInt32
    var name: String {
        switch cpu {
        case 0x0100000c: return subtype & 0xff == 2 ? "arm64e" : "arm64"
        case 0x01000007: return "x86_64"
        case 12: return "arm"
        case 7: return "i386"
        default: return "cpu_\(cpu)"
        }
    }
}

enum MachContainer {
    static func slices(_ data: Data) throws -> [MachSlice] {
        let reader = try BinaryReader(data: data)
        let magic = try reader.u32(0)
        if magic == 0xfeedfacf || magic == 0xfeedface || magic == 0xcffaedfe || magic == 0xcefaedfe {
            let r = try BinaryReader(data: data, swapped: magic == 0xcffaedfe || magic == 0xcefaedfe)
            guard r.contains(0, magic == 0xfeedface || magic == 0xcefaedfe ? 28 : 32) else {
                throw ScopeError.invalid("Mach-O 文件头不完整。")
            }
            return [MachSlice(offset: 0, size: data.count, cpu: try r.u32(4), subtype: try r.u32(8))]
        }
        guard [0xbebafeca, 0xbfbafeca, 0xcafebabe, 0xcafebabf].contains(magic) else {
            throw ScopeError.invalid("不是 Mach-O 文件。")
        }
        let fat64 = magic == 0xbfbafeca || magic == 0xcafebabf
        let r = try BinaryReader(data: data, swapped: magic == 0xbebafeca || magic == 0xbfbafeca)
        let count = Int(try r.u32(4))
        let stride = fat64 ? 32 : 20
        guard count > 0, count <= 64, r.contains(8, count * stride) else { throw ScopeError.invalid("通用二进制的架构表无效。") }
        return try (0..<count).map { index in
            let entry = 8 + index * stride
            let offset = fat64 ? try r.u64(entry + 8) : UInt64(try r.u32(entry + 8))
            let size = fat64 ? try r.u64(entry + 16) : UInt64(try r.u32(entry + 12))
            guard offset <= UInt64(data.count), size <= UInt64(data.count) - offset, size >= 28 else {
                throw ScopeError.invalid("通用二进制的架构范围越界。")
            }
            return MachSlice(offset: Int(offset), size: Int(size), cpu: try r.u32(entry), subtype: try r.u32(entry + 4))
        }
    }
}
