import Foundation
import iScopeCore

/// A retained result set, independent of the current browser page and keyword filters.
struct FeatureSearchSession: Identifiable {
    let id: UUID
    let query: String
    let imageID: String?
    let searchAllImages: Bool
    let analyses: [BinaryAnalysis]
    var plan: FeatureSearchPlan?
    var response: FeatureSearchResponse?
    var review: CandidateReview?
    var results: [SearchResult] = []
    var total = 0
    var status = ""
    var error: String?
    var reviewError: String?
    var selectedResultID: String?

    var scopeTitle: String {
        let files = analyses.prefix(2).map { "\($0.image.name) (\($0.architecture))" }.joined(separator: "、")
        return analyses.count > 2 ? files + " 等 \(analyses.count) 个文件" : files
    }
}
