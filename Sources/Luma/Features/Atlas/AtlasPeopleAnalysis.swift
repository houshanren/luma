import SwiftUI

// MARK: - 人物页的五个视角

/// 人物页内部再分视角：档案负责逐个看，其余四个各看一个角度。
enum AtlasPeopleView: String, CaseIterable, Identifiable {
    case archive
    case bust
    case height
    case tags
    case works

    var id: String { rawValue }

    var title: String {
        switch self {
        case .archive: return "档案"
        case .bust: return "胸型谱"
        case .height: return "身高谱"
        case .tags: return "标签星座"
        case .works: return "作品量"
        }
    }

    var symbol: String {
        switch self {
        case .archive: return "person.text.rectangle"
        case .bust: return "leaf"
        case .height: return "figure.stand"
        case .tags: return "tag"
        case .works: return "star.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .archive: return "杂志式档案，一键关联在线资源"
        case .bust: return "把罩杯按胸型拟人成一枚果子"
        case .height: return "从 145 到 185，站成一排"
        case .tags: return "按身材、长相、气质分成四片星区"
        case .works: return "作品数分五档，看常青与新人"
        }
    }
}

// MARK: - 当前筛选

/// 顶部的一条胶囊：把已生效的地区 / 罩杯 / 身高 / 标签 / 作品量摊开，随时拆掉。
struct AtlasActiveFilterBar: View {
    @Environment(AtlasStore.self) private var atlas

    var body: some View {
        HStack(spacing: 8) {
            Text("当前筛选")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            if let region = atlas.regionFilter {
                chip(regionTitle(region)) { atlas.regionFilter = nil }
            }
            if let cup = atlas.cupFilter {
                chip("\(cup) 杯") { atlas.cupFilter = nil }
            }
            if let band = atlas.heightBandFilter {
                chip("\(band)–\(band + 4) cm") { atlas.heightBandFilter = nil }
            }
            if let tag = atlas.tagFilter {
                chip("「\(tag)」") { atlas.tagFilter = nil }
            }
            if let tier = atlas.workTierFilter {
                chip(tier == 0 ? "作品 < 50" : "作品 \(tier)+") { atlas.workTierFilter = nil }
            }

            Button("全部清除") {
                atlas.resetFigureFilters()
                atlas.regionFilter = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.accentColor)

            Spacer(minLength: 8)

            if atlas.isLoadingRoster {
                ProgressView().controlSize(.mini)
            }
            Text("\(atlas.rosterTotal) 位")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025))
    }

    private func chip(_ title: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
    }

    private func regionTitle(_ region: String) -> String {
        switch region {
        case "china": return "大陆"
        case "taiwan": return "台湾"
        case "hongkong": return "香港"
        case "korea": return "韩国"
        case "western": return "欧美"
        default: return "日本"
        }
    }
}

// MARK: - 分页头

private struct AtlasAnalysisHeader: View {
    let title: String
    let english: String
    let subtitle: String
    let symbol: String
    var usesFigure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if usesFigure {
                    ZStack {
                        AtlasHairShape().fill(Color.accentColor.opacity(0.45))
                        AtlasFemaleFigureShape(bust: 0.3).fill(Color.accentColor)
                    }
                    .frame(width: 13, height: 30)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(title)
                    .font(.system(size: 26, weight: .black, design: .serif))
                Text(english)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(.tertiary)
            }
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

// MARK: - 结果区（各视角共用）

/// 选中一个角度之后，下面统一铺这批人的卡片；点人进档案，↗ 直接去网络资源。
struct AtlasAnalysisResults: View {
    let title: String
    let detail: String

    @Environment(AtlasStore.self) private var atlas

    private var people: [AtlasPerson] { Array(atlas.roster.prefix(24)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .serif))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(atlas.roster.count < atlas.rosterTotal
                     ? "共 \(atlas.rosterTotal) 位 · 显示前 \(atlas.roster.count)"
                     : "共 \(atlas.rosterTotal) 位")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button("在档案中打开") {
                    withAnimation(.easeOut(duration: 0.16)) { atlas.peopleView = .archive }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }

            if atlas.isLoadingRoster && people.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在筛人…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 26)
            } else if people.isEmpty {
                Text("这一组暂时没有人。拆掉一个条件再试。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 26)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 212), spacing: 12)], spacing: 12) {
                    ForEach(people) { person in
                        AtlasAnalysisPersonCard(person: person)
                    }
                }
            }
        }
    }
}

/// 分析页里的人物卡：头像 + 关键事实 + 一个去网络资源的入口。
struct AtlasAnalysisPersonCard: View {
    let person: AtlasPerson

    @Environment(AtlasStore.self) private var atlas
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AtlasAvatar(person: person, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(person.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let cup = person.cup {
                        tag("\(cup) 杯", tint: AtlasCupPalette.tint(cup))
                    }
                    if let height = person.heightCM {
                        tag("\(height)cm", tint: LumaBrand.cyan)
                    }
                }
                Text("\(person.workCount) 部作品")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Button {
                atlas.searchText = person.name
                atlas.mode = .galleries
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .help("在网络资源里找「\(person.name)」")
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.18 : 0.05), lineWidth: 0.6)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            atlas.selectedPersonID = person.id
            atlas.peopleView = .archive
        }
        .help(person.name)
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - 胸型谱

/// 罩杯的拟人化：每一杯画成一对胸型，配一个果子的名字。
struct AtlasBustChartView: View {
    @Environment(AtlasStore.self) private var atlas

    private var cups: [AtlasCupFacet] { atlas.cupFacets }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AtlasAnalysisHeader(
                    title: "胸型谱",
                    english: "BUST ATLAS",
                    subtitle: "把罩杯按胸型拟人成一位女性：从初樱到山峦，胸型随杯递增。点一位只看这一类的人；卡片右侧的 ↗ 直接去网络资源找她的图集。",
                    symbol: "leaf")

                if cups.isEmpty {
                    Text(atlas.isLoadingRoster ? "正在读罩杯分布…" : "这份资料库没有罩杯数据。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(cups) { facet in
                            AtlasBustCupCard(facet: facet,
                                             index: AtlasCupPalette.order.firstIndex(of: facet.cup) ?? 0,
                                             active: atlas.cupFilter == facet.cup,
                                             tint: AtlasCupPalette.tint(facet.cup)) {
                                atlas.toggleCup(facet.cup)
                            }
                        }
                    }
                }

                AtlasAnalysisResults(
                    title: atlas.cupFilter.map { "\($0) 杯 · \(AtlasCupPalette.poetic($0))" } ?? "全部人物",
                    detail: atlas.cupFilter == nil ? "点上面的任一胸型，锁定那一杯" : "再点一次同一枚可以取消")
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
    }
}

private struct AtlasBustCupCard: View {
    let facet: AtlasCupFacet
    let index: Int
    let active: Bool
    let tint: Color
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                AtlasBustGlyph(index: index, tint: tint)
                    .frame(width: 46, height: 120)
                Text(facet.cup)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(active ? tint : Color.primary.opacity(0.85))
                Text(AtlasCupPalette.poetic(facet.cup))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(info(for: facet))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(active ? tint.opacity(0.14) : Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.85) : Color.white.opacity(0.06),
                                  lineWidth: active ? 1.4 : 0.6)
            }
        }
        .buttonStyle(.plain)
        .help("\(facet.cup) 杯 · \(facet.count) 位 · \(AtlasCupPalette.poetic(facet.cup))")
    }

    private func info(for facet: AtlasCupFacet) -> String {
        if let average = facet.averageBust {
            return "\(AtlasLook.compact(facet.count)) 位 · 均 \(average)cm"
        }
        return "\(AtlasLook.compact(facet.count)) 位"
    }
}

/// 胸型的拟人剪影：全身女性身形，胸部随罩杯变大、外扩、下沉。
struct AtlasBustGlyph: View {
    let index: Int
    let tint: Color

    private var bust: CGFloat {
        CGFloat(min(max(index, 0), 14)) / 14
    }

    var body: some View {
        ZStack {
            AtlasHairShape()
                .fill(tint.opacity(0.42))
            AtlasFemaleFigureShape(bust: bust)
                .fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.22)],
                                     startPoint: .top, endPoint: .bottom))
            Canvas { context, size in
                let centerY = size.height * 0.360
                let spread = size.width * (0.048 + 0.070 * bust)
                let rx = size.width * (0.042 + 0.115 * bust)
                let ry = size.height * (0.022 + 0.040 * bust)
                for sign in [-1.0, 1.0] {
                    let centerX = size.width / 2 + CGFloat(sign) * spread
                    let ellipse = CGRect(x: centerX - rx, y: centerY - ry,
                                         width: rx * 2, height: ry * 2)
                    context.fill(Path(ellipseIn: ellipse), with: .color(tint.opacity(0.95)))
                }
                if bust > 0.10 {
                    var gap = Path()
                    gap.move(to: CGPoint(x: size.width / 2, y: centerY - ry * 0.8))
                    gap.addLine(to: CGPoint(x: size.width / 2, y: centerY + ry * 0.8))
                    context.stroke(gap, with: .color(tint.opacity(0.42)),
                                   lineWidth: max(0.7, size.width * 0.011))
                }
            }
        }
    }
}

/// 头发：包住头两侧、落到肩上，让剪影一眼是女性。
struct AtlasHairShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.minX + 0.335 * w, y: rect.minY + 0.010 * h,
                                       width: 0.33 * w, height: 0.185 * h),
                            cornerSize: CGSize(width: 0.13 * w, height: 0.07 * h))
        return path
    }
}

/// 全身女性剪影：头、颈、肩、手臂、收腰、宽胯、双腿；`bust` 让胸廓随罩杯外扩。
struct AtlasFemaleFigureShape: Shape {
    var bust: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let b = min(max(bust, 0), 1)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }

        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + 0.39 * w, y: rect.minY + 0.012 * h,
                                   width: 0.22 * w, height: 0.122 * h))
        path.move(to: p(0.45, 0.134))
        path.addLine(to: p(0.45, 0.180))
        path.addQuadCurve(to: p(0.27, 0.210), control: p(0.37, 0.180))
        path.addQuadCurve(to: p(0.15, 0.400), control: p(0.17, 0.280))
        path.addLine(to: p(0.14, 0.640))
        path.addQuadCurve(to: p(0.20, 0.664), control: p(0.145, 0.664))
        path.addQuadCurve(to: p(0.26, 0.640), control: p(0.25, 0.664))
        path.addQuadCurve(to: p(0.27, 0.307), control: p(0.30, 0.450))
        path.addQuadCurve(to: p(0.23 - 0.03 * b, 0.360), control: p(0.225, 0.325))
        path.addQuadCurve(to: p(0.30 - 0.015 * b, 0.421), control: p(0.245, 0.398))
        path.addQuadCurve(to: p(0.36, 0.464), control: p(0.34, 0.455))
        path.addQuadCurve(to: p(0.25, 0.550), control: p(0.31, 0.500))
        path.addQuadCurve(to: p(0.29, 0.757), control: p(0.26, 0.650))
        path.addLine(to: p(0.37, 0.936))
        path.addLine(to: p(0.35, 0.971))
        path.addLine(to: p(0.45, 0.971))
        path.addLine(to: p(0.46, 0.593))
        path.addQuadCurve(to: p(0.54, 0.593), control: p(0.50, 0.575))
        path.addLine(to: p(0.55, 0.971))
        path.addLine(to: p(0.65, 0.971))
        path.addLine(to: p(0.63, 0.936))
        path.addLine(to: p(0.71, 0.757))
        path.addQuadCurve(to: p(0.75, 0.550), control: p(0.74, 0.650))
        path.addQuadCurve(to: p(0.64, 0.464), control: p(0.69, 0.500))
        path.addQuadCurve(to: p(0.70 + 0.015 * b, 0.421), control: p(0.66, 0.455))
        path.addQuadCurve(to: p(0.77 + 0.03 * b, 0.360), control: p(0.755, 0.398))
        path.addQuadCurve(to: p(0.73, 0.307), control: p(0.775, 0.325))
        path.addQuadCurve(to: p(0.74, 0.640), control: p(0.70, 0.450))
        path.addQuadCurve(to: p(0.80, 0.664), control: p(0.75, 0.664))
        path.addQuadCurve(to: p(0.86, 0.640), control: p(0.855, 0.664))
        path.addLine(to: p(0.85, 0.400))
        path.addQuadCurve(to: p(0.73, 0.210), control: p(0.83, 0.280))
        path.addLine(to: p(0.55, 0.180))
        path.addLine(to: p(0.55, 0.134))
        path.closeSubpath()
        return path
    }
}

/// 罩杯的配色与拟人名字。
enum AtlasCupPalette {
    static let order = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"]
    private static let names = ["初樱", "青杏", "蜜桃", "圆月", "满月", "蜜瓜", "双柚",
                                "丰盈", "沉甸", "盈掌", "满溢", "巨澜", "山峦", "传世", "奇观", "异闻"]

    static func poetic(_ cup: String) -> String {
        guard let index = order.firstIndex(of: cup.uppercased()) else { return "未知" }
        return names[min(index, names.count - 1)]
    }

    static func tint(_ cup: String) -> Color {
        switch cup.uppercased() {
        case "A", "B", "C": return LumaBrand.mint
        case "D", "E": return LumaBrand.cyan
        case "F", "G": return LumaBrand.violet
        case "H", "I", "J", "K", "L", "M", "N", "O": return LumaBrand.coral
        default: return Color.secondary.opacity(0.6)
        }
    }
}

// MARK: - 身高谱

/// 身高拟人：一排小人站在同一条地平线上，越高的人形越大。
struct AtlasHeightChartView: View {
    @Environment(AtlasStore.self) private var atlas

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AtlasAnalysisHeader(
                    title: "身高谱",
                    english: "HEIGHT ROW",
                    subtitle: "每 5cm 一位女性剪影，个子越高身形越大。点一格只看这一段；卡片右侧的 ↗ 直接去网络资源找她的图集。",
                    symbol: "figure.stand",
                    usesFigure: true)

                if atlas.heightBands.isEmpty {
                    Text(atlas.isLoadingRoster ? "正在读身高分布…" : "这份资料库没有身高数据。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: 10) {
                            ForEach(atlas.heightBands) { band in
                                HeightFigure(band: band,
                                             active: atlas.heightBandFilter == band.start) {
                                    atlas.toggleHeightBand(band.start)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                AtlasAnalysisResults(
                    title: atlas.heightBandFilter.map { "\($0)–\($0 + 4) cm" } ?? "全部身高",
                    detail: atlas.heightBandFilter == nil ? "点一个小人，锁定那一段身高" : "再点一次同一格可以取消")
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
    }
}

private struct HeightFigure: View {
    let band: AtlasHeightBand
    let active: Bool
    var onTap: () -> Void

    private var figureHeight: CGFloat {
        42 + CGFloat(band.start - 145)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(AtlasLook.compact(band.count))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                ZStack {
                    AtlasHairShape()
                        .fill(active ? Color.accentColor.opacity(0.55) : LumaBrand.violet.opacity(0.30))
                    AtlasFemaleFigureShape(bust: 0.3)
                        .fill(active
                              ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(LinearGradient(colors: [LumaBrand.cyan.opacity(0.8),
                                                                      LumaBrand.violet.opacity(0.45)],
                                                             startPoint: .top, endPoint: .bottom)))
                }
                .frame(width: figureHeight * 0.38, height: figureHeight)
                .frame(height: 84, alignment: .bottom)
                Rectangle()
                    .fill(Color.primary.opacity(active ? 0.55 : 0.12))
                    .frame(height: 1)
                Text("\(band.start)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.8))
                Text("– \(band.start + 4) · \(band.count) 位")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(band.label) cm · \(band.count) 位")
    }
}

// MARK: - 标签星座

/// 标签按身材 / 长相 / 气质 / 风格分成四片星区，字号就是人数。
struct AtlasTagMapView: View {
    @Environment(AtlasStore.self) private var atlas
    @State private var sortByCount = true

    private func tags(in group: AtlasTagGroup) -> [AtlasTagFacet] {
        let tags = atlas.tagFacets.filter { AtlasTagGroup.group(for: $0.tag) == group }
        return sortByCount ? tags : tags.sorted { $0.tag < $1.tag }
    }

    private var related: [AtlasTagFacet] {
        guard let tag = atlas.tagFilter else { return [] }
        var counts: [String: Int] = [:]
        for person in atlas.roster.prefix(400) {
            for item in person.tags where item != tag {
                counts[item, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(8)
            .map { AtlasTagFacet(tag: $0.key, count: $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AtlasAnalysisHeader(
                    title: "标签星座",
                    english: "TAG CONSTELLATIONS",
                    subtitle: "身材、长相、气质、风格四片星区；每个标签都画成一个人，字越大带这个标签的人越多。选中一个标签后，会顺着共现关系给出「常一起出现」。",
                    symbol: "tag")

                HStack(spacing: 4) {
                    ForEach([true, false], id: \.self) { byCount in
                        Button {
                            sortByCount = byCount
                        } label: {
                            Text(byCount ? "按人数" : "按名称")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(sortByCount == byCount ? Color.white : Color.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 21)
                                .background {
                                    if sortByCount == byCount {
                                        Capsule(style: .continuous).fill(Color.accentColor)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)

                if atlas.tagFacets.isEmpty {
                    Text(atlas.isLoadingRoster ? "正在读标签…" : "这份资料库还没有标签。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 14) {
                        ForEach(AtlasTagGroup.allCases) { group in
                            groupCard(group, tags: tags(in: group))
                        }
                    }
                }

                if !related.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("常一起出现")
                            .font(.system(size: 14, weight: .bold, design: .serif))
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(related) { facet in
                                Button {
                                    atlas.tagFilter = facet.tag
                                } label: {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(AtlasTagGroup.group(for: facet.tag).color)
                                            .frame(width: 5, height: 5)
                                        Text(facet.tag)
                                            .font(.system(size: 11.5))
                                        Text(AtlasLook.compact(facet.count))
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help("换成「\(facet.tag)」")
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                AtlasAnalysisResults(
                    title: atlas.tagFilter.map { "「\($0)」" } ?? "全部人物",
                    detail: atlas.tagFilter == nil ? "点一个标签，只留带它的人" : "再点一次同一个标签可以取消")
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
    }

    private func groupCard(_ group: AtlasTagGroup, tags: [AtlasTagFacet]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    AtlasHairShape().fill(group.color.opacity(0.45))
                    AtlasFemaleFigureShape(bust: 0.3).fill(group.color)
                }
                .frame(width: 14, height: 34)
                Text(group.title)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                Text(group.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("\(tags.count) 个")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if tags.isEmpty {
                Text("这一区暂时没有标签")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                    ForEach(tags) { facet in
                        tagTile(facet, group: group)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(group.color.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(group.color.opacity(0.12), lineWidth: 0.6)
        }
    }

    /// 每个标签都画一个人：身材类画身形、长相类画头像、气质类画姿态、风格类带道具。
    private func tagTile(_ facet: AtlasTagFacet, group: AtlasTagGroup) -> some View {
        let active = atlas.tagFilter == facet.tag
        return Button {
            atlas.toggleTag(facet.tag)
        } label: {
            VStack(spacing: 3) {
                AtlasTagGlyph(motif: AtlasTagMotif.motif(for: facet.tag), color: group.color)
                    .frame(width: 42, height: 66)
                Text(facet.tag)
                    .font(.system(size: tileFontSize(facet.count), weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(AtlasLook.compact(facet.count)) 位")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active ? group.color.opacity(0.16) : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? group.color.opacity(0.85) : group.color.opacity(0.10),
                                  lineWidth: active ? 1.4 : 0.6)
            }
        }
        .buttonStyle(.plain)
        .help("\(facet.count) 位带这个标签")
    }

    private func tileFontSize(_ count: Int) -> CGFloat {
        CGFloat(max(11.5, min(16, 11 + log10(Double(max(count, 1))) * 2.2)))
    }
}

// MARK: 标签拟人

/// 一个标签画成什么样：身材类画身形、长相类画头像、气质类画姿态、风格类带道具。
enum AtlasTagMotif {
    case bust(CGFloat)
    case hip
    case petite
    case faceEyes
    case faceRound
    case facePure
    case sexy
    case mature
    case gentle
    case style
    case generic

    static func motif(for tag: String) -> AtlasTagMotif {
        if tag.contains("極上巨乳") || tag.contains("巨乳") { return .bust(1.0) }
        if tag.contains("大乳房") { return .bust(0.9) }
        if tag.contains("美乳") || tag.contains("乳") || tag.contains("胸") { return .bust(0.78) }
        if tag.contains("臀") { return .hip }
        if tag.contains("嬌小") || tag.contains("矮小") { return .petite }
        if tag.contains("大眼睛") { return .faceEyes }
        if tag.contains("娃娃臉") || tag.contains("可愛") || tag.contains("萌")
            || tag.contains("美少女") { return .faceRound }
        if tag.contains("清純") || tag.contains("天然") || tag.contains("美人")
            || tag.contains("網紅臉") { return .facePure }
        if tag.contains("性感") || tag.contains("嫵媚") || tag.contains("女人味") { return .sexy }
        if tag.contains("成熟") || tag.contains("御姐") { return .mature }
        if tag.contains("溫柔") { return .gentle }
        if tag.contains("寫真") || tag.contains("模特") || tag.contains("Cos")
            || tag.contains("網紅") || tag.contains("博主") || tag.contains("演員")
            || tag.contains("主播") { return .style }
        return .generic
    }
}

/// 标签旁的小人：直接画出这个标签在讲什么。
struct AtlasTagGlyph: View {
    let motif: AtlasTagMotif
    let color: Color

    var body: some View {
        if isPortrait {
            AtlasTagPortrait(motif: motif, color: color)
        } else {
            figure
        }
    }

    private var isPortrait: Bool {
        switch motif {
        case .faceEyes, .faceRound, .facePure: return true
        default: return false
        }
    }

    private var bustValue: CGFloat {
        switch motif {
        case .bust(let level): return level
        case .sexy: return 0.66
        case .mature: return 0.55
        case .hip: return 0.40
        default: return 0.32
        }
    }

    private var figureScale: CGFloat {
        switch motif {
        case .petite: return 0.72
        case .mature: return 1.0
        default: return 0.92
        }
    }

    private var figure: some View {
        ZStack(alignment: .bottom) {
            if case .gentle = motif {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                    .offset(y: -36)
            }
            ZStack(alignment: .bottom) {
                AtlasHairShape().fill(color.opacity(0.42))
                AtlasFemaleFigureShape(bust: bustValue)
                    .fill(LinearGradient(colors: [color.opacity(0.68), color.opacity(0.26)],
                                         startPoint: .top, endPoint: .bottom))
                if case .hip = motif {
                    Ellipse()
                        .fill(color.opacity(0.45))
                        .frame(width: 30, height: 12)
                        .offset(y: -20)
                }
                if case .sexy = motif {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                        .offset(x: 15, y: -50)
                }
                if case .style = motif {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .offset(x: 15, y: -34)
                }
                if case .mature = motif {
                    Circle()
                        .fill(color.opacity(0.55))
                        .frame(width: 7, height: 7)
                        .offset(y: -58)
                }
            }
            .frame(width: 22, height: 60)
            .scaleEffect(figureScale, anchor: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// 长相类标签的头像：头发、肩、脸，眼睛大小与脸型随标签变化。
struct AtlasTagPortrait: View {
    let motif: AtlasTagMotif
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            var shoulders = Path()
            shoulders.move(to: CGPoint(x: w * 0.20, y: h * 0.98))
            shoulders.addQuadCurve(to: CGPoint(x: w * 0.80, y: h * 0.98),
                                   control: CGPoint(x: w * 0.50, y: h * 0.62))
            shoulders.closeSubpath()
            context.fill(shoulders, with: .color(color.opacity(0.32)))

            let headR = min(w, h) * 0.29
            let center = CGPoint(x: w / 2, y: h * 0.36)
            context.fill(Path(ellipseIn: CGRect(x: center.x - headR * 1.18,
                                                y: center.y - headR * 1.24,
                                                width: headR * 2.36,
                                                height: headR * 2.62)),
                         with: .color(color.opacity(0.45)))

            let faceW = headR * (isRound ? 1.96 : 1.72)
            let faceH = headR * (isRound ? 1.78 : 1.86)
            let face = CGRect(x: center.x - faceW / 2, y: center.y - faceH / 2,
                              width: faceW, height: faceH)
            context.fill(Path(ellipseIn: face), with: .color(color))

            let eyeR = headR * (isBigEyes ? 0.17 : 0.11)
            let eyeY = face.midY - face.height * 0.05
            let eyeDX = face.width * 0.20
            for sign in [-1.0, 1.0] {
                let cx = face.midX + CGFloat(sign) * eyeDX
                context.fill(Path(ellipseIn: CGRect(x: cx - eyeR, y: eyeY - eyeR,
                                                    width: eyeR * 2, height: eyeR * 2)),
                             with: .color(.black.opacity(0.55)))
            }

            var smile = Path()
            smile.addArc(center: CGPoint(x: face.midX, y: face.midY + face.height * 0.14),
                         radius: face.width * 0.14,
                         startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
            context.stroke(smile, with: .color(.black.opacity(0.32)),
                           lineWidth: max(0.8, headR * 0.09))
        }
    }

    private var isRound: Bool {
        if case .faceRound = motif { return true }
        return false
    }

    private var isBigEyes: Bool {
        if case .faceEyes = motif { return true }
        return false
    }
}

/// 标签的四片星区：按关键词粗分，不追求严格语义。
enum AtlasTagGroup: String, CaseIterable, Identifiable {
    case body
    case face
    case mood
    case style

    var id: String { rawValue }

    var title: String {
        switch self {
        case .body: return "身材"
        case .face: return "长相"
        case .mood: return "气质"
        case .style: return "风格"
        }
    }

    var caption: String {
        switch self {
        case .body: return "胸、腰、臀、腿"
        case .face: return "清纯、可爱、美少女"
        case .mood: return "性感、妩媚、成熟"
        case .style: return "写真、模特、Cos"
        }
    }

    var color: Color {
        switch self {
        case .body: return LumaBrand.coral
        case .face: return LumaBrand.violet
        case .mood: return LumaBrand.mint
        case .style: return LumaBrand.cyan
        }
    }

    static func group(for tag: String) -> AtlasTagGroup {
        let body = ["乳", "胸", "臀", "腰", "腿", "身材", "巨乳", "美乳", "纖腰", "長腿", "美背", "瘦", "胖"]
        let face = ["清純", "可愛", "美少女", "美人", "萌", "娃娃臉", "大眼睛", "網紅臉", "臉", "蘿莉", "五官"]
        let mood = ["性感", "嫵媚", "成熟", "女人味", "氣質", "溫柔", "天然", "高冷", "御姐", "妖嬈"]
        let style = ["模特", "寫真", "Cos", "cos", "網紅", "主播", "博主", "演員", "偶像", "素人"]
        if body.contains(where: { tag.contains($0) }) { return .body }
        if face.contains(where: { tag.contains($0) }) { return .face }
        if mood.contains(where: { tag.contains($0) }) { return .mood }
        if style.contains(where: { tag.contains($0) }) { return .style }
        return .style
    }
}

// MARK: - 作品量

/// 作品量分档，用星等讲：殿堂 / 常青 / 高产 / 活跃 / 新人。
struct AtlasWorkTierView: View {
    @Environment(AtlasStore.self) private var atlas

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AtlasAnalysisHeader(
                    title: "作品量",
                    english: "OUTPUT TIERS",
                    subtitle: "作品数分五档：殿堂、常青、高产、活跃、新人。点一档只看这一层，卡片右侧的 ↗ 直接去网络资源找她的图集。",
                    symbol: "star.circle")

                if atlas.workTiers.isEmpty {
                    Text(atlas.isLoadingRoster ? "正在统计作品量…" : "这份资料库没有作品数。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                } else {
                    HStack(spacing: 14) {
                        ForEach(atlas.workTiers) { tier in
                            tierCard(tier)
                        }
                    }
                }

                AtlasAnalysisResults(
                    title: atlas.workTierFilter.map { "\(caption(for: $0).title) · \($0)+ 部" } ?? "全部人物",
                    detail: atlas.workTierFilter == nil ? "点一档，只看这一层" : "再点一次同一档可以取消")
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
    }

    private func tierCard(_ tier: AtlasWorkTier) -> some View {
        let active = atlas.workTierFilter == tier.min
        let info = caption(for: tier.min)
        return Button {
            atlas.toggleWorkTier(tier.min)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: info.symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(active
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(LinearGradient(colors: [LumaBrand.violet.opacity(0.8),
                                                                             LumaBrand.coral.opacity(0.5)],
                                                                    startPoint: .top, endPoint: .bottom)))
                Text(AtlasLook.compact(tier.count))
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text(info.title)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                Text(info.note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(tier.label + " 部")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06),
                                  lineWidth: active ? 1.4 : 0.6)
            }
        }
        .buttonStyle(.plain)
        .help("\(tier.label) 部 · \(tier.count) 位")
    }

    private func caption(for tier: Int) -> (title: String, note: String, symbol: String) {
        switch tier {
        case 1000: return ("殿堂", "千部以上", "crown.fill")
        case 500: return ("常青", "五百起步", "star.fill")
        case 200: return ("高产", "两百有余", "sparkles")
        case 50: return ("活跃", "五十到两百", "flame.fill")
        default: return ("新人", "不足五十", "leaf.fill")
        }
    }
}
