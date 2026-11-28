import SwiftUI

/// 发现：一屏把人物、分类、年代与在线资源串起来。
struct AtlasDiscoverView: View {
    @Environment(AtlasStore.self) private var atlas
    @Environment(CatalogBrowserModel.self) private var catalog
    @Environment(LibraryStore.self) private var store

    @State private var searchPeople: [AtlasPerson] = []
    @State private var searchWorks: [AtlasWork] = []

    private var online: AtlasOnlineStore { AtlasOnlineStore.shared }

    private var keyword: String {
        atlas.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !keyword.isEmpty {
                    searchResults
                } else {
                    if let person = atlas.featuredPerson {
                        hero(person)
                        onlineRail(person)
                    }
                    genreCloud
                    decadeStrip
                    personRail
                    worksRail
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .task(id: keyword) { await runSearch() }
    }

    // MARK: 搜索

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 22) {
            AtlasSectionHeader("搜索结果", subtitle: "「\(keyword)」· 人物 \(searchPeople.count) · 作品 \(searchWorks.count)")
            if searchPeople.isEmpty && searchWorks.isEmpty {
                Text("资料库里没有匹配「\(keyword)」的人物或作品。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 30)
            }
            if !searchPeople.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(searchPeople) { person in
                        personCard(person)
                    }
                }
            }
            if !searchWorks.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 14)], spacing: 16) {
                    ForEach(searchWorks) { work in
                        AtlasPosterCard(work: work) { atlas.focusedWork = $0 }
                    }
                }
            }
        }
    }

    private func runSearch() async {
        guard !keyword.isEmpty else {
            searchPeople = []
            searchWorks = []
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled, keyword == atlas.searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        async let people = atlas.searchPeople(keyword, limit: 24)
        async let works = atlas.searchWorks(keyword, limit: 36)
        let result = await (people, works)
        guard !Task.isCancelled else { return }
        searchPeople = result.0
        searchWorks = result.1
    }

    // MARK: 头图

    private func hero(_ person: AtlasPerson) -> some View {
        let color = AtlasLook.regionColor(person.region)
        return HStack(alignment: .bottom, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Text("FEATURED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(color)
                    Text("今日人物")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(person.name)
                    .font(.system(size: 38, weight: .black, design: .serif))
                    .foregroundStyle(.primary.opacity(0.94))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    fact("作品", "\(person.workCount)")
                    if let height = person.heightCM { fact("身高", "\(height)") }
                    if let cup = person.cup { fact("罩杯", cup) }
                    fact("地区", person.regionTitle)
                }
                Text(person.regionTitle + " · " + (person.nameJA ?? person.nameEN ?? "资料库人物"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        atlas.selectPerson(person.id)
                    } label: {
                        Label("打开人物档案", systemImage: "person.text.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        atlas.mode = .constellation
                        atlas.selectedPersonID = person.id
                    } label: {
                        Label("在星图定位", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 12)
            AtlasAvatar(person: person, size: 132)
                .shadow(color: color.opacity(0.35), radius: 26, y: 10)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [color.opacity(0.26), color.opacity(0.06), .clear],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [Color.primary.opacity(0.04), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: 在线联动

    private func onlineRail(_ person: AtlasPerson) -> some View {
        let matches = online.keyword == person.name
        let entries = matches ? online.videos + online.galleries : []
        return VStack(alignment: .leading, spacing: 10) {
            AtlasSectionHeader("在线联动", subtitle: "按「\(person.name)」匹配网络资源") {
                HStack(spacing: 6) {
                    if online.isLoading || !matches {
                        ProgressView().controlSize(.mini)
                    } else if online.lastUpdated != nil {
                        Label("已缓存", systemImage: "checkmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Button("刷新") {
                        Task { await online.load(person.name, catalog: catalog, force: true) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .disabled(online.isLoading)
                }
            }

            if entries.isEmpty {
                if online.isLoading || !matches {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                                    .frame(width: 152, height: 198)
                                    .overlay { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                } else if let note = online.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(entries.prefix(14)) { entry in
                            AtlasOnlineCard(entry: entry,
                                            source: catalog.sources.first { $0.id == entry.sourceID }) {
                                openOnline(entry)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task(id: person.id) {
            await online.load(person.name, catalog: catalog)
        }
    }

    // MARK: 分类星球

    private var genreCloud: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtlasSectionHeader("分类星球", subtitle: "点一颗标签，翻这一类的作品") {
                Button("全部作品") { atlas.openWorks() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            FlowLayout(spacing: 7, lineSpacing: 7) {
                ForEach(Array(atlas.genres.prefix(30).enumerated()), id: \.element.id) { index, genre in
                    genrePill(genre, index: index)
                }
            }
        }
    }

    private func genrePill(_ genre: AtlasGenre, index: Int) -> some View {
        let palette: [Color] = [LumaBrand.violet, LumaBrand.cyan, LumaBrand.mint,
                                LumaBrand.amber, LumaBrand.coral]
        let color = palette[index % palette.count]
        let size = CGFloat(max(10, min(15, 9 + log10(Double(max(genre.count, 1))) * 1.6)))
        return Button {
            atlas.openWorks(genre: genre.name)
        } label: {
            HStack(spacing: 5) {
                Text(genre.name)
                    .font(.system(size: size, weight: .medium))
                Text(AtlasLook.compact(genre.count))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(color.opacity(0.9))
            }
            .foregroundStyle(.primary.opacity(0.88))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.22), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .help("\(genre.count) 部作品")
    }

    // MARK: 年代长河

    private var decadeStrip: some View {
        let years = Array(atlas.years.prefix(30))
        let maxCount = years.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            AtlasSectionHeader("年代长河", subtitle: "柱高就是那一年的作品量") {
                Button("按年份浏览") { atlas.openWorks() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(years) { item in
                        Button {
                            atlas.openWorks(year: item.year)
                        } label: {
                            VStack(spacing: 5) {
                                Capsule()
                                    .fill(LinearGradient(colors: [LumaBrand.violet.opacity(0.9),
                                                                  LumaBrand.cyan.opacity(0.55)],
                                                         startPoint: .top, endPoint: .bottom))
                                    .frame(width: 26,
                                           height: 16 + 70 * CGFloat(item.count) / CGFloat(max(maxCount, 1)))
                                Text(String(item.year))
                                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(item.year) 年 · \(item.count) 部")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: 人物星轨

    private var personRail: some View {
        let list = filteredPeople.prefix(24)
        return VStack(alignment: .leading, spacing: 12) {
            AtlasSectionHeader("人物星轨", subtitle: "按作品数排序 \(atlas.people.count) 位") {
                Button("全部人物") { atlas.mode = .people }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(list)) { person in
                        personCard(person)
                            .frame(width: 108)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var filteredPeople: [AtlasPerson] {
        guard let region = atlas.regionFilter else { return atlas.people }
        return atlas.people.filter { $0.region == region }
    }

    private func personCard(_ person: AtlasPerson) -> some View {
        Button {
            atlas.selectPerson(person.id)
        } label: {
            VStack(spacing: 7) {
                AtlasAvatar(person: person, size: 62)
                Text(person.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Text("\(person.workCount) 部")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(person.name)
    }

    // MARK: 作品放映

    private var worksRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtlasSectionHeader("作品放映", subtitle: "资料库最新 \(atlas.workItems.count) 部") {
                Button("进入作品集") { atlas.openWorks() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 13) {
                    ForEach(atlas.workItems.prefix(14)) { work in
                        AtlasPosterCard(work: work) { atlas.focusedWork = $0 }
                            .frame(width: 132)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 打开在线条目

    private func openOnline(_ entry: AtlasOnlineEntry) {
        catalog.pendingInlineItem = entry.item
        catalog.focus(entry.sourceID)
        store.navigate(to: .catalogSource(entry.sourceID))
    }
}
