import SwiftUI
import AppKit

/// 重复项目：按文件大小 + 像素尺寸归组，支持单组处理与一键处理全部。
/// 本地图库合并到最近删除；系统图库只读，改为隐藏其余副本或到「照片」中合并。
struct DuplicatesView: View {
    /// true 表示浏览系统图库（只读）：不删除 Apple 的照片，只能隐藏副本或到「照片」中合并。
    var system: Bool = false

    @EnvironmentObject private var store: LibraryStore

    @State private var sortMode: SortMode = .space
    @State private var hoveredPhotoID: UUID?
    @State private var pending: PendingMerge?

    private enum SortMode: String, CaseIterable, Identifiable {
        case space, date, count

        var id: String { rawValue }

        var title: String {
            switch self {
            case .space: return "按可释放空间"
            case .date: return "按拍摄日期"
            case .count: return "按副本数量"
            }
        }
    }

    private struct PendingMerge: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let actionTitle: String
        let perform: () -> Void
    }

    private var groups: [DuplicateGroup] {
        let base = system ? store.systemDuplicateGroups : store.duplicateGroups
        switch sortMode {
        case .space:
            return base
        case .date:
            return base.sorted { $0.capturedAt > $1.capturedAt }
        case .count:
            return base.sorted {
                if $0.photos.count != $1.photos.count { return $0.photos.count > $1.photos.count }
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        hero
                        ForEach(groups) { group in
                            groupCard(group)
                        }
                        footer
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 56)
                }
            }
        }
        .alert(pending?.title ?? "", isPresented: alertBinding, presenting: pending) { item in
            Button(item.actionTitle) {
                item.perform()
                pending = nil
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { item in
            Text(item.message)
        }
    }

    // MARK: - 顶部总览

    private var hero: some View {
        let redundant = groups.reduce(0) { $0 + $1.photos.count - 1 }
        let bytes = groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("重复项目")
                        .font(.system(size: 27, weight: .bold))
                    Text(system
                         ? "官方「照片」图库只读；可到「照片」中合并，或在拾光里隐藏其余副本（随时可恢复）。"
                         : "同一张照片的多份副本会归到一组；合并保留一个版本，并汇总收藏、关键词与相簿关系。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if system {
                    HStack(spacing: 8) {
                        Button {
                            openSystemDuplicatesInPhotos()
                        } label: {
                            Label("在「照片」中合并", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("官方图库只读，真正的合并需在系统「照片」中完成")

                        if store.canEditNativeOverlay {
                            Button {
                                requestHideAll()
                            } label: {
                                Label("隐藏全部副本", systemImage: "eye.slash")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .help("每组保留推荐版本，其余副本在拾光中隐藏，可在「已隐藏」中恢复")
                        }
                    }
                } else {
                    Button {
                        requestMergeAll()
                    } label: {
                        Label("合并全部", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help("每组保留推荐版本，其余副本移入最近删除")
                }
            }

            HStack(spacing: 10) {
                statChip("\(groups.count)", "组重复", icon: "square.on.square")
                statChip("\(redundant)", "个多余副本", icon: "doc.on.doc")
                statChip(formatFileSize(bytes), system ? "副本占用" : "可释放空间", icon: "internaldrive")
                Spacer(minLength: 8)
                sortMenu
            }

            if system && store.isLoadingSystemLibrary {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在读取系统图库… \(store.systemScanCount.formatted()) 项，完成后会自动更新重复结果。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.16),
                                                  Color.accentColor.opacity(0.03)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 0.8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 74, weight: .ultraLight))
                .foregroundStyle(Color.accentColor.opacity(0.10))
                .padding(.trailing, 22)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
    }

    private func statChip(_ value: String, _ label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(label)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortMode.allCases) { mode in
                Button {
                    sortMode = mode
                } label: {
                    if mode == sortMode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Label(sortMode.title, systemImage: "arrow.up.arrow.down")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("调整重复组的排序")
    }

    // MARK: - 分组卡片

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(DateText.dayFormatter.string(from: group.capturedAt))
                    .font(.system(size: 13, weight: .semibold))
                Text("合并 \(group.photos.count) 个项目")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if group.reclaimableBytes > 0 {
                    Text(system
                         ? "副本占用 \(formatFileSize(group.reclaimableBytes))"
                         : "可释放 \(formatFileSize(group.reclaimableBytes))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if system {
                    Button {
                        store.importSystemDuplicateKeep(group)
                    } label: {
                        Label("拷贝保留版本", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("把建议保留的版本拷贝到拾光，官方图库保持不变")

                    if store.canEditNativeOverlay {
                        Button {
                            requestHide(group, keeping: group.keepID)
                        } label: {
                            Label("隐藏其余", systemImage: "eye.slash")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("保留建议版本，其余副本在拾光中隐藏（可恢复）")
                    }
                } else {
                    Button {
                        requestMerge(group, keeping: group.keepID)
                    } label: {
                        Label("合并", systemImage: "arrow.triangle.merge")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("保留建议版本，其余副本移入最近删除")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.photos) { photo in
                        DuplicateThumb(photo: photo,
                                       system: system,
                                       isKeep: photo.id == group.keepID,
                                       reasons: photo.id == group.keepID ? group.keepReasons : [],
                                       isHovering: hoveredPhotoID == photo.id,
                                       onHover: { hovering in
                                           hoveredPhotoID = hovering
                                               ? photo.id
                                               : (hoveredPhotoID == photo.id ? nil : hoveredPhotoID)
                                       },
                                       onKeep: {
                                           requestMerge(group, keeping: photo.id)
                                       })
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("共 \(groups.reduce(0) { $0 + $1.photos.count }) 张照片")
                .font(.system(size: 11.5, weight: .medium))
            Text(system
                 ? "官方图库只读，拾光不会删除 Apple 的照片；可用「隐藏」管理重复项，或到「照片」中合并。"
                 : "重复项目按文件大小与分辨率归组，也可能包含元数据不同的精确副本。合并后可随时在「最近删除」中恢复。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if system && store.isLoadingSystemLibrary {
                ProgressView()
                    .controlSize(.large)
                Text("正在读取系统图库…")
                    .font(.system(size: 14, weight: .semibold))
                Text("扫描完成后会自动列出重复项目。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text(system ? "没有检测到重复项目" : "没有重复项目")
                    .font(.system(size: 14, weight: .semibold))
                Text(system
                     ? "官方「照片」图库中没有找到重复副本。"
                     : "当同一张照片被重复导入时，会在这里按组显示，并标出建议保留的版本。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    // MARK: - 合并确认

    private func requestMerge(_ group: DuplicateGroup, keeping keepID: UUID) {
        let keepText = keepID == group.keepID ? "建议保留的版本" : "所选的版本"
        pending = PendingMerge(
            title: "合并重复项目",
            message: "所选项目按文件大小与分辨率判定为副本，元数据可能不同。合并将保留\(keepText)，汇总收藏、关键词、标题与相簿关系，并将其余 \(group.photos.count - 1) 个项目移至「最近删除」，30 天内可恢复。",
            actionTitle: "合并 \(group.photos.count) 个精确副本",
            perform: { store.mergeDuplicateGroup(group, keeping: keepID) }
        )
    }

    private func requestMergeAll() {
        let groupCount = groups.count
        let total = groups.reduce(0) { $0 + $1.photos.count }
        let redundant = total - groupCount
        let bytes = groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        pending = PendingMerge(
            title: "合并全部重复项目",
            message: "将合并 \(groupCount) 组共 \(total) 个项目：每组保留推荐版本，其余 \(redundant) 个副本移至「最近删除」，预计释放 \(formatFileSize(bytes))。收藏、关键词与相簿关系会汇总到保留的版本。",
            actionTitle: "合并 \(redundant) 个副本",
            perform: { store.mergeAllDuplicateGroups() }
        )
    }

    // MARK: - 系统图库：隐藏副本

    private func openSystemDuplicatesInPhotos() {
        if store.isNativeContainer {
            store.openContainerInPhotos()
        } else if let path = store.systemLibraryPath {
            store.openSystemLibraryInPhotos(path)
        }
    }

    private func requestHide(_ group: DuplicateGroup, keeping keepID: UUID) {
        let keepText = keepID == group.keepID ? "建议保留的版本" : "所选的版本"
        pending = PendingMerge(
            title: "隐藏其余副本",
            message: "官方「照片」图库不会被修改。拾光将保留\(keepText)，并隐藏其余 \(group.photos.count - 1) 个副本；隐藏项可在「已隐藏」中随时恢复。",
            actionTitle: "隐藏 \(group.photos.count - 1) 个副本",
            perform: { store.hideSystemDuplicateCopies(group, keeping: keepID) }
        )
    }

    private func requestHideAll() {
        let groupCount = groups.count
        let total = groups.reduce(0) { $0 + $1.photos.count }
        let redundant = total - groupCount
        pending = PendingMerge(
            title: "隐藏全部重复副本",
            message: "官方「照片」图库不会被修改。拾光将按推荐版本隐藏 \(groupCount) 组中的 \(redundant) 个副本，可在「已隐藏」中恢复。",
            actionTitle: "隐藏 \(redundant) 个副本",
            perform: { store.hideAllSystemDuplicateCopies() }
        )
    }
}

private struct DuplicateThumb: View {
    @EnvironmentObject private var store: LibraryStore

    let photo: PhotoItem
    /// 系统图库为只读来源：不能合并删除，只能隐藏副本或拷贝到拾光。
    let system: Bool
    let isKeep: Bool
    let reasons: [String]
    let isHovering: Bool
    let onHover: (Bool) -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PhotoThumbnailView(photo: photo)
                .frame(width: 148, height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isKeep ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: isKeep ? 2 : 0.5)
                }
                .overlay(alignment: .topLeading) {
                    if isKeep {
                        keepBadge
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    sizeBadge
                }
                .overlay(alignment: .bottom) {
                    if isHovering && !isKeep && (!system || store.canEditNativeOverlay) {
                        keepButton
                    }
                }
                .shadow(color: .black.opacity(isHovering ? 0.20 : 0.10),
                        radius: isHovering ? 12 : 6, y: isHovering ? 5 : 2)
                .scaleEffect(isHovering ? 1.015 : 1)
                .animation(.snappy(duration: 0.16), value: isHovering)
                .onHover(perform: onHover)
                .onTapGesture { store.openViewer(photo.id) }
                .contextMenu {
                    Button("打开") { store.openViewer(photo.id) }
                    if system {
                        Button("拷贝到拾光") { store.importSystemPhotoToLibrary(photo) }
                        if !isKeep, store.canEditNativeOverlay {
                            Button("隐藏此副本") {
                                store.setSystemHidden(true, ids: [photo.id])
                            }
                        }
                    } else if !isKeep {
                        Button("保留这张，合并其余") { onKeep() }
                    }
                    Button("在访达中显示") { store.revealInFinder(photo.id) }
                }
                .help(isKeep
                      ? (reasons.isEmpty ? "建议保留这个版本" : "建议保留：\(reasons.joined(separator: "、"))")
                      : "合并时默认移除这个副本")

            HStack(spacing: 4) {
                Image(systemName: isKeep ? "checkmark.seal.fill" : "doc.on.doc")
                    .font(.system(size: 9.5))
                    .foregroundStyle(isKeep ? Color.accentColor : Color.secondary)
                Text(isKeep ? "建议保留" : "副本")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isKeep ? Color.accentColor : Color.secondary)
                Spacer(minLength: 0)
            }

            Text(isKeep
                 ? (reasons.isEmpty ? "与其他副本等效" : reasons.joined(separator: " · "))
                 : "加入于 \(DateText.dayFormatter.string(from: photo.addedAt))")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
        .accessibilityLabel(isKeep ? "建议保留的版本" : "重复副本")
    }

    private var keepBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 8.5, weight: .bold))
            Text("建议保留")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(LinearGradient(colors: [Color.accentColor,
                                            Color.accentColor.opacity(0.72)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(6)
    }

    private var sizeBadge: some View {
        Text(formatFileSize(photo.fileSize))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
    }

    private var keepButton: some View {
        Button(action: onKeep) {
            Text("保留这张")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}
