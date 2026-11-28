import AppKit
import SwiftUI

/// 创意工坊：技能与连接器市场。
/// 技能是「怎么说」，连接器是「能接什么」；两者都不绕过计划、审批与撤销。
struct AISkillsSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var query = ""
    @State private var domain = "全部"
    @State private var paths: [String: String] = [:]
    @State private var busyPreset: String?

    private var mcp: MCPService { MCPService.shared }

    private var domains: [String] {
        ["全部"] + Array(Set(AISkillLibrary.skills.map(\.domain))).sorted()
    }

    private var filteredSkills: [AISkill] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AISkillLibrary.skills.filter { skill in
            let domainOK = domain == "全部" || skill.domain == domain
            let queryOK = keyword.isEmpty
                || skill.title.lowercased().contains(keyword)
                || skill.summary.lowercased().contains(keyword)
            return domainOK && queryOK
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    if tab == 0 {
                        skillFilters
                        skillGrid
                    } else {
                        connectorGrid
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 660)
        .background(.regularMaterial)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("创意工坊")
                    .font(.system(size: 14, weight: .semibold))
                Text("把常说的那句话变成一键；连接器按需安装，默认关闭")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: $tab) {
                Text("技能").tag(0)
                Text("连接器").tag(1)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 160)
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

    private var hero: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85),
                                                  Color.accentColor.opacity(0.40)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("你的常用任务，不该每次重新描述")
                    .font(.system(size: 13, weight: .semibold))
                Text("技能只改变「怎么说」，执行仍走计划、审批与撤销。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(AISkillLibrary.skills.count) 个技能")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("\(AIConnectorMarket.presets.count) 个连接器预设")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text(mcp.status)
                    .font(.system(size: 9))
                    .foregroundStyle(mcp.serverCount > 0 ? Color.green : Color.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.10),
                                              Color.accentColor.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - 技能

    private var skillFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextField("搜索技能", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: 220)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(domains, id: \.self) { value in
                            Button {
                                domain = value
                            } label: {
                                Text(value)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(domain == value ? .white : Color.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(domain == value ? Color.accentColor : Color.primary.opacity(0.05),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var skillGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            ForEach(filteredSkills) { skill in
                skillCard(skill)
            }
        }
    }

    private func skillCard(_ skill: AISkill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: skill.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.title)
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 5) {
                        Text(skill.domain)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        if skill.writes {
                            Text("会修改")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Text(skill.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("填入") {
                    store.fillAISkill(skill)
                    dismiss()
                }
                .controlSize(.small)
                Button("执行") {
                    store.runAISkill(skill)
                    dismiss()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 连接器

    private var connectorGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            ForEach(AIConnectorMarket.presets) { preset in
                connectorCard(preset)
            }
        }
    }

    private func connectorCard(_ preset: AIConnectorPreset) -> some View {
        let added = mcp.configuredServerNames.contains { $0 == preset.id || $0.hasPrefix(preset.id + "-") }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(preset.command)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if added {
                    Label("已添加", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.green)
                }
            }
            Text(preset.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if preset.needsPath, !added {
                HStack(spacing: 8) {
                    TextField("选择目录", text: Binding(
                        get: { paths[preset.id] ?? "" },
                        set: { paths[preset.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5))
                    Button("选择…") {
                        chooseDirectory(for: preset.id)
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if !added {
                    Button(busyPreset == preset.id ? "添加中…" : "添加连接器") {
                        Task {
                            busyPreset = preset.id
                            await store.addAIConnector(preset, path: paths[preset.id] ?? "")
                            busyPreset = nil
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(busyPreset != nil || (preset.needsPath && (paths[preset.id] ?? "").isEmpty))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 底

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(mcp.serverCount > 0 ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(mcp.status)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("连接器工具每次调用都会请求确认")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Button("打开 mcp.json") {
                revealConfig()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func chooseDirectory(for id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            paths[id] = url.path
        }
    }

    private func revealConfig() {
        let url = MCPService.shared.configURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
