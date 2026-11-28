import SwiftUI

/// 图集：把网络资源里的图集 / 写真接进星图。
/// 关键词来自资料库人物或番号，结果按站点过滤，自动缓存 7 天。
struct AtlasGalleriesView: View {
    @Environment(AtlasStore.self) private var atlas
    @Environment(CatalogBrowserModel.self) private var catalog
    @Environment(LibraryStore.self) private var store

    @State private var sourceFilter: UUID?
    @State private var showsVideos = false

    private var online: AtlasOnlineStore { AtlasOnlineStore.shared }

    private var keyword: String {
        atlas.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gallerySources: [CatalogSource] {
        catalog.enabledResourceSources.filter {
            $0.kind.isGallerySite || $0.kind.isComprehensiveSite
        }
    }

    private var entries: [AtlasOnlineEntry] {
        // 关键词刚改、在线结果还是上一位的时候先不显示，避免闪一下旧图集。
        guard online.keyword == keyword else { return [] }
        let base = showsVideos ? online.galleries + online.videos : online.galleries
        guard let sourceFilter else { return base }
        return base.filter { $0.sourceID == sourceFilter }
    }

    private var isSearching: Bool {
        online.isLoading || online.keyword != keyword
    }

    private var currentGalleries: [AtlasOnlineEntry] {
        online.keyword == keyword ? online.galleries : []
    }

    private var currentVideos: [AtlasOnlineEntry] {
        online.keyword == keyword ? online.videos : []
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.1)
            ScrollView {
                if keyword.isEmpty {
                    landing
                } else {
                    results
                }
            }
            .scrollIndicators(.never)
        }
        .task(id: keyword) { await runSearch() }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 6) {
            sourceChip(nil, title: "全部站点")
            ForEach(gallerySources) { source in
                sourceChip(source.id, title: source.name)
            }
            Spacer(minLength: 8)
            if !keyword.isEmpty {
                Toggle(isOn: $showsVideos) {
                    Text("含视频")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                if online.isLoading {
                    ProgressView().controlSize(.mini)
                } else if let updated = online.lastUpdated, online.keyword == keyword {
                    Label("已缓存 \(updated.formatted(date: .omitted, time: .shortened))",
                          systemImage: "checkmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    Task { await online.load(keyword, catalog: catalog, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("重新抓取在线图集")
                .disabled(online.isLoading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private func sourceChip(_ id: UUID?, title: String) -> some View {
        let active = sourceFilter == id
        return Button {
            sourceFilter = id
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.8))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.05))
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: 落地页

    private var landing: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(LumaBrand.violet)
                    Text("写真与图集")
                        .font(.system(size: 24, weight: .black, design: .serif))
                    Text("ONLINE GALLERIES")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.tertiary)
                }
                Text(gallerySources.isEmpty
                     ? "还没有启用的图集站。接入网络资源后，图集会自动出现在这里，并与人物、番号对齐。"
                     : "在顶部搜索人物或番号，星图会同时问所有图集站；结果缓存 7 天，点开即进入站点详情。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if gallerySources.isEmpty {
                    Button {
                        store.presentCatalogWizard()
                    } label: {
                        Label("接入网络资源…", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(colors: [LumaBrand.violet.opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
            }

            if !gallerySources.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    AtlasSectionHeader("图集站点", subtitle: "点开站点也可以直接浏览")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                        ForEach(gallerySources) { source in
                            Button {
                                catalog.focus(source.id)
                                store.navigate(to: .catalogSource(source.id))
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "photo.stack")
                                        .font(.system(size: 13))
                                        .foregroundStyle(LumaBrand.violet)
                                        .frame(width: 30, height: 30)
                                        .background(LumaBrand.violet.opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(source.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Text(source.kind.title)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                AtlasSectionHeader("试试这些名字", subtitle: "点一下直接搜图集")
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(atlas.people.prefix(18)) { person in
                        Button {
                            atlas.searchText = person.name
                        } label: {
                            HStack(spacing: 5) {
                                AtlasAvatar(person: person, size: 18)
                                Text(person.name)
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: 结果

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("「\(keyword)」")
                    .font(.system(size: 13, weight: .semibold))
                Text("图集 \(currentGalleries.count) · 视频 \(currentVideos.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if isSearching && entries.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                    ForEach(0..<8, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 210)
                            .overlay { ProgressView().controlSize(.small) }
                    }
                }
            } else if entries.isEmpty {
                if let note = online.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                } else {
                    Text("这个站点下没有匹配的图集，换一个站点或关键词再试。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                    ForEach(entries) { entry in
                        AtlasOnlineCard(entry: entry,
                                        source: catalog.sources.first { $0.id == entry.sourceID },
                                        width: 150) {
                            openOnline(entry)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func runSearch() async {
        guard !keyword.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        await online.load(keyword, catalog: catalog)
    }

    private func openOnline(_ entry: AtlasOnlineEntry) {
        catalog.pendingInlineItem = entry.item
        catalog.focus(entry.sourceID)
        store.navigate(to: .catalogSource(entry.sourceID))
    }
}
