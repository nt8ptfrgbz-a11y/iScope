import SwiftUI
import AppKit
import iScopeCore

enum WorkspacePage: String, CaseIterable, Identifiable {
    case overview, all, methods, classes, strings, symbols, bookmarks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "分析概览"; case .all: return "功能定位"; case .methods: return "方法"; case .classes: return "类与 Category"
        case .strings: return "字符串"; case .symbols: return "符号"; case .bookmarks: return "收藏"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"; case .all: return "scope"; case .methods: return "function"; case .classes: return "square.stack.3d.up"
        case .strings: return "text.quote"; case .symbols: return "number"; case .bookmarks: return "bookmark"
        }
    }
    var kind: ResultKind? {
        switch self { case .methods: return .method; case .classes: return .classInfo; case .strings: return .string; case .symbols: return .symbol; default: return nil }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var artifact: ImportedArtifact?
    @Published var analyses: [String: BinaryAnalysis] = [:]
    @Published var selectedImageID: String? { didSet {
        guard oldValue != selectedImageID, !restoringFeatureSearch else { return }
        scheduleSearch(); selectedResultID = nil; analyzeSelected()
    } }
    @Published var page: WorkspacePage = .overview {
        willSet {
            if newValue != page {
                if isSmartSearching { cancelSmartSearch() }
                saveActiveFeatureSearch()
            }
        }
        didSet {
            guard oldValue != page, !restoringFeatureSearch else { return }
            if page == .all, let id = selectedFeatureSearchID { restoreFeatureSearch(id); return }
            selectedResultID = nil; scheduleSearch()
        }
    }
    @Published var query = "" { didSet {
        guard oldValue != query, !restoringFeatureSearch else { return }
        if !query.isEmpty && page == .overview { selectedFeatureSearchID = nil; page = .all }
        scheduleSearch()
    } }
    @Published var searchAllImages = false { didSet { if oldValue != searchAllImages && !restoringFeatureSearch { scheduleSearch() } } }
    @Published var caseSensitive = false { didSet { if oldValue != caseSensitive { scheduleSearch() } } }
    @Published var useRegex = false { didSet { if oldValue != useRegex { scheduleSearch() } } }
    @Published var expandFeatures = true { didSet { if oldValue != expandFeatures { scheduleSearch() } } }
    @Published var results: [SearchResult] = []
    @Published var resultCount = 0
    @Published var expandedTerms: [String] = []
    @Published var selectedResultID: String? { didSet { if oldValue != selectedResultID { saveActiveFeatureSearch() } } }
    @Published var isWorking = false
    @Published var isSearching = false
    @Published var progress = ""
    @Published var errorMessage: String?
    @Published var searchError: String?
    @Published var showExport = false
    @Published var showHookProject = false
    @Published var showWorkflow = false
    let workflow = WorkflowModel()
    var pendingWorkflow = false
    @Published var hookSeeds: [ObjCMethod] = []
    @Published var bookmarks: Set<String> = []
    @Published var noteText = ""
    @Published var recentPaths: [String] = UserDefaults.standard.stringArray(forKey: "recentArtifacts") ?? []
    @Published var toast: String?
    @Published var showCodexSettings = false
    @Published var codexSettings: CodexSettings = {
        guard let data = UserDefaults.standard.data(forKey: "codexSettings"), let settings = try? JSONDecoder().decode(CodexSettings.self, from: data) else { return CodexSettings() }
        return settings
    }() { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(codexSettings), forKey: "codexSettings") } }
    @Published var codexStatus = "尚未检查 CLI"
    @Published var isCheckingCodex = false
    @Published var isSmartSearching = false
    @Published var smartQuery: String?
    @Published var smartPlan: FeatureSearchPlan?
    @Published var smartResponse: FeatureSearchResponse?
    @Published var smartReview: CandidateReview?
    @Published var smartStatus = ""
    @Published var smartError: String?
    @Published var reviewError: String?
    @Published private(set) var featureSearchSessions: [FeatureSearchSession] = []
    @Published private(set) var selectedFeatureSearchID: UUID?
    private var liveFeatureSearchID: UUID?
    private var restoringFeatureSearch = false
    private var workspaceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var notes: [String: String] = [:]
    private var pendingFunction: (UInt64, String, ResultKind)?

    var currentAnalysis: BinaryAnalysis? { selectedImageID.flatMap { analyses[$0] } }
    var selectedResult: SearchResult? { results.first { $0.id == selectedResultID } }
    var selectedAnalysis: BinaryAnalysis? {
        guard let result = selectedResult else { return nil }
        return activeFeatureSearch?.analyses.first { $0.image.id == result.imageID } ?? analyses[result.imageID]
    }
    var activeFeatureSearch: FeatureSearchSession? {
        guard isSmartMode, let id = liveFeatureSearchID else { return nil }
        return featureSearchSessions.first { $0.id == id }
    }
    var hookAnalyses: [BinaryAnalysis] { activeFeatureSearch?.analyses ?? orderedAnalyses }
    var resultListIdentity: String { isSmartMode ? "feature:\(liveFeatureSearchID?.uuidString ?? "")" : page.rawValue }
    var scopedAnalyses: [BinaryAnalysis] {
        if searchAllImages { return orderedAnalyses }
        return currentAnalysis.map { [$0] } ?? []
    }
    var orderedAnalyses: [BinaryAnalysis] { artifact?.images.compactMap { analyses[$0.id] } ?? [] }
    var selectedImage: BinaryImage? { artifact?.images.first { $0.id == selectedImageID } }
    var canAnalyzeAll: Bool { !isWorking && analyses.count < (artifact?.images.count ?? 0) }
    var isSmartMode: Bool { page == .all && smartQuery != nil }
    var canSmartSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !scopedAnalyses.isEmpty && !isWorking && !isSmartSearching }
    func assessment(for result: SearchResult) -> CandidateReview.Assessment? { smartReview?.assessments.first { $0.id == result.id } }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入 IPA、应用或 Mach-O"
        panel.message = "支持脱壳 IPA、.app、Framework、dylib 和无扩展名的 Mach-O。"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    func open(_ url: URL) {
        workspaceTask?.cancel(); searchTask?.cancel()
        clearSmartSearch()
        isWorking = true; progress = "正在导入 \(url.lastPathComponent)…"; errorMessage = nil
        workspaceTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try ArtifactImporter.load(url)
            }
            do {
                let imported = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                if Task.isCancelled { if let directory = imported.temporaryDirectory { try? FileManager.default.removeItem(at: directory) }; return }
                if let directory = imported.temporaryDirectory { TemporaryArtifacts.directories.append(directory) }
                artifact = imported; analyses = [:]; selectedResultID = nil; results = []; resultCount = 0
                featureSearchSessions = []; selectedFeatureSearchID = nil
                query = ""; page = .overview
                loadAnnotations()
                recentPaths.removeAll { $0 == url.path }; recentPaths.insert(url.path, at: 0); recentPaths = Array(recentPaths.prefix(6))
                UserDefaults.standard.set(recentPaths, forKey: "recentArtifacts")
                // Avoid the selection observer starting a second task during this import.
                isWorking = true
                selectedImageID = imported.images.first?.id
                if let image = imported.images.first {
                    progress = "正在分析 \(image.name)…"
                    let analysis = try await analyze(image)
                    guard !Task.isCancelled else { return }
                    analyses[image.id] = analysis
                }
                isWorking = false; progress = "分析完成"; scheduleSearch(preserveFeatureResults: true)
            } catch {
                guard !Task.isCancelled else { return }
                isWorking = false
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
                progress = "导入未完成"
            }
        }
    }

    private func analyze(_ image: BinaryImage, architecture: String? = nil) async throws -> BinaryAnalysis {
        let worker = Task.detached(priority: .userInitiated) { try MachOAnalyzer.analyze(image, architecture: architecture) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    func analyzeSelected(architecture: String? = nil) {
        guard !isWorking, let image = selectedImage, analyses[image.id] == nil || architecture != nil else { return }
        workspaceTask?.cancel()
        isWorking = true; progress = "正在分析 \(image.name)…"
        workspaceTask = Task {
            do {
                let analysis = try await analyze(image, architecture: architecture)
                guard !Task.isCancelled else { return }
                analyses[image.id] = analysis; isWorking = false; progress = "分析完成"; scheduleSearch(preserveFeatureResults: true)
            } catch {
                guard !Task.isCancelled else { return }
                isWorking = false; progress = "分析失败"
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func analyzeAll() {
        guard let artifact, !isWorking else { return }
        isWorking = true
        workspaceTask = Task {
            var failures: [String] = []
            for (index, image) in artifact.images.enumerated() where analyses[image.id] == nil {
                guard !Task.isCancelled else { return }
                progress = "分析 \(index + 1)/\(artifact.images.count) · \(image.name)"
                do { let analysis = try await analyze(image); guard !Task.isCancelled else { return }; analyses[image.id] = analysis }
                catch { if !(error is CancellationError) { failures.append("\(image.name)：\(error.localizedDescription)") } }
            }
            guard !Task.isCancelled else { return }
            isWorking = false; progress = "已分析 \(analyses.count) 个 Mach-O"
            if !isSmartMode { searchAllImages = true }
            scheduleSearch(preserveFeatureResults: true)
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    func cancelWork() {
        workspaceTask?.cancel(); workspaceTask = nil; isWorking = false; progress = "已取消"; scheduleSearch(preserveFeatureResults: true)
    }

    func scheduleSearch(preserveFeatureResults: Bool = false) {
        if preserveFeatureResults && isSmartMode { return }
        searchTask?.cancel()
        clearSmartSearch()
        if page == .all { selectedFeatureSearchID = nil }
        guard page != .overview else { isSearching = false; return }
        let analyses = scopedAnalyses, query = query, kind = page.kind
        let saved = page == .bookmarks ? bookmarks : nil
        var options = SearchOptions()
        options.caseSensitive = caseSensitive; options.regularExpression = useRegex; options.expandFeatureWords = expandFeatures
        isSearching = true; searchError = nil
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let worker = Task.detached(priority: .userInitiated) { try SearchEngine.search(analyses, query: query, kind: kind, options: options, bookmarked: saved) }
                let response = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                results = response.results; resultCount = response.total; expandedTerms = response.expandedTerms; isSearching = false
                if let pending = pendingFunction {
                    selectedResultID = results.first { $0.kind == pending.2 && $0.address == pending.0 && $0.imageID == pending.1 }?.id
                    pendingFunction = nil
                }
                if let selectedResultID, !results.contains(where: { $0.id == selectedResultID }) { self.selectedResultID = nil }
            } catch {
                guard !Task.isCancelled else { return }
                results = []; resultCount = 0; expandedTerms = []; isSearching = false
                if !(error is CancellationError) { searchError = error.localizedDescription }
            }
        }
    }

    private func clearSmartSearch() {
        if isSmartSearching {
            smartStatus = smartResponse == nil ? "定位已停止，可重新提交" : "已保留本地候选 · 后续评估已停止"
        }
        saveActiveFeatureSearch()
        smartTask?.cancel(); smartTask = nil; isSmartSearching = false
        liveFeatureSearchID = nil
        smartQuery = nil; smartPlan = nil; smartResponse = nil; smartReview = nil; smartError = nil; reviewError = nil
    }

    func useKeywordSearch() { scheduleSearch() }

    func cancelSmartSearch() {
        smartTask?.cancel(); smartTask = nil; isSmartSearching = false
        smartStatus = smartResponse == nil ? "已取消，可重新定位或返回关键词结果" : "已取消后续评估，保留本地候选"
        saveActiveFeatureSearch()
    }

    func saveActiveFeatureSearch() {
        guard !restoringFeatureSearch, page == .all, smartQuery != nil, let id = liveFeatureSearchID,
              let index = featureSearchSessions.firstIndex(where: { $0.id == id }) else { return }
        var session = featureSearchSessions[index]
        session.plan = smartPlan; session.response = smartResponse; session.review = smartReview
        session.results = results; session.total = resultCount; session.status = smartStatus
        session.error = smartError; session.reviewError = reviewError; session.selectedResultID = selectedResultID
        featureSearchSessions[index] = session
    }

    func restoreFeatureSearch(_ id: UUID) {
        guard featureSearchSessions.contains(where: { $0.id == id }) else { return }
        if isSmartMode && liveFeatureSearchID == id { return }
        searchTask?.cancel(); clearSmartSearch()
        guard let session = featureSearchSessions.first(where: { $0.id == id }) else { return }
        restoringFeatureSearch = true
        defer { restoringFeatureSearch = false }
        page = .all; selectedFeatureSearchID = id; liveFeatureSearchID = id
        selectedImageID = session.imageID; searchAllImages = session.searchAllImages; query = session.query
        smartQuery = session.query; smartPlan = session.plan; smartResponse = session.response; smartReview = session.review
        smartStatus = session.status; smartError = session.error; reviewError = session.reviewError
        results = session.results; resultCount = session.total; expandedTerms = []; searchError = nil; isSearching = false
        pendingFunction = nil
        selectedResultID = session.selectedResultID
    }

    func closeFeatureSearch(_ id: UUID) {
        let wasSelected = selectedFeatureSearchID == id
        if liveFeatureSearchID == id { clearSmartSearch() }
        featureSearchSessions.removeAll { $0.id == id }
        guard wasSelected else { return }
        selectedFeatureSearchID = featureSearchSessions.last?.id
        if page == .all {
            if let next = selectedFeatureSearchID { restoreFeatureSearch(next) }
            else { selectedResultID = nil; scheduleSearch() }
        }
    }

    func checkCodex() {
        guard !isCheckingCodex else { return }
        let settings = codexSettings
        isCheckingCodex = true
        Task {
            do {
                let version = try await Task.detached { try CodexCLI.check(settings) }.value
                codexStatus = "已检测到 \(version)（服务连接将在定位时验证）"
            } catch { codexStatus = error.localizedDescription }
            isCheckingCodex = false
        }
    }

    func startSmartSearch() {
        guard canSmartSearch else { return }
        let description = query, values = scopedAnalyses, settings = codexSettings
        let imageID = selectedImageID, allImages = searchAllImages
        page = .all
        searchTask?.cancel(); clearSmartSearch()
        restoringFeatureSearch = true
        query = description; selectedImageID = imageID; searchAllImages = allImages
        restoringFeatureSearch = false
        smartQuery = description; smartStatus = "Codex 正在理解描述并生成检索计划…"
        isSmartSearching = true; isSearching = false; searchError = nil; selectedResultID = nil
        results = []; resultCount = 0; expandedTerms = []
        let id = UUID()
        liveFeatureSearchID = id; selectedFeatureSearchID = id
        featureSearchSessions.append(FeatureSearchSession(id: id, query: description, imageID: selectedImageID,
                                                         searchAllImages: searchAllImages, analyses: values))
        saveActiveFeatureSearch()
        smartTask = Task {
            do {
                let planner = Task.detached(priority: .userInitiated) { try CodexCLI.makePlan(description: description, settings: settings) }
                let plan = try await withTaskCancellationHandler(operation: { try await planner.value }, onCancel: { planner.cancel() })
                try Task.checkCancellation()
                smartPlan = plan; smartStatus = "正在本地检索名称、字符串与直接调用线索…"
                saveActiveFeatureSearch()
                let retriever = Task.detached(priority: .userInitiated) { try FeatureSearchEngine.search(values, plan: plan) }
                let response = try await withTaskCancellationHandler(operation: { try await retriever.value }, onCancel: { retriever.cancel() })
                try Task.checkCancellation()
                smartResponse = response; results = response.results; resultCount = response.total
                saveActiveFeatureSearch()
                if settings.reviewCandidates && response.results.count > 1 {
                    smartStatus = "已找到本地候选，Codex 正在评估前 \(response.results.count) 条…"
                    do {
                        let reviewer = Task.detached(priority: .userInitiated) { try CodexCLI.review(plan: plan, candidates: response.results, settings: settings) }
                        let review = try await withTaskCancellationHandler(operation: { try await reviewer.value }, onCancel: { reviewer.cancel() })
                        try Task.checkCancellation()
                        smartReview = review; results = review.ordering(response.results)
                    } catch {
                        try Task.checkCancellation()
                        reviewError = error.localizedDescription
                    }
                }
                try Task.checkCancellation()
                isSmartSearching = false
                smartStatus = "定位完成 · \(response.total) 个本地候选 · 展示前 \(response.results.count) 个"
                saveActiveFeatureSearch()
            } catch {
                guard !Task.isCancelled else { return }
                isSmartSearching = false; smartStatus = "智能定位未完成"
                smartError = error.localizedDescription
                saveActiveFeatureSearch()
            }
        }
    }

    func navigateToClue(_ result: SearchResult) {
        pendingFunction = (result.address, result.imageID, .string)
        page = .strings; selectedImageID = result.imageID; query = result.address.hex
    }

    func navigateToMethod(address: UInt64, imageID: String) {
        let isMethod = analyses[imageID]?.classes.contains { $0.methods.contains { $0.address == address } } ?? false
        pendingFunction = (address, imageID, isMethod ? .method : .symbol)
        page = isMethod ? .methods : .symbols; selectedImageID = imageID; query = address.hex
    }

    func toggleBookmark(_ result: SearchResult) {
        if bookmarks.contains(result.id) { bookmarks.remove(result.id) } else { bookmarks.insert(result.id) }
        saveAnnotations()
        if page == .bookmarks { scheduleSearch() }
    }

    func note(for result: SearchResult) -> String { notes[result.id] ?? "" }
    func saveNote(_ text: String, for result: SearchResult) { notes[result.id] = text; saveAnnotations() }

    private var annotationKey: String { "annotations:" + (artifact?.sourceURL.standardizedFileURL.path ?? "") }
    private struct Annotations: Codable { let bookmarks: Set<String>; let notes: [String: String] }
    private func loadAnnotations() {
        if let data = UserDefaults.standard.data(forKey: annotationKey), let values = try? JSONDecoder().decode(Annotations.self, from: data) {
            bookmarks = values.bookmarks; notes = values.notes
        } else { bookmarks = []; notes = [:] }
    }
    private func saveAnnotations() { UserDefaults.standard.set(try? JSONEncoder().encode(Annotations(bookmarks: bookmarks, notes: notes)), forKey: annotationKey) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        toast = "已复制"
        Task { try? await Task.sleep(for: .seconds(2)); toast = nil }
    }

    func createHookProject(from result: SearchResult? = nil) {
        saveActiveFeatureSearch()
        if let result = result ?? selectedResult {
            switch result.payload {
            case .method(let method): hookSeeds = [method]
            case .classInfo(let cls): hookSeeds = cls.methods
            default: hookSeeds = []
            }
        } else {
            hookSeeds = results.filter { bookmarks.contains($0.id) }.compactMap {
                if case .method(let method) = $0.payload { return method }; return nil
            }
        }
        showHookProject = true
    }

    func export(format: ExportFormat, all: Bool) {
        let values = all ? orderedAnalyses : currentAnalysis.map { [$0] } ?? []
        guard !values.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(all ? artifact?.name ?? "iScope" : currentAnalysis?.image.name ?? "iScope")-\(format.rawValue).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let worker = Task.detached { try AnalysisExporter.data(values, format: format) }
                    let data = try await worker.value
                    try data.write(to: url, options: .atomic)
                    self?.toast = "导出完成"
                } catch { self?.errorMessage = error.localizedDescription }
            }
        }
    }
}

@MainActor enum TemporaryArtifacts { static var directories: [URL] = [] }
