import Foundation

public enum ResultKind: String, Codable, CaseIterable, Sendable {
    case method, classInfo, string, symbol
    public var title: String {
        switch self { case .method: return "方法"; case .classInfo: return "类"; case .string: return "字符串"; case .symbol: return "符号" }
    }
    public var icon: String {
        switch self { case .method: return "function"; case .classInfo: return "square.stack.3d.up"; case .string: return "text.quote"; case .symbol: return "number" }
    }
}

public enum ResultPayload: Sendable {
    case method(ObjCMethod), classInfo(ObjCClass), string(BinaryString), symbol(BinarySymbol)
}

public struct SearchResult: Identifiable, Sendable {
    public let id: String
    public let imageID: String
    public let imageName: String
    public let kind: ResultKind
    public let title: String
    public let subtitle: String
    public let address: UInt64
    public let evidence: [String]
    public let score: Int
    public let payload: ResultPayload
}

public struct SearchOptions: Sendable {
    public var caseSensitive = false
    public var regularExpression = false
    public var expandFeatureWords = true
    public init() {}
}

public struct SearchResponse: Sendable {
    public let results: [SearchResult]
    public let total: Int
    public let expandedTerms: [String]
}

public enum SearchEngine {
    public static let featureWords: [String: [String]] = [
        "登录": ["login", "signin", "signIn", "authenticate", "authentication", "oauth"],
        "注册": ["register", "signup", "signUp", "registration"],
        "支付": ["pay", "payment", "purchase", "checkout", "transaction", "iap"],
        "会员": ["vip", "premium", "subscription", "membership", "subscribe"],
        "消息": ["message", "chat", "conversation", "inbox"],
        "搜索": ["search", "query", "lookup"],
        "下载": ["download", "cache", "offline"],
        "上传": ["upload", "multipart"],
        "分享": ["share", "forward"],
        "相机": ["camera", "capture", "AVCapture"],
        "定位": ["location", "CLLocation", "geocode"],
        "直播": ["live", "stream", "broadcast"],
        "视频": ["video", "player", "playback", "AVPlayer"],
        "订单": ["order", "checkout", "receipt"],
        "设置": ["settings", "preferences", "configuration"]
    ]

    public static func search(_ analyses: [BinaryAnalysis], query: String, kind: ResultKind? = nil,
                              options: SearchOptions = SearchOptions(), limit: Int = 1000, bookmarked: Set<String>? = nil) throws -> SearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex: NSRegularExpression?
        if options.regularExpression && !query.isEmpty {
            do { regex = try NSRegularExpression(pattern: query, options: options.caseSensitive ? [] : [.caseInsensitive]) }
            catch { throw ScopeError.invalid("正则表达式无效：\(error.localizedDescription)") }
        } else { regex = nil }
        let tokens = options.regularExpression ? (query.isEmpty ? [] : [query]) : query.split(whereSeparator: \.isWhitespace).map(String.init)
        let groups: [[String]] = tokens.map { token in
            options.expandFeatureWords && !options.regularExpression ? [token] + (featureWords[token] ?? []) : [token]
        }
        let expanded = options.expandFeatureWords && !options.regularExpression ? tokens.flatMap { featureWords[$0] ?? [] } : []
        func matches(_ text: String, _ group: [String]) -> Bool {
            if let regex { return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            return group.contains { text.range(of: $0, options: options.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var results: [SearchResult] = []
        var iteration = 0
        for analysis in analyses {
            let byFunction = Dictionary(grouping: analysis.references, by: \.function)
            let byTarget = Dictionary(grouping: analysis.references, by: \.target)
            func append(id: String, kind: ResultKind, title: String, subtitle: String, address: UInt64, fields: [(String, String, Int)], payload: ResultPayload) throws {
                iteration += 1
                if iteration % 1024 == 0 { try Task.checkCancellation() }
                let identity = analysis.image.id + "|" + kind.rawValue + "|" + id
                if let bookmarked, !bookmarked.contains(identity) { return }
                var evidence: [String] = [], score = 0
                for group in groups {
                    let matching = fields.filter { matches($0.0, group) }
                    guard let best = matching.max(by: { $0.2 < $1.2 }) else { return }
                    score += best.2
                    if !evidence.contains(best.1) { evidence.append(best.1) }
                }
                results.append(SearchResult(id: identity, imageID: analysis.image.id, imageName: analysis.image.name, kind: kind, title: title, subtitle: subtitle, address: address,
                                            evidence: evidence, score: score, payload: payload))
            }
            if kind == nil || kind == .method {
                for cls in analysis.classes {
                    for method in cls.methods {
                        let refs = byFunction[method.address] ?? []
                        let strings = refs.filter { $0.kind == .string }.map(\.label).joined(separator: "\n")
                        let selectors = refs.filter { $0.kind == .selector }.map(\.label).joined(separator: "\n")
                        try append(id: method.id, kind: .method, title: method.signature, subtitle: cls.name, address: method.address,
                                   fields: [(method.selector, "方法名命中", 120), (cls.name, "所属类命中", 75), (method.address.hex, "方法地址命中", 130),
                                            (strings, "方法引用的字符串命中", 110), (selectors, "方法装载的 Selector 命中", 90)], payload: .method(method))
                    }
                }
            }
            if kind == nil || kind == .classInfo {
                for cls in analysis.classes {
                    try append(id: cls.id, kind: .classInfo, title: cls.name, subtitle: "\(cls.methods.count) 个方法 · \(cls.superclass ?? "未解析父类")", address: cls.address,
                               fields: [(cls.name, "类名命中", 115), (cls.methods.map(\.selector).joined(separator: "\n"), "类中的方法名命中", 65),
                                        (cls.properties.map(\.name).joined(separator: "\n"), "属性名命中", 60), (cls.protocols.joined(separator: " "), "协议名命中", 55)], payload: .classInfo(cls))
                }
            }
            if kind == nil || kind == .string {
                for string in analysis.strings {
                    let count = byTarget[string.address]?.count ?? 0
                    try append(id: string.id, kind: .string, title: string.value, subtitle: "\(string.section) · \(count) 处静态引用", address: string.address,
                               fields: [(string.value, "字符串内容命中", 100), (string.address.hex, "字符串地址命中", 130)], payload: .string(string))
                }
            }
            if kind == nil || kind == .symbol {
                for symbol in analysis.symbols {
                    let refs = symbol.isImported ? [] : byFunction[symbol.address] ?? []
                    try append(id: symbol.id, kind: .symbol, title: symbol.name, subtitle: symbol.isImported ? "外部导入符号" : symbol.isSwift ? "Swift 符号" : "本地符号", address: symbol.address,
                               fields: [(symbol.name, "符号名称命中", 105), (symbol.rawName, "原始符号命中", 100), (symbol.address.hex, "符号地址命中", 130),
                                        (refs.filter { $0.kind == .string }.map(\.label).joined(separator: "\n"), "函数引用的字符串命中", 110)], payload: .symbol(symbol))
                }
                // Preserve address-derived functions in navigation and bookmarks, even without a symbol-table name.
                let namedAddresses = Set(analysis.methods.map(\.address) + analysis.symbols.filter { !$0.isImported }.map(\.address))
                for address in byFunction.keys.sorted() where address != 0 && !namedAddresses.contains(address) {
                    let name = "sub_" + String(address, radix: 16)
                    let symbol = BinarySymbol(rawName: name, name: name, address: address, isImported: false, isSwift: false)
                    let refs = byFunction[address] ?? []
                    try append(id: symbol.id, kind: .symbol, title: name, subtitle: "未恢复名称的函数 · 地址来自静态引用归属", address: address,
                               fields: [(name, "函数地址标签命中", 105), (address.hex, "函数地址命中", 130),
                                        (refs.filter { $0.kind == .string }.map(\.label).joined(separator: "\n"), "函数引用的字符串命中", 110)], payload: .symbol(symbol))
                }
            }
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.title != rhs.title { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
            return lhs.id < rhs.id
        }
        return SearchResponse(results: Array(results.prefix(max(0, limit))), total: results.count, expandedTerms: expanded)
    }
}
