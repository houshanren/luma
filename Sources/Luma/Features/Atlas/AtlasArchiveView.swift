import AppKit
import SwiftUI

/// 人物：五个视角共用一套筛选。
/// 档案负责逐个看；胸型谱 / 身高谱 / 标签星座 / 作品量各看一个角度，结果都能点回档案并联动在线资源。
struct AtlasArchiveView: View {
    @Environment(AtlasStore.self) private var atlas
    @Environment(CatalogBrowserModel.self) private var catalog
    @Environment(LibraryStore.self) private var store

    @Environment(\.colorScheme) private var scheme

    @State private var rosterSearchTask: Task<Void, Never>?
    @State private var onlineQuery = ""
    @State private var appliedQuery = ""
    @State private var summaryExpanded = false

    /// 花名册来自 SQL 筛选结果（地区 / 罩杯 / 身高 / 标签 / 作品量 / 关键词叠加）。
    private var roster: [AtlasPerson] {
        atlas.roster
    }

    private var detail: AtlasPersonDetail? {
        guard let detail = atlas.detail, detail.person.id == atlas.selectedPersonID else { return nil }
        return detail
    }

    var body: some View {
        VStack(spacing: 0) {
            peopleBar
            if atlas.hasFigureFilters || atlas.regionFilter != nil {
                AtlasActiveFilterBar()
            }
            Divider().opacity(0.12)
            Group {
                switch atlas.peopleView {
                case .archive:
                    archivePage
                case .bust:
                    AtlasBustChartView()
                case .height:
                    AtlasHeightChartView()
                case .tags:
                    AtlasTagMapView()
                case .works:
                    AtlasWorkTierView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if atlas.roster.isEmpty { atlas.reloadRoster() }
            if atlas.cupFacets.isEmpty { atlas.reloadFacets() }
            // 人体网格解析要读 OBJ，进人物页就开始准备，别等选中才转圈。
            AtlasHumanModel.shared.prefetch()
        }
        .onChange(of: atlas.searchText) { _, _ in scheduleRosterReload() }
    }

    private func scheduleRosterReload() {
        rosterSearchTask?.cancel()
        rosterSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            atlas.reloadRoster()
        }
    }

    // MARK: 视角切换

    private var peopleBar: some View {
        HStack(spacing: 6) {
            ForEach(AtlasPeopleView.allCases) { item in
                let active = atlas.peopleView == item
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { atlas.peopleView = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(active ? Color.white : Color.primary.opacity(0.75))
                    .padding(.horizontal, 12)
                    .frame(height: 29)
                    .background {
                        if active {
                            Capsule(style: .continuous).fill(Color.accentColor)
                        } else {
                            Capsule(style: .continuous).fill(Color.primary.opacity(0.05))
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(item.subtitle)
            }
            Spacer(minLength: 8)
            personSortMenu
            if atlas.isLoadingRoster {
                ProgressView().controlSize(.mini)
            }
            Text("\(atlas.rosterTotal) 位")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var personSortMenu: some View {
        Menu {
            ForEach(AtlasPersonSort.allCases) { sort in
                Button {
                    atlas.personSort = sort
                } label: {
                    if atlas.personSort == sort {
                        Label(sort.title, systemImage: "checkmark")
                    } else {
                        Label(sort.title, systemImage: sort.symbol)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(atlas.personSort.title)
                    .font(.system(size: 10.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("花名册与分析结果的排序")
    }

    // MARK: 档案

    private var archivePage: some View {
        HStack(spacing: 0) {
            rosterColumn
                .frame(width: 240)
            Divider().opacity(0.12)
            spread
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 花名册

    private var rosterColumn: some View {
        @Bindable var atlas = atlas
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("搜索人物", text: $atlas.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(roster) { person in
                        rosterRow(person)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }

    private func rosterRow(_ person: AtlasPerson) -> some View {
        let active = person.id == atlas.selectedPersonID
        return Button {
            atlas.selectedPersonID = person.id
        } label: {
            HStack(spacing: 8) {
                AtlasAvatar(person: person, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                    Text("\(person.workCount) 部")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if active {
                    Circle()
                        .fill(AtlasLook.regionColor(person.region))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 跨页

    @ViewBuilder
    private var spread: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    hero(detail)
                    identityCard(detail)
                    onlineSection(detail)
                    HStack(alignment: .top, spacing: 26) {
                        genreFingerprint(detail)
                        coStarWall(detail)
                    }
                    labelTrail(detail)
                    contactSheet(detail)
                }
                .padding(.horizontal, 26)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.never)
        } else {
            AtlasEmptyState(title: atlas.isLoadingRoster ? "正在筛人…" : "这一组没有匹配的人",
                            message: atlas.isLoadingRoster
                                ? "尺子上的条件正在叠加，稍等片刻。"
                                : "拆掉一个条件，或者换一个视角再试。",
                            symbol: "person.text.rectangle")
        }
    }

    // MARK: 人物特稿

    private func hero(_ detail: AtlasPersonDetail) -> some View {
        let person = detail.person
        return HStack(alignment: .top, spacing: 24) {
            bodyLab(person)
                .frame(width: 330, height: 440)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        headline(detail)
                        metaLine(person)
                    }
                    Spacer(minLength: 8)
                    portraitMedallion(person)
                }
                factsRow(person)
                measurementPanel(person)
                if !person.tags.isEmpty {
                    FlowChips(items: Array(person.tags.prefix(10)))
                }
                actionRow(person)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Color.primary.opacity(0.022),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
        }
    }

    /// 3D 身材模型：优先用随包的人体网格，可拖动旋转；脚下压一行真实数值。
    private func bodyLab(_ person: AtlasPerson) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(stageGradient)
            AtlasBodyViewer(person: person, scheme: scheme)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Label("3D 身材模型", systemImage: "cube.transparent")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(stageText.opacity(0.78))
                    if person.bust == nil && person.waist == nil && person.hips == nil {
                        Text("按身高与罩杯估算")
                            .font(.system(size: 8))
                            .foregroundStyle(stageText.opacity(0.62))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(stageChip, in: Capsule())
                    }
                    Spacer()
                    Text("拖动旋转 · 双指缩放")
                        .font(.system(size: 8.5))
                        .foregroundStyle(stageText.opacity(0.45))
                }
                Spacer()
                HStack(spacing: 6) {
                    measureBadge("胸", person.bust, color: LumaBrand.coral)
                    measureBadge("腰", person.waist, color: LumaBrand.amber)
                    measureBadge("臀", person.hips, color: LumaBrand.mint)
                    Spacer(minLength: 0)
                    measureBadge("身高", person.heightCM, color: LumaBrand.cyan)
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07),
                              lineWidth: 0.8)
        }
    }

    private var stageGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.19),
                                           Color(red: 0.05, green: 0.05, blue: 0.09)],
                                  startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color(red: 0.98, green: 0.97, blue: 0.96),
                                       Color(red: 0.91, green: 0.90, blue: 0.89)],
                              startPoint: .top, endPoint: .bottom)
    }

    private var stageText: Color {
        scheme == .dark ? .white : Color(red: 0.24, green: 0.22, blue: 0.22)
    }

    private var stageChip: Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06)
    }

    private func measureBadge(_ title: String, _ value: Int?, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value.map { "\($0)" } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 7.5))
                .foregroundStyle(stageText.opacity(0.55))
        }
        .foregroundStyle(stageText.opacity(0.92))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(scheme == .dark ? 0.22 : 0.16),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 头像做成圆形徽章：外圈是地区色的渐变环，缺图时落在姓名首字的渐变底上。
    private func portraitMedallion(_ person: AtlasPerson) -> some View {
        let color = AtlasLook.regionColor(person.region)
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: [
                        color, color.opacity(0.20), color.opacity(0.85), color.opacity(0.18), color
                    ]), center: .center))
                    .frame(width: 120, height: 120)
                    .blur(radius: 1.4)
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 112, height: 112)
                AtlasAvatar(person: person, size: 104)
                    .clipShape(Circle())
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    .frame(width: 104, height: 104)
            }
            .shadow(color: color.opacity(0.35), radius: 16, y: 7)
            Text(person.hasAvatar ? "档案照片" : "暂无照片")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    /// 姓名下面的一行小字：出身地 / 血型 / 出道年 / 事务所，有哪条显示哪条。
    @ViewBuilder
    private func metaLine(_ person: AtlasPerson) -> some View {
        let items = metaItems(person)
        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(item.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func metaItems(_ person: AtlasPerson) -> [(symbol: String, title: String)] {
        var items: [(symbol: String, title: String)] = []
        if let place = person.birthplace, !place.isEmpty {
            items.append(("mappin.and.ellipse", place))
        }
        if let blood = person.bloodType, !blood.isEmpty {
            items.append(("drop", "\(blood) 型"))
        }
        if let debut = person.debutYear {
            items.append(("sparkles", "\(debut) 出道"))
        }
        if let agency = person.agency, !agency.isEmpty {
            items.append(("building.2", agency))
        }
        if let hobby = person.hobby?.trimmingCharacters(in: .whitespaces), !hobby.isEmpty {
            items.append(("heart", hobby))
        }
        return items
    }

    private func factsRow(_ person: AtlasPerson) -> some View {
        HStack(spacing: 8) {
            heroFact("作品", "\(person.workCount)")
            if let height = person.heightCM { heroFact("身高", "\(height)") }
            if let cup = person.cup { heroFact("罩杯", cup) }
            if let birth = person.birthDate, birth.count >= 4 {
                heroFact("出生", String(birth.prefix(4)))
            }
        }
    }

    private func heroFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func measurementPanel(_ person: AtlasPerson) -> some View {
        let missing = person.bust == nil && person.waist == nil && person.hips == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("三围")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                if missing {
                    Text("资料库未收录，3D 模型按身高与罩杯估算")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            measurementRow("胸", person.bust, color: LumaBrand.coral)
            measurementRow("腰", person.waist, color: LumaBrand.amber)
            measurementRow("臀", person.hips, color: LumaBrand.mint)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func actionRow(_ person: AtlasPerson) -> some View {
        HStack(spacing: 9) {
            Button {
                atlas.searchText = person.name
                atlas.mode = .galleries
            } label: {
                Label("在线图集", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)

            Button {
                atlas.mode = .constellation
            } label: {
                Label("星图定位", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 2)
    }

    private func headline(_ detail: AtlasPersonDetail) -> some View {
        let person = detail.person
        let color = AtlasLook.regionColor(person.region)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("ARCHIVE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(2.6)
                    .foregroundStyle(color)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(person.regionTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(person.name)
                .font(.system(size: 42, weight: .black, design: .serif))
                .foregroundStyle(.primary.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 10) {
                if let ja = person.nameJA, ja != person.name {
                    Text(ja).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let en = person.nameEN {
                    Text(en)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func genreFingerprint(_ detail: AtlasPersonDetail) -> some View {
        let color = AtlasLook.regionColor(detail.person.region)
        let maxCount = detail.genres.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            AtlasSectionHeader("分类指纹", subtitle: "按作品数排序的 Top \(detail.genres.count)") {
                Button("按分类翻作品") {
                    if let genre = detail.genres.first?.name {
                        atlas.openWorks(genre: genre)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.accentColor)
            }
            ForEach(detail.genres) { item in
                HStack(spacing: 9) {
                    Text(item.name)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .frame(width: 86, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.35)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(max(maxCount, 1))))
                        }
                    }
                    .frame(height: 6)
                    Text("\(item.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
    }

    /// 厂牌足迹：她作品里出现最多的发行 label。
    @ViewBuilder
    private func labelTrail(_ detail: AtlasPersonDetail) -> some View {
        if !detail.labels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                AtlasSectionHeader("厂牌足迹", subtitle: "作品最多的厂牌")
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(detail.labels) { item in
                        HStack(spacing: 5) {
                            Image(systemName: "film")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(item.name)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Text("\(item.count)")
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
            }
        }
    }

    private func coStarWall(_ detail: AtlasPersonDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AtlasSectionHeader("共演网络", subtitle: "同片出现次数")
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(detail.coStars) { star in
                    Button {
                        atlas.selectedPersonID = star.id
                    } label: {
                        HStack(spacing: 5) {
                            CatalogAvatarView(name: star.name,
                                              base64: CatalogAvatarStore.personBase64(star.id),
                                              size: 18,
                                              ringColor: AtlasLook.regionColor(detail.person.region))
                            Text(star.name)
                                .font(.system(size: 10))
                            Text("\(star.count)")
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 在线资源

    private func onlineSection(_ detail: AtlasPersonDetail) -> some View {
        let person = detail.person
        let online = AtlasOnlineStore.shared
        let matches = online.keyword == appliedQuery
        let videos = matches ? online.videos : []
        let galleries = matches ? online.galleries : []
        return VStack(alignment: .leading, spacing: 12) {
            AtlasSectionHeader("联动资源站",
                               subtitle: "在 \(catalog.enabledResourceSources.count) 个站点里搜她的作品") {
                HStack(spacing: 8) {
                    if online.isLoading || !matches {
                        ProgressView().controlSize(.mini)
                    } else if let updated = online.lastUpdated {
                        Label("已缓存 \(updated.formatted(date: .omitted, time: .shortened))",
                              systemImage: "checkmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("在资源站搜索名字 / 番号 / 片名", text: $onlineQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .onSubmit { Task { await runOnlineSearch(person) } }
                    if !onlineQuery.isEmpty {
                        Button {
                            onlineQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }

                Button("搜索") {
                    Task { await runOnlineSearch(person) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(online.isLoading)

                Button {
                    onlineQuery = person.name
                    appliedQuery = person.name
                    Task { await AtlasOnlineStore.shared.load(person.name, catalog: catalog, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("按她的名字重新抓一遍")

                Button {
                    atlas.searchText = person.name
                    atlas.mode = .galleries
                } label: {
                    Label("更多图集", systemImage: "photo.stack")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            if videos.isEmpty && galleries.isEmpty {
                if online.isLoading || !matches {
                    HStack(spacing: 10) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                                .frame(width: 124, height: 160)
                                .overlay { ProgressView().controlSize(.small) }
                        }
                    }
                } else if catalog.enabledResourceSources.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text("还没有启用的网络资源站点。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Button("去接入…") { store.presentCatalogWizard() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                } else if let note = online.note {
                    HStack(spacing: 8) {
                        Image(systemName: "safari")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if !videos.isEmpty {
                        onlineRail(title: "视频 \(videos.count)", entries: videos)
                    }
                    if !galleries.isEmpty {
                        onlineRail(title: "图集 \(galleries.count)", entries: galleries)
                    }
                }
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.022),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
        }
        .task(id: person.id) {
            onlineQuery = person.name
            appliedQuery = person.name
            await AtlasOnlineStore.shared.load(person.name, catalog: catalog)
        }
    }

    private func runOnlineSearch(_ person: AtlasPerson) async {
        let text = onlineQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = text.isEmpty ? person.name : text
        appliedQuery = query
        await AtlasOnlineStore.shared.load(query, catalog: catalog, force: true)
    }

    private func onlineRail(title: String, entries: [AtlasOnlineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 11) {
                    ForEach(entries.prefix(12)) { entry in
                        AtlasOnlineCard(entry: entry,
                                        source: catalog.sources.first { $0.id == entry.sourceID },
                                        width: 124) {
                            openOnline(entry)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func openOnline(_ entry: AtlasOnlineEntry) {
        catalog.pendingInlineItem = entry.item
        catalog.focus(entry.sourceID)
        store.navigate(to: .catalogSource(entry.sourceID))
    }

    // MARK: 接触印样

    private func contactSheet(_ detail: AtlasPersonDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AtlasSectionHeader("接触印样", subtitle: "最近 \(detail.works.count) 部") {
                Button("查看全部作品") { atlas.openWorks() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.accentColor)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 12) {
                ForEach(detail.works.prefix(20)) { work in
                    Button {
                        // 不弹窗：直接去作品集里按番号翻这一部。
                        atlas.searchText = work.dvdID
                        atlas.mode = .works
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            AtlasRemoteImage(urlString: work.thumbURL ?? work.coverURL, seed: Int(work.id))
                                .frame(height: 146)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                                }
                            HStack(spacing: 4) {
                                Text(work.dvdID)
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(String(AtlasLook.shortDate(work.releaseDate).prefix(7)))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 零件

    /// 三围小尺子：60–110cm 映射成条宽，没数据就留一条灰底 + 破折号。
    private func measurementRow(_ title: String, _ value: Int?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(color.opacity(0.8))
                        .frame(width: value.map {
                            geo.size.width * CGFloat(min(max($0, 60), 110) - 60) / 50
                        } ?? 4)
                }
            }
            .frame(height: 5)
            Text(value.map { "\($0)" } ?? "—")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    // MARK: 数字名片

    /// 抖音 / 微博 / Instagram…以及别名、简介：资料库里有哪条就摆哪条。
    @ViewBuilder
    private func identityCard(_ detail: AtlasPersonDetail) -> some View {
        let person = detail.person
        let links = detail.links
        let official = person.officialSite?.trimmingCharacters(in: .whitespaces) ?? ""
        let aliases = person.aliases
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let summary = (person.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !links.isEmpty || !official.isEmpty || !aliases.isEmpty || !summary.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !links.isEmpty || !official.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        AtlasSectionHeader("数字名片", subtitle: "有公开账号才显示 · 点开直达，右键复制")
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(links) { link in
                                contactChip(title: link.title, symbol: link.symbol,
                                            handle: link.displayHandle,
                                            tint: socialColor(link.kind), url: link.url,
                                            copyText: link.handle)
                            }
                            if !official.isEmpty, let url = AtlasDatabase.webURL(official) {
                                contactChip(title: "个人主页", symbol: "globe",
                                            handle: official.replacingOccurrences(of: "https://", with: "")
                                                .replacingOccurrences(of: "http://", with: "")
                                                .split(separator: "/").first.map(String.init),
                                            tint: Color.accentColor, url: url, copyText: official)
                            }
                        }
                    }
                }
                if !aliases.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        AtlasSectionHeader("别名 / 曾用名", subtitle: "\(aliases.count) 个")
                        FlowChips(items: Array(aliases.prefix(12)))
                    }
                }
                if !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        AtlasSectionHeader("档案摘录", subtitle: "资料库简介")
                        HStack(alignment: .top, spacing: 8) {
                            Text("“")
                                .font(.system(size: 22, weight: .black, design: .serif))
                                .foregroundStyle(Color.accentColor.opacity(0.35))
                                .offset(y: -2)
                            Text(summary)
                                .font(.system(size: 11.5))
                                .lineSpacing(3.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(summaryExpanded ? nil : 4)
                                .textSelection(.enabled)
                        }
                        if summary.count > 80 {
                            Button(summaryExpanded ? "收起" : "展开全文") {
                                withAnimation(.easeOut(duration: 0.16)) { summaryExpanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .padding(18)
            .background(Color.primary.opacity(0.022),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
            }
            .onChange(of: person.id) { _, _ in summaryExpanded = false }
        }
    }

    private func contactChip(title: String, symbol: String, handle: String?,
                             tint: Color, url: URL?, copyText: String?) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                if let handle, !handle.isEmpty {
                    Text(handle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay { Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.8) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(url?.absoluteString ?? title)
        .contextMenu {
            if let copyText, !copyText.isEmpty {
                Button("复制账号") { copyToPasteboard(copyText) }
            }
            if let url {
                Button("在浏览器打开") { NSWorkspace.shared.open(url) }
                Button("复制链接") { copyToPasteboard(url.absoluteString) }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func socialColor(_ kind: String) -> Color {
        switch kind {
        case "douyin": return Color.primary.opacity(0.82)
        case "weibo": return Color(red: 0.92, green: 0.30, blue: 0.20)
        case "instagram": return Color(red: 0.76, green: 0.26, blue: 0.55)
        case "twitter", "x": return Color.primary.opacity(0.82)
        case "bilibili": return Color(red: 0.95, green: 0.42, blue: 0.60)
        case "xiaohongshu": return Color(red: 0.92, green: 0.20, blue: 0.26)
        case "youtube": return Color(red: 0.88, green: 0.16, blue: 0.16)
        default: return Color.accentColor
        }
    }
}
