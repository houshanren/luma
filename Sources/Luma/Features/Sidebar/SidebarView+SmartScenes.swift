import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaContentCore

extension SidebarView {
    // MARK: - 场景（端侧智能分析）

    @ViewBuilder
    var sceneSectionBody: some View {
        // 识别进度只在背景任务面板里展示；侧边栏保持干净，不重复一行进度。
        if store.analyzedCount == 0 {
            if !store.isAnalyzingIntelligence {
                Button {
                    store.analyzeIntelligence()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("分析照片内容…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    // 与上面的图库行对齐：图标列落在 22pt，文字落在 50pt。
                    .padding(.leading, 22)
                    .padding(.trailing, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("识别场景与照片中的文字，全部在本机完成")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        } else {
            let counts = store.sceneCounts
            let recognized = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
            let visible = recognized.filter { isUnpinned("scene:\($0.id)") }
            if recognized.isEmpty {
                Text("未识别到常见场景")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            } else {
                ForEach(visible) { category in
                    sceneRow(category, count: counts[category.id] ?? 0)
                }
            }
        }
    }

    func sceneRow(_ category: SceneCategory, count: Int) -> some View {
        let item = SidebarItem.scene(category.id)
        return SidebarCategoryRow(icon: category.icon,
                                  title: category.title,
                                  count: count,
                                  isActive: store.sidebarItem == item,
                                  isHovered: hoveredItem == item,
                                  helpText: "查看「\(category.title)」照片",
                                  action: { store.navigate(to: item) })
            .contextMenu {
                Button(store.isPinned(.system("scene:\(category.id)")) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system("scene:\(category.id)"))
                }
            }
            .onHover { hovering in
                hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            }
    }

    // MARK: - 系统图库场景（端侧识别，缓存到 system_analysis）

    @ViewBuilder
    var systemSceneSectionBody: some View {
        // 同上：识别进度已在背景任务面板，侧边栏不再重复。
        if store.systemAnalyzedCount == 0 {
            if !store.isAnalyzingSystemContent {
                Button {
                    store.analyzeSystemContent()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("识别照片内容…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("在本机识别系统图库的场景与图内文字；结果只保存在内存，不写回「照片」")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        } else {
            // 结果边识别边出现：每识别一批就刷新下面的场景行。
            let counts = store.sceneCounts
            let recognized = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
            let visible = recognized.filter { isUnpinned("scene:\($0.id)") }
            if recognized.isEmpty {
                if !store.isAnalyzingSystemContent {
                    Text("未识别到常见场景")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                }
            } else {
                ForEach(visible) { category in
                    systemSceneRow(category, count: counts[category.id] ?? 0)
                }
            }
            // 剩余数量属于识别进度：只在任务中心呈现，侧边栏不再挂一行状态。
        }
    }

    func systemSceneRow(_ category: SceneCategory, count: Int) -> some View {
        let item = SidebarItem.systemScene(category.id)
        return SidebarCategoryRow(icon: category.icon,
                                  title: category.title,
                                  count: count,
                                  isActive: store.sidebarItem == item,
                                  isHovered: hoveredItem == item,
                                  helpText: "查看「\(category.title)」照片",
                                  action: { store.navigate(to: item) })
            .contextMenu {
                Button(store.isPinned(.system("scene:\(category.id)")) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system("scene:\(category.id)"))
                }
            }
            .onHover { hovering in
                hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            }
    }
}
