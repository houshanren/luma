import AppKit
import SwiftUI

/// 助手控制台：把「模型、角色、审批、记忆、技能、定时、连接器、会话」收进一个面板。
/// 替代原来头部的简单下拉菜单。
struct AIControlCenterSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.selectedTab) private var settingsTab: SettingsTab = .general
    @AppStorage("ai.surface.autoHide") private var autoHide = true
    @AppStorage("ai.peek.enabled") private var peekEnabled = true

    @State private var confirmClear = false
    /// 「始终允许」存在 UserDefaults，清除后靠它刷新卡片。
    @State private var approvalMemoryRevision = 0

    private var mcp: MCPService { MCPService.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    grid
                    surfaceSection
                    footerNote
                }
                .padding(18)
            }
        }
        .frame(width: 740, height: 680)
        .background(.regularMaterial)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .confirmationDialog("清空当前对话？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                store.clearAIConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清空聊天记录；成果物、记忆与定时任务不受影响。")
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("助手控制台")
                    .font(.system(size: 14, weight: .semibold))
                Text("模型、角色、记忆、技能与自动化，都在这里")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("完整设置") {
                openSettings()
            }
            .controlSize(.small)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 状态

    private var hero: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85),
                                                  Color.accentColor.opacity(0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.aiConfig.provider.title) · \(store.aiConfig.model)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    chip(store.aiConfigurationReady ? "模型已配置" : "待配置模型",
                         tint: store.aiConfigurationReady ? .green : .orange)
                    chip(store.aiHasAPIKey ? "Key 已保存" : "无 Key",
                         tint: store.aiHasAPIKey ? .green : .secondary)
                    chip("\(store.aiMessages.count) 条消息", tint: .secondary)
                    if store.aiConfig.includeImages {
                        chip("图片理解", tint: .blue)
                    }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(store.aiSurfaceMode.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("⌘J 开关 · ⇧⌘J 浮窗 · ⌥⌘J 工作台")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.10),
                                              Color.accentColor.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tint == .secondary ? Color.primary : tint).opacity(0.10), in: Capsule())
    }

    // MARK: - 卡片

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            modelCard
            roleCard
            memoryCard
            skillCard
            scheduleCard
            sessionCard
        }
    }

    private var modelCard: some View {
        card(title: "模型与连接", icon: "cpu", subtitle: "接口、模型与图片理解") {
            VStack(alignment: .leading, spacing: 6) {
                row("提供商", store.aiConfig.provider.title)
                row("模型", store.aiConfig.model)
                row("图片", store.aiConfig.includeImages ? "发送压缩缩略图" : "只发元数据")
            }
            HStack(spacing: 8) {
                Button("更换模型") { openSettings() }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    private var roleCard: some View {
        card(title: "角色与审批", icon: "person.2", subtitle: "工具边界与写操作确认") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("角色")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Picker("", selection: configBinding(\.agentRole)) {
                        ForEach(AIAgentRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
                HStack {
                    Text("审批")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Picker("", selection: configBinding(\.approval)) {
                        ForEach(AIApprovalMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
                Toggle("自动角色可委派只读子任务", isOn: configBinding(\.delegateToSubAgents))
                    .font(.system(size: 10.5))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Toggle("按意图收窄工具（关掉 = 全量，用于成本对比）", isOn: configBinding(\.toolRoutingEnabled))
                    .font(.system(size: 10.5))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                if !store.aiAlwaysAllowedTools.isEmpty {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        Text("已记住 \(store.aiAlwaysAllowedTools.count) 个工具的「始终允许」")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button("清除") {
                            store.forgetAllAIAlwaysAllowedTools()
                            approvalMemoryRevision &+= 1
                        }
                        .controlSize(.small)
                    }
                    .id(approvalMemoryRevision)
                }
            }
        }
    }

    private var memoryCard: some View {
        card(title: "长期记忆", icon: "brain", subtitle: "跨对话保留的偏好") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(store.aiMemories.filter(\.isEnabled).count)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("条启用 / 共 \(store.aiMemories.count) 条")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("管理记忆") {
                    openLater { store.showAIMemorySheet = true }
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    private var skillCard: some View {
        card(title: "技能与连接器", icon: "wand.and.stars", subtitle: "任务模板与 MCP 市场") {
            VStack(alignment: .leading, spacing: 5) {
                row("技能", "\(AISkillLibrary.skills.count) 个内置")
                row("连接器", "\(AIConnectorMarket.presets.count) 个预设")
                row("MCP", mcp.status)
            }
            HStack(spacing: 8) {
                Button("打开市场") {
                    openLater { store.showAISkillsSheet = true }
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    private var scheduleCard: some View {
        card(title: "定时任务", icon: "clock.arrow.circlepath", subtitle: "到点自动跑只读任务") {
            VStack(alignment: .leading, spacing: 5) {
                row("已启用", "\(store.aiSchedules.filter(\.isEnabled).count) 条")
                if let next = store.aiSchedules
                    .filter(\.isEnabled)
                    .compactMap(\.nextRunAt)
                    .min() {
                    row("下次", Self.dateFormatter.string(from: next))
                } else {
                    row("下次", "未安排")
                }
            }
            HStack(spacing: 8) {
                Button("管理定时任务") {
                    openLater { store.showAIScheduleSheet = true }
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    private var tokenText: String {
        let prompt = store.aiLastPromptTokens
        let completion = store.aiLastCompletionTokens
        guard prompt + completion > 0 else { return "端点未返回" }
        return "\(prompt) in · \(completion) out"
    }

    private var sessionCard: some View {
        card(title: "会话", icon: "bubble.left.and.bubble.right", subtitle: "当前对话与产出") {
            VStack(alignment: .leading, spacing: 5) {
                row("消息", "\(store.aiMessages.count) 条")
                row("成果物", "\(store.aiArtifactLibrary.count) 个")
                row("本轮工具", store.aiLastToolCount > 0 ? "\(store.aiLastToolCount) 个" : "未运行")
                row("本轮 tokens", tokenText)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("成果物库") {
                        openLater { store.showAIArtifactSheet = true }
                    }
                    .controlSize(.small)
                    Button("任务中心") {
                        openLater { store.showAITaskCenter = true }
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button("清空对话") {
                        confirmClear = true
                    }
                    .controlSize(.small)
                    .disabled(store.aiMessages.isEmpty)
                    Spacer(minLength: 0)
                    Button("新问题") {
                        dismiss()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func card<Content: View>(title: String,
                                     icon: String,
                                     subtitle: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
    }

    // MARK: - 呈现方式

    private var surfaceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("呈现方式")
                .font(.system(size: 11.5, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(AISurfaceMode.presentations) { mode in
                    surfaceButton(mode, subtitle: mode.detail)
                }
            }
            HStack(spacing: 18) {
                Toggle("沉浸内容时自动让位", isOn: $autoHide)
                    .font(.system(size: 10.5))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Toggle("显示半隐藏入口", isOn: $peekEnabled)
                    .font(.system(size: 10.5))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!autoHide)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func surfaceButton(_ mode: AISurfaceMode, subtitle: String) -> some View {
        let selected = store.aiSurfaceMode == mode
        // 并排 / 叠放都要占右侧空间：看图、播放、编辑器里不可用。
        let enabled = (mode != .docked && mode != .overlay) || store.aiDockAvailable
        return Button {
            store.selectAISurface(mode)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(enabled ? "切换到\(mode.title)：\(mode.detail)" : "当前上下文不能并排 / 叠放")
    }

    private var footerNote: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("写操作始终经过审批与检查点；关闭助手不会中断正在跑的任务。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 工具

    private func configBinding<T>(_ keyPath: WritableKeyPath<AIConfig, T>) -> Binding<T> {
        Binding(
            get: { store.aiConfig[keyPath: keyPath] },
            set: { value in
                store.aiConfig[keyPath: keyPath] = value
                store.saveAIConfig()
            }
        )
    }

    private func openSettings() {
        settingsTab = .assistant
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        dismiss()
    }

    /// 先收起控制台，再在同一个宿主上打开下一层 sheet。
    private func openLater(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: action)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
