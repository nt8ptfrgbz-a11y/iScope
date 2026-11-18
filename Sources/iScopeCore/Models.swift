import Foundation

public enum ScopeError: LocalizedError {
    case invalid(String)
    case tool(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .tool(let message): return message }
    }
}

public struct BinaryImage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let relativePath: String
    public let size: UInt64
    public let architectures: [String]
    public let isMainExecutable: Bool
    public var name: String { url.lastPathComponent }

    public init(url: URL, relativePath: String, size: UInt64, architectures: [String], isMainExecutable: Bool) {
        self.id = relativePath
        self.url = url
        self.relativePath = relativePath
        self.size = size
        self.architectures = architectures
        self.isMainExecutable = isMainExecutable
    }
}

public struct ImportedArtifact: Sendable {
    public let sourceURL: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let images: [BinaryImage]
    public let temporaryDirectory: URL?
}

public struct MachSection: Codable, Hashable, Sendable {
    public let segment: String
    public let name: String
    public let address: UInt64
    public let size: UInt64
    /// Relative to the selected architecture, not the universal file.
    public let fileOffset: UInt64
    public let flags: UInt32
    public var qualifiedName: String { "\(segment),\(name)" }
}

public struct ObjCMethod: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(className):\(isClassMethod ? "+" : "-"):\(selector):\(address)" }
    public let className: String
    public let selector: String
    public let typeEncoding: String
    public let address: UInt64
    public let fileOffset: UInt64?
    public let isClassMethod: Bool
    public var signature: String { "\(isClassMethod ? "+" : "-")[\(className) \(selector)]" }
}

public struct ObjCProperty: Codable, Hashable, Sendable {
    public let name: String
    public let attributes: String
}

public struct ObjCClass: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(name):\(address)" }
    public let name: String
    public let superclass: String?
    public let address: UInt64
    public let methods: [ObjCMethod]
    public let properties: [ObjCProperty]
    public let protocols: [String]
    public let isCategory: Bool
}

public struct BinarySymbol: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(address):\(rawName)" }
    public let rawName: String
    public var name: String
    public let address: UInt64
    public let isImported: Bool
    public let isSwift: Bool
}

public struct BinaryString: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(address):\(section)" }
    public let value: String
    public let address: UInt64
    public let section: String
}

public struct CodeReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case string, selector, call }
    public let instruction: UInt64
    public let target: UInt64
    public let function: UInt64
    public let kind: Kind
    public let label: String
}

public struct BinaryAnalysis: Codable, Sendable {
    public let image: BinaryImage
    public let architecture: String
    public let uuid: String?
    public let encrypted: Bool
    public let imageBase: UInt64
    public let sliceOffset: UInt64
    public let sections: [MachSection]
    public let classes: [ObjCClass]
    public let symbols: [BinarySymbol]
    public let strings: [BinaryString]
    public let references: [CodeReference]
    public let dependencies: [String]
    public let warnings: [String]
    public let elapsed: Double

    public var methods: [ObjCMethod] { classes.flatMap(\.methods) }
    public func name(forFunction address: UInt64) -> String {
        if let method = classes.lazy.flatMap(\.methods).first(where: { $0.address == address }) { return method.signature }
        if let symbol = symbols.first(where: { !$0.isImported && $0.address == address }) { return symbol.name }
        return "sub_\(String(address, radix: 16))"
    }
}

public extension UInt64 {
    var hex: String { "0x" + String(self, radix: 16).uppercased() }
}
