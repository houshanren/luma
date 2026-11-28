import SwiftUI
import AppKit

/// 助手的四种外壳：浮窗卡片（sheet）、并排侧栏（inspector）、叠放侧栏（overlay）、工作台整页（workspace）。
/// 共用同一套对话与工具，只有尺寸与顶部操作按钮不同。
enum AIAssistantPresentation {
    case sheet
    case inspector
    case overlay
    case workspace

    /// 并排 / 叠放 / 工作台都能再展开成浮窗；浮窗自己不再重复这个按钮。
    var showsExpandAction: Bool { self != .sheet }
}

/// 智能助手面板：问答、图片理解、检索建议与图库工具操作。
struct AIAssistantView: View {
    var presentation: AIAssistantPresentation = .sheet
    /// 宿主注入：展开 / 关闭 / 收进侧栏时由宿主统一收尾。
    var onClose: (() -> Void)? = nil
    var onExpand: (() -> Void)? = nil
    var onCollapse: (() -> Void)? = nil
    /// 由宿主决定尺寸（浮窗）：视图铺满容器，不再用 AppStorage 里的固定宽高。
    var fillContainer = false
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// 本地模型状态：服务被关掉或重启后没起来时，底栏直接给一键启动。
    @ObservedObject private var localLLM = LocalLLMRuntime.shared
    /// 语音输入：系统 Speech 转文字，优先端侧。
    @ObservedObject private var voice = AIVoiceInput.shared
    @AppStorage("ai.voice.consent") private var voiceConsent = false
    /// 设置窗口分页：模型菜单里的「更多设置」直接落到助手页。
    @AppStorage(SettingsKeys.selectedTab) private var settingsTab: SettingsTab = .general
    @State private var showVoiceConsent = false
    @State private var voiceBase = ""
    /// 输入 @ 时的候选查询：nil 表示选择器收起。
    @State private var mentionQuery: String?

    @FocusState private var inputFocused: Bool
    /// 主动追问卡的自由输入。
    @State private var questionDraft = ""
    @FocusState private var questionFocused: Bool
    @State private var showClearConfirm = false
    @State private var hoveredID: String?
    @State private var appeared = false
    /// 鼠标所在的对话消息：显示复制按钮等轻量操作。
    @State private var hoveredMessageID: UUID?
    /// 刚复制的消息：复制按钮短暂变成「已复制」。
    @State private var copiedMessageID: UUID?
    /// 折叠起来的执行轨迹分组。
    @State private var collapsedActionGroups: Set<String> = []
    /// 手动展开的执行轨迹：默认超过 4 步先折叠，点开才展开。
    @State private var expandedActionGroups: Set<String> = []
    /// 本轮开始的时刻：运行状态里显示已用时。
    @State private var thinkingStartedAt = Date()
    /// 面板尺寸：默认更大，支持拖右下角缩放，并随图库/设备记住上次大小。
    @AppStorage("ai.panel.width") private var panelWidth = 960.0
    @AppStorage("ai.panel.height") private var panelHeight = 820.0
    /// 拖动缩放时的起始尺寸，保证跟手。
    @State private var resizeBase: CGSize?

    /// 能力领域：与真实注册的工具体系一一对应，首页按领域展示，当前页面排在最前。
    private struct CapabilityDomain: Identifiable {
        let id: String
        let icon: String
        let title: String
        let tagline: String
        /// 这一域实际注册的工具数：直接取 AILibraryTools 的定义数量，不手写。
        let toolCount: Int
        /// 面向用户的能力名，不暴露工具名。
        let abilities: [String]
        /// 点一下就能填进输入框的示例。
        let examples: [String]
    }

    /// 深度场景：把多个工具组合成一件事，而不只是单步操作。
    private struct DeepScenario: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let prompt: String
    }

    /// 首页主推案例：直接对应真实可执行的操作。
    private struct CaseCard: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let prompt: String
    }

    private let libraryCases: [CaseCard] = [
        CaseCard(id: "album", icon: "calendar.badge.clock",
                 title: "按时间地点建相簿",
                 detail: "从拍摄时间与地点里找出去年在上海的照片，一次归组。",
                 prompt: "把去年在上海拍的照片按月份整理成相簿"),
        CaseCard(id: "rate", icon: "star.leadinghalf.filled",
                 title: "批量评级与标记",
                 detail: "给一组照片打星级、留用旗标与色标，方便后续筛选。",
                 prompt: "把选中的照片设为 4 星，标记留用，并加绿色色标"),
        CaseCard(id: "keywords", icon: "tag",
                 title: "关键词与标题",
                 detail: "补齐关键词、删掉错词、批量改标题，让后续检索更准。",
                 prompt: "给选中的照片加上「旅行」「海边」关键词，并把这几条视频的标题统一一下"),
        CaseCard(id: "process", icon: "wand.and.stars",
                 title: "压缩与美化",
                 detail: "按质量或长边压缩、生成美化副本，原图与备份都保留。",
                 prompt: "把选中的照片无损压缩，再给这 5 张生成美化副本")
    ]

    private let cinemaCases: [CaseCard] = [
        CaseCard(id: "cinema-match", icon: "wand.and.stars",
                 title: "整理未识别影片",
                 detail: "读取目录树、按文件名分组，再批量搜索候选并写回。",
                 prompt: "整理当前影院里未识别的影片，先按季集分组再匹配"),
        CaseCard(id: "cinema-resume", icon: "play.circle",
                 title: "继续上次没看完的",
                 detail: "从观看记录里挑最近一条，自动接上进度播放。",
                 prompt: "继续播放上次没看完的"),
        CaseCard(id: "cinema-collection", icon: "star.square.on.square",
                 title: "收藏、片单与活动",
                 detail: "查看收藏、片单和最近活动，挑一部接着看。",
                 prompt: "我收藏了哪些电影？按最近看过排序列出来"),
        CaseCard(id: "cinema-skip", icon: "forward.end",
                 title: "跳过片头与进度",
                 detail: "为剧集设置跳过片头的秒数，或重置某一集的观看进度。",
                 prompt: "把这部剧设为跳过片头 90 秒")
    ]

    private let catalogCases: [CaseCard] = [
        CaseCard(id: "catalog-update", icon: "sparkles.tv",
                 title: "今天的更新",
                 detail: "读取更新日历里今天新增的条目，直接播放或加入稍后看。",
                 prompt: "今天网络资源有什么更新？把前三个加入稍后看"),
        CaseCard(id: "catalog-search", icon: "magnifyingglass",
                 title: "跨源搜索",
                 detail: "在全部已启用站点里搜番号、标题或演员。",
                 prompt: "在所有已启用的源里搜一下「沙丘」"),
        CaseCard(id: "catalog-watchlist", icon: "bookmark",
                 title: "稍后看与追更",
                 detail: "把想看的放进稍后看，并跟住关注人物的更新。",
                 prompt: "把今天新片加入稍后看，再列出我追更的人物"),
        CaseCard(id: "catalog-browse", icon: "square.grid.2x2",
                 title: "逛逛站点分类",
                 detail: "浏览某个源的全部分类，找到图集、专题或短剧。",
                 prompt: "打开第一个网络资源的图集分类，看看最新几套")
    ]

    private let networkCinemaCases: [CaseCard] = [
        CaseCard(id: "ncinema-resume", icon: "play.circle",
                 title: "继续上次没看完的",
                 detail: "聚合各源的续看记录，接着上次的进度播放。",
                 prompt: "播放网络影院里上次没看完的那部"),
        CaseCard(id: "ncinema-search", icon: "film.stack",
                 title: "找一部电影",
                 detail: "跨影视源搜索，同名会聚合成多个来源。",
                 prompt: "搜索并播放《流浪地球 2》"),
        CaseCard(id: "ncinema-history", icon: "clock.arrow.circlepath",
                 title: "最近看过什么",
                 detail: "汇总各源的观看记录，按时间排序。",
                 prompt: "我最近在网络影院看了什么？"),
        CaseCard(id: "ncinema-sources", icon: "antenna.radiowaves.left.and.right",
                 title: "都有哪些影视源",
                 detail: "列出已接入的影视源和各自的片库规模。",
                 prompt: "列出网络影院的源和各自的片库规模")
    ]

    private let tvCases: [CaseCard] = [
        CaseCard(id: "tv-tonight", icon: "moon.stars.fill",
                 title: "今晚看什么",
                 detail: "按节目单挑今晚的频道与黄金时段节目。",
                 prompt: "今晚有什么好看的？帮我挑几个频道"),
        CaseCard(id: "tv-play", icon: "tv",
                 title: "直接播放频道",
                 detail: "说出频道名即可开播，也可以查节目单或回看。",
                 prompt: "播放 CCTV-1，并看看今晚的节目单"),
        CaseCard(id: "tv-guide", icon: "calendar.badge.clock",
                 title: "查节目单",
                 detail: "按频道与时段查节目，挑一个正在播的节目。",
                 prompt: "看看 CCTV-1 今晚 8 点播什么"),
        CaseCard(id: "tv-favorite", icon: "star",
                 title: "收藏与切台",
                 detail: "收藏常看的频道，或在电视页之间快速切换。",
                 prompt: "收藏这个频道，然后回到电视首页")
    ]

    /// 首页主推案例跟随当前模块，避免在影院页还推荐「压缩照片」。
    private var cases: [CaseCard] {
        if isTVContext { return tvCases }
        if isCinemaContext { return cinemaCases }
        if isNetworkCinemaContext { return networkCinemaCases }
        if isCatalogContext { return catalogCases }
        return libraryCases
    }

    /// 深度场景：都由真实工具组合完成，点一下即可执行。
    private let deepScenarios: [DeepScenario] = [
        DeepScenario(id: "insights", icon: "chart.bar.doc.horizontal",
                     title: "图库画像",
                     detail: "按年份、机型、地点与未整理比例拆解图库，看清自己的拍摄习惯。",
                     prompt: "分析一下我的图库：哪年拍得最多、常用什么设备、还有多少没整理"),
        DeepScenario(id: "health", icon: "stethoscope",
                     title: "图库体检与清理",
                     detail: "模糊照、相似连拍、过大视频一次列出，并算出能释放多少空间。",
                     prompt: "做一次图库体检，看看重复、模糊和过大的视频能清理多少空间"),
        DeepScenario(id: "trip", icon: "airplane",
                     title: "旅行与回忆",
                     detail: "从时间与 GPS 识别旅行，还能把某次旅行播成回忆影片。",
                     prompt: "我去过哪些旅行？把最近一次播成回忆影片"),
        DeepScenario(id: "digest", icon: "newspaper",
                     title: "今日日报",
                     detail: "新资源、追更、跨端续看与今晚电视节目合成一份可执行的日报。",
                     prompt: "给我今天的日报：新资源、没看完的、今晚有什么节目"),
        DeepScenario(id: "resume", icon: "play.rectangle.on.rectangle",
                     title: "跨端续看",
                     detail: "本地影院、网盘、网络影院与网络资源的进度一起汇总，接着看。",
                     prompt: "我还有哪些没看完？按最近观看时间排一下"),
        DeepScenario(id: "cinema-health", icon: "film.stack",
                     title: "影院体检",
                     detail: "未识别视频、缺海报与剧集集数一目了然，再决定怎么批量整理。",
                     prompt: "看看影院整理得怎么样，还有多少没识别、哪些缺海报")
    ]

    private var libraryDomain: CapabilityDomain {
        CapabilityDomain(
            id: "library", icon: "photo.stack",
            title: "图库与照片",
            tagline: "检索 · 相簿 · 标记 · 压缩与美化",
            toolCount: AILibraryTools.definitions.count,
            abilities: ["多条件检索", "统一搜索", "相簿与文件夹", "星级 / 旗标 / 色标",
                        "关键词与标题", "压缩与美化", "图库画像与体检", "旅行与回忆"],
            examples: ["把去年在上海的照片按月份整理成相簿",
                       "把选中的照片设为 4 星并加绿色色标"])
    }

    private var cinemaDomain: CapabilityDomain {
        CapabilityDomain(
            id: "cinema", icon: "film.stack",
            title: "本地影院",
            tagline: "目录树 · 刮削匹配 · 片单 · 续看",
            toolCount: AILibraryTools.cinemaToolDefinitions.count,
            abilities: ["目录树盘点", "批量刮削匹配", "季集对齐", "多版本合并",
                        "片单与范围", "续看与进度", "跳过片头", "影院体检"],
            examples: ["整理当前影院里未识别的影片，先按季集分组再匹配",
                       "继续播放上次没看完的"])
    }

    private var networkCinemaDomain: CapabilityDomain {
        CapabilityDomain(
            id: "networkCinema", icon: "play.rectangle.on.rectangle",
            title: "网络影院",
            tagline: "聚合各影视源 · 跨源搜索 · 续看",
            toolCount: AILibraryTools.networkCinemaToolDefinitions.count,
            abilities: ["影视源清单", "聚合片库", "跨源搜索", "同名多源聚合",
                        "续看记录", "直接播放"],
            examples: ["播放网络影院里上次没看完的那部",
                       "在各影视源里搜《流浪地球 2》并播放"])
    }

    private var catalogDomain: CapabilityDomain {
        CapabilityDomain(
            id: "catalog", icon: "sparkles.tv",
            title: "网络资源",
            tagline: "站点分类 · 今日更新 · 稍后看 · 追更",
            toolCount: AILibraryTools.catalogToolDefinitions.count,
            abilities: ["已接入站点", "分类浏览", "跨源搜索", "今日更新",
                        "稍后看", "人物追更", "图集与图文"],
            examples: ["今天网络资源有什么更新？把前三个加入稍后看",
                       "在所有已启用的源里搜一下「沙丘」"])
    }

    private var tvDomain: CapabilityDomain {
        CapabilityDomain(
            id: "tv", icon: "tv",
            title: "网络电视",
            tagline: "频道 · 节目单 · 直播 · 收藏",
            toolCount: AILibraryTools.tvToolDefinitions.count,
            abilities: ["直播源", "频道清单", "节目单查询", "今晚节目", "直播播放",
                        "频道收藏", "页面导航"],
            examples: ["今晚有什么好看的？帮我挑几个频道",
                       "播放 CCTV-1，并看看今晚的节目单"])
    }

    /// 当前页面所属领域：决定排序与「当前」标记。
    private var currentDomainID: String {
        if isTVContext { return "tv" }
        if isCatalogContext { return "catalog" }
        if isNetworkCinemaContext { return "networkCinema" }
        if isCinemaContext { return "cinema" }
        return "library"
    }

    /// 能力全景：当前领域排第一，其余保持固定顺序，避免面板里跳动。
    private var domains: [CapabilityDomain] {
        let all = [libraryDomain, cinemaDomain, networkCinemaDomain, catalogDomain, tvDomain]
        guard let index = all.firstIndex(where: { $0.id == currentDomainID }) else { return all }
        return [all[index]] + all.enumerated().filter { $0.offset != index }.map(\.element)
    }

    private var quickExamples: [String] {
        if isTVContext {
            return ["收藏的频道今晚播什么", "今晚有什么好看的", "播放 CCTV-1", "查一下湖南卫视节目单"]
        }
        if isCinemaContext {
            return ["看看影院整理得怎么样", "继续播放上次没看完的",
                    "整理未识别的影片", "把这部剧设为跳过片头 90 秒"]
        }
        if isNetworkCinemaContext {
            return ["我还有哪些没看完", "播放上次没看完的", "搜一下《沙丘》"]
        }
        if isCatalogContext {
            return ["给我今天的日报", "今天网络资源有什么更新", "播放第一条结果", "把今天新片加入稍后看"]
        }
        return ["做一次图库体检", "给我今天的日报", "我去过哪些旅行", "把 4 星以上照片建成相簿"]
    }

    private var isCinemaContext: Bool {
        switch store.sidebarItem {
        case .cinema, .cloudCinema: return true
        default: return false
        }
    }

    private var isCatalogContext: Bool {
        switch store.sidebarItem {
        case .catalogSources, .catalogSource: return true
        default: return false
        }
    }

    private var isNetworkCinemaContext: Bool {
        store.sidebarItem == .networkCinema
    }

    private var isTVContext: Bool {
        store.sidebarItem == .iptv
    }

    private var isInspector: Bool { presentation == .inspector }
    /// 副标题里的页面名：工作台整页时保留进入前的页面，避免写「助手 · N 项」。
    private var contextAreaTitle: String {
        store.aiSurfaceMode == .workspace ? store.aiWorkspaceOriginTitle : store.sidebarTitle
    }
    private var effectiveWidth: CGFloat { isInspector ? 380 : CGFloat(panelWidth) }

    var body: some View {
        @Bindable var store = store
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                divider
                messageList
                divider
                composer
            }
        }
        .frame(width: (isInspector || fillContainer) ? nil : CGFloat(panelWidth),
               height: (isInspector || fillContainer) ? nil : CGFloat(panelHeight))
        .frame(maxWidth: (isInspector || fillContainer) ? .infinity : nil,
               maxHeight: (isInspector || fillContainer) ? .infinity : nil)
        .overlay(alignment: .bottomTrailing) {
            if !isInspector, !fillContainer {
                resizeHandle
                    .padding(5)
            }
        }
        .overlay {
            if let request = store.aiPendingApproval {
                aiApprovalOverlay(request)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .overlay {
            if let question = store.aiPendingQuestion {
                aiQuestionOverlay(question)
                    .transition(.opacity)
                    .zIndex(21)
            }
        }
        .sheet(isPresented: $store.showAIMemorySheet) {
            AIMemorySheet()
                .environment(store)
                .environment(settings)
        }
        .sheet(isPresented: $store.showAISkillsSheet) {
            AISkillsSheet()
                .environment(store)
                .environment(settings)
        }
        .sheet(isPresented: $store.showAIScheduleSheet) {
            AIScheduleSheet()
                .environment(store)
                .environment(settings)
        }
        .sheet(isPresented: $store.showAIControlCenter) {
            AIControlCenterSheet()
                .environment(store)
                .environment(settings)
        }
        .sheet(isPresented: $store.showAIArtifactSheet) {
            AIArtifactSheet()
                .environment(store)
                .environment(settings)
        }
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .confirmationDialog("使用语音输入？", isPresented: $showVoiceConsent) {
            Button("继续") {
                voiceConsent = true
                startVoice()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("语音识别使用系统 Speech，优先在本机处理；设备或语种不支持时可能使用系统在线识别。只在你点击麦克风时录音。")
        }
        .confirmationDialog("开始新对话？", isPresented: $showClearConfirm) {
            Button("新对话", role: .destructive) {
                store.clearAIConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前对话会从图库中清除，清空后无法恢复。")
        }
        .onAppear {
            inputFocused = true
            store.refreshAIContextCapsules()
            if !isInspector {
                let size = clampedPanelSize(CGSize(width: panelWidth, height: panelHeight))
                if size.width != CGFloat(panelWidth) { panelWidth = Double(size.width) }
                if size.height != CGFloat(panelHeight) { panelHeight = Double(size.height) }
            }
            withAnimation(settings.motion.overlay) { appeared = true }
        }
        .onChange(of: store.aiIsResponding) { _, responding in
            if responding { thinkingStartedAt = Date() }
        }
        .onChange(of: store.aiFocusRequest) { _, _ in
            inputFocused = true
        }
        .onChange(of: store.sidebarItem) { _, _ in
            store.refreshAIContextCapsules()
        }
        .onChange(of: store.selection.count) { _, _ in
            store.refreshAIContextCapsules()
        }
        .onChange(of: store.searchText) { _, _ in
            store.refreshAIContextCapsules()
        }
        .onChange(of: voice.transcript) { _, text in
            guard voice.isRecording || !text.isEmpty else { return }
            store.aiInput = voiceBase + text
        }
    }

    // MARK: - 背景

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                           startPoint: .topLeading, endPoint: .center)
            RadialGradient(colors: [Color.accentColor.opacity(0.07), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 460)
        }
        .ignoresSafeArea()
    }

    private var divider: some View {
        Divider().opacity(0.55)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color.accentColor,
                                                Color.accentColor.opacity(0.62)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 9, y: 3)
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(isInspector ? "助手" : "智能助手")
                        .font(.system(size: 15, weight: .semibold))
                    if effectiveWidth >= 700 {
                        badge(store.aiConfig.provider.title)
                        badge(store.aiConfig.mode.title, icon: store.aiConfig.mode.symbol)
                            .help("当前模式：\(store.aiConfig.mode.detail)；可在输入框左侧切换")
                    }
                    if effectiveWidth >= 620 {
                        badge("\(domains.count) 个领域 · \(AILibraryTools.count) 项能力", accent: true)
                            .help("共 \(AILibraryTools.count) 项本地工具，分为图库、影院、网络影院、网络资源与网络电视 5 个领域；修改前会弹窗确认")
                    }
                    if store.aiConfig.approval == .automatic, effectiveWidth >= 620 {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.badge.automatic.fill")
                                .font(.system(size: 9, weight: .medium))
                            Text("自动应用")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help("当前为自动应用：AI 写操作不再弹窗，可在控制台 › 角色与审批调整")
                    }
                    if store.aiConfig.includeImages, effectiveWidth >= 620 {
                        badge("图片理解", icon: "photo")
                    }
                    if effectiveWidth >= 620,
                       !store.aiMemories.filter(\.isEnabled).isEmpty {
                        badge("记忆 \(store.aiMemories.filter(\.isEnabled).count)", icon: "brain")
                    }
                    if effectiveWidth >= 620,
                       !store.aiSchedules.filter(\.isEnabled).isEmpty {
                        badge("定时 \(store.aiSchedules.filter(\.isEnabled).count)",
                              icon: "clock.arrow.circlepath")
                    }
                    if effectiveWidth >= 620, store.aiConfig.agentRole != .auto {
                        badge(store.aiConfig.agentRole.title,
                              icon: store.aiConfig.agentRole.symbol)
                    }
                }
                HStack(spacing: 6) {
                    // 侧栏只有 320–560pt，标题留白优先；把位置名放在工具提示里，避免被挤成「拾…」。
                    if !isInspector {
                        Text(contextAreaTitle)
                        Text("·")
                    }
                    Text("\(store.visibleCount.formatted()) 项")
                    Text("·")
                    Text("选中 \(store.selection.count)")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.65))
                .lineLimit(1)
                .help("当前位置：\(contextAreaTitle)")
            }

            Spacer(minLength: 8)

            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.aiMessages.isEmpty)
            .help("新对话（清空当前对话）")

            Button {
                store.showAIControlCenter = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("助手控制台：模型、角色、记忆、技能与定时任务")

            if presentation.showsExpandAction {
                Button {
                    if let onExpand {
                        onExpand()
                    } else {
                        store.expandAISurface()
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help(presentation == .inspector ? "展开为浮窗（⇧⌘J）" : "切换到浮窗（⇧⌘J）")
            }

            if !isInspector, let onCollapse {
                Button {
                    onCollapse()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("收进并排侧栏")
            }

            Button {
                // 收起时，如果正等计划 / 审批，先把这次任务收尾，避免后台悬挂。
                if store.aiPendingPlan != nil || store.aiPendingApproval != nil {
                    store.cancelAIPendingInteractions()
                }
                if let onClose {
                    onClose()
                } else if isInspector {
                    store.hideAISurface()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isInspector ? "收起侧边栏" : "关闭")
        }
        .padding(.horizontal, isInspector ? 14 : 20)
        .padding(.vertical, isInspector ? 12 : 15)
    }

    private func badge(_ text: String, icon: String? = nil, accent: Bool = false) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .medium))
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(accent ? Color.accentColor : Color.primary.opacity(0.72))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(accent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06),
                    in: Capsule())
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: isInspector ? 14 : 18) {
                    if store.aiMessages.isEmpty {
                        welcome
                    }
                    ForEach(chatItems) { item in
                        switch item {
                        case .message(let message):
                            messageRow(message)
                                .id(message.id)
                        case .actionGroup(let key, let items):
                            actionGroupRow(key: key, items: items)
                                .id(key)
                        }
                    }
                    if store.aiIsResponding {
                        if store.aiStreamingText.isEmpty {
                            thinkingRow
                        } else {
                            liveStreamingRow
                        }
                    }
                    // 滚到底用的锚点：执行轨迹与回复交错时也能稳定滚到最新内容。
                    Color.clear.frame(height: 1).id("ai.bottom")
                }
                .frame(maxWidth: isInspector ? .infinity : 860, alignment: .leading)
                .padding(.horizontal, isInspector ? 12 : 22)
                .padding(.vertical, isInspector ? 14 : 20)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.aiMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.aiIsResponding) { _, responding in
                if responding { scrollToBottom(proxy) }
            }
            .onChange(of: store.aiActivity) { _, _ in
                if store.aiIsResponding { scrollToBottom(proxy) }
            }
            .onChange(of: store.aiStreamingText) { _, _ in
                if store.aiIsResponding { scrollToBottom(proxy) }
            }
        }
    }

    /// 对话流里的单元：连续的工具回执合并成一张「执行轨迹」卡。
    private enum ChatItem: Identifiable {
        case message(AIChatMessage)
        case actionGroup(key: String, items: [AIChatMessage])

        var id: String {
            switch self {
            case .message(let message): return message.id.uuidString
            case .actionGroup(let key, _): return key
            }
        }
    }

    private var chatItems: [ChatItem] {
        var result: [ChatItem] = []
        var pending: [AIChatMessage] = []
        func flush() {
            guard let first = pending.first else { return }
            result.append(.actionGroup(key: "actions-" + first.id.uuidString, items: pending))
            pending.removeAll()
        }
        for message in store.aiMessages {
            if message.role == .action {
                pending.append(message)
            } else {
                flush()
                result.append(.message(message))
            }
        }
        flush()
        return result
    }

    // MARK: - 欢迎页

    private var welcome: some View {
        VStack(spacing: 18) {
            VStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color.accentColor,
                                                    Color.accentColor.opacity(0.48)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.accentColor.opacity(0.32), radius: 14, y: 5)
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.top, 12)

                VStack(spacing: 7) {
                    Text("把想法说出来，剩下的交给我。")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [.primary, Color.accentColor],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    Text("图库整理、影院刮削、跨源检索、电视直播与播放，一句话就能直接执行；\(AILibraryTools.count) 项工具覆盖 \(domains.count) 个领域，修改数据前会先向你确认。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    heroStat(icon: "square.grid.2x2.fill",
                             value: "\(domains.count) 个领域", detail: "图库到电视")
                    heroStat(icon: "wrench.and.screwdriver.fill",
                             value: "\(AILibraryTools.count) 项工具", detail: "真实可执行")
                    heroStat(icon: "checkmark.shield.fill",
                             value: "\(AILibraryTools.writeToolNames.count) 项写操作", detail: "默认需确认")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                welcomeSectionHeader("上手试试", detail: "点一下填进输入框，按需再改")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: effectiveWidth < 780 ? 1 : 2),
                          alignment: .leading,
                          spacing: 10) {
                    ForEach(cases) { item in
                        caseCard(item)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                welcomeSectionHeader("深度场景", detail: "组合多个工具，一句话完成一整件事")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: effectiveWidth < 780 ? 1 : 2),
                          alignment: .leading,
                          spacing: 10) {
                    ForEach(deepScenarios) { scenario in
                        deepScenarioCard(scenario)
                    }
                }
            }

            if !store.aiArtifactLibrary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    welcomeSectionHeader("成果物库", detail: "跨对话保留，可打开或移除")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                             count: effectiveWidth < 780 ? 1 : 2),
                              alignment: .leading,
                              spacing: 10) {
                        ForEach(Array(store.aiArtifactLibrary.prefix(isInspector ? 4 : 6))) { artifact in
                            artifactLibraryCard(artifact)
                        }
                    }
                }
            }

            if !isInspector {
                unifiedSearchBanner

                VStack(alignment: .leading, spacing: 10) {
                    welcomeSectionHeader("能力全景",
                                         detail: "\(domains.count) 个领域 · \(AILibraryTools.count) 项工具 · 当前页面排在前面")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                             count: effectiveWidth < 780 ? 1 : 2),
                              alignment: .leading,
                              spacing: 10) {
                        ForEach(domains) { domain in
                            domainCard(domain)
                        }
                    }
                }
            }

            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("默认只发送元数据与端侧标签，不包含原图；写操作默认先确认，Key 保存在钥匙串。")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

                HStack(spacing: 6) {
                    Image(systemName: store.aiConfig.mode.symbol)
                    Text("当前模式：\(store.aiConfig.mode.title) · \(store.aiConfig.mode.detail)")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            if !store.aiHasAPIKey {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .foregroundStyle(Color.accentColor)
                    Text("还没有填写 \(store.aiConfig.provider.title) 的 API Key。")
                        .font(.system(size: 11.5))
                    Spacer(minLength: 8)
                    SettingsLink {
                        Text("打开设置")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
    }

    private func caseCard(_ item: CaseCard) -> some View {
        let hovered = hoveredID == item.id
        return Button {
            insert(item.prompt)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(hovered ? 0.22 : 0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                Text(item.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 8))
                    Text(item.prompt)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovered ? 0.075 : 0.04),
                        in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(hovered ? 0.30 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? item.id : nil
            }
        }
        .help("填入输入框")
    }

    /// 深度场景卡：标题 + 一句说明 + 可直接执行的完整指令。
    private func deepScenarioCard(_ item: DeepScenario) -> some View {
        let hovered = hoveredID == item.id
        return Button {
            insert(item.prompt)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(hovered ? 0.22 : 0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.45))
                    }
                    Text(item.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 7))
                        Text(item.prompt)
                            .font(.system(size: 9.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovered ? 0.075 : 0.04),
                        in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(hovered ? 0.26 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? item.id : nil
            }
        }
        .help("填入输入框")
    }

    /// 首页顶部的小统计：领域数 / 工具数 / 需要确认的写操作数。
    private func heroStat(icon: String, value: String, detail: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.045), in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.10), lineWidth: 1))
    }

    private func welcomeSectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    /// 跨源统一检索：一次问遍六个来源，是单个模块卡片装不下的能力。
    private var unifiedSearchBanner: some View {
        let hovered = hoveredID == "unified-search"
        let prompt = "在全部来源里一起搜「海边」，把每个来源的结果都列出来"
        return Button {
            insert(prompt)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(hovered ? 0.22 : 0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("跨源统一检索")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("一次问遍图库、网盘、影院、网络影院、网络电视与网络资源，按来源分区返回。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("试一下")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(hovered ? 0.075 : 0.05),
                        in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(hovered ? 0.28 : 0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? "unified-search" : nil
            }
        }
        .help("填入输入框")
    }

    /// 能力领域卡：工具数来自真实注册表，能力名与示例都可直接提问。
    private func domainCard(_ domain: CapabilityDomain) -> some View {
        let hovered = hoveredID == domain.id
        let current = domain.id == currentDomainID
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(hovered || current ? 0.20 : 0.13))
                        .frame(width: 30, height: 30)
                    Image(systemName: domain.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(domain.title)
                            .font(.system(size: 12.5, weight: .semibold))
                        if current {
                            Text("当前")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(domain.tagline)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(domain.toolCount) 项")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(hovered || current ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }

            FlexibleTagLayout(spacing: 5) {
                ForEach(domain.abilities, id: \.self) { ability in
                    Text(ability)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }

            VStack(spacing: 5) {
                ForEach(domain.examples, id: \.self) { example in
                    Button {
                        insert(example)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 8))
                            Text(example)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(hovered ? 0.10 : 0.07),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("填入输入框")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(current ? 0.055 : (hovered ? 0.075 : 0.04)),
                    in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                .stroke(Color.accentColor.opacity(current ? 0.22 : (hovered ? 0.18 : 0.08)),
                        lineWidth: 1)
        )
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredID = inside ? domain.id : nil
            }
        }
    }

    // MARK: - 消息行

    @ViewBuilder
    private func messageRow(_ message: AIChatMessage) -> some View {
        switch message.role {
        case .user:
            userRow(message)
        case .action:
            actionRow(message)
        case .assistant:
            assistantRow(message)
        }
    }

    private func userRow(_ message: AIChatMessage) -> some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 5) {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [Color.accentColor.opacity(0.24),
                                                Color.accentColor.opacity(0.13)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                    )
                HStack(spacing: 6) {
                    if message.id == lastUserID, !store.aiIsResponding {
                        editButton(message)
                    }
                    copyButton(message)
                }
                .opacity(hoveredMessageID == message.id ? 1 : 0)
                .allowsHitTesting(hoveredMessageID == message.id)
            }
            .frame(maxWidth: 520, alignment: .trailing)
        }
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredMessageID = inside ? message.id
                    : (hoveredMessageID == message.id ? nil : hoveredMessageID)
            }
        }
    }

    private func assistantRow(_ message: AIChatMessage) -> some View {
        let parsed = message.isError
            ? (text: message.text, choices: [AIActionChoice]())
            : parseActionChoices(from: message.text)
        return HStack(alignment: .top, spacing: 10) {
            miniAvatar(tint: message.isError ? .red : Color.accentColor,
                       icon: message.isError ? "exclamationmark" : "sparkles")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(isInspector ? "助手" : "智能助手")
                        .font(.system(size: 12, weight: .semibold))
                    Text(assistantMeta(message))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if message.id == lastAssistantID, !store.aiIsResponding {
                        regenerateButton(message)
                            .opacity(hoveredMessageID == message.id ? 1 : 0)
                            .allowsHitTesting(hoveredMessageID == message.id)
                    }
                    copyButton(message)
                        .opacity(hoveredMessageID == message.id ? 1 : 0)
                        .allowsHitTesting(hoveredMessageID == message.id)
                }

                VStack(alignment: .leading, spacing: 9) {
                    if let plan = message.plan {
                        planCard(plan)
                    }

                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        reasoningDisclosure(reasoning)
                    }

                    AIMarkdownText(text: parsed.text,
                                   tint: message.isError ? Color.red : Color.primary)

                    if !parsed.choices.isEmpty {
                        actionChoiceButtons(parsed.choices)
                    }

                    if let code = message.errorCode, message.isError {
                        aiErrorActions(code)
                    }

                    if !message.photoIDs.isEmpty {
                        photoStrip(message.photoIDs)
                    }

                    if !message.previews.isEmpty {
                        previewStrip(message.previews)
                    }

                    if !message.artifacts.isEmpty {
                        artifactStrip(message.artifacts)
                    }

                    if let suggestion = message.suggestion,
                       (suggestion.keywords?.isEmpty == false) || (suggestion.filter?.isEmpty == false) {
                        suggestionCard(suggestion)
                    }

                    if store.canUndoAITask(message.taskID) {
                        undoTaskButton(message.taskID)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(message.isError
                              ? Color.red.opacity(0.07)
                              : Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(message.isError
                                ? Color.red.opacity(0.22)
                                : Color.primary.opacity(0.07),
                                lineWidth: 1)
                )
            }
        }
        .onHover { inside in
            withAnimation(settings.motion.hover) {
                hoveredMessageID = inside ? message.id
                    : (hoveredMessageID == message.id ? nil : hoveredMessageID)
            }
        }
    }

    // MARK: - 可执行动作

    /// 把「可选：① …；② …」渲染成可点击动作，点一下直接把该条指令发给助手执行。
    private func actionChoiceButtons(_ choices: [AIActionChoice]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("点击执行")
                    .font(.system(size: 10, weight: .semibold))
                if store.aiIsResponding {
                    Text("· 等本轮结束")
                        .font(.system(size: 9.5))
                }
            }
            .foregroundStyle(.secondary)

            ForEach(choices) { choice in
                Button {
                    guard !store.aiIsResponding else { return }
                    store.aiInput = choice.title
                    store.sendAIMessage()
                } label: {
                    HStack(spacing: 8) {
                        Text("\(choice.index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Color.accentColor))
                        Text(choice.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.65))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.aiIsResponding)
                .help("让助手执行：\(choice.title)")
            }
        }
    }

    /// 解析回答里的「可选：① …；② …」段落；解析成功时把这段从正文中移除，避免和动作按钮重复。
    private func parseActionChoices(from text: String) -> (text: String, choices: [AIActionChoice]) {
        guard let marker = text.range(of: "可选：") ?? text.range(of: "可选:") else {
            return (text, [])
        }
        let tail = text[marker.upperBound...]
        let terminator = tail.firstIndex(where: { $0 == "。" || $0 == "\n" }) ?? tail.endIndex
        let choices = parseActionItems(String(tail[..<terminator]))
        guard choices.count >= 2 else { return (text, []) }

        var visible = text
        let end = terminator < tail.endIndex ? text.index(after: terminator) : terminator
        visible.removeSubrange(marker.lowerBound..<end)
        visible = visible
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (visible.isEmpty ? text : visible, choices)
    }

    private func parseActionItems(_ segment: String) -> [AIActionChoice] {
        let marks: Set<Character> = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]
        var raw: [String] = []
        if segment.contains(where: { marks.contains($0) }) {
            var current = ""
            for character in segment {
                if marks.contains(character) {
                    if !current.isEmpty { raw.append(current) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { raw.append(current) }
        } else {
            raw = segment.split(whereSeparator: { $0 == "；" || $0 == ";" }).map(String.init)
        }

        let trimmings = CharacterSet.whitespaces
            .union(CharacterSet(charactersIn: "；;，,。.、"))
        let items = raw
            .map { stripActionPrefix($0.trimmingCharacters(in: trimmings)) }
            .filter { !$0.isEmpty }
        guard (2...6).contains(items.count) else { return [] }
        return items.enumerated().map { AIActionChoice(index: $0.offset, title: $0.element) }
    }

    private func stripActionPrefix(_ item: String) -> String {
        let digits = item.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 2 else { return item }
        let rest = item.dropFirst(digits.count)
        for separator in [". ", "、", ")", "）", ": ", "："] where rest.hasPrefix(separator) {
            return String(rest.dropFirst(separator.count)).trimmingCharacters(in: .whitespaces)
        }
        return item
    }

    // MARK: - 计划 / 成果物 / 撤销 / 错误

    private func riskTint(_ risk: AIRiskLevel) -> Color {
        switch risk {
        case .read: return .gray
        case .reversible: return .green
        case .destructive: return .red
        case .external: return .orange
        }
    }

    private func riskPill(_ risk: AIRiskLevel) -> some View {
        Text(risk.title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(riskTint(risk))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(riskTint(risk).opacity(0.12), in: Capsule())
    }

    private func planCard(_ plan: AIPlan) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("执行计划")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(plan.status == .pending ? "待批准" : plan.status == .approved ? "已批准" : "已取消")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(plan.status == .pending ? Color.orange : plan.status == .approved ? Color.green : Color.gray)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((plan.status == .pending ? Color.orange : plan.status == .approved ? Color.green : Color.gray).opacity(0.12), in: Capsule())
            }

            Text(plan.summary)
                .font(.system(size: 12.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 5) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 17, height: 17)
                            .background(Color.primary.opacity(0.06), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.system(size: 11.5, weight: .medium))
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        riskPill(step.risk)
                    }
                }
            }

            if plan.status == .pending, store.aiPendingPlan?.id == plan.id {
                HStack(spacing: 7) {
                    Button("调整计划") { store.adjustAIPlan() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    Button("批准执行") { store.approveAIPlan() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: Capsule())
                    Button("取消") { store.cancelAIPlan() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(11)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private func artifactLibraryCard(_ artifact: AIArtifact) -> some View {
        Button {
            store.openAIArtifact(artifact)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 30, height: 30)
                    Image(systemName: artifact.kind.symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !artifact.detail.isEmpty {
                        Text(artifact.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 5) {
                        Text(artifact.kind.title)
                        if artifact.count > 0 { Text("· \(artifact.count) 项") }
                        Text("·")
                        Text(artifact.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("从成果物库移除", role: .destructive) {
                store.removeAIArtifact(artifact)
            }
        }
        .help("打开\(artifact.kind.title)")
    }

    private func artifactStrip(_ artifacts: [AIArtifact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(artifacts) { artifact in
                Button {
                    store.openAIArtifact(artifact)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: artifact.kind.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(artifact.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                            if !artifact.detail.isEmpty {
                                Text(artifact.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if artifact.count > 0 {
                            Text("\(artifact.count)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("打开\(artifact.kind.title)")
            }
            if store.aiArtifactLibrary.count > artifacts.count {
                Button {
                    store.showAIArtifactSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 9, weight: .semibold))
                        Text("全部 \(store.aiArtifactLibrary.count) 个成果物")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("打开成果物库")
            }
        }
    }

    private func undoTaskButton(_ taskID: UUID?) -> some View {
        Button {
            store.undoAITask(taskID)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("撤销本次修改")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("撤销这次任务里所有可逆操作")
    }

    private func aiErrorActions(_ code: AIErrorCode) -> some View {
        HStack(spacing: 7) {
            Button("重试") {
                store.regenerateAIResponse()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.10), in: Capsule())

            SettingsLink {
                Text("打开设置")
            }
            .controlSize(.mini)

            Spacer(minLength: 0)
            Text(code.title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 实时时间线

    private var liveStreamingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            miniAvatar(tint: Color.accentColor, icon: "sparkles")
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(isInspector ? "助手" : "智能助手")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.aiActivity ?? "正在回答")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    takeoverButton
                    elapsedLabel
                }
                if !store.aiStreamingReasoning.isEmpty {
                    DisclosureGroup {
                        Text(store.aiStreamingReasoning)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 3)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                                .font(.system(size: 9, weight: .semibold))
                            Text("思考中")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Text(store.aiStreamingText.isEmpty ? "正在思考…" : store.aiStreamingText + " ▍")
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                if !store.aiToolSteps.isEmpty {
                    liveToolSteps
                }
            }
        }
    }

    private var liveToolSteps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(store.aiToolSteps.suffix(8))) { step in
                HStack(spacing: 6) {
                    Image(systemName: step.status == .running
                          ? "circle.dotted"
                          : step.status == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(step.status == .running ? Color.accentColor
                                         : step.status == .done ? .green : .red)
                    Text(step.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if !step.detail.isEmpty {
                        Text(step.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let duration = step.duration {
                        Text(String(format: "%.1fs", duration))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 接管

    private var takeoverButton: some View {
        Button {
            store.requestAITakeover()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.aiTakeoverRequested ? "hourglass" : "hand.raised")
                    .font(.system(size: 9, weight: .semibold))
                Text(store.aiTakeoverRequested ? "等待暂停" : "接管")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.aiTakeoverPaused)
        .help("暂停 AI，自己动手处理；完成后再决定继续或结束")
    }

    private var takeoverBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("你已接管，AI 暂停中")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("可以先去图库、影院或电视里处理；完成后选择继续或结束。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("结束任务") {
                store.endAITaskFromTakeover()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())

            Button("继续执行") {
                store.resumeAITaskFromTakeover()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.orange, in: Capsule())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - 审批

    private func aiQuestionOverlay(_ question: AIQuestionRequest) -> some View {
        ZStack {
            Color.black.opacity(0.16)
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Image(systemName: "questionmark.bubble")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("需要你确认")
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 0)
                }

                Text(question.question)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)

                if !question.options.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(question.options, id: \.self) { option in
                            Button {
                                submitQuestion(option)
                            } label: {
                                HStack {
                                    Text(option)
                                        .font(.system(size: 11.5, weight: .medium))
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.primary.opacity(0.045),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("也可以自己输入…", text: $questionDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .focused($questionFocused)
                        .onSubmit { submitQuestion() }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Button("回答") {
                        submitQuestion()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .disabled(questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }

                HStack {
                    Button("跳过，让助手按保守方式继续") {
                        store.resolveAIQuestion(nil)
                        questionDraft = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 24, y: 10)
            .padding(18)
        }
        .onAppear {
            questionDraft = ""
            questionFocused = true
        }
    }

    private func submitQuestion(_ answer: String? = nil) {
        let text = (answer ?? questionDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.resolveAIQuestion(text)
        questionDraft = ""
    }

    private func aiApprovalOverlay(_ request: AIApprovalRequest) -> some View {
        ZStack {
            Color.black.opacity(0.16)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(request.highestRisk == .destructive ? .red : Color.accentColor)
                    Text(request.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 0)
                    riskPill(request.highestRisk)
                }

                if !request.summary.isEmpty {
                    Text(request.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(request.items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                    if !item.detail.isEmpty {
                                        Text(item.detail)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 4)
                                riskPill(item.risk)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 230)

                Text("允许后仍可在对话里撤销可逆操作；高风险操作会保留检查点。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Button("取消") {
                        store.resolveAIApproval(.deny)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    if request.allowsTaskScope {
                        Button("本次都允许") {
                            store.resolveAIApproval(.allowTask)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    if !request.memorableToolNames.isEmpty {
                        Button("始终允许") {
                            store.resolveAIApproval(.allowAlways)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .help("记住这些可逆写工具，之后同类操作不再确认；可在控制台 › 角色与审批中清除。高风险与外部连接器不会被记住。")
                    }

                    Button("允许") {
                        store.resolveAIApproval(.allowOnce)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(16)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 24, y: 10)
            .padding(18)
        }
    }

    /// 执行轨迹里的合并项：相同文字只显示一次并计数。
    private struct TraceItem: Identifiable {
        let text: String
        let count: Int
        var id: String { text }
    }

    private func condensedTrace(_ items: [AIChatMessage]) -> [TraceItem] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for message in items {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if counts[text] == nil { order.append(text) }
            counts[text, default: 0] += 1
        }
        return order.map { TraceItem(text: $0, count: counts[$0] ?? 1) }
    }

    private func traceIcon(_ text: String) -> String {
        if text.hasPrefix("查看") { return "folder" }
        if text.hasPrefix("读取") { return "list.bullet" }
        if text.hasPrefix("搜索") { return "magnifyingglass" }
        if text.hasPrefix("写回") || text.contains("匹配") { return "arrow.triangle.merge" }
        if text.hasPrefix("播放") { return "play.fill" }
        if text.hasPrefix("选中") { return "cursorarrow" }
        if text.hasPrefix("压缩") || text.hasPrefix("美化") { return "wand.and.rays" }
        if text.hasPrefix("已") { return "checkmark" }
        return "circle"
    }

    private func traceSummary(_ items: [TraceItem]) -> String {
        items.prefix(3)
            .map { $0.count > 1 ? "\($0.text) ×\($0.count)" : $0.text }
            .joined(separator: "  ·  ")
    }

    /// 一段连续的工具回执：合并重复步骤、默认折叠，只展示可读摘要。
    private func actionGroupRow(key: String, items: [AIChatMessage]) -> some View {
        let trace = condensedTrace(items)
        let collapsed = collapsedActionGroups.contains(key)
            || (items.count > 4 && !expandedActionGroups.contains(key))
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 24, height: 24)
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.green)
            }

            VStack(alignment: .leading, spacing: 7) {
                Button {
                    withAnimation(settings.motion.layout) {
                        if collapsed {
                            collapsedActionGroups.remove(key)
                            expandedActionGroups.insert(key)
                        } else {
                            expandedActionGroups.remove(key)
                            collapsedActionGroups.insert(key)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text("执行轨迹")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("\(items.count) 步")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                        if trace.count < items.count {
                            Text("\(trace.count) 类")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(collapsed ? "展开执行步骤" : "收起执行步骤")

                if collapsed {
                    if !trace.isEmpty {
                        Text(traceSummary(trace))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(trace.map(\.text).joined(separator: "\n"))
                            .padding(.leading, 1)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(trace.prefix(30).enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider()
                                    .opacity(0.35)
                                    .padding(.leading, 20)
                            }
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: traceIcon(item.text))
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 12)
                                Text(item.text)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(item.text)
                                if item.count > 1 {
                                    Text("×\(item.count)")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.05), in: Capsule())
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                        }
                        if trace.count > 30 {
                            Text("还有 \(trace.count - 30) 类操作…")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.leading, 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(.leading, 32)
    }

    /// 单条回执的兜底渲染（连续回执会走 actionGroupRow）。
    private func actionRow(_ message: AIChatMessage) -> some View {
        actionGroupRow(key: "actions-" + message.id.uuidString, items: [message])
    }

    private var thinkingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            miniAvatar(tint: Color.accentColor, icon: "sparkles")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("智能助手")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.aiActivity ?? "正在思考")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    elapsedLabel
                }

                HStack(spacing: 9) {
                    ThinkingDots()
                    Text(store.aiToolSteps.isEmpty ? "正在为你执行，稍候…" : "正在执行 \(store.aiToolSteps.count) 个步骤…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

                if !store.aiToolSteps.isEmpty {
                    liveToolSteps
                }
            }
        }
    }

    /// 运行中已用时：让长任务有进度感。
    private var elapsedLabel: some View {
        TimelineView(.periodic(from: thinkingStartedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(thinkingStartedAt)))
            Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m\(seconds % 60)s")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var lastAssistantID: UUID? {
        store.aiMessages.last(where: { $0.role == .assistant })?.id
    }

    /// 思考摘要：默认折叠，避免挤占回答；端点不返回 reasoning 时不出现。
    private func reasoningDisclosure(_ reasoning: String) -> some View {
        DisclosureGroup {
            Text(reasoning)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 9, weight: .semibold))
                Text("思考过程")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var lastUserID: UUID? {
        store.aiMessages.last(where: { $0.role == .user })?.id
    }

    /// 只对最后一条用户消息提供：截断后续回复后放回输入框，改完再发。
    private func editButton(_ message: AIChatMessage) -> some View {
        Button {
            store.beginEditingAIMessage(message.id)
            inputFocused = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 8.5, weight: .semibold))
                Text("编辑重发")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("把这条消息放回输入框，这之后的回复会被移除")
    }

    /// 助手消息页脚：时间 · 用时 · 执行步数。
    private func assistantMeta(_ message: AIChatMessage) -> String {
        var parts = [Self.timeFormatter.string(from: message.createdAt)]
        if let elapsed = message.elapsed, elapsed >= 0.1 {
            parts.append(String(format: "%.1fs", elapsed))
        }
        if let steps = message.toolSteps, steps > 0 {
            parts.append("\(steps) 步")
        }
        if let prompt = message.promptTokens, let completion = message.completionTokens,
           prompt + completion > 0 {
            parts.append("\(prompt + completion) tok")
        }
        return parts.joined(separator: " · ")
    }

    private func regenerateButton(_ message: AIChatMessage) -> some View {
        Button {
            store.regenerateAIResponse()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(message.isError ? "重试" : "重新生成")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(message.isError ? "重试上一条请求" : "重新生成这条回复")
    }

    private func copyButton(_ message: AIChatMessage) -> some View {
        Button {
            copy(message)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedMessageID == message.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(copiedMessageID == message.id ? "已复制" : "复制")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(copiedMessageID == message.id ? Color.green : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("复制这条消息")
    }

    private func copy(_ message: AIChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        withAnimation(settings.motion.hover) { copiedMessageID = message.id }
        store.showToast("已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedMessageID == message.id {
                withAnimation(settings.motion.hover) { copiedMessageID = nil }
            }
        }
    }

    private func miniAvatar(tint: Color, icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 24, height: 24)
                .shadow(color: tint.opacity(0.22), radius: 4, y: 1)
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - 内容渲染

    private func photoStrip(_ ids: [UUID]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    if let photo = store.anyPhoto(id: id) {
                        photoCard(photo)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func photoCard(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .top) {
                PhotoThumbnailView(photo: photo, purpose: .cover(84))
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 4) {
                    if let rating = photo.rating, rating > 0 {
                        Text(String(repeating: "★", count: min(rating, 5)))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.42), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if photo.isVideo {
                        Image(systemName: "video.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.42), in: Circle())
                    }
                }
                .padding(5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            Text(photo.originalName)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
        }
        .onTapGesture {
            store.openViewer(photo.id)
        }
        .help(photo.displayFilename)
    }

    private struct PreviewGroup: Identifiable {
        let domain: AIResultDomain
        let items: [AIResultPreview]
        var id: String { domain.rawValue }
    }

    private func previewStrip(_ previews: [AIResultPreview]) -> some View {
        let groups: [PreviewGroup] = AIResultDomain.allCases.compactMap { domain in
            let items = previews.filter { $0.domain == domain }
            return items.isEmpty ? nil : PreviewGroup(domain: domain, items: items)
        }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: group.domain.symbol)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(moduleTint(group.domain))
                        Text(group.domain.title)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("\(group.items.count) 项")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(group.items) { item in
                                previewCard(item)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private func previewCard(_ item: AIResultPreview) -> some View {
        let width: CGFloat = item.domain.isPortrait ? 88 : 134
        let height: CGFloat = item.domain.isPortrait ? 126 : 76
        return Button {
            store.openAIPreview(item)
        } label: {
            ZStack(alignment: .topTrailing) {
                previewArtwork(item, width: width, height: height)
                LinearGradient(colors: [.clear, .black.opacity(0.68)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                Image(systemName: item.domain.symbol)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.38), in: Circle())
                    .padding(5)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("在\(item.domain.title)中打开「\(item.title)」")
    }

    @ViewBuilder
    private func previewArtwork(_ item: AIResultPreview, width: CGFloat, height: CGFloat) -> some View {
        if let raw = item.imageURL, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    modulePlaceholder(item.domain)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        } else {
            modulePlaceholder(item.domain)
                .frame(width: width, height: height)
        }
    }

    private func modulePlaceholder(_ domain: AIResultDomain) -> some View {
        ZStack {
            LinearGradient(colors: [moduleTint(domain).opacity(0.62),
                                    moduleTint(domain).opacity(0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: domain.symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func moduleTint(_ domain: AIResultDomain) -> Color {
        switch domain {
        case .photo: return .blue
        case .cinema: return .orange
        case .catalog: return .purple
        case .networkCinema: return .pink
        case .tv: return .teal
        }
    }

    private func suggestionCard(_ suggestion: AISearchSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let keywords = suggestion.keywords, !keywords.isEmpty {
                    Text("搜索：\(keywords)")
                        .font(.system(size: 11.5, weight: .medium))
                }
                if let raw = suggestion.filter,
                   let filter = PhotoFilter(rawValue: raw) {
                    Text("筛选：\(filter.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("应用到当前网格") {
                store.applyAISuggestion(suggestion)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 输入

    private var composer: some View {
        @Bindable var store = store
        return VStack(spacing: 9) {
            if store.aiTakeoverPaused {
                takeoverBar
            }

            if let error = store.aiError {
                errorBanner(error)
            }

            if !store.aiContextCapsules.isEmpty {
                contextChips
            }

            if !store.aiMessages.isEmpty, !store.aiIsResponding {
                quickCommands
            }

            if !store.aiMentionedPhotoIDs.isEmpty || store.aiMentionedTimecode != nil
                || store.aiViewerTimecodeLabel != nil {
                mentionChips
            }

            VStack(spacing: 8) {
                if let query = mentionQuery {
                    mentionPanel(query: query)
                }

                ZStack(alignment: .topLeading) {
                    if store.aiInput.isEmpty {
                        Text(inputPlaceholder)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $store.aiInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .onSubmit {
                            store.sendAIMessage()
                        }
                        .onChange(of: store.aiInput) { _, value in
                            updateMentionQuery(value)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                }

                HStack(spacing: 8) {
                    imageToggleButton
                    voiceButton
                    modeMenu
                    planModeButton
                    if !isInspector {
                        modelChip
                    }
                    Spacer(minLength: 0)
                    if !isInspector {
                        Text("↩ 发送")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    sendButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(inputFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                            lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 12, y: 4)
            .animation(settings.motion.hover, value: inputFocused)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 5, height: 5)
                Text("\(store.aiConfig.provider.title) · \(store.aiConfig.model)")
                    .lineLimit(1)
                if !isInspector {
                    Text("·")
                    if store.aiConfig.provider == .local {
                        localServiceStatus
                    } else {
                        Text(store.aiHasAPIKey ? "Key 已保存在钥匙串" : "未配置 Key")
                    }
                    if store.aiConfig.includeImages {
                        Text("· 图片理解已开启")
                    }
                }
                Spacer(minLength: 0)
                Text("\(store.aiConfig.mode.title)")
                if store.aiForcePlan {
                    Text("· 计划模式")
                }
                if store.aiLastToolCount > 0 {
                    Text("· \(store.aiLastToolCount) 工具")
                } else {
                    Text("· 记忆 \(store.aiConfig.historyRounds) 轮")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.trailing, 16)
        }
        .frame(maxWidth: isInspector ? .infinity : 860)
        .padding(.horizontal, isInspector ? 12 : 22)
        .padding(.top, isInspector ? 10 : 12)
        .padding(.bottom, isInspector ? 10 : 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 指认

    private func updateMentionQuery(_ text: String) {
        guard let at = text.lastIndex(of: "@") else {
            mentionQuery = nil
            return
        }
        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            guard previous.isWhitespace || "，。,.!?！？、；;：:（(".contains(previous) else {
                mentionQuery = nil
                return
            }
        }
        let token = text[text.index(after: at)...]
        guard !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              token.count <= 24 else {
            mentionQuery = nil
            return
        }
        mentionQuery = String(token)
    }

    private func insertMention(_ photo: PhotoItem) {
        let token = "@" + (mentionQuery ?? "")
        if let range = store.aiInput.range(of: token, options: .backwards) {
            store.aiInput.replaceSubrange(range, with: "@\(photo.originalName) ")
        } else {
            store.aiInput += "@\(photo.originalName) "
        }
        store.pinAIMention(photo)
        mentionQuery = nil
        inputFocused = true
    }

    private func insertTimecodeMention() {
        guard let seconds = store.aiViewerTimecode, let label = store.aiViewerTimecodeLabel else { return }
        let token = "@" + (mentionQuery ?? "")
        if let range = store.aiInput.range(of: token, options: .backwards) {
            store.aiInput.replaceSubrange(range, with: "@\(label) ")
        }
        store.pinAIMentionTimecode(seconds)
        mentionQuery = nil
        inputFocused = true
    }

    private func mentionPanel(query: String) -> some View {
        let candidates = store.aiMentionCandidates(query)
        let timecode = store.aiViewerTimecodeLabel
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "at")
                    .font(.system(size: 9, weight: .semibold))
                Text("指认给助手")
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                Text("点一项插入")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)

            if query.isEmpty, let timecode {
                Button {
                    insertTimecodeMention()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("当前视频 \(timecode)")
                                .font(.system(size: 11, weight: .medium))
                            Text("指认这个时间点，问「这里在讲什么」")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(candidates) { photo in
                Button {
                    insertMention(photo)
                } label: {
                    HStack(spacing: 8) {
                        PhotoThumbnailView(photo: photo, purpose: .cover(24))
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(photo.originalName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(photo.filename)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(photo.isVideo ? "视频" : "照片")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if candidates.isEmpty, timecode == nil, !query.isEmpty {
                Text("没有匹配的照片")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private var mentionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.aiMentionedPhotos) { photo in
                    HStack(spacing: 4) {
                        PhotoThumbnailView(photo: photo, purpose: .cover(18))
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(photo.originalName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Button {
                            store.unpinAIMention(photo.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                }

                if let pinned = store.aiMentionedTimecode {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(LibraryStore.aiTimecodeText(pinned))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Button {
                            store.unpinAIMentionTimecode()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(Color.orange)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                } else if let label = store.aiViewerTimecodeLabel {
                    Button {
                        if let seconds = store.aiViewerTimecode {
                            store.pinAIMentionTimecode(seconds)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text("指认当前 \(label)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("把视频当前时间点指认给助手")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// 输入框上方的上下文胶囊：让用户看见这一轮到底带了什么。
    private var contextChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.aiContextCapsules.filter(\.isEnabled)) { capsule in
                    HStack(spacing: 4) {
                        Image(systemName: capsule.kind.symbol)
                            .font(.system(size: 8.5))
                        Text(capsule.title)
                            .font(.system(size: 10.5, weight: .medium))
                        if !capsule.detail.isEmpty {
                            Text(capsule.detail)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            store.toggleAIContext(capsule.kind)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("移除这个上下文")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }

                Menu {
                    ForEach(AIContextKind.allCases) { kind in
                        Button {
                            store.toggleAIContext(kind)
                        } label: {
                            Label(kind.title,
                                  systemImage: store.isAIContextEnabled(kind) ? "checkmark" : kind.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("管理上下文")
            }
            .padding(.vertical, 1)
        }
    }

    /// 底栏状态点：本地模型看服务是否活着，云端看 Key。
    private var statusDotColor: Color {
        if store.aiConfig.provider == .local {
            return localLLM.isServerRunning ? .green : .orange
        }
        return store.aiHasAPIKey ? .green : .orange
    }

    /// 本地模型的服务状态：没起来时直接给一键启动，不用再去设置页找开关。
    @ViewBuilder
    private var localServiceStatus: some View {
        if localLLM.isServerRunning {
            Text("服务运行中")
        } else if localLLM.stage.isBusy {
            Text("正在启动服务…")
        } else {
            Button("服务未启动 · 点此启动") {
                Task { await localLLM.startServerIfNeeded() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.orange)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
            Text(error)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var voiceButton: some View {
        Button {
            if voice.isRecording {
                voice.stop()
                store.aiInput = voiceBase + voice.transcript
                return
            }
            guard voiceConsent else {
                showVoiceConsent = true
                return
            }
            startVoice()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: voice.isRecording ? "waveform" : "mic")
                    .font(.system(size: 11.5, weight: voice.isRecording ? .semibold : .regular))
                if !isInspector {
                    Text(voice.isRecording ? "停止" : "语音")
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(voice.isRecording ? Color.red : Color.secondary)
            .padding(.horizontal, isInspector ? 6 : 8)
            .padding(.vertical, 4)
            .background(voice.isRecording
                        ? Color.red.opacity(0.10)
                        : Color.primary.opacity(0.05),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .help(voice.isRecording ? "停止语音输入" : "语音输入（系统 Speech，优先端侧）")
    }

    private func startVoice() {
        voiceBase = store.aiInput
        if !voiceBase.isEmpty, !voiceBase.hasSuffix(" ") { voiceBase += " " }
        Task { @MainActor in
            await voice.start()
            if let error = voice.error {
                store.showToast(error)
            }
        }
    }

    private var imageToggleButton: some View {
        Button {
            store.aiConfig.includeImages.toggle()
            store.saveAIConfig()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.aiConfig.includeImages ? "photo.fill" : "photo")
                    .font(.system(size: 11.5))
                Text("图片")
                    .font(.system(size: 11))
            }
            .foregroundStyle(store.aiConfig.includeImages ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(store.aiConfig.includeImages
                        ? Color.accentColor.opacity(0.10)
                        : Color.primary.opacity(0.05),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .help(store.aiConfig.includeImages
              ? "已开启图片理解：会发送压缩缩略图，点击关闭"
              : "开启图片理解：把选中/候选照片压成长边 1024 的 JPEG 发送")
    }

    /// 模型胶囊：点开可直接切换当前提供商的模型，不用跳到设置页。
    private var modelChip: some View {
        Menu {
            if availableModels.isEmpty {
                Text(store.aiConfig.provider == .local ? "未检测到本地模型" : "先在设置里填写模型名")
            } else {
                ForEach(availableModels, id: \.self) { model in
                    Button {
                        selectAIModel(model)
                    } label: {
                        if model == store.aiConfig.model {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            }
            Divider()
            Menu("切换提供商") {
                ForEach(AIProvider.allCases) { provider in
                    Button {
                        store.updateAIProvider(provider)
                    } label: {
                        if provider == store.aiConfig.provider {
                            Label(provider.title, systemImage: "checkmark")
                        } else {
                            Text(provider.title)
                        }
                    }
                }
            }
            Button("模型与接口设置…") { openAIModelSettings() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 8.5))
                Text(store.aiConfig.model.isEmpty ? "未配置模型" : store.aiConfig.model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.aiIsResponding)
        .help("点击切换模型：\(store.aiConfig.provider.title) / \(store.aiConfig.model)")
    }

    /// 当前提供商可切换的模型：本地模型取运行时已安装列表，其它取预置常用模型。
    private var availableModels: [String] {
        var models = store.aiConfig.provider == .local
            ? localLLM.installedModels
            : store.aiConfig.provider.models
        let current = store.aiConfig.model
        if !current.isEmpty, !models.contains(current) {
            models.insert(current, at: 0)
        }
        return models
    }

    private func selectAIModel(_ model: String) {
        guard store.aiConfig.model != model else { return }
        store.aiConfig.model = model
        store.saveAIConfig()
    }

    private func openAIModelSettings() {
        settingsTab = .assistant
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// 会话模式：快速 / 标准 / 深度，切换后立即持久化。
    private var modeMenu: some View {
        Menu {
            ForEach(AIMode.allCases) { mode in
                Button {
                    store.aiConfig.mode = mode
                    store.saveAIConfig()
                } label: {
                    Label("\(mode.title) · \(mode.detail)",
                          systemImage: store.aiConfig.mode == mode ? "checkmark" : mode.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.aiConfig.mode.symbol)
                    .font(.system(size: 8.5))
                Text(store.aiConfig.mode.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("会话模式：\(store.aiConfig.mode.detail)")
    }

    /// 计划模式：多步任务先出步骤，确认后再执行。
    private var planModeButton: some View {
        Button {
            store.toggleAIPlanMode()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.aiForcePlan ? "checklist.checked" : "checklist")
                    .font(.system(size: 8.5))
                Text("计划")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(store.aiForcePlan ? Color.white : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(store.aiForcePlan ? Color.accentColor : Color.primary.opacity(0.07),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .help(store.aiForcePlan
              ? "计划模式已开启：多步任务先生成步骤，确认后才执行"
              : "计划模式：多步任务先出步骤再执行")
    }

    private var sendButton: some View {
        Button {
            if store.aiIsResponding {
                store.stopAIResponse()
            } else {
                store.sendAIMessage()
            }
        } label: {
            Image(systemName: store.aiIsResponding ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(colors: [Color.accentColor,
                                            Color.accentColor.opacity(0.72)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .shadow(color: Color.accentColor.opacity(canSend || store.aiIsResponding ? 0.32 : 0),
                        radius: 7, y: 2)
                .opacity(canSend || store.aiIsResponding ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !store.aiIsResponding)
        .help(store.aiIsResponding ? "停止生成" : "发送")
    }

    /// 对话开始后保留一条轻量示例条，方便继续操作。
    private var quickCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ForEach(quickExamples, id: \.self) { example in
                    Button {
                        insert(example)
                    } label: {
                        Text(example)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var canSend: Bool {
        !store.aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.aiIsResponding
    }

    /// 输入框占位文案跟随当前模块，示例更贴近用户正在看的页面。
    private var inputPlaceholder: String {
        if isTVContext { return "问点什么，例如：今晚有什么好看的" }
        if isCinemaContext { return "问点什么，例如：整理未识别的影片" }
        if isCatalogContext { return "问点什么，例如：今天网络资源有什么更新" }
        if isNetworkCinemaContext { return "问点什么，例如：播放上次没看完的" }
        return "问点什么，例如：把去年在上海的照片整理成相簿"
    }

    private func insert(_ text: String) {
        store.aiInput = text
        inputFocused = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(settings.motion.layout) {
            proxy.scrollTo("ai.bottom", anchor: .bottom)
        }
    }

    // MARK: - 尺寸

    /// 右下角的缩放把手：拖动改变面板大小，双击恢复默认。
    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let base = resizeBase ?? CGSize(width: panelWidth, height: panelHeight)
                        if resizeBase == nil { resizeBase = base }
                        let size = clampedPanelSize(CGSize(
                            width: base.width + value.translation.width,
                            height: base.height + value.translation.height))
                        panelWidth = Double(size.width)
                        panelHeight = Double(size.height)
                    }
                    .onEnded { _ in resizeBase = nil }
            )
            .onTapGesture(count: 2) { resetPanelSize() }
            .help("拖动调整面板大小，双击恢复默认")
    }

    /// 限制在屏幕可用区域内，避免拖出屏幕后下次打开看不见。
    private func clampedPanelSize(_ size: CGSize) -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let minWidth = 680.0
        let minHeight = 560.0
        let maxWidth = max(minWidth, visible.width - 96)
        let maxHeight = max(minHeight, visible.height - 140)
        return CGSize(width: min(maxWidth, max(minWidth, size.width)),
                      height: min(maxHeight, max(minHeight, size.height)))
    }

    private func resetPanelSize() {
        let size = clampedPanelSize(CGSize(width: 960, height: 820))
        withAnimation(settings.motion.layout) {
            panelWidth = Double(size.width)
            panelHeight = Double(size.height)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 简单的流式标签布局，用于推荐问题。
private struct FlexibleTagLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 460
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 运行中的三点脉冲：比转圈更轻，贴近主流助手的「正在输入」。
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(time * 4 - Double(index) * 0.8) + 1) / 2
                    Circle()
                        .fill(Color.accentColor.opacity(0.35 + 0.55 * wave))
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.85 + 0.3 * wave)
                }
            }
        }
        .frame(width: 28, height: 12)
    }
}

/// 助手回答里可直接点选执行的动作。
private struct AIActionChoice: Identifiable {
    let index: Int
    let title: String
    var id: Int { index }
}

/// 轻量 Markdown：标题、列表、引用、代码块与行内强调。
/// 只用于助手回复，避免把模型输出原样当成纯文本。
private struct AIMarkdownText: View {
    let text: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case rule
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCode {
                    result.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                result.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                let marks = trimmed.prefix(while: { $0 == "#" }).count
                let content = String(trimmed.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                if !content.isEmpty {
                    flushParagraph()
                    result.append(.heading(level: min(3, max(1, marks)), text: content))
                    continue
                }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                result.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let (index, content) = Self.numberedPrefix(trimmed) {
                flushParagraph()
                result.append(.numbered(index, content))
                continue
            }
            paragraph.append(trimmed)
        }

        flushParagraph()
        if inCode, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private static func numberedPrefix(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        let content: String
        if rest.hasPrefix(". ") {
            content = String(rest.dropFirst(2))
        } else if rest.hasPrefix("、") {
            content = String(rest.dropFirst(1))
        } else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (String(digits), trimmed)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            Text(inline(content))
                .font(.system(size: 12.5))
                .lineSpacing(3.5)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let content):
            Text(inline(content))
                .font(.system(size: level == 1 ? 15 : (level == 2 ? 13.5 : 12.5),
                              weight: .semibold))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let content):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.55))
                Text(inline(content))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .numbered(let index, let content):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(index).")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint.opacity(0.55))
                Text(inline(content))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .quote(let content):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint.opacity(0.28))
                    .frame(width: 2.5)
                Text(inline(content))
                    .font(.system(size: 12))
                    .lineSpacing(2.5)
                    .foregroundStyle(tint.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .code(let content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        case .rule:
            Divider()
                .opacity(0.5)
                .padding(.vertical, 2)
        }
    }

    private func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: string, options: options))
            ?? AttributedString(string)
    }
}
