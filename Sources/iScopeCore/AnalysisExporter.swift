import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case methods, classes, headers, strings, symbols, json, csv
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .methods: return "Objective-C 方法名列表 (.txt)"
        case .classes: return "Objective-C 类名列表 (.txt)"
        case .headers: return "Objective-C 接口草稿 (.h)"
        case .strings: return "字符串列表 (.txt)"
        case .symbols: return "符号名列表（含 Swift）(.txt)"
        case .json: return "完整分析结果 (.json)"
        case .csv: return "方法与地址 (.csv)"
        }
    }
    public var fileExtension: String {
        switch self { case .headers: return "h"; case .json: return "json"; case .csv: return "csv"; default: return "txt" }
    }
}

public enum AnalysisExporter {
    public static func data(_ analyses: [BinaryAnalysis], format: ExportFormat) throws -> Data {
        if format == .json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(analyses)
        }
        var lines: [String] = []
        if format == .csv { lines.append("image,architecture,class,kind,selector,vm_address,file_offset,type_encoding") }
        for analysis in analyses {
            if format != .csv { lines.append("// \(analysis.image.relativePath) [\(analysis.architecture)]") }
            switch format {
            case .methods: lines += analysis.methods.map(\.signature)
            case .classes: lines += analysis.classes.map(\.name)
            case .strings: lines += analysis.strings.map { "\($0.address.hex)\t\($0.value.replacingOccurrences(of: "\n", with: "\\n"))" }
            case .symbols: lines += analysis.symbols.map { "\($0.address.hex)\t\($0.name)\t\($0.rawName)" }
            case .headers: lines += analysis.classes.map(header)
            case .csv:
                lines += analysis.methods.map { method in
                    [analysis.image.relativePath, analysis.architecture, method.className, method.isClassMethod ? "+" : "-", method.selector, method.address.hex, method.fileOffset?.hex ?? "", method.typeEncoding].map(csvField).joined(separator: ",")
                }
            case .json: break
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func header(_ cls: ObjCClass) -> String {
        var lines = ["// 从 Objective-C 元数据生成的接口草稿。参数名为占位符，不能直接视为原始源码。"]
        if cls.isCategory { lines.append("@interface \(cls.name)") }
        else { lines.append("@interface \(cls.name) : \(cls.superclass ?? "NSObject /* superclass unresolved */")" + (cls.protocols.isEmpty ? "" : " <\(cls.protocols.joined(separator: ", "))>")) }
        for property in cls.properties { lines.append("// property \(property.name)   attributes: \(property.attributes)") }
        if !cls.properties.isEmpty { lines.append("") }
        for method in cls.methods { lines.append(declaration(method)) }
        lines.append("@end\n")
        return lines.joined(separator: "\n")
    }

    public static func declaration(_ method: ObjCMethod) -> String {
        let types = ObjCTypeDecoder.types(method.typeEncoding)
        let result = types.first ?? "id"
        let arguments = Array(types.dropFirst(3))
        let prefix = "\(method.isClassMethod ? "+" : "-") (\(result))"
        let count = method.selector.filter { $0 == ":" }.count
        guard count > 0 else { return prefix + method.selector + "; // " + method.address.hex }
        let parts = method.selector.split(separator: ":", omittingEmptySubsequences: false)
        let selector = (0..<count).map { index in "\(parts[index]):(\(index < arguments.count ? arguments[index] : "id"))arg\(index + 1)" }.joined(separator: " ")
        return prefix + selector + "; // " + method.address.hex
    }

    private static func csvField(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

public enum ObjCTypeDecoder {
    public static func types(_ encoding: String) -> [String] {
        let chars = Array(encoding)
        var index = 0
        func parse() -> String {
            guard index < chars.count else { return "id" }
            let char = chars[index]; index += 1
            switch char {
            case "r", "n", "N", "o", "O", "R", "V": return parse()
            case "v": return "void"
            case "@":
                if index < chars.count && chars[index] == "?" { index += 1; return "id /* block */" }
                if index < chars.count && chars[index] == "\"" {
                    index += 1; let start = index
                    while index < chars.count && chars[index] != "\"" { index += 1 }
                    let name = String(chars[start..<index]); if index < chars.count { index += 1 }
                    return name + " *"
                }
                return "id"
            case "#": return "Class"
            case ":": return "SEL"
            case "c": return "char"
            case "C": return "unsigned char"
            case "s": return "short"
            case "S": return "unsigned short"
            case "i": return "int"
            case "I": return "unsigned int"
            case "l": return "long"
            case "L": return "unsigned long"
            case "q": return "long long"
            case "Q": return "unsigned long long"
            case "f": return "float"
            case "d": return "double"
            case "B": return "BOOL"
            case "*": return "char *"
            case "^": return parse() + " *"
            case "{", "(", "[":
                let closing: Character = char == "{" ? "}" : char == "(" ? ")" : "]"
                let start = index
                while index < chars.count && chars[index] != "=" && chars[index] != closing { index += 1 }
                let name = String(chars[start..<index]); var depth = 1
                while index < chars.count && depth > 0 {
                    if chars[index] == char { depth += 1 }; if chars[index] == closing { depth -= 1 }; index += 1
                }
                return char == "[" ? "void * /* array */" : "\(char == "{" ? "struct" : "union") \(name)"
            case "b":
                while index < chars.count && chars[index].isNumber { index += 1 }
                return "unsigned int /* bitfield */"
            default: return "void * /* unknown */"
            }
        }
        var result: [String] = []
        while index < chars.count {
            if chars[index].isNumber || chars[index] == "+" || chars[index] == "-" { index += 1; continue }
            result.append(parse())
        }
        return result
    }
}
