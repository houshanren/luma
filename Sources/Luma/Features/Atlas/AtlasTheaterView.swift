import SwiftUI

/// 影院：大银幕试看 + 节目单；资料库没有的片子，直接去在线资源里找。
struct AtlasTheaterView: View {
    @Environment(AtlasStore.self) private var atlas
    @Environment(CatalogBrowserModel.self) private var catalog
    @Environment(LibraryStore.self) private var store

    @State private var hour = Calendar.current.component(.hour, from: Date())
    @State private var index = 0
    @State private var genre: String?

    @State private var onlineVideos: [AtlasOnlineEntry] = []
    @State private var isLoadingOnline = false

    private var online: AtlasOnlineStore { AtlasOnlineStore.shared }

    private var queue: [AtlasWork] { atlas.theaterQueue(hour: hour) }

    private var current: AtlasWork? {
        guard !queue.isEmpty else { return nil }
        return queue[min(index, queue.count - 1)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                scheduleStrip

                if let work = current {
                    HStack(alignment: .top, spacing: 18) {
                        stage(work)
                            .frame(maxWidth: .infinity)
                        onlinePanel(work)
                            .frame(width: 306)
                    }
                    playlistRail
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .frame(height: 360)
                        .overlay {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在编排今晚的档期…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                }

                genreChannels
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.never)
        .onAppear { atlas.loadTheaterPool() }
        .onChange(of: hour) { _, _ in index = 0 }
        .task(id: current?.dvdID) { await loadOnline() }
    }

    // MARK: 档期

    private var scheduleStrip: some View {
        let now = Calendar.current.component(.hour, from: Date())
        let slots = (0..<6).map { (hour + $0) % 24 }
        return HStack(spacing: 8) {
            Text("今日档期")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            ForEach(slots, id: \.self) { slot in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { hour = slot }
                } label: {
                    VStack(spacing: 1) {
                        Text(String(format: "%02d:00", slot))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text(slot == now ? "现在" : "第 \((slot + 1) % 24) 档")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(hour == slot ? Color.white : Color.primary.opacity(0.72))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background {
                        if hour == slot {
                            Capsule().fill(Color.accentColor)
                        } else {
                            Capsule().fill(Color.primary.opacity(0.05))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if let current {
                Label("正在放映 · \(current.dvdID)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 大银幕

    private func stage(_ work: AtlasWork) -> some View {
        ZStack(alignment: .bottomLeading) {
            AtlasRemoteImage(urlString: work.coverURL ?? work.thumbURL, seed: Int(work.id))
                .frame(height: 388)
                .blur(radius: 34)
                .overlay(Color.black.opacity(0.46))

            HStack(alignment: .bottom, spacing: 24) {
                AtlasRemoteImage(urlString: work.coverURL ?? work.thumbURL, seed: Int(work.id))
                    .frame(width: 182, height: 258)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.46), radius: 26, y: 14)

                VStack(alignment: .leading, spacing: 10) {
                    Text("NOW SHOWING")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(2.6)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(work.title)
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(work.dvdID)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.white.opacity(0.14), in: Capsule())
                        if let date = work.releaseDate {
                            Text(AtlasLook.shortDate(date))
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.8))

                    if !work.genres.isEmpty {
                        Text(work.genres.prefix(5).joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    HStack(spacing: 9) {
                        Button {
                            atlas.focusedWork = work
                        } label: {
                            Label(work.trailerURL == nil ? "查看详情" : "播放试看", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            withAnimation(.easeOut(duration: 0.22)) {
                                index = (index + 1) % max(queue.count, 1)
                            }
                        } label: {
                            Label("下一部", systemImage: "forward.end.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.7))

                        Button {
                            atlas.searchText = work.dvdID
                            atlas.mode = .galleries
                        } label: {
                            Label("找图集", systemImage: "photo.stack")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.7))
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: 430, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(height: 388)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
        }
    }

    // MARK: 在线放映

    private func onlinePanel(_ work: AtlasWork) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label("在线放映", systemImage: "safari")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if isLoadingOnline {
                    ProgressView().controlSize(.mini)
                } else if !onlineVideos.isEmpty {
                    Text("\(onlineVideos.count) 条")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 8)

            if isLoadingOnline && onlineVideos.isEmpty {
                VStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 56)
                    }
                }
            } else if onlineVideos.isEmpty {
                Text("网络资源里没有找到 \(work.dvdID)。可以去「图集」搜同名人物的写真，或先在「网络资源」里接入站点。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(onlineVideos.prefix(8)) { entry in
                            onlineRow(entry)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 388, alignment: .top)
        .atlasGlass(radius: 16, padding: 12)
    }

    private func onlineRow(_ entry: AtlasOnlineEntry) -> some View {
        Button {
            openOnline(entry)
        } label: {
            HStack(spacing: 9) {
                if let source = catalog.sources.first(where: { $0.id == entry.sourceID }) {
                    CatalogArtworkImage(source: source, urlString: entry.item.coverURL,
                                        cornerRadius: 6, quality: .thumbnail)
                        .frame(width: 42, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 42, height: 58)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.title)
                        .font(.system(size: 10))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(entry.sourceName)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                        if let code = entry.code {
                            Text(code)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 节目单

    private var playlistRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            AtlasSectionHeader("节目单", subtitle: String(format: "%02d:00 档 · %d 部", hour, queue.count)) {
                if queue.count > 1 {
                    Button("换一档") {
                        withAnimation(.easeOut(duration: 0.22)) {
                            index = (index + 1) % max(queue.count, 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 13) {
                    ForEach(Array(queue.prefix(12).enumerated()), id: \.offset) { offset, work in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { index = offset }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                AtlasRemoteImage(urlString: work.thumbURL ?? work.coverURL, seed: Int(work.id))
                                    .frame(width: 112, height: 158)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(offset == index
                                                          ? Color.accentColor.opacity(0.9)
                                                          : Color.white.opacity(0.08),
                                                          lineWidth: offset == index ? 1.6 : 0.6)
                                    }
                                Text(String(format: "%02d:%02d", (hour + offset) % 24, (offset * 25) % 60))
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(offset == index ? Color.accentColor : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 分类频道

    private var genreChannels: some View {
        VStack(alignment: .leading, spacing: 10) {
            AtlasSectionHeader("分类频道", subtitle: "点一个分类，换一条片带") {
                if genre != nil {
                    Button("收起") {
                        withAnimation(.easeOut(duration: 0.18)) { self.genre = nil }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(atlas.genres.prefix(18)) { item in
                        Button {
                            let next: String? = genre == item.name ? nil : item.name
                            withAnimation(.easeOut(duration: 0.18)) { genre = next }
                            if let next { atlas.loadWorksIfNeeded(genre: next) }
                        } label: {
                            HStack(spacing: 5) {
                                Text(item.name)
                                    .font(.system(size: 10.5, weight: .medium))
                                Text("\(item.count)")
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(genre == item.name ? Color.white : Color.primary.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background {
                                Capsule().fill(genre == item.name ? Color.accentColor : Color.primary.opacity(0.055))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if let genre {
                let works = atlas.works(forGenre: genre)
                if works.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在调取「\(genre)」…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 26)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 13) {
                            ForEach(works) { work in
                                AtlasPosterCard(work: work) { atlas.focusedWork = $0 }
                                    .frame(width: 122)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: 数据

    private func loadOnline() async {
        guard let code = current?.dvdID else {
            onlineVideos = []
            return
        }
        isLoadingOnline = true
        await online.load(code, catalog: catalog)
        onlineVideos = online.videos
        isLoadingOnline = false
    }

    private func openOnline(_ entry: AtlasOnlineEntry) {
        catalog.pendingInlineItem = entry.item
        catalog.focus(entry.sourceID)
        store.navigate(to: .catalogSource(entry.sourceID))
    }
}
