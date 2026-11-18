import Foundation

public struct FeatureSearchResponse: Sendable {
    public let results: [SearchResult]
    public let total: Int
    public let clues: [SearchResult]
    public let notes: [String]
}

/// Executes only literal searches over already-parsed evidence. Model output never becomes executable code.
public enum FeatureSearchEngine {
    private struct Field {
        let text: String
        let normalized: String
        let source: String
        let weight: Int
        init(_ text: String, _ source: String, _ weight: Int) {
            self.text = text; normalized = normalize(text); self.source = source; self.weight = weight
        }
    }
    private struct Concept {
        let role: FeatureConcept.Role
        let terms: [(literal: String, normalized: String, generic: Bool)]
    }
    private static let broadTerms: Set<String> = ["step", "steps", "count", "sport", "health", "walk", "run", "data", "get", "set", "运动", "健康"]
    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    private static func precedes(_ a: SearchResult, _ b: SearchResult) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.title != b.title { return a.title < b.title }
        return a.id < b.id
    }

    public static func search(_ analyses: [BinaryAnalysis], plan: FeatureSearchPlan, limit: Int = 20) throws -> FeatureSearchResponse {
        _ = try plan.validated()
        let concepts = plan.concepts.map { concept in
            Concept(role: concept.role, terms: concept.terms.map { ($0, normalize($0), broadTerms.contains(normalize($0))) }.filter { !$0.normalized.isEmpty })
        }
        func evaluate(_ fields: [Field], genericMethod: Bool = false) -> (score: Int, evidence: [String])? {
            var total = 0, core = false, coreDirect = false, hits: [(Int, String)] = []
            var coreConcepts = 0
            for concept in concepts {
                var matches: [(Int, String, Int)] = []
                for field in fields {
                    var best: (Int, String)?
                    for term in concept.terms where field.normalized.contains(term.normalized) {
                        let specificity = term.generic ? 45 : 100
                        let value = field.weight * specificity / 100
                        if best == nil || value > best!.0 { best = (value, term.literal) }
                    }
                    if let best {
                        let excerpt = String(field.text.replacingOccurrences(of: "\n", with: " ↵ ").prefix(160))
                        matches.append((best.0, "\(field.source)「\(excerpt)」含「\(best.1)」", field.weight))
                    }
                }
                matches.sort { $0.0 > $1.0 }
                guard let best = matches.first else { continue }
                switch concept.role {
                case .feature:
                    core = true; coreConcepts += 1; coreDirect = coreDirect || best.2 >= 90
                    total += best.0
                    hits.append((best.0, best.1))
                    // Corroboration across evidence sources; repeating the same string does not stack scores.
                    if let independent = matches.first(where: { $0.2 != best.2 && $0.2 >= 90 }) {
                        total += independent.0 / 3; hits.append((independent.0, independent.1))
                    }
                case .action: total += best.0 / 2; hits.append((best.0 / 2, best.1))
                case .context: total += min(16, best.0 / 5); hits.append((min(16, best.0 / 5), best.1))
                case .hint: total += min(22, best.0 / 4); hits.append((min(22, best.0 / 4), best.1))
                }
            }
            guard core else { return nil }
            if coreConcepts > 1 { total += min(45, (coreConcepts - 1) * 15) }
            if !coreDirect { total = min(total, 60) }
            if genericMethod { total = max(1, total - 45) }
            hits.sort { $0.0 > $1.0 }
            var seen = Set<String>()
            let evidence = hits.map(\.1).filter { seen.insert($0).inserted }.prefix(8)
            return (total, Array(evidence))
        }
        var results: [SearchResult] = [], clues: [SearchResult] = []
        var identities = Set<String>()
        var total = 0, iteration = 0
        func trim() { if results.count > 2000 { results.sort(by: precedes); results = Array(results.prefix(1000)) } }
        let genericNames: Set<String> = ["init", "dealloc", "load", "initialize", "viewDidLoad", "viewWillAppear:", "description", ".cxx_destruct", "layoutSubviews", "hash", "class"]
        for analysis in analyses {
            try Task.checkCancellation()
            let byFunction = Dictionary(grouping: analysis.references.filter { $0.function != 0 }, by: \.function)
            let methods = analysis.methods
            var names = [UInt64: String]()
            for method in methods { names[method.address] = method.signature }
            for symbol in analysis.symbols where !symbol.isImported && names[symbol.address] == nil { names[symbol.address] = symbol.name }
            func fields(name: String, className: String?, address: UInt64) -> [Field] {
                var fields = [Field(name, "\(className == nil ? "函数" : "方法")名", 120)]
                if let className { fields.append(Field(className, "所属类", 30)) }
                let refs = byFunction[address] ?? []
                var labels = Set<String>()
                for ref in refs where ref.kind != .call {
                    if labels.insert(ref.kind.rawValue + ref.label).inserted {
                        fields.append(Field(ref.label, ref.kind == .string ? "直接引用字符串" : "装载 Selector（非调用证明）", ref.kind == .string ? 110 : 95))
                    }
                }
                for call in refs.lazy.filter({ $0.kind == .call }).prefix(8) {
                    let target = names[call.target] ?? call.label
                    fields.append(Field(target, "直接 BL 目标", 50))
                    for ref in (byFunction[call.target] ?? []).lazy.filter({ $0.kind != .call }).prefix(8) {
                        fields.append(Field(ref.label, "一层 BL 目标 \(String(target.prefix(100))) 的\(ref.kind == .string ? "字符串" : "Selector")", 40))
                    }
                }
                return fields
            }
            func append(id: String, kind: ResultKind, title: String, subtitle: String, address: UInt64,
                        candidateFields: [Field], generic: Bool, payload: ResultPayload) throws {
                iteration += 1
                if iteration % 256 == 0 { try Task.checkCancellation() }
                guard let match = evaluate(candidateFields, genericMethod: generic) else { return }
                let identity = analysis.image.id + "|" + kind.rawValue + "|" + id
                guard identities.insert(identity).inserted else { return }
                total += 1
                results.append(SearchResult(id: identity, imageID: analysis.image.id,
                                            imageName: analysis.image.name, kind: kind, title: title, subtitle: subtitle, address: address,
                                            evidence: match.evidence, score: match.score, payload: payload))
                trim()
            }
            var knownAddresses = Set<UInt64>()
            for method in methods {
                knownAddresses.insert(method.address)
                try append(id: method.id, kind: .method, title: method.signature, subtitle: method.className, address: method.address,
                           candidateFields: fields(name: method.selector, className: method.className, address: method.address),
                           generic: genericNames.contains(method.selector), payload: .method(method))
            }
            for symbol in analysis.symbols where !symbol.isImported && symbol.address != 0 {
                guard knownAddresses.insert(symbol.address).inserted else { continue }
                try append(id: symbol.id, kind: .symbol, title: symbol.name, subtitle: symbol.isSwift ? "Swift 函数" : "本地符号", address: symbol.address,
                           candidateFields: fields(name: symbol.name, className: nil, address: symbol.address), generic: false, payload: .symbol(symbol))
            }
            for address in byFunction.keys.sorted() where address != 0 && !knownAddresses.contains(address) {
                let name = "sub_" + String(address, radix: 16)
                let symbol = BinarySymbol(rawName: name, name: name, address: address, isImported: false, isSwift: false)
                try append(id: symbol.id, kind: .symbol, title: name, subtitle: "未恢复名称的函数 · 地址来自静态引用归属", address: address,
                           candidateFields: fields(name: "", className: nil, address: address), generic: false, payload: .symbol(symbol))
            }
            for string in analysis.strings {
                iteration += 1
                if iteration % 1024 == 0 { try Task.checkCancellation() }
                guard let match = evaluate([Field(string.value, "字符串", 110)]) else { continue }
                clues.append(SearchResult(id: analysis.image.id + "|string|" + string.id, imageID: analysis.image.id, imageName: analysis.image.name,
                                          kind: .string, title: string.value, subtitle: "字符串线索 · 尚不证明某方法实现了此功能", address: string.address,
                                          evidence: match.evidence, score: match.score, payload: .string(string)))
                if clues.count > 64 { clues.sort(by: precedes); clues = Array(clues.prefix(8)) }
            }
        }
        results.sort(by: precedes); clues.sort(by: precedes)
        let warnings = analyses.flatMap(\.warnings)
        var notes = ["仅覆盖当前范围中已分析的 \(analyses.count) 个 Mach-O；静态线索不等于运行时验证。",
                     "一层调用线索每个函数最多取前 8 个直接 BL 目标及各自前 8 条引用；不解析动态派发。"]
        if !warnings.isEmpty { notes.append("有 \(warnings.count) 条解析范围提示，详见各文件概览。") }
        if total == 0 && !clues.isEmpty { notes.append("发现文本线索，但未关联到候选函数；可以从下方线索继续查看静态引用。") }
        return FeatureSearchResponse(results: Array(results.prefix(max(0, min(limit, 1000)))), total: total, clues: Array(clues.prefix(8)), notes: notes)
    }
}
