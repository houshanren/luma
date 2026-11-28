import Combine
import Foundation
import LumaAI
import LumaDomain

/// 三个「一次性 AI 辅助」的共享执行层与状态：
/// 图库体检解读、回忆 / 旅行起名与旁白、影院未识别兜底。
///
/// 和助手对话是两条独立通道：
/// - 不带工具、不带历史、不写对话记录；
/// - 同一时刻只跑一个请求（本机只有一个推理进程）；
/// - 只由用户点按钮触发，不后台偷跑；
/// - 失败只影响这一个功能，界面保留原有规则结果。
@MainActor
final class AIAssistCenter: ObservableObject {
    static let shared = AIAssistCenter()

    /// 三个功能共用同一套「能不能用」的判断。
    enum Availability: Equatable {
        case ready
        /// 没选服务 / 没填 Key / 本地模型还没装。
        case notConfigured
        /// 选了本地模型，但 ollama 服务没在跑。
        case localServiceOff
        /// 本地服务在跑，但当前档位的模型还没下载。
        case localModelMissing
        /// 助手正在回答：等这一轮结束再点，避免两个请求抢同一块 GPU。
        case assistantBusy

        var isReady: Bool { self == .ready }

        var hint: String? {
            switch self {
            case .ready: return nil
            case .notConfigured: return "先在「设置 › 助手」或「本地模型」里配置一个模型"
            case .localServiceOff: return "本地模型服务未启动：到「设置 › 本地模型」点启动服务"
            case .localModelMissing: return "当前档位的本地模型还没下载完成"
            case .assistantBusy: return "助手正在回答，等这一轮结束再试"
            }
        }
    }

    /// 起名结果：标题 + 一句旁白。
    struct StoryTitle: Codable, Equatable {
        var title: String
        var narration: String
    }

    /// 关键词 / 标题补全的一条建议（对应一张照片）。
    struct KeywordSuggestion: Identifiable, Equatable {
        var id: UUID
        var title: String
        var keywords: [String]
    }

    /// 一次关键词合并：把 variants 合并成 canonical。
    struct KeywordMergeSuggestion: Identifiable, Equatable {
        var canonical: String
        var variants: [String]
        var id: String { canonical }
    }

    /// 一张缺定位照片的地点建议。
    struct PlaceSuggestion: Identifiable, Equatable {
        var id: UUID
        var city: String
        var poi: String
    }

    // MARK: - 状态

    @Published private(set) var healthDigest: String?
    @Published private(set) var healthDigestLoading = false
    @Published private(set) var healthDigestError: String?

    /// 故事 id → 起名结果；只保留当前图库的（按图库 key 分桶持久化）。
    @Published private(set) var storyTitles: [String: StoryTitle] = [:]
    @Published private(set) var storyLoadingID: String?
    @Published private(set) var storyError: String?

    @Published private(set) var cinemaFallbackBusy = false
    @Published private(set) var cinemaFallbackStatus: String?

    // 分享文案（朋友圈 / 小红书）
    @Published private(set) var shareCopy: [String] = []
    @Published private(set) var shareLoading = false
    @Published private(set) var shareError: String?
    /// 上一次生成用的照片：面板里「重新生成」沿用同一批，不会换成当前选中项。
    @Published private(set) var shareSourceIDs: Set<UUID> = []
    @Published var showShareSheet = false

    // 中文关键词 / 标题补全
    @Published private(set) var keywordSuggestions: [KeywordSuggestion] = []
    @Published private(set) var keywordLoading = false
    @Published private(set) var keywordError: String?
    @Published var showKeywordSheet = false

    // 搜索框自然语言改写
    @Published private(set) var searchRewriteLoading = false

    // 电视 M3U 频道清洗
    @Published private(set) var channelCleanupLoading = false
    @Published private(set) var channelCleanupStatus: String?

    // 离线帮助问答
    @Published var showHelpSheet = false
    @Published private(set) var helpAnswer: String?
    @Published private(set) var helpLoading = false
    @Published private(set) var helpError: String?

    // 诊断日志摘要
    @Published private(set) var diagnosticsSummary: String?
    @Published private(set) var diagnosticsLoading = false
    @Published private(set) var diagnosticsError: String?
    @Published var showDiagnosticsSheet = false

    // 关键词归一化（合并同义 / 错别字 / 垃圾词）
    @Published private(set) var keywordMerges: [KeywordMergeSuggestion] = []
    @Published private(set) var keywordMergeLoading = false
    @Published private(set) var keywordMergeError: String?
    @Published var showKeywordMergeSheet = false

    // 地点补全
    @Published private(set) var placeSuggestions: [PlaceSuggestion] = []
    @Published private(set) var placeLoading = false
    @Published private(set) var placeError: String?
    @Published var showPlaceSheet = false

    // 电视「今晚看什么」
    @Published private(set) var tonightPicks: [String] = []
    @Published private(set) var tonightLoading = false
    @Published private(set) var tonightError: String?

    // 影院系列归组
    @Published private(set) var cinemaGroupingBusy = false
    @Published private(set) var cinemaGroupingStatus: String?

    private var digestKey: String?
    private var storyLibraryKey: String?

    private init() {}

    /// 任意一个一次性任务在跑时，其它入口先让路。
    var isBusy: Bool {
        healthDigestLoading || storyLoadingID != nil || cinemaFallbackBusy
            || shareLoading || keywordLoading || searchRewriteLoading
            || channelCleanupLoading || helpLoading || diagnosticsLoading
            || keywordMergeLoading || placeLoading || tonightLoading || cinemaGroupingBusy
    }

    // MARK: - 可用性

    /// 三条规则依次判断：有没有模型 → 本地服务在不在 → 助手是否占用。
    /// 三个功能都只发文本，不发送照片，因此不受「发送压缩缩略图」开关影响。
    static func availability(config: AIConfig, assistantBusy: Bool) -> Availability {
        if assistantBusy { return .assistantBusy }
        if config.provider == .local {
            let runtime = LocalLLMRuntime.shared
            guard runtime.isRuntimeInstalled else { return .notConfigured }
            guard runtime.isServerRunning else { return .localServiceOff }
            guard runtime.installedModels.contains(runtime.selectedOption.id) else {
                return .localModelMissing
            }
            guard !config.baseURL.isEmpty, !config.model.isEmpty else { return .notConfigured }
            return .ready
        }
        guard !config.baseURL.isEmpty, !config.model.isEmpty else { return .notConfigured }
        guard AIKeychain.hasKey(for: config.provider) else { return .notConfigured }
        return .ready
    }

    // MARK: - 执行

    /// 发一次纯文本请求。返回去掉空白后的正文；空正文按「无法解析」处理。
    /// `preferLightweight`：纯文本小任务自动挑本机已装的最轻档位（1.5B 优先），
    /// 避免用户选了 8B 后为一句旁白等两三分钟；判断类任务（影院兜底）则用当前档位。
    /// 长输出或长上下文再多升一档：1.5B 写长 JSON 容易中途断掉。
    func complete(config: AIConfig,
                  apiKey: String,
                  system: String,
                  user: String,
                  maxTokens: Int = 600,
                  preferLightweight: Bool = false) async throws -> String {
        let escalate = preferLightweight
            && (maxTokens >= 700 || (system.count + user.count) >= 2600)
        var config = preferLightweight
            ? lightweightConfig(config, escalate: escalate)
            : config
        config.maxTokens = max(maxTokens, 200)
        let request = AIChatRequest(
            config: config,
            apiKey: apiKey,
            messages: [
                AIRequestMessage(role: "system", text: system),
                AIRequestMessage(role: "user", text: user)
            ]
        )
        let completion = try await AIChatProviderFactory.make(config: config).complete(request)
        let text = completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }

    /// 本地档位下改成「已安装里体积最小」的那个；长任务升一档；云端不动。
    private func lightweightConfig(_ config: AIConfig, escalate: Bool) -> AIConfig {
        guard config.provider == .local else { return config }
        let runtime = LocalLLMRuntime.shared
        let installed = LocalLLMRuntime.options
            .filter { runtime.installedModels.contains($0.id) }
            .sorted { $0.bytes < $1.bytes }
        guard !installed.isEmpty else { return config }
        let index = escalate && installed.count > 1 ? 1 : 0
        let pick = installed[index]
        guard pick.id != config.model else { return config }
        var config = config
        config.model = pick.id
        return config
    }

    // MARK: - 体检解读

    func beginHealthDigest(key: String) -> Bool {
        guard !isBusy else { return false }
        digestKey = key
        healthDigestLoading = true
        healthDigestError = nil
        return true
    }

    func finishHealthDigest(_ result: Result<String, Error>) {
        healthDigestLoading = false
        switch result {
        case .success(let text):
            healthDigest = text
            healthDigestError = nil
        case .failure(let error):
            healthDigestError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// 体检结果没变就直接复用上次的解读。
    func cachedHealthDigest(for key: String) -> String? {
        digestKey == key ? healthDigest : nil
    }

    // MARK: - 回忆 / 旅行起名

    /// 切换到某个图库时载入它的起名结果（只存本机 UserDefaults，按图库路径分桶）。
    func loadStoryTitles(libraryKey: String) {
        guard storyLibraryKey != libraryKey else { return }
        storyLibraryKey = libraryKey
        guard let data = UserDefaults.standard.data(forKey: Self.storyKey(libraryKey)),
              let decoded = try? JSONDecoder().decode([String: StoryTitle].self, from: data) else {
            storyTitles = [:]
            return
        }
        storyTitles = decoded
    }

    func storyTitle(for id: String) -> StoryTitle? { storyTitles[id] }

    func beginStoryTitle(id: String) -> Bool {
        guard !isBusy else { return false }
        storyLoadingID = id
        storyError = nil
        return true
    }

    func finishStoryTitle(id: String, result: Result<StoryTitle, Error>) {
        storyLoadingID = nil
        switch result {
        case .success(let value):
            storyTitles[id] = value
            storyError = nil
            persistStoryTitles()
        case .failure(let error):
            storyError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func persistStoryTitles() {
        guard let key = storyLibraryKey,
              let data = try? JSONEncoder().encode(storyTitles) else { return }
        UserDefaults.standard.set(data, forKey: Self.storyKey(key))
    }

    private static func storyKey(_ libraryKey: String) -> String {
        "ai.storyTitles.\(libraryKey)"
    }

    // MARK: - 影院兜底

    func beginCinemaFallback() -> Bool {
        guard !isBusy else { return false }
        cinemaFallbackBusy = true
        cinemaFallbackStatus = "准备匹配…"
        return true
    }

    func updateCinemaFallback(_ status: String) {
        cinemaFallbackStatus = status
    }

    func finishCinemaFallback(_ summary: String?) {
        cinemaFallbackBusy = false
        cinemaFallbackStatus = summary
    }

    // MARK: - 分享文案

    func beginShare() -> Bool {
        guard !isBusy else { return false }
        shareCopy = []
        shareError = nil
        shareLoading = true
        return true
    }

    func rememberShareSources(_ ids: Set<UUID>) {
        shareSourceIDs = ids
    }

    func finishShare(_ result: Result<[String], Error>) {
        shareLoading = false
        switch result {
        case .success(let items):
            shareCopy = items
            shareError = items.isEmpty ? "这次没有生成可用文案，换几张照片再试" : nil
        case .failure(let error):
            shareError = Self.describe(error)
        }
    }

    // MARK: - 关键词 / 标题补全

    func beginKeywordSuggestions() -> Bool {
        guard !isBusy else { return false }
        keywordSuggestions = []
        keywordError = nil
        keywordLoading = true
        return true
    }

    func finishKeywordSuggestions(_ result: Result<[KeywordSuggestion], Error>) {
        keywordLoading = false
        switch result {
        case .success(let items):
            keywordSuggestions = items
            keywordError = items.isEmpty ? "没有生成建议，换几张照片再试" : nil
        case .failure(let error):
            keywordError = Self.describe(error)
        }
    }

    /// 应用后清空，避免下次打开看到已经写过的旧建议。
    func clearKeywordSuggestions() {
        keywordSuggestions = []
        keywordError = nil
    }

    // MARK: - 搜索改写

    func beginSearchRewrite() -> Bool {
        guard !isBusy else { return false }
        searchRewriteLoading = true
        return true
    }

    func finishSearchRewrite() {
        searchRewriteLoading = false
    }

    // MARK: - 电视频道清洗

    func beginChannelCleanup() -> Bool {
        guard !isBusy else { return false }
        channelCleanupStatus = "准备清洗…"
        channelCleanupLoading = true
        return true
    }

    func updateChannelCleanup(_ status: String) {
        channelCleanupStatus = status
    }

    func finishChannelCleanup(_ summary: String?) {
        channelCleanupLoading = false
        channelCleanupStatus = summary
    }

    // MARK: - 离线帮助

    func beginHelp() -> Bool {
        guard !isBusy else { return false }
        helpAnswer = nil
        helpError = nil
        helpLoading = true
        return true
    }

    func finishHelp(_ result: Result<String, Error>) {
        helpLoading = false
        switch result {
        case .success(let text):
            helpAnswer = text
            helpError = nil
        case .failure(let error):
            helpError = Self.describe(error)
        }
    }

    // MARK: - 诊断摘要

    func beginDiagnostics() -> Bool {
        guard !isBusy else { return false }
        diagnosticsSummary = nil
        diagnosticsError = nil
        diagnosticsLoading = true
        return true
    }

    func finishDiagnostics(_ result: Result<String, Error>) {
        diagnosticsLoading = false
        switch result {
        case .success(let text):
            diagnosticsSummary = text
            diagnosticsError = nil
        case .failure(let error):
            diagnosticsError = Self.describe(error)
        }
    }

    // MARK: - 关键词归一化

    func beginKeywordMerge() -> Bool {
        guard !isBusy else { return false }
        keywordMerges = []
        keywordMergeError = nil
        keywordMergeLoading = true
        return true
    }

    func finishKeywordMerge(_ result: Result<[KeywordMergeSuggestion], Error>) {
        keywordMergeLoading = false
        switch result {
        case .success(let items):
            keywordMerges = items
            keywordMergeError = items.isEmpty ? "没有需要合并的关键词" : nil
        case .failure(let error):
            keywordMergeError = Self.describe(error)
        }
    }

    // MARK: - 地点补全

    func beginPlaceSuggestions() -> Bool {
        guard !isBusy else { return false }
        placeSuggestions = []
        placeError = nil
        placeLoading = true
        return true
    }

    func finishPlaceSuggestions(_ result: Result<[PlaceSuggestion], Error>) {
        placeLoading = false
        switch result {
        case .success(let items):
            placeSuggestions = items
            placeError = items.isEmpty ? "这些照片里没有能推断地点的线索" : nil
        case .failure(let error):
            placeError = Self.describe(error)
        }
    }

    // MARK: - 今晚推荐

    func beginTonightPicks() -> Bool {
        guard !isBusy else { return false }
        tonightPicks = []
        tonightError = nil
        tonightLoading = true
        return true
    }

    func finishTonightPicks(_ result: Result<[String], Error>) {
        tonightLoading = false
        switch result {
        case .success(let items):
            tonightPicks = items
            tonightError = items.isEmpty ? "今晚没有可推荐的节目" : nil
        case .failure(let error):
            tonightError = Self.describe(error)
        }
    }

    // MARK: - 影院系列归组

    func beginCinemaGrouping() -> Bool {
        guard !isBusy else { return false }
        cinemaGroupingBusy = true
        cinemaGroupingStatus = "准备归组…"
        return true
    }

    func updateCinemaGrouping(_ status: String) {
        cinemaGroupingStatus = status
    }

    func finishCinemaGrouping(_ summary: String?) {
        cinemaGroupingBusy = false
        cinemaGroupingStatus = summary
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - JSON 提取

    /// 模型偶尔会包一层 ```json：统一取出第一个 JSON 对象再解码。
    static func jsonObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
