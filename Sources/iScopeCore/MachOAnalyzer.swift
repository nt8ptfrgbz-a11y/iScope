import Foundation

public enum MachOAnalyzer {
    public static func analyze(_ image: BinaryImage, architecture: String? = nil) throws -> BinaryAnalysis {
        let started = Date()
        let data = try Data(contentsOf: image.url, options: .mappedIfSafe)
        let slices = try MachContainer.slices(data)
        let slice: MachSlice
        if let architecture {
            guard let match = slices.first(where: { $0.name == architecture }) else { throw ScopeError.invalid("该文件不包含 \(architecture) 架构。") }
            slice = match
        } else {
            slice = slices.first(where: { $0.name == "arm64" }) ?? slices.first(where: { $0.name == "arm64e" }) ?? slices[0]
        }
        let parser = try MachParser(data: data, slice: slice)
        try parser.parse()
        return BinaryAnalysis(image: image, architecture: slice.name, uuid: parser.uuid, encrypted: parser.encrypted,
                              imageBase: parser.imageBase, sliceOffset: UInt64(slice.offset), sections: parser.sections,
                              classes: parser.classes, symbols: parser.symbols, strings: parser.strings,
                              references: parser.references, dependencies: parser.dependencies,
                              warnings: parser.warnings, elapsed: Date().timeIntervalSince(started))
    }
}

private final class MachParser {
    struct Segment { let address: UInt64; let size: UInt64; let file: UInt64; let fileSize: UInt64 }
    enum Pointer { case address(UInt64), bind(String) }
    let r: BinaryReader
    let slice: MachSlice
    var sections: [MachSection] = []
    var segments: [Segment] = []
    var imageBase: UInt64 = 0
    var uuid: String?
    var encrypted = false
    var classes: [ObjCClass] = []
    var symbols: [BinarySymbol] = []
    var strings: [BinaryString] = []
    var references: [CodeReference] = []
    var dependencies: [String] = []
    var warnings: [String] = []
    var pointers: [Int: Pointer] = [:]
    var symbolCommand: Int?
    var fixups: (Int, Int)?
    var functionStarts: (Int, Int)?
    var starts: [UInt64] = []
    var classNames: [UInt64: String] = [:]
    var symbolsAt: [UInt64: String] = [:]
    var fileSections: [MachSection] { sections.filter { ![UInt32(1), 0xc, 0x12].contains($0.flags & 0xff) } }

    init(data: Data, slice: MachSlice) throws {
        self.slice = slice
        let basic = try BinaryReader(data: data, base: slice.offset, count: slice.size)
        let magic = try basic.u32(0)
        guard magic == 0xfeedfacf else {
            throw ScopeError.invalid("当前支持 little-endian 64 位 Mach-O（arm64 / arm64e / x86_64）。请选择对应架构。")
        }
        r = basic
    }

    func parse() throws {
        try parseCommands()
        try Task.checkCancellation()
        if let fixups {
            do { try parseFixups(fixups.0, size: fixups.1) }
            catch is CancellationError { throw CancellationError() }
            catch { warnings.append("部分 chained fixups 无法解析：\(error.localizedDescription)") }
        }
        try parseSymbols()
        if encrypted {
            warnings.append("检测到 cryptid ≠ 0。此文件仍有加密标记，未解析加密区的类和方法；请导入正确脱壳的文件。")
            return
        }
        try parseClasses()
        try parseStrings()
        try parseFunctionStarts()
        if slice.cpu == 0x0100000c { try parseARM64References() }
        else { warnings.append("字符串与调用引用扫描仅支持 arm64 / arm64e；此架构仍可浏览类、方法、字符串和符号。") }
        if classes.isEmpty { warnings.append("没有可恢复的 Objective-C 类元数据。纯 Swift、Flutter、Unity 或混淆产物可能只保留部分符号与字符串。") }
        warnings.append("静态引用只覆盖可解析的 ARM64 地址装载与直接 BL 调用；动态派发、间接调用和运行时拼接字符串可能缺失。")
    }

    func parseCommands() throws {
        let count = Int(try r.u32(16)), size = Int(try r.u32(20))
        guard count <= 65_536, r.contains(32, size) else { throw ScopeError.invalid("Mach-O load commands 越界。") }
        var cursor = 32
        for _ in 0..<count {
            try Task.checkCancellation()
            guard r.contains(cursor, 8), cursor + 8 <= 32 + size else { throw ScopeError.invalid("Load command 截断。") }
            let command = try r.u32(cursor), length = Int(try r.u32(cursor + 4))
            guard length >= 8, length % 4 == 0, length <= 32 + size - cursor else { throw ScopeError.invalid("Load command 长度无效。") }
            switch command {
            case 0x19: // LC_SEGMENT_64
                guard length >= 72 else { throw ScopeError.invalid("Segment 截断。") }
                let address = try r.u64(cursor + 24), vmSize = try r.u64(cursor + 32)
                let file = try r.u64(cursor + 40), fileSize = try r.u64(cursor + 48)
                guard file <= UInt64(r.count), fileSize <= UInt64(r.count) - file, vmSize <= UInt64.max - address else { throw ScopeError.invalid("Segment 范围无效。") }
                segments.append(Segment(address: address, size: vmSize, file: file, fileSize: fileSize))
                if file == 0 && fileSize > 0 { imageBase = address }
                let sectionCount = Int(try r.u32(cursor + 64))
                guard sectionCount <= (length - 72) / 80 else { throw ScopeError.invalid("Section 表截断。") }
                for index in 0..<sectionCount {
                    let offset = cursor + 72 + index * 80
                    let flags = try r.u32(offset + 64)
                    let section = MachSection(segment: try r.fixedString(offset + 16, size: 16), name: try r.fixedString(offset, size: 16),
                                              address: try r.u64(offset + 32), size: try r.u64(offset + 40), fileOffset: UInt64(try r.u32(offset + 48)), flags: flags)
                    guard section.size <= UInt64.max - section.address else { throw ScopeError.invalid("Section 虚拟地址溢出。") }
                    let type = flags & 0xff
                    if ![UInt32(1), 0xc, 0x12].contains(type) {
                        guard section.fileOffset <= UInt64(r.count), section.size <= UInt64(r.count) - section.fileOffset else { throw ScopeError.invalid("Section 数据越界。") }
                    }
                    sections.append(section)
                }
            case 0x2: guard length >= 24 else { throw ScopeError.invalid("符号表命令截断。") }; symbolCommand = cursor
            case 0x1b:
                guard length >= 24 else { throw ScopeError.invalid("UUID 命令截断。") }
                let bytes = (0..<16).map { r.data[r.base + cursor + 8 + $0] }
                uuid = [bytes[0..<4], bytes[4..<6], bytes[6..<8], bytes[8..<10], bytes[10..<16]].map { $0.map { String(format: "%02X", $0) }.joined() }.joined(separator: "-")
            case 0x21, 0x2c:
                guard length >= 20 else { throw ScopeError.invalid("加密信息命令截断。") }
                let cryptid = try r.u32(cursor + 16)
                encrypted = encrypted || cryptid != 0
            case 0x80000034:
                guard length >= 16 else { throw ScopeError.invalid("Fixups 命令截断。") }
                fixups = (Int(try r.u32(cursor + 8)), Int(try r.u32(cursor + 12)))
            case 0x26:
                guard length >= 16 else { throw ScopeError.invalid("函数边界命令截断。") }
                functionStarts = (Int(try r.u32(cursor + 8)), Int(try r.u32(cursor + 12)))
            case 0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023:
                guard length >= 24 else { throw ScopeError.invalid("动态库命令截断。") }
                let nameOffset = Int(try r.u32(cursor + 8))
                if nameOffset >= 24, nameOffset < length, let name = r.string(cursor + nameOffset, limit: length - nameOffset) { dependencies.append(name) }
            default: break
            }
            cursor += length
        }
        guard cursor == 32 + size else { throw ScopeError.invalid("Load commands 总长度不一致。") }
    }

    func offset(_ address: UInt64) -> Int? {
        guard address != 0 else { return nil }
        for segment in segments where address >= segment.address {
            let delta = address - segment.address
            if delta < segment.fileSize, segment.file <= UInt64(r.count), delta < UInt64(r.count) - segment.file {
                return Int(segment.file + delta)
            }
        }
        return nil
    }

    func pointer(_ fileOffset: Int) throws -> UInt64 {
        if let value = pointers[fileOffset] {
            switch value { case .address(let address): return address; case .bind: return 0 }
        }
        let value = try r.u64(fileOffset)
        if value == 0 || offset(value) != nil { return value }
        // Strip top-byte / PAC bits only if that produces an address in this image.
        for mask: UInt64 in [0x0000ffffffffffff, 0x0000000fffffffff] {
            if offset(value & mask) != nil { return value & mask }
        }
        return value
    }

    func text(at address: UInt64) -> String? { offset(address).flatMap { r.string($0) } }
    func boundName(_ fileOffset: Int) -> String? { if case .bind(let name) = pointers[fileOffset] { return name }; return nil }

    func parseFixups(_ base: Int, size: Int) throws {
        guard size >= 28, r.contains(base, size), try r.u32(base) == 0 else { throw ScopeError.invalid("不支持的 chained fixups 头。") }
        let startsOffset = Int(try r.u32(base + 4)), importsOffset = Int(try r.u32(base + 8)), symbolsOffset = Int(try r.u32(base + 12))
        let importCount = Int(try r.u32(base + 16)), format = try r.u32(base + 20)
        guard startsOffset <= size - 4, symbolsOffset <= size, importCount <= 2_000_000, try r.u32(base + 24) == 0 else { throw ScopeError.invalid("Fixups 范围或符号压缩格式不支持。") }
        let importStride = format == 1 ? 4 : format == 2 ? 8 : format == 3 ? 16 : 0
        guard importStride > 0 || importCount == 0, importsOffset <= size, importCount * importStride <= size - importsOffset else { throw ScopeError.invalid("Fixups imports 无效。") }
        var imports: [String] = []
        for index in 0..<importCount {
            let entry = base + importsOffset + index * importStride
            let nameOffset = format == 3 ? UInt64(try r.u32(entry + 4)) : UInt64(try r.u32(entry) >> 9)
            if nameOffset < UInt64(size - symbolsOffset), let name = r.string(base + symbolsOffset + Int(nameOffset), limit: size - symbolsOffset - Int(nameOffset)) { imports.append(name) }
            else { imports.append("") }
        }
        let startsBase = base + startsOffset
        let count = Int(try r.u32(startsBase))
        guard count <= segments.count, count <= (size - startsOffset - 4) / 4 else { throw ScopeError.invalid("Fixups segment 表越界。") }
        var unsupported = Set<UInt16>()
        for index in 0..<count {
            let relative = Int(try r.u32(startsBase + 4 + index * 4))
            if relative == 0 { continue }
            guard relative <= size - startsOffset - 22 else { throw ScopeError.invalid("Fixups starts 越界。") }
            let info = startsBase + relative
            let infoSize = Int(try r.u32(info)), pageSize = Int(try r.u16(info + 4)), pointerFormat = try r.u16(info + 6)
            let segmentOffset = try r.u64(info + 8), pageCount = Int(try r.u16(info + 20))
            guard infoSize >= 22, infoSize <= base + size - info, pageSize > 0, pageCount <= (infoSize - 22) / 2 else { throw ScopeError.invalid("Fixups 页面表无效。") }
            guard [UInt16(1), 2, 6, 7, 9, 12].contains(pointerFormat) else { unsupported.insert(pointerFormat); continue }
            for page in 0..<pageCount {
                try Task.checkCancellation()
                let pageStart = try r.u16(info + 22 + page * 2)
                if pageStart == 0xffff { continue }
                var chains: [Int] = []
                if pageStart & 0x8000 == 0 { chains = [Int(pageStart)] }
                else {
                    var overflow = Int(pageStart & 0x7fff)
                    while 22 + overflow * 2 + 2 <= infoSize {
                        let value = try r.u16(info + 22 + overflow * 2)
                        chains.append(Int(value & 0x7fff)); overflow += 1
                        if value & 0x8000 != 0 { break }
                    }
                }
                let pageDelta = UInt64(page * pageSize)
                guard segmentOffset <= UInt64.max - imageBase, pageDelta <= UInt64.max - imageBase - segmentOffset else { continue }
                let pageAddress = imageBase + segmentOffset + pageDelta
                for chain in chains {
                    var position = chain
                    var visited = 0
                    while position >= 0, position <= pageSize - 8, visited <= pageSize / 4 {
                        guard UInt64(position) <= UInt64.max - pageAddress, let file = offset(pageAddress + UInt64(position)) else { break }
                        let raw = try r.u64(file)
                        let next: Int, stride: Int
                        let binding: Bool, ordinal: Int, target: UInt64
                        if pointerFormat == 2 || pointerFormat == 6 {
                            next = Int((raw >> 51) & 0xfff); stride = 4
                            binding = raw >> 63 != 0; ordinal = Int(raw & 0xffffff)
                            let low = raw & 0xfffffffff
                            target = pointerFormat == 6 ? imageBase &+ low : low | (((raw >> 36) & 0xff) << 56)
                        } else {
                            next = Int((raw >> 51) & 0x7ff); stride = pointerFormat == 7 ? 4 : 8
                            binding = (raw >> 62) & 1 != 0
                            ordinal = Int(raw & (pointerFormat == 12 ? 0xffffff : 0xffff))
                            if raw >> 63 != 0 { target = imageBase &+ (raw & 0xffffffff) }
                            else {
                                let low = raw & 0x7ffffffffff
                                target = pointerFormat == 1 ? low | (((raw >> 43) & 0xff) << 56) : imageBase &+ low
                            }
                        }
                        pointers[file] = binding ? .bind(ordinal < imports.count ? imports[ordinal] : "") : .address(target)
                        if next == 0 { break }
                        position += next * stride; visited += 1
                    }
                }
            }
        }
        if !unsupported.isEmpty { warnings.append("存在暂不支持的 chained pointer 格式：\(unsupported.sorted().map(String.init).joined(separator: ", "))；部分元数据可能缺失。") }
    }

    func parseSymbols() throws {
        guard let command = symbolCommand else { return }
        let table = Int(try r.u32(command + 8)), count = Int(try r.u32(command + 12))
        let stringTable = Int(try r.u32(command + 16)), stringSize = Int(try r.u32(command + 20))
        guard count <= 5_000_000, r.contains(table, count * 16), r.contains(stringTable, stringSize) else { throw ScopeError.invalid("符号表范围无效。") }
        for index in 0..<count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            let entry = table + index * 16, nameOffset = Int(try r.u32(entry))
            let type = r.data[r.base + entry + 4]
            guard type & 0xe0 == 0, nameOffset > 0, nameOffset < stringSize,
                  let name = r.string(stringTable + nameOffset, limit: min(16384, stringSize - nameOffset)), !name.isEmpty else { continue }
            let address = try r.u64(entry + 8), imported = type & 0x0e == 0
            symbols.append(BinarySymbol(rawName: name, name: name, address: address, isImported: imported, isSwift: name.hasPrefix("_$s") || name.hasPrefix("$s") || name.hasPrefix("__T") || name.hasPrefix("_$S")))
            if !imported && address != 0 { symbolsAt[address] = name }
        }
        let swiftIndices = symbols.indices.filter { symbols[$0].isSwift }
        if !swiftIndices.isEmpty {
            for batchStart in stride(from: 0, to: swiftIndices.count, by: 2000) {
                try Task.checkCancellation()
                let indices = Array(swiftIndices[batchStart..<min(batchStart + 2000, swiftIndices.count)])
                let input = indices.map { symbols[$0].rawName }.joined(separator: "\n") + "\n"
                do {
                    let demangled = try ProcessRunner.run("/usr/bin/xcrun", ["swift-demangle", "--compact"], input: Data(input.utf8))
                    let lines = demangled.split(separator: "\n", omittingEmptySubsequences: false)
                    if lines.count >= indices.count { for (index, line) in zip(indices, lines) { symbols[index].name = String(line) } }
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.append("Swift 符号还原不可用，请安装 Xcode Command Line Tools。原始符号仍可搜索。"); break }
            }
        }
    }

    func className(at address: UInt64) -> String? {
        if let cached = classNames[address] { return cached }
        guard let file = offset(address), r.contains(file, 40), let ro = try? pointer(file + 32), let info = offset(ro & ~UInt64(7)),
              r.contains(info, 72), let namePointer = try? pointer(info + 24), let name = text(at: namePointer), !name.isEmpty else { return nil }
        classNames[address] = name
        return name
    }

    func externalClass(at file: Int) -> String? {
        boundName(file)?.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "").replacingOccurrences(of: "_OBJC_METACLASS_$_", with: "")
    }

    func parseClasses() throws {
        var seen = Set<UInt64>()
        var failed = 0
        for section in fileSections where section.name == "__objc_classlist" || section.name == "__objc_nlclslist" {
            for index in 0..<Int(section.size / 8) {
                if index % 256 == 0 { try Task.checkCancellation() }
                let address = try pointer(Int(section.fileOffset) + index * 8)
                guard address != 0, seen.insert(address).inserted else { continue }
                guard let file = offset(address), let name = className(at: address), let roValue = try? pointer(file + 32), let ro = offset(roValue & ~UInt64(7)) else { failed += 1; continue }
                let superclass = try pointer(file + 8)
                var methods = try methodList(try pointer(ro + 32), className: name, isClass: false)
                let isa = try pointer(file)
                if let meta = offset(isa), r.contains(meta, 40), let metaROValue = try? pointer(meta + 32), let metaRO = offset(metaROValue & ~UInt64(7)), r.contains(metaRO, 72) {
                    methods += try methodList(try pointer(metaRO + 32), className: name, isClass: true)
                }
                classes.append(ObjCClass(name: name, superclass: className(at: superclass) ?? externalClass(at: file + 8), address: address,
                                         methods: methods.sorted { $0.signature < $1.signature }, properties: try propertyList(try pointer(ro + 64)),
                                         protocols: try protocolList(try pointer(ro + 40)), isCategory: false))
            }
        }
        seen.removeAll()
        for section in fileSections where section.name == "__objc_catlist" || section.name == "__objc_nlcatlist" {
            for index in 0..<Int(section.size / 8) {
                if index % 256 == 0 { try Task.checkCancellation() }
                let address = try pointer(Int(section.fileOffset) + index * 8)
                guard address != 0, seen.insert(address).inserted, let file = offset(address), r.contains(file, 48), let category = text(at: try pointer(file)) else { continue }
                let owner = className(at: try pointer(file + 8)) ?? externalClass(at: file + 8) ?? "UnknownClass"
                let name = "\(owner)(\(category))"
                let methods = try methodList(try pointer(file + 16), className: name, isClass: false) + methodList(try pointer(file + 24), className: name, isClass: true)
                classes.append(ObjCClass(name: name, superclass: owner, address: address, methods: methods.sorted { $0.signature < $1.signature }, properties: try propertyList(try pointer(file + 40)), protocols: try protocolList(try pointer(file + 32)), isCategory: true))
            }
        }
        classes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if failed > 0 { warnings.append("\(failed) 个类记录无法恢复，可能使用了当前未支持的元数据布局。") }
    }

    func relativeAddress(_ field: Int) throws -> UInt64? {
        guard let segment = segments.first(where: { UInt64(field) >= $0.file && UInt64(field) - $0.file < $0.fileSize }) else { return nil }
        let address = segment.address + UInt64(field) - segment.file
        let delta = Int64(try r.i32(field))
        if delta >= 0 { return address <= UInt64.max - UInt64(delta) ? address + UInt64(delta) : nil }
        return address >= UInt64(-delta) ? address - UInt64(-delta) : nil
    }

    func methodList(_ address: UInt64, className: String, isClass: Bool) throws -> [ObjCMethod] {
        guard address != 0, let file = offset(address), r.contains(file, 8) else { return [] }
        let flags = try r.u32(file), count = Int(try r.u32(file + 4))
        let small = flags & 0x80000000 != 0, direct = flags & 0x40000000 != 0
        let stride = Int(flags & 0x0000fffc)
        guard stride >= (small ? 12 : 24), count <= 1_000_000, r.contains(file + 8, count * stride) else {
            warnings.append("\(className) 的方法列表布局不受支持。"); return []
        }
        var methods: [ObjCMethod] = []
        for index in 0..<count {
            if index % 1024 == 0 { try Task.checkCancellation() }
            let entry = file + 8 + index * stride
            let name: UInt64, types: UInt64, implementation: UInt64
            if small {
                guard let nameRef = try relativeAddress(entry), let typeRef = try relativeAddress(entry + 4), let imp = try relativeAddress(entry + 8) else { continue }
                if direct { name = nameRef }
                else { guard let nameOffset = offset(nameRef) else { continue }; name = try pointer(nameOffset) }
                types = typeRef; implementation = imp
            } else { name = try pointer(entry); types = try pointer(entry + 8); implementation = try pointer(entry + 16) }
            guard let selector = text(at: name), !selector.isEmpty else { continue }
            methods.append(ObjCMethod(className: className, selector: selector, typeEncoding: text(at: types) ?? "", address: implementation,
                                      fileOffset: offset(implementation).map { UInt64($0 + slice.offset) }, isClassMethod: isClass))
        }
        return methods
    }

    func propertyList(_ address: UInt64) throws -> [ObjCProperty] {
        guard let file = offset(address), r.contains(file, 8) else { return [] }
        let stride = Int(try r.u32(file)), count = Int(try r.u32(file + 4))
        guard stride >= 16, stride <= 4096, count <= 100_000, r.contains(file + 8, count * stride) else { return [] }
        return try (0..<count).compactMap { index in
            let entry = file + 8 + index * stride
            guard let name = text(at: try pointer(entry)), let attributes = text(at: try pointer(entry + 8)) else { return nil }
            return ObjCProperty(name: name, attributes: attributes)
        }
    }

    func protocolList(_ address: UInt64) throws -> [String] {
        guard let file = offset(address), r.contains(file, 8) else { return [] }
        let count = try r.u64(file)
        guard count <= 100_000, r.contains(file + 8, Int(count) * 8) else { return [] }
        return try (0..<Int(count)).compactMap { index in
            guard let proto = offset(try pointer(file + 8 + index * 8)), r.contains(proto, 16) else { return nil }
            return text(at: try pointer(proto + 8))
        }
    }

    func parseStrings() throws {
        let names: Set<String> = ["__cstring", "__objc_methname", "__objc_classname", "__objc_methtype", "__swift5_reflstr"]
        for section in fileSections where names.contains(section.name) || section.flags & 0xff == 2 {
            let base = Int(section.fileOffset), end = base + Int(section.size)
            var cursor = base
            while cursor < end {
                if strings.count >= 500_000 { warnings.append("字符串数量超过 500,000，已停止字符串索引；类和方法未截断。"); return }
                if (cursor - base) % 4096 == 0 { try Task.checkCancellation() }
                var next = cursor
                while next < end && r.data[r.base + next] != 0 { next += 1 }
                if next > cursor, next < end, next - cursor <= 16_384,
                   let value = String(data: r.data.subdata(in: (r.base + cursor)..<(r.base + next)), encoding: .utf8),
                   value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
                    strings.append(BinaryString(value: value, address: section.address + UInt64(cursor - base), section: section.qualifiedName))
                }
                cursor = next + 1
            }
        }
    }

    func parseFunctionStarts() throws {
        if let (base, size) = functionStarts {
            guard r.contains(base, size) else { throw ScopeError.invalid("函数边界数据越界。") }
            var cursor = base, address = imageBase
            while cursor < base + size {
                let delta = try r.uleb(&cursor, end: base + size)
                if delta == 0 { break }
                guard delta <= UInt64.max - address else { throw ScopeError.invalid("函数边界溢出。") }
                address += delta; starts.append(address)
            }
        } else { warnings.append("缺少 LC_FUNCTION_STARTS；部分引用的所属函数仅能根据已知方法和符号边界推定。") }
        starts += classes.flatMap(\.methods).map(\.address).filter { $0 > 0 }
        let code = fileSections.filter { $0.name == "__text" }
        starts += symbols.filter { symbol in !symbol.isImported && code.contains { symbol.address >= $0.address && symbol.address - $0.address < $0.size } }.map(\.address)
        starts = Array(Set(starts)).sorted()
    }

    func parseARM64References() throws {
        var targets: [UInt64: (CodeReference.Kind, String, UInt64)] = [:]
        for string in strings where !string.section.contains("methtype") && !string.section.contains("classname") {
            targets[string.address] = (string.section.contains("methname") ? .selector : .string, string.value, string.address)
        }
        for section in fileSections where section.name == "__cfstring" {
            for index in 0..<Int(section.size / 32) {
                if index % 1024 == 0 { try Task.checkCancellation() }
                let file = Int(section.fileOffset) + index * 32
                let chars = try pointer(file + 16)
                if let target = targets[chars] { targets[section.address + UInt64(index * 32)] = target }
                else {
                    // Constant CFStrings with the UTF-16 flag are not in __cstring.
                    let flags = try r.u64(file + 8), length = try r.u64(file + 24)
                    if strings.count < 500_000, flags & 0x10 != 0, length > 0, length <= 8192, let bytes = offset(chars), r.contains(bytes, Int(length) * 2),
                       let value = String(data: r.data.subdata(in: (r.base + bytes)..<(r.base + bytes + Int(length) * 2)), encoding: .utf16LittleEndian) {
                        strings.append(BinaryString(value: value, address: chars, section: section.qualifiedName))
                        let target: (CodeReference.Kind, String, UInt64) = (.string, value, chars)
                        targets[chars] = target; targets[section.address + UInt64(index * 32)] = target
                    }
                }
            }
        }
        for section in fileSections where section.name == "__objc_selrefs" {
            for index in 0..<Int(section.size / 8) {
                let pointer = try pointer(Int(section.fileOffset) + index * 8)
                if let name = text(at: pointer) { targets[section.address + UInt64(index * 8)] = (.selector, name, pointer) }
            }
        }
        var functionNames = symbolsAt
        for method in classes.flatMap(\.methods) { functionNames[method.address] = method.signature }
        var dedup = Set<CodeReference>()
        for section in fileSections where section.name == "__text" {
            var registers: [Int: UInt64] = [:]
            var currentFunction: UInt64 = 0, nextStart = 0
            for cursor in stride(from: 0, to: Int(section.size) - 3, by: 4) {
                if cursor % 16384 == 0 { try Task.checkCancellation() }
                let pc = section.address + UInt64(cursor), file = Int(section.fileOffset) + cursor
                while nextStart < starts.count && starts[nextStart] <= pc {
                    currentFunction = starts[nextStart]; nextStart += 1; registers.removeAll(keepingCapacity: true)
                }
                guard currentFunction >= section.address else { continue }
                let instruction = try r.u32(file), rd = Int(instruction & 31), rn = Int((instruction >> 5) & 31)
                func record(_ address: UInt64) {
                    guard let target = targets[address] else { return }
                    dedup.insert(CodeReference(instruction: pc, target: target.2, function: currentFunction, kind: target.0, label: target.1))
                }
                func signed(_ value: UInt64, bits: Int) -> Int64 { Int64(bitPattern: value << (64 - bits)) >> (64 - bits) }
                if instruction & 0x9f000000 == 0x90000000 { // ADRP
                    let immediate = (UInt64((instruction >> 5) & 0x7ffff) << 2) | UInt64((instruction >> 29) & 3)
                    registers[rd] = (pc & ~UInt64(0xfff)) &+ UInt64(bitPattern: signed(immediate, bits: 21) << 12)
                } else if instruction & 0x9f000000 == 0x10000000 { // ADR
                    let immediate = (UInt64((instruction >> 5) & 0x7ffff) << 2) | UInt64((instruction >> 29) & 3)
                    let target = pc &+ UInt64(bitPattern: signed(immediate, bits: 21))
                    registers[rd] = target; record(target)
                } else if instruction & 0xff800000 == 0x91000000 { // 64-bit ADD immediate
                    if let base = registers[rn], rn != 31 {
                        let immediate = UInt64((instruction >> 10) & 0xfff) << (instruction & 0x400000 == 0 ? 0 : 12)
                        let target = base &+ immediate; registers[rd] = target; record(target)
                    } else { registers[rd] = nil }
                } else if instruction & 0xffc00000 == 0xf9400000 { // LDR Xt, [Xn, #imm]
                    if let base = registers[rn], rn != 31 {
                        let address = base &+ UInt64((instruction >> 10) & 0xfff) * 8
                        record(address)
                        if let targetFile = offset(address), r.contains(targetFile, 8) { let value = try pointer(targetFile); registers[rd] = value; record(value) }
                        else { registers[rd] = nil }
                    } else { registers[rd] = nil }
                } else if instruction & 0xff000000 == 0x58000000 { // LDR literal, 64-bit
                    let address = pc &+ UInt64(bitPattern: signed(UInt64((instruction >> 5) & 0x7ffff), bits: 19) << 2)
                    record(address)
                    if let targetFile = offset(address), r.contains(targetFile, 8) { let value = try pointer(targetFile); registers[rd] = value; record(value) }
                    else { registers[rd] = nil }
                } else if instruction & 0xfc000000 == 0x94000000 { // BL; caller-saved registers become unknown.
                    let target = pc &+ UInt64(bitPattern: signed(UInt64(instruction & 0x03ffffff), bits: 26) << 2)
                    dedup.insert(CodeReference(instruction: pc, target: target, function: currentFunction, kind: .call, label: functionNames[target] ?? "sub_\(String(target, radix: 16))"))
                    for register in 0...18 { registers[register] = nil }
                    registers[30] = nil
                } else if instruction & 0x7c000000 == 0x14000000 || instruction & 0xff000010 == 0x54000000 || instruction & 0x7e000000 == 0x34000000 || instruction & 0x7e000000 == 0x36000000 || instruction & 0xfe000000 == 0xd6000000 {
                    registers.removeAll(keepingCapacity: true)
                } else if instruction & 0xffe0ffe0 == 0xaa0003e0 { // MOV Xd, Xm
                    registers[rd] = registers[Int((instruction >> 16) & 31)]
                } else {
                    // Be conservative after an unmodelled instruction: stale register values create false references.
                    registers.removeAll(keepingCapacity: true)
                }
                if dedup.count >= 1_000_000 { warnings.append("静态引用超过 1,000,000，已停止扫描。"); break }
            }
        }
        references = dedup.sorted { $0.instruction == $1.instruction ? $0.target < $1.target : $0.instruction < $1.instruction }
    }
}
