import SwiftUI

/// 星图：人物是星点，共演是连线。
/// 位置在本地用黄金角螺旋排布（同一份数据每次进来都一样），不跑运行时力导向。
struct AtlasConstellationView: View {
    @Environment(AtlasStore.self) private var atlas

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var hovered: Int64?
    @State private var selected: Int64?

    private var filtered: [AtlasPerson] {
        guard let region = atlas.regionFilter else { return atlas.people }
        return atlas.people.filter { $0.region == region }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                starCanvas(size: geo.size)
                legend
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
                if let selected, let detail = atlas.detail, detail.person.id == selected {
                    detailPanel(detail)
                        .frame(width: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if atlas.isLoading {
                    ProgressView("正在铺开星图…")
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
        }
        .onAppear {
            if selected == nil, let id = atlas.selectedPersonID ?? atlas.people.first?.id {
                selected = id
                atlas.selectedPersonID = id
            }
        }
        .onChange(of: atlas.selectedPersonID) { _, newValue in
            if let newValue { selected = newValue }
        }
        .onChange(of: selected) { _, newValue in
            if let newValue { atlas.selectedPersonID = newValue }
        }
    }

    // MARK: 画布

    private func starCanvas(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let points = layout(in: canvasSize)
            guard !points.isEmpty else { return }

            // 背景的细碎星尘：用确定性伪随机，不闪烁。
            var dust = context
            dust.opacity = 0.35
            for index in 0..<220 {
                let x = pseudo(index * 7 + 3) * canvasSize.width
                let y = pseudo(index * 13 + 11) * canvasSize.height
                let radius = 0.5 + pseudo(index * 17) * 1.1
                dust.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                          with: .color(.white.opacity(0.35)))
            }

            // 共演连线：只画选中人物的一跳关系，避免变成一团毛线。
            if let selected, let detail = atlas.detail, detail.person.id == selected {
                let lookup = Dictionary(uniqueKeysWithValues: points.map { ($0.person.id, $0.point) })
                if let origin = lookup[selected] {
                    for star in detail.coStars {
                        guard let target = lookup[star.id] else { continue }
                        var path = Path()
                        path.move(to: origin)
                        let mid = CGPoint(x: (origin.x + target.x) / 2,
                                          y: (origin.y + target.y) / 2 - 18)
                        path.addQuadCurve(to: target, control: mid)
                        context.stroke(path,
                                       with: .linearGradient(
                                        Gradient(colors: [AtlasLook.regionColor(detail.person.region).opacity(0.55),
                                                          .white.opacity(0.18)]),
                                        startPoint: origin, endPoint: target),
                                       lineWidth: 0.7)
                    }
                }
            }

            for star in points {
                let color = AtlasLook.regionColor(star.person.region)
                let radius = star.radius
                let isSelected = star.person.id == selected
                let isHovered = star.person.id == hovered

                if isSelected || isHovered {
                    context.fill(Path(ellipseIn: CGRect(x: star.point.x - radius * 3.4,
                                                        y: star.point.y - radius * 3.4,
                                                        width: radius * 6.8,
                                                        height: radius * 6.8)),
                                 with: .color(color.opacity(isSelected ? 0.22 : 0.12)))
                }
                context.fill(Path(ellipseIn: CGRect(x: star.point.x - radius,
                                                    y: star.point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(color.opacity(isSelected ? 1 : 0.82)))

                if isSelected {
                    context.stroke(Path(ellipseIn: CGRect(x: star.point.x - radius * 2.2,
                                                         y: star.point.y - radius * 2.2,
                                                         width: radius * 4.4, height: radius * 4.4)),
                                   with: .color(.white.opacity(0.55)), lineWidth: 0.8)
                }

                let shouldLabel = isSelected || isHovered || star.rank < 14
                if shouldLabel {
                    let text = Text(star.person.name)
                        .font(.system(size: isSelected ? 11 : 9,
                                      weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.62))
                    context.draw(text, at: CGPoint(x: star.point.x, y: star.point.y + radius + 9))
                }
            }
        }
        .background(
            RadialGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.18),
                                    Color(red: 0.03, green: 0.04, blue: 0.08)],
                           center: .center, startRadius: 40, endRadius: 900)
        )
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    if let hit = hitTest(at: value.location, size: size) {
                        withAnimation(.easeOut(duration: 0.18)) { selected = hit }
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { selected = nil }
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hovered = hitTest(at: location, size: size)
            case .ended:
                hovered = nil
            }
        }
    }

    // MARK: 布局与命中

    private struct StarPoint {
        let person: AtlasPerson
        let point: CGPoint
        let radius: CGFloat
        let rank: Int
    }

    private func layout(in size: CGSize) -> [StarPoint] {
        let list = filtered
        guard !list.isEmpty else { return [] }
        let center = CGPoint(x: size.width / 2 + pan.width,
                             y: size.height / 2 + pan.height)
        let maxRadius = min(size.width, size.height) * 0.44 * zoom
        return list.enumerated().map { index, person in
            let angle = Double(index) * 2.399963229728653
            let spread = sqrt(Double(index) / Double(max(list.count, 1)))
            let radius = CGFloat(spread) * maxRadius
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                y: center.y + CGFloat(sin(angle)) * radius * 0.86)
            let weight = log10(Double(max(person.workCount, 1)) + 1)
            return StarPoint(person: person, point: point,
                             radius: CGFloat(1.6 + weight * 1.25) * min(zoom, 2),
                             rank: index)
        }
    }

    private func hitTest(at location: CGPoint, size: CGSize) -> Int64? {
        var best: (Int64, CGFloat)?
        for star in layout(in: size) {
            let dx = star.point.x - location.x
            let dy = star.point.y - location.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < max(14, star.radius * 2.4) else { continue }
            if best == nil || distance < best!.1 {
                best = (star.person.id, distance)
            }
        }
        return best?.0
    }

    private func pseudo(_ seed: Int) -> CGFloat {
        let value = sin(Double(seed) * 12.9898) * 43758.5453
        return CGFloat(value - floor(value))
    }

    // MARK: 手势

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                pan = CGSize(width: lastPan.width + value.translation.width,
                             height: lastPan.height + value.translation.height)
            }
            .onEnded { _ in lastPan = pan }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in zoom = min(2.4, max(0.6, value)) }
    }

    // MARK: 浮层

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([("japan", "日本"), ("china", "大陆"), ("korea", "韩国"), ("western", "欧美")], id: \.0) { item in
                HStack(spacing: 6) {
                    Circle().fill(AtlasLook.regionColor(item.0)).frame(width: 6, height: 6)
                    Text(item.1).font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
            Text("拖拽平移 · 双指缩放 · 点星看共演")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailPanel(_ detail: AtlasPersonDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AtlasAvatar(person: detail.person, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.person.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text(detail.person.nameJA ?? detail.person.nameEN ?? detail.person.regionTitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        atlas.mode = .people
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("打开完整档案")
                }

                HStack(spacing: 9) {
                    fact("作品", "\(detail.person.workCount)")
                    if let height = detail.person.heightCM { fact("身高", "\(height)") }
                    if let cup = detail.person.cup { fact("罩杯", cup) }
                    fact("地区", detail.person.regionTitle)
                }

                if !detail.genres.isEmpty {
                    FlowChips(items: detail.genres.map { "\($0.name) \($0.count)" })
                }

                if !detail.coStars.isEmpty {
                    Text("共演")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FlowChips(items: detail.coStars.map { "\($0.name) · \($0.count)" })
                }

                if !detail.works.isEmpty {
                    Text("作品")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(detail.works.prefix(8)) { work in
                                AtlasRemoteImage(urlString: work.thumbURL ?? work.coverURL,
                                                 seed: Int(work.id))
                                    .frame(width: 64, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .onTapGesture { atlas.focusedWork = work }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 520)
        .atlasGlass(radius: 16, padding: 0)
        .transition(.move(edge: .trailing).combined(with: .opacity))
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
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
