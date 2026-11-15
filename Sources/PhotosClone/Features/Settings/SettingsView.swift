import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    @State private var cacheSize: Int64 = 0
    @State private var systemCacheSize: Int64 = 0
    @State private var libraryEntries: [LibraryEntry] = []
    @State private var aiKeyInput = ""
    @State private var aiTesting = false
    @State private var aiTestOK = false
    @State private var aiTestMessage: String?

    /// 与幻灯片窗口共用同一组偏好。
    @AppStorage("slideshowInterval") private var slideshowInterval: Double = 3
    @AppStorage("slideshowKenBurns") private var slideshowKenBurns = true

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            appearanceTab
                .tabItem { Label("外观", systemImage: "paintpalette") }
            browsingTab
                .tabItem { Label("浏览", systemImage: "photo.on.rectangle") }
            libraryTab
                .tabItem { Label("图库", systemImage: "photo.stack") }
            assistantTab
                .tabItem { Label("智能助手", systemImage: "sparkles") }
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
                Picker("双击照片时", selection: $settings.photoOpenMode) {
                    ForEach(PhotoOpenMode.allCases) { mode in
                        Text(mode.title).tag(mode)
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

            Section("系统图库载入") {
                Picker("载入上限", selection: $settings.systemLibraryMaxAssets) {
                    Text("最近 5 万项").tag(50_000)
                    Text("最近 10 万项").tag(100_000)
                    Text("最近 20 万项").tag(200_000)
                    Text("不限制（大图库不推荐）").tag(0)
                }
                Text("仅对当前图库连接的系统「照片」图库生效，设置随当前图库保存。只读接入，按拍摄日期从新到旧载入；索引缓存在图库内，之后打开无需重新扫描。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    private var browsingTab: some View {
        Form {
            Section("缩略图") {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3")
                        .foregroundStyle(.secondary)
                    Slider(value: $store.thumbSize, in: LibraryStore.thumbSizeRange)
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Text("\(Int(store.thumbSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Picker("显示形式", selection: $store.thumbnailAspect) {
                    ForEach(ThumbnailAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)

                Text("完整宽高比与瀑布流保留原始比例；列表适合核对文件名与拍摄信息。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("网格尺寸同时决定「所有相簿」里的卡片大小。")
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

    // MARK: 卡片样式

    private func cacheCard(title: String,
                           icon: String,
                           size: Int64,
                           clear: @escaping () -> Void) -> some View {
        infoCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(size > 0 ? formatFileSize(size) : "暂无缓存")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("刷新") { refreshCacheSize() }
                    .controlSize(.small)
                Button("清理") { clear() }
                    .controlSize(.small)
                    .disabled(size == 0)
            }
        }
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }

    // MARK: 智能助手（只读问答）

    private var assistantTab: some View {
        Form {
            Section("模型提供商") {
                Picker("提供商", selection: aiProviderBinding) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                TextField("接口地址", text: aiBinding(\.baseURL))
                TextField("模型", text: aiBinding(\.model))
                if !store.aiConfig.provider.models.isEmpty {
                    Picker("常用模型", selection: aiBinding(\.model)) {
                        ForEach(store.aiConfig.provider.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
                if let hint = store.aiConfig.provider.supportsVisionHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if store.aiConfig.provider == .doubao {
                    Text("豆包请把控制台创建的推理接入点 ID（ep-...）填写到「模型」。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if store.aiConfig.provider == .custom {
                    Text("任何 OpenAI 兼容服务都可以接：SiliconFlow、OpenRouter、Ollama（如 http://127.0.0.1:11434/v1）、自建网关等，填写对应的 Base URL 与模型名即可。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("DeepSeek / Kimi / GLM / 通义千问 / 豆包 / OpenAI 统一使用 OpenAI 兼容的 chat/completions 接口；也可以填写自建或代理地址。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("API Key") {
                HStack(spacing: 8) {
                    SecureField("粘贴 \(store.aiConfig.provider.title) 的 API Key", text: $aiKeyInput)
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
                    Text(store.aiHasAPIKey ? "已保存到钥匙串" : "未配置，智能助手无法发送请求")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text("API Key 只保存在 macOS 钥匙串（service com.baymax.luma.ai），不写入图库数据库、UserDefaults 或日志。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("图片理解") {
                Toggle("发送压缩缩略图", isOn: aiBinding(\.includeImages))
                Picker("单次图片上限", selection: aiBinding(\.maxImages)) {
                    ForEach(1...6, id: \.self) { count in
                        Text("\(count) 张").tag(count)
                    }
                }
                .disabled(!store.aiConfig.includeImages)
                Text("默认关闭：只发送本地 Vision 标签、OCR 文字与元数据。开启后优先发送选中照片，否则发送当前范围的前几张；统一压成长边约 1024 的 JPEG，原始 RAW、视频与云端照片不会发送。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("需要模型支持视觉输入（例如 gpt-4o-mini、glm-4v-flash、qwen-vl-plus）；若模型不支持，请关闭此开关。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("连接测试") {
                HStack(spacing: 10) {
                    Button(aiTesting ? "测试中…" : "测试连接") {
                        runAIConnectionTest()
                    }
                    .disabled(aiTesting || !store.aiHasAPIKey)
                    if let aiTestMessage {
                        Text(aiTestMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(aiTestOK ? Color.green : Color.red)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }

            Section("存储与隐私") {
                Text("智能助手可以检索与浏览图库，也能实际操作相簿、文件夹、图片与视频（收藏、隐藏、关键词、标题、最近删除与恢复）；每次修改图库前都会弹窗确认，不支持永久删除或编辑原图。对话记录保存在当前图库，切换图库会切换到各自的对话。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { syncAIKeyInput() }
        .onChange(of: store.aiConfig.provider) { _, _ in syncAIKeyInput() }
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
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前使用图库")
                        .font(.system(size: 17, weight: .semibold))
                    Text("每个图库独立保存自己的照片、元数据、系统图库连接、网络存储连接与库级设置；切换图库时这些内容一起切换。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if store.containerLibraryPath != nil {
                    currentLibraryCard
                } else {
                    emptyLibraryCard
                }

                Label("切换后，界面只显示新图库自己的照片、连接与设置；原图库的文件不会被删除。",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                Text("其他图库")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 6)

                if otherLibraryEntries.isEmpty {
                    infoCard {
                        Text("没有找到其他图库。用上方「打开图库…」或「新建图库…」添加后会出现在这里。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    infoCard {
                        VStack(spacing: 0) {
                            ForEach(otherLibraryEntries) { entry in
                                HStack(spacing: 10) {
                                    Image(systemName: "photo.stack")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 28)
                                        .background(Color.primary.opacity(0.05),
                                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                        Text(entry.url.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    Button("切换到此图库") {
                                        store.activateLibrary(entry.url)
                                        reloadLibraryEntries()
                                    }
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 6)
                                if entry.id != otherLibraryEntries.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                Text("「切换到此图库」会打开该图库自己的照片、连接与设置；原图库的文件不会被删除。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                Text("最近删除")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 6)

                infoCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("自动清理", selection: $settings.trashRetentionDays) {
                            Text("7 天后").tag(7)
                            Text("30 天后").tag(30)
                            Text("90 天后").tag(90)
                            Text("180 天后").tag(180)
                            Text("永不自动清理").tag(0)
                        }
                        Text("移至最近删除的项目超过保留期后会在启动时自动永久删除；手动「清空最近删除」始终可用。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("缓存")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 6)

                VStack(spacing: 10) {
                    cacheCard(title: "系统图库缩略图",
                              icon: "photo.stack",
                              size: systemCacheSize) {
                        store.clearSystemThumbnailCache()
                        refreshCacheSize()
                    }
                    cacheCard(title: "网盘缩略图",
                              icon: "externaldrive.badge.icloud",
                              size: cacheSize) {
                        store.clearCloudThumbnailCache()
                        refreshCacheSize()
                    }
                }

                Text("仅删除本机的缩略图缓存，不会影响图库、网盘或云端原图。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                Text("关于")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 6)

                infoCard {
                    HStack(spacing: 10) {
                        Image(systemName: "app.badge.checkmark")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("拾光 Luma")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("版本 \(version)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { reloadLibraryEntries() }
        .onChange(of: store.containerLibraryPath) { _, _ in reloadLibraryEntries() }
    }

    /// 当前系统图库中未删除、未隐藏的项目。
    private var libraryPhotos: [PhotoItem] {
        store.photos.filter { $0.deletedAt == nil && !$0.isHidden }
    }

    /// 最近使用过的其他图库（含官方「照片」图库）；每个库都以自己的数据与连接打开。
    private var otherLibraryEntries: [LibraryEntry] {
        libraryEntries.filter { !$0.isCurrent }
    }

    private func reloadLibraryEntries() {
        libraryEntries = store.knownLibraryEntries()
    }

    private var currentLibraryCard: some View {
        let url = store.containerLibraryPath.map { URL(fileURLWithPath: $0) }
        let photos = libraryPhotos
        let photoCount = photos.lazy.filter { !$0.isVideo }.count
        let videoCount = photos.lazy.filter { $0.isVideo }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                libraryCover(photos)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(url?.deletingPathExtension().lastPathComponent ?? "当前图库")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        statusTag(icon: "internaldrive.fill", text: "当前图库")
                    }

                    Text(url?.path ?? "")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    HStack(spacing: 14) {
                        statItem(photoCount, "照片")
                        statItem(videoCount, "视频")
                        statItem(store.albums.count, "相簿")
                        statItem(store.folders.count, "文件夹")
                        statItem(store.systemLibraries.count, "系统图库")
                        statItem(store.cloudMounts.count, "网络存储")
                    }
                    .padding(.top, 1)
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
                    Label("在访达中显示", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.02)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14),
                              style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
        }
    }

    private func libraryCover(_ photos: [PhotoItem]) -> some View {
        ZStack {
            if let first = photos.first(where: { !$0.isVideo }) ?? photos.first {
                PhotoThumbnailView(photo: first)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 96, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
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

    private func statItem(_ value: Int, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value.formatted())
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func refreshCacheSize() {
        cacheSize = store.cloudThumbnailCacheSize()
        systemCacheSize = store.systemThumbnailCacheSize()
    }
}
