import AppKit
import SwiftUI
import LumaContentCore

/// 设置 › 本地模型：端侧能力与本地语言模型，逐个开关本机模型，默认全部关闭。
struct LocalModelsSettingsSection: View {
    @Environment(LibraryStore.self) private var store
    @ObservedObject private var installer = ModelInstaller.shared
    /// 本地语言模型的一键安装 / 启动流程（内置 Ollama 运行时 + Qwen / Gemma 模型）。
    @ObservedObject private var localLLM = LocalLLMRuntime.shared
    @AppStorage(SettingsKeys.modelManifestURL) private var manifestURL = ModelInstaller.defaultManifestURL
    @State private var pendingRemoval: ModelComponentDescriptor?
    @State private var confirmLocalRemoval = false
    /// 「什么时候用哪个模型」对照卡。
    @State private var showModelGuide = false
    /// 图像理解的开关差异与安装说明。
    @State private var showImageInfo = false
    @State private var showAdvancedSource = false
    @State private var checkingManifest = false
    @State private var runtimeCandidates: [LocalRuntimeCandidate] = []
    @State private var selectedModels: [String: String] = [:]
    @State private var scanningRuntime = false
    @State private var runtimeMessage: String?
    /// 模型下载在统一任务中心里的登记 id：下载期间切走设置页也能看到进度。
    @State private var installJobID: UUID?
    @State private var installJobModel: ModelComponentID?
    @State private var installJobSawBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heroCard
                if let descriptor = ModelRegistry.descriptor(.siglip2) {
                    imageCard(descriptor)
                }
                if let descriptor = ModelRegistry.descriptor(.localLLM) {
                    localCard(descriptor)
                }
                runtimeCard
                advancedCard
                Text("模型存放在本机 \(ModelRegistry.modelsRoot.path)，不随图库迁移或备份；关闭开关只停用，不删文件。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .alert("删除本地模型？", isPresented: removalBinding) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("删除", role: .destructive) {
                if let descriptor = pendingRemoval {
                    installer.uninstall(descriptor.id)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("会删除本机文件，之后需要重新下载；随 App 内置的模型只会停用，不会被删除。")
        }
        .alert("删除本地语言模型？", isPresented: $confirmLocalRemoval) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                localLLM.uninstall()
                // 助手还指着已删掉的模型时清空模型名，避免一直报连接失败。
                if store.aiConfig.provider == .local {
                    store.aiConfig.model = ""
                    store.saveAIConfig()
                }
            }
        } message: {
            Text("会停掉本机服务，并删除 Ollama 运行时、已下载的模型和下载缓存。")
        }
        .onChange(of: installer.states) { _, _ in
            syncInstallJob()
        }
        .task { await localLLM.refresh() }
    }

    // MARK: - 概览

    /// 首屏只回答一件事：本机现在能做什么、占了什么状态。
    private var heroCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [LumaBrand.violet,
                                                  LumaBrand.cyan.opacity(0.80)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image(systemName: "cpu")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .shadow(color: LumaBrand.violet.opacity(0.35), radius: 12, y: 5)

            VStack(alignment: .leading, spacing: 6) {
                Text("本机智能引擎")
                    .font(.system(size: 17, weight: .bold))
                HStack(spacing: 6) {
                    heroPill(imageStatus.text, tint: imageStatus.tint)
                    heroPill(localStatus.text, tint: localStatus.tint)
                }
                Text("看图、起名、整理、诊断都在这台 Mac 上完成，不联网。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [LumaBrand.violet.opacity(0.16),
                                              Color.accentColor.opacity(0.07),
                                              Color.clear],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
    }

    private var imageStatus: (text: String, tint: Color) {
        if installer.isBusy(.siglip2) { return ("图像理解 · 准备中", .secondary) }
        if ModelRegistry.isEnabled(.siglip2) { return ("图像理解 · 已启用", .green) }
        return (ModelRegistry.isInstalled(.siglip2) ? "图像理解 · 已停用" : "图像理解 · 未启用",
                .secondary)
    }

    private var localStatus: (text: String, tint: Color) {
        if localLLM.stage.isBusy { return ("本地模型 · 准备中", .secondary) }
        if localLLM.isServerRunning { return ("本地模型 · 运行中", .green) }
        if ModelRegistry.isEnabled(.localLLM) { return ("本地模型 · 已安装", .orange) }
        return ("本地模型 · 未启用", .secondary)
    }

    private func heroPill(_ text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint == .secondary ? Color.secondary.opacity(0.6) : tint)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((tint == .secondary ? Color.primary : tint).opacity(0.10), in: Capsule())
    }

    // MARK: - 图像理解

    private func imageCard(_ descriptor: ModelComponentDescriptor) -> some View {
        let installed = ModelRegistry.isInstalled(descriptor.id)
        let enabled = ModelRegistry.isEnabled(descriptor.id)
        let state = installer.state(for: descriptor.id)
        let busy = state.phase.isBusy
        return settingsCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    iconTile("photo.on.rectangle.angled", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("图像理解")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("SigLIP2 · 自动标签与语义搜索")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    infoButton(isPresented: $showImageInfo) {
                        imageInfo(descriptor)
                    }
                    Toggle("", isOn: toggleBinding(descriptor))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!ModelRegistry.isInstallable(descriptor.id))
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(state: state, enabled: enabled))
                        .frame(width: 5, height: 5)
                    Text(statusText(descriptor, installed: installed, enabled: enabled, state: state))
                        .font(.system(size: 10.5))
                        .foregroundStyle(statusColor(state: state, enabled: enabled))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if installed {
                        Text(byteText(ModelRegistry.sizeOnDisk(descriptor.id)))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                if state.phase == .downloading {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(state.progress * 100))% · \(byteText(state.received)) / \(byteText(state.total))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if descriptor.installable, !busy {
                    HStack(spacing: 8) {
                        actionChip("从本地导入…", icon: "square.and.arrow.down") {
                            pickLocalDirectory(descriptor)
                        }
                        if installed {
                            if ModelRegistry.isRemovable(descriptor.id) {
                                actionChip("删除本地文件（\(byteText(ModelRegistry.sizeOnDisk(descriptor.id)))）",
                                           icon: "trash",
                                           tint: .red) {
                                    pendingRemoval = descriptor
                                }
                            } else {
                                Text("随 App 内置，关闭开关即可停用")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
        }
    }

    private func imageInfo(_ descriptor: ModelComponentDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开 / 关的区别")
                .font(.system(size: 12.5, weight: .semibold))
            differenceLine("开",
                           text: "249 个中文标签、场景分类、相似照片、语义搜索扩展，标签写入当前图库。",
                           color: .green)
            differenceLine("关",
                           text: "退回系统 Vision 分类：只剩少量粗粒度中文标签（人物 / 文档 / 天空…）和英文概念，没有相似照片与语义扩展；重新开启后会自动补扫。",
                           color: .secondary)
            if let note = descriptor.note {
                Divider()
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("也可以从本地导入已下载的模型目录，全程不联网。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: - 本地语言模型

    private func localCard(_ descriptor: ModelComponentDescriptor) -> some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    iconTile("bubble.left.and.bubble.right.fill", tint: LumaBrand.violet)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("本地语言模型")
                                .font(.system(size: 12.5, weight: .semibold))
                            Circle()
                                .fill(localStatusColor)
                                .frame(width: 5, height: 5)
                            Text(localLLM.statusText)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(localStatusColor)
                                .lineLimit(1)
                        }
                        Text("Ollama 运行时 · 当前 \(localLLM.selectedOption.title)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        showModelGuide.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("什么时候用哪个模型？")
                    .popover(isPresented: $showModelGuide, arrowEdge: .bottom) {
                        modelGuide(descriptor)
                    }
                    Toggle("", isOn: localToggle)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if localLLM.stage.isBusy {
                    ProgressView(value: localLLM.progress)
                        .progressViewStyle(.linear)
                    Text("\(localLLM.detail) · \(Int((localLLM.progress * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                startupSteps

                // 档位换成可点选的卡片：体积、是否看图、当前选择一眼可见。
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(LocalLLMRuntime.options) { option in
                        modelTile(option)
                    }
                }

                HStack(spacing: 8) {
                    if localLLM.stage.isBusy {
                        actionChip("取消", icon: "xmark") { localLLM.cancel() }
                    } else {
                        if localLLM.isRuntimeInstalled, !localLLM.isServerRunning {
                            actionChip("启动服务", icon: "play.fill", tint: .accentColor) {
                                Task { await localLLM.startServerIfNeeded() }
                            }
                        }
                        if let version = localLLM.runtimeVersion,
                           version != LocalLLMRuntime.runtimeRelease,
                           localLLM.isRuntimeInstalled {
                            actionChip("升级运行时", icon: "arrow.up.circle") {
                                Task { await localLLM.upgradeRuntimeIfNeeded() }
                            }
                        }
                        actionChip("重新检测", icon: "arrow.clockwise") {
                            Task { await localLLM.refresh() }
                        }
                        if localLLM.isRuntimeInstalled {
                            actionChip("删除已下载", icon: "trash", tint: .red) {
                                confirmLocalRemoval = true
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
        }
    }

    /// 先开开关、再选档位、之后各页自动可用：压成一行，顺序一眼看完。
    private var startupSteps: some View {
        HStack(spacing: 4) {
            stepChip(1, "打开开关",
                     done: localLLM.isRuntimeInstalled,
                     help: "打开开关会自动下载运行时并启动服务")
            stepArrow
            stepChip(2, "选档位",
                     done: localLLM.installedModels.contains(localLLM.selectedOption.id),
                     help: "越大越聪明，4B 是推荐档")
            stepArrow
            stepChip(3, "各页可用",
                     done: localLLM.isServerRunning,
                     help: "助手、体检、关键词、影院都用它")
            Spacer(minLength: 0)
        }
    }

    private func stepChip(_ index: Int,
                          _ title: String,
                          done: Bool,
                          help: String) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.18))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 12, height: 12)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(done ? .green : .primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((done ? Color.green : Color.primary).opacity(0.07), in: Capsule())
        .help(help)
    }

    private var stepArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 6.5, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func modelTile(_ option: LocalLLMRuntime.ModelOption) -> some View {
        let selected = option.id == localLLM.selectedOptionID
        return Button {
            localLLM.selectedOptionID = option.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                HStack(spacing: 4) {
                    miniBadge(option.sizeText, tint: .secondary)
                    if option.supportsVision {
                        miniBadge("可看图", tint: Color.accentColor)
                    }
                }
                Text(option.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.10)
                                 : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55)
                                           : Color.primary.opacity(0.06),
                                  lineWidth: selected ? 1.2 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(localLLM.stage.isBusy)
        .help("\(option.whenToUse)\n\(modelFacts(option))")
    }

    private func miniBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((tint == .secondary ? Color.primary : tint).opacity(0.09),
                        in: Capsule())
    }

    /// 「什么时候用哪个模型」：档位卡片已经给了体积，这里补场景与开关差异。
    private func modelGuide(_ descriptor: ModelComponentDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("什么时候用哪个模型")
                .font(.system(size: 13, weight: .semibold))
            ForEach(LocalLLMRuntime.options) { option in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.system(size: 11.5, weight: .medium))
                        if option.supportsVision {
                            miniBadge("可看图", tint: Color.accentColor)
                        }
                        if option.id == localLLM.selectedOption.id {
                            miniBadge("当前", tint: .green)
                        }
                        Spacer()
                        Text(option.sizeText)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(option.whenToUse)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.primary.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                    let facts = modelFacts(option)
                    if !facts.isEmpty {
                        Text(facts)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Divider()

            Text("开 / 关的区别")
                .font(.system(size: 11, weight: .semibold))
            differenceLine("开",
                           text: "助手对话与看图、体检解读、回忆 / 旅行起名、分享文案、关键词整理、地点补全、搜索改写、频道清洗、今晚看什么、影院兜底与系列归组、离线帮助与日志摘要，全部在本机完成。",
                           color: .green)
            differenceLine("关",
                           text: "这些一次性 AI 辅助入口会置灰；分享文案退回标签模板、搜索改写退回规则简化。助手需接云端服务。自动标签、场景分类与相似照片由图像模型负责，不受影响。",
                           color: .secondary)
            if let note = descriptor.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("换档位会自动下载新模型；旧档位文件不会自动删，可在「删除已下载」里一起清掉。")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 430)
    }

    private func modelFacts(_ option: LocalLLMRuntime.ModelOption) -> String {
        [option.speed, option.memory]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: - 模型来源

    /// 助手当前实际指向的运行时：内置或外部，打勾的那一份生效。
    private var activeRuntimeBaseURL: String { store.aiConfig.baseURL }

    private var runtimeCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    iconTile("point.3.connected.trianglepath.dotted", tint: .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模型来源")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("内置运行时和外部 Ollama / LM Studio 二选一，打勾的那份生效")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(scanningRuntime ? "检测中…" : "检测") {
                        detectRuntime()
                    }
                    .controlSize(.small)
                    .disabled(scanningRuntime)
                }

                // 内置运行时也作为一项列出：从外部切回来不用再去动上面的开关。
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("内置运行时（Luma 自带）")
                                .font(.system(size: 11.5, weight: .medium))
                            if activeRuntimeBaseURL == LocalLLMRuntime.baseURLString {
                                miniBadge("当前使用", tint: .green)
                            }
                        }
                        Text("\(localLLM.statusText) · \(localLLM.selectedOption.title)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if activeRuntimeBaseURL != LocalLLMRuntime.baseURLString {
                        actionChip("切回", icon: "arrow.left", tint: .accentColor) {
                            useBuiltinRuntime()
                        }
                        .disabled(!localLLM.isServerRunning)
                        .help(localLLM.isServerRunning
                              ? "把助手切回内置运行时"
                              : "先打开上面的开关启动内置服务")
                    }
                }
                .padding(.vertical, 2)

                ForEach(runtimeCandidates) { candidate in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(candidate.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                if activeRuntimeBaseURL == candidate.baseURL {
                                    miniBadge("当前使用", tint: .green)
                                }
                            }
                            Text(candidate.baseURL)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if activeRuntimeBaseURL == candidate.baseURL {
                            Text(store.aiConfig.model)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Picker("模型", selection: modelBinding(candidate)) {
                                ForEach(candidate.models, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            .controlSize(.small)
                            actionChip("使用", icon: "arrow.right", tint: .accentColor) {
                                use(candidate)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let runtimeMessage {
                    Text(runtimeMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("默认扫描 11434（Ollama）与 1234（LM Studio），数据不出本机。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }

    /// 从外部运行时切回内置：模型跟随当前档位，档位切换也会实时同步。
    private func useBuiltinRuntime() {
        store.aiConfig.provider = .local
        store.aiConfig.baseURL = LocalLLMRuntime.baseURLString
        store.aiConfig.model = localLLM.selectedOption.id
        if localLLM.selectedOption.supportsVision {
            store.aiConfig.includeImages = true
        }
        store.saveAIConfig()
        runtimeMessage = "已切回内置运行时 · \(localLLM.selectedOption.title)"
    }

    // MARK: - 高级（下载源）

    private var manifestSummary: String {
        if installer.manifestError != nil { return "检查失败" }
        if let manifest = installer.manifest {
            return "v\(manifest.version) · \(manifest.components.count) 个组件"
        }
        return "内置清单"
    }

    private var advancedCard: some View {
        settingsCard {
            DisclosureGroup(isExpanded: $showAdvancedSource) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("留空使用 App 内置清单", text: $manifestURL)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button(checkingManifest ? "检查中…" : "检查更新") {
                            checkingManifest = true
                            Task {
                                await installer.refreshManifest()
                                checkingManifest = false
                            }
                        }
                        .controlSize(.small)
                        .disabled(checkingManifest)
                        if let error = installer.manifestError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        } else if let manifest = installer.manifest {
                            Text("清单版本 \(manifest.version) · \(manifest.components.count) 个组件")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("默认使用内置清单")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("图像 / 文本编码器走 hf-mirror 国内镜像，词表随 App 内置。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 12)
            } label: {
                HStack(spacing: 12) {
                    iconTile("slider.horizontal.3", tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高级 · 下载源")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("模型清单与镜像地址")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(manifestSummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
        }
    }

    // MARK: - 通用组件

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

    private func iconTile(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .frame(width: 32, height: 32)
            .background((tint == .secondary ? Color.primary : tint).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func infoButton<Content: View>(isPresented: Binding<Bool>,
                                           @ViewBuilder content: @escaping () -> Content) -> some View {
        Button {
            isPresented.wrappedValue.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("开 / 关的区别")
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            content()
        }
    }

    private func actionChip(_ title: String,
                            icon: String,
                            tint: Color = .secondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((tint == .secondary ? Color.primary : tint).opacity(0.07),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func differenceLine(_ mark: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(mark)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.13), in: Capsule())
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 模型下载任务

    /// 把模型安装进度映射到统一任务中心：开始下载时登记，结束 / 失败时收尾。
    private func syncInstallJob() {
        guard let jobID = installJobID, let modelID = installJobModel else { return }
        let state = installer.state(for: modelID)
        switch state.phase {
        case .preparing, .downloading, .verifying, .installing:
            installJobSawBusy = true
            store.updateSourceJob(jobID,
                                  message: "\(phaseText(state.phase)) \(Int((state.progress * 100).rounded()))%",
                                  fraction: state.progress)
        case .failed(let message):
            store.failSourceJob(jobID, message: message)
            resetInstallJob()
        case .idle:
            // 刚开始安装时 installer 还没进入 busy 阶段，不能立刻判定为结束。
            guard installJobSawBusy else { return }
            if ModelRegistry.isInstalled(modelID) {
                store.finishSourceJob(jobID, message: "已安装")
            } else {
                store.cancelSourceJob(jobID)
            }
            resetInstallJob()
        }
    }

    private func startInstall(_ descriptor: ModelComponentDescriptor) {
        installJobID = store.beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .download,
                      title: "下载模型 \(descriptor.title)"),
            cancel: { ModelInstaller.shared.cancel(descriptor.id) }
        )
        installJobModel = descriptor.id
        installJobSawBusy = false
        installer.install(descriptor.id)
    }

    private func resetInstallJob() {
        installJobID = nil
        installJobModel = nil
        installJobSawBusy = false
    }

    private func phaseText(_ phase: ModelInstaller.Phase) -> String {
        switch phase {
        case .preparing: return "准备中"
        case .downloading: return "下载中"
        case .verifying: return "校验中"
        case .installing: return "安装中"
        case .idle, .failed: return "下载"
        }
    }

    // MARK: - 开关

    private var localToggle: Binding<Bool> {
        Binding(
            get: {
                ModelRegistry.isEnabled(.localLLM)
                    || localLLM.stage == .ready
                    || localLLM.stage.isBusy
            },
            set: { on in
                if on {
                    localLLM.enable()
                } else {
                    localLLM.disable()
                    store.showToast("已停止本地模型服务")
                }
            }
        )
    }

    private var localStatusColor: Color {
        switch localLLM.stage {
        case .failed: return .red
        case .ready: return .green
        default: return .secondary
        }
    }

    private func toggleBinding(_ descriptor: ModelComponentDescriptor) -> Binding<Bool> {
        Binding(
            get: { ModelRegistry.isEnabled(descriptor.id) || installer.isBusy(descriptor.id) },
            set: { on in
                if on {
                    if ModelRegistry.isInstalled(descriptor.id) {
                        ModelRegistry.setEnabled(true, for: descriptor.id)
                    } else {
                        startInstall(descriptor)
                    }
                } else {
                    if installer.isBusy(descriptor.id) {
                        installer.cancel(descriptor.id)
                    }
                    ModelRegistry.setEnabled(false, for: descriptor.id)
                    // 关掉图像理解就停掉正在跑的场景识别，别让后台任务继续占着 CPU。
                    if descriptor.id == .siglip2 {
                        if store.isAnalyzingIntelligence { store.cancelIntelligenceAnalysis() }
                        if store.isAnalyzingSystemContent { store.cancelSystemContentAnalysis() }
                        if store.cloudModel.isAnalyzing { store.cancelCloudContentAnalysis() }
                    }
                }
            }
        )
    }

    private func statusText(_ descriptor: ModelComponentDescriptor,
                            installed: Bool,
                            enabled: Bool,
                            state: ModelInstaller.InstallState) -> String {
        switch state.phase {
        case .preparing: return "准备中…"
        case .downloading: return "下载中"
        case .verifying: return "校验中…"
        case .installing: return "安装中…"
        case .failed(let message): return "失败：\(message)"
        case .idle:
            guard installed else {
                if !descriptor.installable {
                    return "由外部运行时提供（Ollama / LM Studio）"
                }
                return ModelRegistry.isInstallable(descriptor.id)
                    ? "未安装 · \(descriptor.approxSize)"
                    : "当前系统不支持（需要 macOS 15 以上）"
            }
            let version = ModelRegistry.installedVersion(descriptor.id) ?? ""
            let suffix = version.isEmpty ? "" : " · v\(version)"
            return enabled ? "已启用\(suffix)" : "已停用\(suffix)"
        }
    }

    private func statusColor(state: ModelInstaller.InstallState, enabled: Bool) -> Color {
        switch state.phase {
        case .failed: return .red
        case .preparing, .downloading, .verifying, .installing: return .secondary
        case .idle: return enabled ? .green : .secondary
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 本地导入

    private func pickLocalDirectory(_ descriptor: ModelComponentDescriptor) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择包含 \(descriptor.requiredEntries.joined(separator: "、")) 的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            installer.importLocalDirectory(url, for: descriptor.id)
        }
    }

    // MARK: - 本地运行时

    private func detectRuntime() {
        scanningRuntime = true
        runtimeMessage = nil
        let configured = store.aiConfig.baseURL
        Task {
            let candidates = await LocalRuntimeScanner.scan(extra: configured)
            runtimeCandidates = candidates
            scanningRuntime = false
            if candidates.isEmpty {
                runtimeMessage = "没有检测到本机服务，请先启动 Ollama 或 LM Studio。"
            }
        }
    }

    private func modelBinding(_ candidate: LocalRuntimeCandidate) -> Binding<String> {
        Binding(
            get: { selectedModels[candidate.baseURL] ?? candidate.models.first ?? "" },
            set: { selectedModels[candidate.baseURL] = $0 }
        )
    }

    private func use(_ candidate: LocalRuntimeCandidate) {
        let model = selectedModels[candidate.baseURL] ?? candidate.models.first ?? ""
        guard !model.isEmpty else { return }
        store.aiConfig.provider = .local
        store.aiConfig.baseURL = candidate.baseURL
        store.aiConfig.model = model
        store.saveAIConfig()
        runtimeMessage = "已切换到 \(candidate.title) · \(model)"
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
    }
}
