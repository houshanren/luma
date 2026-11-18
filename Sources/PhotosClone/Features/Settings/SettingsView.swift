import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    @State private var cacheSize: Int64 = 0
    @State private var systemCacheSize: Int64 = 0
    @State private var sidecarSize: Int64 = 0
    @State private var confirmDestroySidecar = false
    @State private var libraryEntries: [LibraryEntry] = []
    @State private var aiKeyInput = ""
    @State private var aiTesting = false
    @State private var aiTestOK = false
    @State private var aiTestMessage: String?
    @State private var confirmClearAIConversation = false

    /// 与幻灯片窗口共用同一组偏好。
    @AppStorage("slideshowInterval") private var slideshowInterval: Double = 3
    @AppStorage("slideshowKenBurns") private var slideshowKenBurns = true
    /// 当前分页；其它入口可先写入目标页再打开设置窗口。
    @AppStorage(SettingsKeys.selectedTab) private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            appearanceTab
                .tabItem { Label("外观", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            browsingTab
                .tabItem { Label("浏览", systemImage: "photo.on.rectangle") }
                .tag(SettingsTab.browsing)
            cinemaTab
                .tabItem { Label("影院", systemImage: "film.stack") }
                .tag(SettingsTab.cinema)
            shortcutsTab
                .tabItem { Label("快捷键", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
            libraryTab
                .tabItem { Label("图库", systemImage: "photo.stack") }
                .tag(SettingsTab.library)
            modelTab
                .tabItem { Label("模型", systemImage: "cpu") }
                .tag(SettingsTab.models)
            assistantTab
                .tabItem { Label("助手", systemImage: "sparkles") }
                .tag(SettingsTab.assistant)
        }
        .frame(width: 580, height: 500)
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .onAppear(perform: refreshCacheSize)
    }

    // MARK: 通用

    private var generalTab: some View {
        Form {
            Section("打开方式") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("双击照片时")
                            .font(.system(size: 12, weight: .medium))
                        Text(settings.photoOpenMode.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        ForEach(PhotoOpenMode.allCases) { mode in
                            OpenModeTile(mode: mode,
                                         selected: settings.photoOpenMode == mode) {
                                settings.photoOpenMode = mode
                            }
                        }
                    }
                }
                Text(settings.photoOpenMode.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("查看器") {
                Picker("浏览方式", selection: $settings.viewerLayout) {
                    ForEach(ViewerLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.viewerLayout.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("打开照片时显示信息面板", isOn: $settings.showInfoOnOpen)
                Text("侧边信息面板会显示文件名、尺寸、相机参数与关键词。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("显示底部缩略图胶片条", isOn: $settings.viewerFilmstrip)
                Text("关闭后查看器只保留照片与工具栏，画面更沉浸；查看器工具栏里也能随时开关。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("照片背景虚化", isOn: $settings.viewerBackdrop)
                Text("用当前照片的模糊影像铺满舞台，竖图两侧不再出现大片空白。关闭后改为纯色背景，翻页更省资源。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("播放与画质") {
                Toggle("自动播放视频", isOn: $settings.autoPlayVideo)
                Text("打开视频时自动开始播放；关闭后需手动点击播放按钮。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("查看完整 HDR", isOn: $settings.viewFullHDR)
                Text("自动调整屏幕以显示照片的完整动态范围（HDR）。关闭后按标准 sRGB 显示。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("默认静音播放", isOn: $settings.muteVideoByDefault)
                Text("打开视频时先静音开始，播放后仍可用 M 键或音量按钮取消静音。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("默认循环播放", isOn: $settings.loopVideoByDefault)
                Text("视频播放结束后自动从头继续；开启后不会自动连播下一个。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("播放结束后自动连播", isOn: $settings.autoPlayNextVideo)
                Text("一个视频播完后按当前浏览顺序自动播放下一个视频（跳过照片），适合连续观看。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("快进 / 快退步长", selection: $settings.videoSeekStep) {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0, 15.0, 30.0], id: \.self) { value in
                        Text("\(Int(value)) 秒").tag(value)
                    }
                }
                Text("视频里 ↑ / ↓ 每次快进 / 快退的距离；J / L 仍固定为 10 秒。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("视频控制条", selection: $settings.videoControlPlacement) {
                    ForEach(VideoControlPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.videoControlPlacement.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("幻灯片") {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .foregroundStyle(.secondary)
                    Slider(value: $slideshowInterval, in: 1...10, step: 1)
                    Text("\(Int(slideshowInterval)) 秒")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle("Ken Burns 动态效果", isOn: $slideshowKenBurns)
                Text("控制每张照片的停留时间，以及缓慢推进的推移动画。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("导入") {
                Toggle("将最后一层文件夹创建为相簿", isOn: $settings.importCreateAlbumsFromFolders)
                Text("每个文件夹的最末一级目录会成为相簿名称。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("保留上层文件夹结构", isOn: $settings.importPreserveFolderStructure)
                    .disabled(!settings.importCreateAlbumsFromFolders)
                Text("上层目录会创建为可展开的文件夹；关闭后只保留末级相簿。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("始终拷贝原文件")
                            .font(.system(size: 12, weight: .medium))
                        Text("导入会把原文件复制进图库，移动或删除原文件后照片仍然可用；不支持仅引用原位置。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 外观

    private var appearanceTab: some View {
        Form {
            Section("主题") {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("跟随系统时会自动切换浅色与深色；也可以固定为其中一种。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("强调色") {
                HStack(spacing: 10) {
                    ForEach(AppAccent.allCases) { item in
                        Button {
                            settings.accent = item
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(item.swatch)
                                    .frame(width: 26, height: 26)
                                if settings.accent == item {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.primary.opacity(settings.accent == item ? 0.35 : 0.08),
                                                  lineWidth: 1)
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                    }
                    Spacer()
                }
                Text("改变按钮、选中态与侧边栏高亮的颜色。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("动画效果") {
                Picker("动效", selection: $settings.motion) {
                    ForEach(MotionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.motion.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("卡片") {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: settings.cardRadius)
                        .fill(
                            LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.18)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 108, height: 70)
                        .overlay {
                            RoundedRectangle(cornerRadius: settings.cardRadius)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("圆角")
                                .font(.system(size: 12))
                            Spacer()
                            Text("\(Int(settings.cardCornerRadius)) pt")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.cardCornerRadius, in: 0...28)
                    }
                }
                Toggle("卡片悬停时轻微放大", isOn: $settings.hoverLift)
                Text("应用于相簿、精选集、网盘文件夹与侧边栏封面。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 浏览

    /// 每行张数的预设；当前值不在预设里时（例如缩到极小）临时补一个。
    private static let gridDensityPresets = [4, 5, 6, 8, 10]
    private static let cardDensityPresets = [3, 4, 5, 6, 8]

    private func densityOptions(current: Int, presets: [Int]) -> [Int] {
        var options = presets
        if !options.contains(current) { options.append(current) }
        return options.sorted()
    }

    private func densityHeader(_ title: String, columns: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text("每行 \(columns) 张")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func densityPicker(current: Int,
                               presets: [Int],
                               action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(densityOptions(current: current, presets: presets), id: \.self) { columns in
                DensityChip(columns: columns, selected: columns == current) {
                    action(columns)
                }
            }
        }
    }

    private var cinemaTab: some View {
        CinemaSettingsSection()
    }

    private var shortcutsTab: some View {
        ShortcutSettingsView()
    }

    private var browsingTab: some View {
        Form {
            Section("图片列表") {
                VStack(alignment: .leading, spacing: 8) {
                    densityHeader("新页面默认", columns: settings.defaultGridColumns)
                    densityPicker(current: settings.defaultGridColumns, presets: Self.gridDensityPresets) {
                        settings.defaultGridColumns = $0
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("第一次打开某个类型、相簿或文件夹时使用这个张数；已单独调整过的页面保持各自记忆。当前页面可在图库里用 ⌘+ / ⌘- / 双指捏合调整。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("应用到所有页面") {
                            store.applyDefaultThumbSizeToAllScopes()
                        }
                        .controlSize(.small)
                    }
                }

                Picker("显示形式", selection: $store.thumbnailAspect) {
                    ForEach(ThumbnailAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)

                Text("张数按当前窗口宽度换算；窗口拉宽或收窄时，同一页面每行的实际张数会跟着变化。完整宽高比与瀑布流保留原始比例；列表适合核对文件名与拍摄信息。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("相簿与分类卡片") {
                VStack(alignment: .leading, spacing: 8) {
                    densityHeader("新页面默认", columns: settings.defaultCardColumns)
                    densityPicker(current: settings.defaultCardColumns, presets: Self.cardDensityPresets) {
                        settings.defaultCardColumns = $0
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("相簿、文件夹、媒体类型、场景、更多项目与关键词共用这组卡片大小；已单独调整过的页面保持各自记忆。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("应用到所有页面") {
                            store.applyDefaultCardColumnsToAllScopes()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("相簿总览") {
                Picker("显示方式", selection: $store.albumDisplayStyle) {
                    ForEach(AlbumDisplayStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text("网格为大卡片；列表是方形封面 + 名称与数量（与系统「照片」一致）；拼贴墙把 1～4 张封面拼成无边框方块，名称叠在底部。随当前图库保存，也可以在「显示 › 相簿显示方式」或相簿页头切换。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("人物总览") {
                Picker("头像形状", selection: $store.peopleDisplayStyle) {
                    ForEach(PeopleDisplayStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text("「人物」页的人物卡片按这里选择的形状展示；圆角方形与系统「照片」的人物平铺一致，圆角大小跟随上面的卡片圆角设置。随当前图库保存。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("排序与分组") {
                Picker("分组方式", selection: $store.grouping) {
                    ForEach(GridGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                Picker("排序方式", selection: $store.sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                Toggle("升序排列", isOn: $store.sortAscending)
                Text(store.sortKey.directionTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("缩略图角标与文字") {
                HStack(spacing: 8) {
                    Text("已开启 \(metadataEnabledCount) / 12 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("简洁") { settings.metadata = metadataOptions(for: .minimal) }
                    Button("标准") { settings.metadata = metadataOptions(for: .standard) }
                    Button("全部") { settings.metadata = metadataOptions(for: .full) }
                }
                .controlSize(.small)

                metadataGroup(title: "基础信息") {
                    Toggle("标题", isOn: $settings.metadata.title)
                    Toggle("拍摄日期", isOn: $settings.metadata.capturedDate)
                    Toggle("文件类型", isOn: $settings.metadata.fileType)
                }
                metadataGroup(title: "状态角标") {
                    Toggle("个人收藏", isOn: $settings.metadata.favorite)
                    Toggle("已编辑", isOn: $settings.metadata.edited)
                    Toggle("视频时长", isOn: $settings.metadata.duration)
                }
                metadataGroup(title: "参数与来源") {
                    Toggle("相机", isOn: $settings.metadata.camera)
                    Toggle("分辨率", isOn: $settings.metadata.resolution)
                    Toggle("文件大小", isOn: $settings.metadata.fileSize)
                    Toggle("关键词", isOn: $settings.metadata.keywords)
                    Toggle("位置", isOn: $settings.metadata.location)
                    Toggle("来源", isOn: $settings.metadata.source)
                }

                Text("也可以在「显示 › 元数据」或工具栏的排序菜单里快速切换。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var metadataEnabledCount: Int {
        let m = settings.metadata
        let flags = [m.title, m.capturedDate, m.fileType,
                     m.favorite, m.edited, m.duration,
                     m.camera, m.resolution, m.fileSize, m.keywords, m.location, m.source]
        return flags.filter { $0 }.count
    }

    private func metadataGroup<Content: View>(title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading,
                      spacing: 7) {
                content()
            }
            .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataOptions(for preset: MetadataPreset) -> MetadataOptions {
        var options = MetadataOptions()
        switch preset {
        case .minimal:
            options.favorite = false
            options.duration = false
        case .standard:
            break
        case .full:
            options.title = true
            options.capturedDate = true
            options.keywords = true
            options.edited = true
            options.fileType = true
            options.favorite = true
            options.location = true
            options.resolution = true
            options.fileSize = true
            options.camera = true
            options.source = true
            options.duration = true
        }
        return options
    }

    // MARK: 模型（端侧能力）

    private var modelTab: some View {
        Form {
            LocalModelsSettingsSection()
        }
        .formStyle(.grouped)
    }

    // MARK: 助手（智能助手自身的配置）

    /// 助手是否可用：模型接入完整，且当前提供商的 Key 已就绪（本地运行不需要 Key）。
    private var assistantReady: Bool {
        store.aiConfigurationReady && store.aiHasAPIKey
    }

    private var assistantHeaderHint: String {
        if !store.aiConfig.provider.requiresAPIKey {
            return "本地运行，无需 API Key。"
        }
        return assistantReady
            ? "已就绪，可在任意页面用 ✨ 提问或操作图库。"
            : "填写模型与 API Key 后可用。"
    }

    private var assistantTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                assistantHeaderCard

                settingsGroup(icon: "cpu", title: "云端模型", subtitle: "") {
                    settingsCard {
                        settingsRow(icon: "building.2",
                                    tint: .secondary,
                                    title: "提供商",
                                    subtitle: nil) {
                            Picker("", selection: aiProviderBinding) {
                                ForEach(AIProvider.allCases) { provider in
                                    Text(provider.title).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 170)
                        }

                        settingsDivider

                        settingsRow(icon: "link",
                                    tint: .secondary,
                                    title: "接口地址",
                                    subtitle: nil) {
                            TextField("https://…", text: aiBinding(\.baseURL))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }

                        settingsDivider

                        settingsRow(icon: "cpu",
                                    tint: .secondary,
                                    title: "模型",
                                    subtitle: nil) {
                            TextField("模型名称", text: aiBinding(\.model))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }

                        if !store.aiConfig.provider.models.isEmpty {
                            settingsDivider
                            settingsRow(icon: "star",
                                        tint: .secondary,
                                        title: "常用模型",
                                        subtitle: nil) {
                                Picker("", selection: aiBinding(\.model)) {
                                    ForEach(store.aiConfig.provider.models, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 170)
                            }
                        }

                        settingsDivider

                        settingsRow(icon: "bolt.horizontal",
                                    tint: .secondary,
                                    title: "连接测试",
                                    subtitle: nil) {
                            HStack(spacing: 8) {
                                if let aiTestMessage {
                                    Text(aiTestMessage)
                                        .font(.system(size: 11))
                                        .foregroundStyle(aiTestOK ? Color.green : Color.red)
                                        .lineLimit(1)
                                }
                                Button(aiTesting ? "测试中…" : "测试") {
                                    runAIConnectionTest()
                                }
                                .controlSize(.small)
                                .disabled(aiTesting || !store.aiHasAPIKey)
                            }
                        }
                    }

                    if let hint = store.aiConfig.provider.supportsVisionHint {
                        Text(hint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    if store.aiConfig.provider == .doubao {
                        Text("豆包填控制台创建的推理接入点 ID（ep-…）。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    if store.aiConfig.provider == .custom {
                        Text("任意 OpenAI 兼容服务：SiliconFlow、OpenRouter、Ollama、自建网关。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                if store.aiConfig.provider.requiresAPIKey {
                    settingsGroup(icon: "key.fill", title: "API Key", subtitle: "") {
                        settingsCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    SecureField("粘贴 \(store.aiConfig.provider.title) 的 API Key", text: $aiKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                    Button("保存") {
                                        store.saveAIAPIKey(aiKeyInput)
                                        store.showToast("已保存 \(store.aiConfig.provider.title) 的 API Key")
                                    }
                                    .disabled(aiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button("清除") {
                                        store.saveAIAPIKey("")
                                        aiKeyInput = ""
                                        store.showToast("已清除 API Key")
                                    }
                                    .disabled(!store.aiHasAPIKey)
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: store.aiHasAPIKey ? "checkmark.seal.fill" : "exclamationmark.triangle")
                                        .foregroundStyle(store.aiHasAPIKey ? Color.green : Color.secondary)
                                    Text(store.aiHasAPIKey ? "已保存到钥匙串" : "未配置")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                Text("只存 macOS 钥匙串，不写入图库。")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                    }
                }

                settingsGroup(icon: "photo.badge.checkmark", title: "图片理解", subtitle: "") {
                    settingsCard {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("发送压缩缩略图", isOn: aiBinding(\.includeImages))
                            HStack(spacing: 8) {
                                Text("单次上限")
                                    .font(.system(size: 12))
                                Spacer(minLength: 8)
                                Picker("", selection: aiBinding(\.maxImages)) {
                                    ForEach(1...6, id: \.self) { count in
                                        Text("\(count) 张").tag(count)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 90)
                                .disabled(!store.aiConfig.includeImages)
                            }
                            Text("关闭时只发送端侧标签、OCR 与元数据。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }

                settingsGroup(icon: "bubble.left.and.bubble.right", title: "对话", subtitle: "") {
                    settingsCard {
                        settingsRow(icon: "clock.arrow.circlepath",
                                    tint: .secondary,
                                    title: "对话记录",
                                    subtitle: store.aiMessages.isEmpty
                                        ? "暂无对话"
                                        : "\(store.aiMessages.count) 条消息") {
                            Button("清空…") { confirmClearAIConversation = true }
                                .controlSize(.small)
                                .disabled(store.aiMessages.isEmpty)
                        }
                    }
                    Text("随当前图库保存。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Text("写操作会先确认；不会永久删除或编辑原图。端侧标签与 OCR 由「模型」页提供。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncAIKeyInput() }
        .onChange(of: store.aiConfig.provider) { _, _ in syncAIKeyInput() }
        .confirmationDialog("清空当前图库的对话记录？",
                            isPresented: $confirmClearAIConversation,
                            titleVisibility: .visible) {
            Button("清空对话", role: .destructive) {
                store.clearAIConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除对话，不影响照片与设置。该操作不可撤销。")
        }
    }

    /// 助手身份卡：一句话说明当前状态与所用模型。
    private var assistantHeaderCard: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [LumaBrand.violet, LumaBrand.cyan.opacity(0.70)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)
            .shadow(color: LumaBrand.violet.opacity(0.35), radius: 12, y: 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("智能助手")
                        .font(.system(size: 18, weight: .bold))
                    statusTag(icon: assistantReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                              text: assistantReady ? "已就绪" : "待配置")
                }

                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(store.aiConfig.provider.title)
                        .font(.system(size: 11.5, weight: .medium))
                    Text(store.aiConfig.model)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(assistantHeaderHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [LumaBrand.violet.opacity(0.16),
                                              Color.accentColor.opacity(0.08),
                                              Color.clear],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    private var aiProviderBinding: Binding<AIProvider> {
        Binding(get: { store.aiConfig.provider },
                set: { provider in
                    store.updateAIProvider(provider)
                    syncAIKeyInput()
                })
    }

    private func aiBinding<T>(_ keyPath: WritableKeyPath<AIConfig, T>) -> Binding<T> {
        Binding(get: { store.aiConfig[keyPath: keyPath] },
                set: { value in
                    store.aiConfig[keyPath: keyPath] = value
                    store.saveAIConfig()
                })
    }

    private func syncAIKeyInput() {
        aiKeyInput = AIKeychain.key(for: store.aiConfig.provider)
        aiTestMessage = nil
    }

    private func runAIConnectionTest() {
        aiTesting = true
        aiTestMessage = nil
        Task { @MainActor in
            let (ok, message) = await store.testAIConnection()
            aiTestOK = ok
            aiTestMessage = message
            aiTesting = false
        }
    }

    // MARK: 图库（当前使用图库）

    private var libraryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if store.containerLibraryPath != nil {
                    currentLibraryCard
                } else {
                    emptyLibraryCard
                }

                settingsGroup(icon: "square.stack.3d.up.fill",
                              title: "图库管理",
                              subtitle: "切换后只显示新图库自己的照片、连接与设置；原图库的文件不会被删除。") {
                    settingsCard {
                        if otherLibraryEntries.isEmpty {
                            settingsRow(icon: "tray",
                                        tint: .secondary,
                                        title: "没有找到其他图库",
                                        subtitle: "用上方「新建图库…」或「打开图库…」添加后会出现在这里。") {
                                EmptyView()
                            }
                        } else {
                            ForEach(otherLibraryEntries) { entry in
                                otherLibraryRow(entry)
                                if entry.id != otherLibraryEntries.last?.id {
                                    settingsDivider
                                }
                            }
                        }
                    }
                }

                settingsGroup(icon: "lock.shield",
                              title: "图库保险库",
                              subtitle: "把 originals、数据库与渲染结果备份到外置盘 / NAS；校验只读清单，恢复只补缺失或损坏的文件。") {
                    VaultSettingsView()
                }

                settingsGroup(icon: "internaldrive",
                              title: "存储与清理",
                              subtitle: "只清理本机缓存与派生数据，不会影响图库、网盘或云端原图。") {
                    settingsCard {
                        settingsRow(icon: "trash",
                                    tint: .secondary,
                                    title: "最近删除",
                                    subtitle: trashRetentionSubtitle) {
                            Picker("", selection: $settings.trashRetentionDays) {
                                Text("7 天后").tag(7)
                                Text("30 天后").tag(30)
                                Text("90 天后").tag(90)
                                Text("180 天后").tag(180)
                                Text("永不清理").tag(0)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 118)
                        }

                        settingsDivider

                        settingsRow(icon: "photo.stack",
                                    tint: .secondary,
                                    title: "系统图库缩略图",
                                    subtitle: systemCacheSize > 0 ? formatFileSize(systemCacheSize) : "暂无缓存") {
                            Button("清理") {
                                store.clearSystemThumbnailCache()
                                refreshCacheSize()
                            }
                            .controlSize(.small)
                            .disabled(systemCacheSize == 0)
                        }

                        settingsDivider

                        settingsRow(icon: "externaldrive.badge.icloud",
                                    tint: .secondary,
                                    title: "网盘缩略图",
                                    subtitle: cacheSize > 0 ? formatFileSize(cacheSize) : "暂无缓存") {
                            Button("清理") {
                                store.clearCloudThumbnailCache()
                                refreshCacheSize()
                            }
                            .controlSize(.small)
                            .disabled(cacheSize == 0)
                        }

                        if store.isNativeContainer {
                            settingsDivider
                            settingsRow(icon: "shippingbox",
                                        tint: .orange,
                                        title: "系统图库旁挂数据",
                                        subtitle: sidecarSize > 0 ? formatFileSize(sidecarSize) : "暂无可清理数据") {
                                HStack(spacing: 8) {
                                    Button("刷新") { refreshCacheSize() }
                                        .controlSize(.small)
                                    Button("销毁…", role: .destructive) {
                                        confirmDestroySidecar = true
                                    }
                                    .controlSize(.small)
                                    .disabled(sidecarSize == 0)
                                    .help("删除拾光的元数据库、索引 / 快照、缩略图、转码与缓存；不会动 Apple 的 Photos.sqlite、originals 原图与衍生图。")
                                }
                            }
                        }
                    }
                }

                settingsGroup(icon: "info.circle", title: "关于", subtitle: "") {
                    ProductizationSettingsView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { reloadLibraryEntries() }
        .onChange(of: store.containerLibraryPath) { _, _ in reloadLibraryEntries() }
        .confirmationDialog("销毁拾光在该系统图库写入的数据？",
                            isPresented: $confirmDestroySidecar,
                            titleVisibility: .visible) {
            Button("销毁拾光数据", role: .destructive) {
                store.destroySystemLibrarySidecar()
                refreshCacheSize()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除拾光自己的元数据库、索引 / 快照、缩略图、转码与缓存；Apple 的 Photos.sqlite、originals 原图与衍生图不会被动到。该操作不可撤销。")
        }
    }

    // MARK: - 设置分组

    /// 统一分组：图标 + 标题 + 一句说明 + 卡片，替代原先散落的纯文本小标题。
    private func settingsGroup<Content: View>(icon: String,
                                              title: String,
                                              subtitle: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
            content()
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func settingsRow<Trailing: View>(icon: String,
                                             tint: Color = .accentColor,
                                             title: String,
                                             subtitle: String?,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var settingsDivider: some View {
        Divider().padding(.leading, 56)
    }

    private func otherLibraryRow(_ entry: LibraryEntry) -> some View {
        settingsRow(icon: "photo.stack",
                    tint: .secondary,
                    title: entry.name,
                    subtitle: entry.url.path) {
            Button("切换") {
                store.activateLibrary(entry.url)
                reloadLibraryEntries()
            }
            .controlSize(.small)
        }
    }

    private var trashRetentionSubtitle: String {
        settings.trashRetentionDays > 0
            ? "超过 \(settings.trashRetentionDays) 天后在启动时自动永久删除"
            : "不自动清理，直到手动清空最近删除"
    }

    /// 最近使用过的其他图库（含官方「照片」图库）；每个库都以自己的数据与连接打开。
    private var otherLibraryEntries: [LibraryEntry] {
        libraryEntries.filter { !$0.isCurrent }
    }

    private func reloadLibraryEntries() {
        libraryEntries = store.knownLibraryEntries()
    }

    /// 当前图库：品牌渐变身份卡，左边封面与身份，右边统计胶囊，底部一组动作。
    private var currentLibraryCard: some View {
        let url = store.containerLibraryPath.map { URL(fileURLWithPath: $0) }
        let stats = store.libraryStats
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                libraryCover(store.libraryCoverPhoto)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(url?.deletingPathExtension().lastPathComponent ?? "当前图库")
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(1)
                        statusTag(icon: "internaldrive.fill", text: "当前图库")
                    }

                    Text(url?.path ?? "")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            metricChip("\(stats.photos.formatted())", "照片", icon: "photo")
                            metricChip("\(stats.videos.formatted())", "视频", icon: "video")
                            metricChip("\(stats.albums.formatted())", "相簿", icon: "rectangle.stack")
                        }
                        HStack(spacing: 6) {
                            metricChip("\(stats.folders.formatted())", "文件夹", icon: "folder")
                            metricChip("\(stats.systemLibraries.formatted())", "系统图库", icon: "photo.stack")
                            metricChip("\(store.cloudMounts.count.formatted())", "网络存储", icon: "externaldrive")
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    store.presentLibraryPicker()
                } label: {
                    Label("切换图库…", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    store.presentNewLibraryPanel()
                } label: {
                    Label("新建图库…", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.bordered)

                Button {
                    store.presentLibraryContainerPanel()
                } label: {
                    Label("打开图库…", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button {
                    store.revealLibraryInFinder()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .help("在访达中显示当前图库")
            }
            .controlSize(.small)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.20),
                                              LumaBrand.violet.opacity(0.08),
                                              Color.clear],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
    }

    private func metricChip(_ value: String, _ label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private var emptyLibraryCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            Text("尚未打开图库")
                .font(.system(size: 14, weight: .semibold))
            Text("新建或打开一个 .photoslibrary；每个图库都会独立保存自己的照片、连接与设置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button {
                    store.presentNewLibraryPanel()
                } label: {
                    Label("新建图库…", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    store.presentLibraryContainerPanel()
                } label: {
                    Label("打开图库…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14),
                              style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
        }
    }

    private func libraryCover(_ cover: PhotoItem?) -> some View {
        ZStack {
            if let cover {
                PhotoThumbnailView(photo: cover)
            } else {
                LinearGradient(colors: [LumaBrand.violet.opacity(0.85), LumaBrand.cyan.opacity(0.55)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 104, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private func statusTag(icon: String, text: String, spinning: Bool = false) -> some View {
        HStack(spacing: 3) {
            if spinning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 9, height: 9)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func refreshCacheSize() {
        cacheSize = store.cloudThumbnailCacheSize()
        systemCacheSize = store.systemThumbnailCacheSize()
        sidecarSize = store.systemLibrarySidecarSize()
    }
}

/// 缩略图密度选项：用一排小竖条示意每行张数，选中的用强调色玻璃底。
private struct DensityChip: View {
    let columns: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(0..<min(columns, 10), id: \.self) { _ in
                        Capsule()
                            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: columns > 6 ? 2.5 : 3.5, height: 10)
                    }
                }
                .frame(height: 10)
                Text("\(columns) 张")
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                                  lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("每行 \(columns) 张")
        .accessibilityLabel("每行 \(columns) 张")
    }
}

/// 打开方式选项：图标 + 短标题的玻璃卡片，选中的用强调色描边与浅底。
private struct OpenModeTile: View {
    let mode: PhotoOpenMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(height: 18)
                Text(mode.shortTitle)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                                  lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(mode.detail)
        .accessibilityLabel(mode.title)
    }
}
