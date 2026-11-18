import Foundation

public struct FeatureConcept: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case feature, action, context, hint }
    public let label: String
    public let role: Role
    public let terms: [String]
    public init(label: String, role: Role, terms: [String]) { self.label = label; self.role = role; self.terms = terms }
}

public struct FeatureSearchPlan: Codable, Sendable, Equatable {
    public let summary: String
    public let appContext: String
    public let action: String
    public let concepts: [FeatureConcept]
    public let cautions: [String]

    public init(summary: String, appContext: String, action: String, concepts: [FeatureConcept], cautions: [String]) {
        self.summary = summary; self.appContext = appContext; self.action = action; self.concepts = concepts; self.cautions = cautions
    }

    public func validated() throws -> FeatureSearchPlan {
        func valid(_ s: String, max: Int, empty: Bool = false) -> Bool {
            s.count <= max && (empty || !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !s.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" }
        }
        guard valid(summary, max: 600), valid(appContext, max: 200, empty: true), valid(action, max: 200),
              (1...8).contains(concepts.count), concepts.contains(where: { $0.role == .feature }),
              concepts.allSatisfy({ concept in
                  valid(concept.label, max: 80) && (1...12).contains(concept.terms.count) && concept.terms.allSatisfy {
                      valid($0, max: 80) && $0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 2
                  }
              }), cautions.count <= 6, cautions.allSatisfy({ valid($0, max: 400) }) else {
            throw ScopeError.invalid("Codex 返回的检索计划不符合约束，请重新定位或改用关键词搜索。")
        }
        return self
    }

    static var schema: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        return object([
            "summary": string, "appContext": string, "action": string,
            "concepts": ["type": "array", "items": object([
                "label": string, "role": ["type": "string", "enum": ["feature", "action", "context", "hint"]],
                "terms": ["type": "array", "items": string]
            ])],
            "cautions": ["type": "array", "items": string]
        ])
    }
    static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }
}

public struct CandidateReview: Codable, Sendable {
    public struct Assessment: Codable, Sendable {
        public enum Relevance: String, Codable, Sendable { case likely, possible, weak }
        public let id: String
        public let relevance: Relevance
        public let reason: String
        public let evidenceIndices: [Int]
    }
    public let summary: String
    public let assessments: [Assessment]

    public func validated(for results: [SearchResult]) throws -> CandidateReview {
        guard Set(results.map(\.id)).count == results.count else { throw ScopeError.invalid("本地候选标识重复，保留本地结果。") }
        let candidates = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        guard summary.count <= 800, assessments.count == results.count,
              Set(assessments.map(\.id)) == Set(candidates.keys),
              assessments.allSatisfy({ item in
                  guard let result = candidates[item.id] else { return false }
                  return !item.reason.isEmpty && item.reason.count <= 600 && !item.evidenceIndices.isEmpty &&
                      item.evidenceIndices.count <= result.evidence.count && item.evidenceIndices.allSatisfy { result.evidence.indices.contains($0) }
              }) else { throw ScopeError.invalid("Codex 候选评估缺少依据或包含未知条目，保留本地排序。") }
        return self
    }

    public func ordering(_ results: [SearchResult]) -> [SearchResult] {
        let ranks = Dictionary(assessments.map { ($0.id, $0.relevance == .likely ? 0 : $0.relevance == .possible ? 1 : 2) }, uniquingKeysWith: { first, _ in first })
        return results.enumerated().sorted { lhs, rhs in
            let a = ranks[lhs.element.id] ?? 1, b = ranks[rhs.element.id] ?? 1
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    static var schema: [String: Any] {
        FeatureSearchPlan.object([
            "summary": ["type": "string"],
            "assessments": ["type": "array", "items": FeatureSearchPlan.object([
                "id": ["type": "string"], "relevance": ["type": "string", "enum": ["likely", "possible", "weak"]],
                "reason": ["type": "string"], "evidenceIndices": ["type": "array", "items": ["type": "integer"]]
            ])]
        ])
    }
}
