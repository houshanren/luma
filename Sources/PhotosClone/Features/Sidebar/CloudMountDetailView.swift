import SwiftUI

/// 打开中的网盘的分类入口：媒体类型 / 场景 / 更多项目。
///
/// 收起状态由本视图自己持有：网盘分区在侧边栏里是 `ForEach` 的子视图，
/// 状态放在外层容易在重算时被复用成旧值，导致「点了收起但条目还在」。
struct CloudMountDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    @State private var collapsed: Set<String> = []
    @State private var hoveredSection: String?
    @State private var hoveredScope: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("媒体类型", key: "media", topPadding: 8)
            if !collapsed.contains("media") {
                mediaRows
            }

            sectionHeader("场景", key: "scenes", topPadding: 12) {
                if cloud.isAnalyzing {
                    Button("停止识别") { store.cancelCloudContentAnalysis() }
                } else if store.cloudPendingAnalysisCount > 0 {
                    Button("识别当前列表…") { store.analyzeCloudContent() }
                }
            }
            if !collapsed.contains("scenes") {
                sceneBody
            }

            sectionHeader("更多项目", key: "more", topPadding: 12)
            if !collapsed.contains("more") {
                let counts = store.cloudScopeCounts
                scopeRow(.favorites, count: counts.favorites)
                if counts.text > 0 {
                    scopeRow(.text, count: counts.text)
                }
            }
        }
        .padding(.leading, 14)
    }

    // MARK: - 媒体类型

    @ViewBuilder
    private var mediaRows: some View {
        let counts = store.cloudScopeCounts
        scopeRow(.all, count: counts.count(for: .all))
        scopeRow(.videos, count: counts.videos)
        scopeRow(.photos, count: counts.photos)
        if counts.screenshots > 0 {
            scopeRow(.screenshots, count: counts.screenshots)
        }
        if counts.animated > 0 {
            scopeRow(.animated, count: counts.animated)
        }
        if counts.raws > 0 {
            scopeRow(.raws, count: counts.raws)
        }
    }

    // MARK: - 场景（端侧识别）

    @ViewBuilder
    private var sceneBody: some View {
        if cloud.isAnalyzing {
            HStack(spacing: 7) {
                ProgressView(value: cloud.analysisProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
                Text("识别中 \(Int((cloud.analysisProgress * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else if cloud.analysis.isEmpty {
            Button {
                store.analyzeCloudContent()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    Text("识别内容…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在本机识别当前网盘列表的场景与图内文字")
            Text("识别场景与图内文字，全部在本机完成，不会上传照片")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        } else {
            let counts = store.cloudScopeCounts
            let visible = SceneCatalog.categories.filter { (counts.scenes[$0.id] ?? 0) > 0 }
            if visible.isEmpty {
                Text("未识别到常见场景")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            } else {
                ForEach(visible) { category in
                    scopeRow(.scene(category.id), count: counts.scenes[category.id] ?? 0)
                }
            }
            let pending = store.cloudPendingAnalysisCount
            if pending > 0 {
                Button {
                    store.analyzeCloudContent()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        Text("继续识别（剩余 \(pending) 张）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("每次最多识别 120 张，避免一次读取过多网盘文件")
            }
        }
    }

    // MARK: - 分区头与行

    private func sectionHeader<MenuContent: View>(
        _ title: String,
        key: String,
        topPadding: CGFloat = 12,
        @ViewBuilder menu: () -> MenuContent = { EmptyView() }
    ) -> some View {
        let isCollapsed = collapsed.contains(key)
        let hovering = hoveredSection == key

        return HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if hovering {
                Menu {
                    Button(isCollapsed ? "展开" : "收起") { toggle(key) }
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .help("更多")
            }
            if hovering || isCollapsed {
                Button {
                    toggle(key)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "展开" : "收起")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, topPadding)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredSection = inside ? key : (hoveredSection == key ? nil : hoveredSection)
        }
    }

    private func toggle(_ key: String) {
        withAnimation(settings.motion.layout) {
            if collapsed.contains(key) {
                collapsed.remove(key)
            } else {
                collapsed.insert(key)
            }
        }
    }

    private func scopeRow(_ scope: CloudScope, count: Int) -> some View {
        let selected = cloud.scope == scope
        return Button {
            store.setCloudScope(scope)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: scope.icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(scope == .favorites ? Color.pink : Color.accentColor)
                    .frame(width: 18)
                Text(scope.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.16))
                } else if hoveredScope == scope.key {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredScope = scope.key
            } else if hoveredScope == scope.key {
                hoveredScope = nil
            }
        }
        .help(scope.title)
        .accessibilityLabel(scope.title)
    }
}
