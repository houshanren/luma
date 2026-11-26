import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaContentCore

// MARK: - 传送门

/// 传送门：按天回到某一天的节目。日期与频道由「节目回看」统一管理，
/// 这里只负责这一扇门与节目列表，和左侧频道栏、顶部日期胶囊实时同步。
struct TVCatchupView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(IPTVBrowserModel.self) private var tv
    @Environment(\.colorScheme) private var scheme

    private var isLight: Bool { scheme == .light }
    /// 门内的正文 / 次要读数 / 提示：暗色是白字，浅色是深字。
    private var portalSecondaryInk: Color {
        isLight ? Color.black.opacity(0.58) : Color.white.opacity(0.55)
    }
    private var portalTertiaryInk: Color {
        isLight ? Color.black.opacity(0.42) : Color.white.opacity(0.38)
    }
    private var portalHintInk: Color {
        isLight ? Color.black.opacity(0.32) : Color.white.opacity(0.30)
    }

    /// 与时间轴 / 时间环共用的日期与当前频道。
    @Binding var day: Date
    @Binding var selectedID: String?
    /// 左栏当前频道：没选中时由外层给出兜底，保证三视图看到的是同一台。
    var channel: TVChannel?

    @State private var query = ""
    /// 时间门：悬停的日期、穿越时的收束动画、节目列表的重放计数。
    @State private var hoveredDay: Date?
    @State private var portalTravel = false
    @State private var crossTick = 0

    /// 时间门保留五天：前天 / 昨天 / 今天 / 明天 / 后天。历史用于回看，未来用于预约。
    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (-2...2).compactMap {
            Calendar.current.date(byAdding: .day, value: $0, to: today)
        }
    }

    private var catchupChannels: [TVChannel] {
        tv.visibleChannels.filter { !($0.catchUpSource ?? "").isEmpty }
    }

    private var selectedChannel: TVChannel? {
        if let selectedID, let match = tv.visibleChannels.first(where: { $0.id == selectedID }) {
            return match
        }
        return channel ?? catchupChannels.first ?? tv.visibleChannels.first
    }

    private var selectedPrograms: [TVEPGProgram] {
        guard let channel = selectedChannel else { return [] }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = tv.programs(on: day, for: channel)
        guard !keyword.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || channel.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        programPane
            .task { tv.loadEPGIfNeeded() }
            .onChange(of: tv.focusedPlaylistID) { _, _ in
                selectedID = nil
            }
    }

    /// 概念 B · 时间门：回看不是「往后拖进度条」，而是「去某一天」。
    private var programPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                breadcrumb
                Spacer(minLength: 0)
                searchField
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        timePortal
                            .id(Self.programPaneTopID)
                        if let channel = selectedChannel {
                            if (channel.catchUpSource ?? "").isEmpty {
                                messageState("该源未声明回看",
                                             detail: "这个频道会保留在列表里，但回看入口不可用。换一个声明了 catchup-source 的源。")
                                    .frame(height: 180)
                            } else if selectedPrograms.isEmpty {
                                messageState("这一天没有节目",
                                             detail: query.isEmpty ? "节目单里没有这天的记录，换一天看看。" : "没有匹配「\(query)」的节目。")
                                    .frame(height: 180)
                            } else {
                                LazyVStack(spacing: 6) {
                                    ForEach(selectedPrograms) { program in
                                        tunnelProgramRow(channel: channel, program: program)
                                    }
                                }
                                // 换日 / 换台 / 穿越时整段节目列表重新淡入，滚动位置回到顶部。
                                .id("\(channel.id)-\(Int(day.timeIntervalSince1970))-\(crossTick)")
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        } else {
                            messageState("没有可用的频道", detail: "当前筛选下没有频道。")
                                .frame(height: 180)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                // 切换频道 / 日期后整页回到顶部，不沿用上一个频道的滚动位置。
                .onChange(of: selectedChannel?.id) { _, _ in
                    scrollProgramPaneToTop(proxy)
                }
                .onChange(of: day) { _, _ in
                    scrollProgramPaneToTop(proxy)
                }
                .onChange(of: crossTick) { _, _ in
                    scrollProgramPaneToTop(proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let programPaneTopID = "programPane.top"

    private func scrollProgramPaneToTop(_ proxy: ScrollViewProxy) {
        // 等新频道的列表完成布局后再定位，否则会停在旧内容的高度。
        DispatchQueue.main.async {
            proxy.scrollTo(Self.programPaneTopID, anchor: .top)
        }
    }

    /// 面包屑：现在 → 所选那天 → 频道。
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Text("现在 \(clock(Date()))")
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
            Text("\(dayTitle(day)) · \(selectedPrograms.count) 档")
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
            Text(selectedChannel?.name ?? "—")
                .foregroundStyle(TVBrand.gold)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
    }

    /// 时间门：一圈全息传送环，日期分布在光环上。
    /// 拖动光环 / 点左右箭头换日，点中心「穿越」进入那一天的节目。
    private var timePortal: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("TIME GATE")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(TVBrand.wave.opacity(0.85))
                Text("回看 · 时间门")
                    .font(.system(size: 9.5))
                    .foregroundStyle(portalTertiaryInk)
                Spacer(minLength: 0)
                if !Calendar.current.isDateInToday(day) {
                    Button("回到现在") {
                        selectDay(Calendar.current.startOfDay(for: Date()))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(TVBrand.wave)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                }
                portalArrow("chevron.left",
                            enabled: selectedIndex > 0,
                            help: "回到更早一天") { stepDay(-1) }
                portalArrow("chevron.right",
                            enabled: selectedIndex < days.count - 1,
                            help: "回到更新一天") { stepDay(1) }
            }

            GeometryReader { proxy in
                let side = max(220, min(proxy.size.width, proxy.size.height) * 0.9)
                ZStack {
                    portalStage(side: side)
                    // 竖立的传送门：整体向后倾 15°，圆环压成椭圆，像一扇立在底座上的门。
                    ZStack {
                        portalRing(side: side)
                        portalCenter(side: side)
                        portalDayMarkers(side: side)
                    }
                    .rotation3DEffect(.degrees(15), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                    .scaleEffect(portalTravel ? 1.5 : 1)
                    .opacity(portalTravel ? 0.08 : 1)
                    .animation(.easeIn(duration: 0.28), value: portalTravel)

                    // 穿越瞬间：一圈白光从门心向外扩。
                    if portalTravel {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                            .frame(width: side * 0.62, height: side * 0.62)
                            .scaleEffect(1.9)
                            .blur(radius: 5)
                            .shadow(color: TVBrand.wave.opacity(0.8), radius: 14)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .gesture(portalDrag(side: side))
            }
            .frame(height: 320)

            portalDataBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background { portalBackdrop }
    }

    /// 传送门背景：暗色是黑曜石暗场，浅色是带一点紫雾的暖白。
    private var portalBackdrop: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: isLight
                                 ? [Color(red: 0.985, green: 0.98, blue: 0.972),
                                    Color(red: 0.925, green: 0.918, blue: 0.945)]
                                 : [Color(red: 0.035, green: 0.03, blue: 0.065),
                                    Color.black.opacity(0.78)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [Color(red: 0.42, green: 0.26, blue: 0.95)
                                            .opacity(isLight ? 0.12 : 0.22),
                                        Color(red: 0.20, green: 0.55, blue: 1.0)
                                            .opacity(isLight ? 0.06 : 0.07),
                                        .clear],
                               center: .center, startRadius: 20, endRadius: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(red: 0.55, green: 0.45, blue: 1)
                        .opacity(isLight ? 0.18 : 0.22),
                                  lineWidth: 0.8)
            }
    }

    /// 门下方的底座：参考传送门的椭圆基座，前沿一道冷光边。
    private func portalStage(side: CGFloat) -> some View {
        ZStack {
            // 地面光斑
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 0.45, green: 0.30, blue: 1)
                                                  .opacity(isLight ? 0.18 : 0.30),
                                              .clear],
                                     center: .center, startRadius: 0, endRadius: side * 0.44))
                .frame(width: side * 0.94, height: 54)
                .blur(radius: 8)
                .offset(y: side * 0.30)
            // 底盘：暗色是深紫金属面，浅色是浅紫瓷面。
            Ellipse()
                .fill(LinearGradient(colors: isLight
                                     ? [Color(red: 0.95, green: 0.94, blue: 0.99),
                                        Color(red: 0.80, green: 0.79, blue: 0.90)]
                                     : [Color(red: 0.14, green: 0.10, blue: 0.28),
                                        Color(red: 0.04, green: 0.03, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: side * 0.76, height: 46)
                .offset(y: side * 0.30)
            // 底盘前沿：青→紫的高光边
            Ellipse()
                .stroke(LinearGradient(colors: [Color(red: 0.35, green: 0.85, blue: 1).opacity(0.95),
                                                Color(red: 0.72, green: 0.40, blue: 1).opacity(0.35),
                                                Color(red: 0.35, green: 0.85, blue: 1).opacity(0.55)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 2.4)
                .frame(width: side * 0.76, height: 46)
                .blur(radius: 0.6)
                .offset(y: side * 0.30)
            // 内圈凹槽
            Ellipse()
                .stroke(isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.14),
                        lineWidth: 0.8)
                .frame(width: side * 0.60, height: 30)
                .offset(y: side * 0.29)
            Ellipse()
                .stroke(Color(red: 0.85, green: 0.40, blue: 0.70)
                    .opacity(isLight ? 0.35 : 0.45), lineWidth: 1.6)
                .frame(width: side * 0.46, height: 20)
                .blur(radius: 1.2)
                .offset(y: side * 0.285)
        }
        .allowsHitTesting(false)
    }

    /// 传输环本体：外圈分段光带 + 秒刻度 + 内圈门弧。
    private func portalRing(side: CGFloat) -> some View {
        let r = side / 2 - 26
        let gateAngle = portalAngle(for: day)
        return ZStack {
            // 外层柔光
            Circle()
                .stroke(AngularGradient(gradient: Gradient(colors: [
                    Color(red: 0.55, green: 0.40, blue: 1),
                    Color(red: 0.25, green: 0.78, blue: 1),
                    Color(red: 0.95, green: 0.35, blue: 0.68),
                    Color(red: 0.55, green: 0.40, blue: 1)
                ]), center: .center), lineWidth: 10)
                .frame(width: r * 2, height: r * 2)
                .blur(radius: 18)
                .opacity(isLight ? 0.34 : 0.48)

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // 外圈：48 段光带，每 4 段加粗一次。
                let segments = 48
                for index in 0..<segments {
                    let a0 = Double(index) / Double(segments) * 360 + 1.1
                    let a1 = a0 + 360 / Double(segments) - 2.2
                    var path = Path()
                    path.addArc(center: center, radius: r,
                                startAngle: .degrees(a0 - 90),
                                endAngle: .degrees(a1 - 90),
                                clockwise: false)
                    let t = Double(index) / Double(segments)
                    let color = Color(red: 0.30 + 0.52 * t,
                                      green: 0.74 - 0.20 * t,
                                      blue: 1.0)
                    context.stroke(path,
                                   with: .color(color.opacity(isLight ? 0.78 : 0.58)),
                                   style: StrokeStyle(lineWidth: index % 4 == 0 ? 2.8 : 1.2,
                                                      lineCap: .round))
                }

                // 秒刻度：短、密、贴在环内侧。
                for index in 0..<60 {
                    let angle = Double(index) / 60 * 360 - 90
                    let outer = r - 6
                    let inner = r - (index % 5 == 0 ? 16 : 11)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + CGFloat(cos(angle * .pi / 180)) * inner,
                                          y: center.y + CGFloat(sin(angle * .pi / 180)) * inner))
                    path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle * .pi / 180)) * outer,
                                             y: center.y + CGFloat(sin(angle * .pi / 180)) * outer))
                    context.stroke(path,
                                   with: .color(Color.primary.opacity(index % 5 == 0 ? 0.26 : 0.10)),
                                   style: StrokeStyle(lineWidth: index % 5 == 0 ? 1 : 0.5,
                                                      lineCap: .round))
                }

                // 内圈细线
                let innerRect = CGRect(x: center.x - (r - 30),
                                       y: center.y - (r - 30),
                                       width: (r - 30) * 2,
                                       height: (r - 30) * 2)
                context.stroke(Path(ellipseIn: innerRect),
                               with: .color(Color.primary.opacity(0.10)),
                               style: StrokeStyle(lineWidth: 1))

                // 门框内沿：白热高光 + 冷光边
                let rimRect = CGRect(x: center.x - (r - 15),
                                     y: center.y - (r - 15),
                                     width: (r - 15) * 2,
                                     height: (r - 15) * 2)
                context.stroke(Path(ellipseIn: rimRect),
                               with: .color(isLight ? Color.primary.opacity(0.55)
                                                    : Color.white.opacity(0.65)),
                               style: StrokeStyle(lineWidth: 1.4))
                context.stroke(Path(ellipseIn: rimRect.insetBy(dx: -2, dy: -2)),
                               with: .color(Color(red: 0.55, green: 0.72, blue: 1).opacity(0.30)),
                               style: StrokeStyle(lineWidth: 5))

                // 选中那一天的门弧：青 → 品红。
                var gate = Path()
                gate.addArc(center: center, radius: r - 18,
                            startAngle: .degrees(gateAngle - 90 - 32),
                            endAngle: .degrees(gateAngle - 90 + 32),
                            clockwise: false)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Color(red: 0.35, green: 0.88, blue: 1),
                                      Color(red: 0.95, green: 0.36, blue: 0.70)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height))
                context.stroke(gate,
                               with: .color(Color(red: 0.35, green: 0.85, blue: 1).opacity(0.28)),
                               style: StrokeStyle(lineWidth: 14, lineCap: .round))
                context.stroke(gate, with: shading,
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    /// 日期节点：今天在正上方，明天在右、昨天在左、前天在下方。
    private func portalDayMarkers(side: CGFloat) -> some View {
        let radius = side / 2 - 26
        return ZStack {
            ForEach(days, id: \.self) { date in
                let angle = portalAngle(for: date) * .pi / 180
                let selected = Calendar.current.isDate(date, inSameDayAs: day)
                let hovered = hoveredDay.map {
                    Calendar.current.isDate($0, inSameDayAs: date)
                } ?? false
                let ink: Color = selected
                    ? Color.black.opacity(0.82)
                    : (isLight ? Color.black.opacity(hovered ? 0.82 : 0.55)
                               : Color.white.opacity(hovered ? 0.86 : 0.52))
                let fill: Color = selected
                    ? TVBrand.wave
                    : (isLight ? Color.white.opacity(0.88) : Color.black.opacity(0.55))
                let border: Color = selected
                    ? Color.clear
                    : (isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.12))
                Button {
                    selectDay(date)
                } label: {
                    VStack(spacing: 1) {
                        Text(dayNumber(date))
                            .font(.system(size: selected ? 12 : 10,
                                          weight: selected ? .bold : .medium,
                                          design: .monospaced))
                        Text(dayTitle(date))
                            .font(.system(size: 7, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(fill, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(border, lineWidth: 0.5)
                    }
                    .scaleEffect(selected ? 1.06 : (hovered ? 1.02 : 0.94))
                    .shadow(color: selected ? TVBrand.wave.opacity(0.55) : .clear,
                            radius: 8)
                }
                .buttonStyle(.plain)
                .position(x: side / 2 + CGFloat(cos(angle)) * radius,
                          y: side / 2 + CGFloat(sin(angle)) * radius)
                .onHover { inside in
                    if inside {
                        hoveredDay = date
                    } else if hoveredDay.map({
                        Calendar.current.isDate($0, inSameDayAs: date)
                    }) == true {
                        hoveredDay = nil
                    }
                }
                .help("穿越到 \(dayTitle(date))")
            }
        }
        .frame(width: side, height: side)
    }

    /// 环心：日期、节目数、穿越按钮。
    private func portalCenter(side: CGFloat) -> some View {
        let r = side / 2 - 26
        let weekday = day.formatted(.dateTime.weekday(.wide))
        let monthDay = day.formatted(.dateTime.month(.defaultDigits).day())
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: isLight
                                     ? [Color.white.opacity(0.95), Color.white.opacity(0.10)]
                                     : [Color.black.opacity(0.80), Color.black.opacity(0.16)],
                                     center: .center, startRadius: 10, endRadius: r * 0.82))
                .frame(width: r * 1.72, height: r * 1.72)

            // 门内光雾：一团品红、一团冷蓝，慢慢在门里晃。
            ZStack {
                Circle()
                    .fill(Color(red: 0.95, green: 0.35, blue: 0.68)
                        .opacity(isLight ? 0.22 : 0.30))
                    .frame(width: r * 0.62, height: r * 0.62)
                    .offset(x: -r * 0.30, y: -r * 0.12)
                    .blur(radius: 26)
                Circle()
                    .fill(Color(red: 0.35, green: 0.58, blue: 1)
                        .opacity(isLight ? 0.20 : 0.28))
                    .frame(width: r * 0.70, height: r * 0.70)
                    .offset(x: r * 0.34, y: r * 0.14)
                    .blur(radius: 30)
                Circle()
                    .fill(Color(red: 0.95, green: 0.35, blue: 0.68)
                        .opacity(isLight ? 0.12 : 0.16))
                    .frame(width: r * 0.42, height: r * 0.42)
                    .offset(x: r * 0.20, y: -r * 0.32)
                    .blur(radius: 20)
            }
            .frame(width: r * 1.72, height: r * 1.72)
            .clipShape(Circle())
            .allowsHitTesting(false)

            VStack(spacing: 3) {
                Text(Calendar.current.isDateInToday(day) ? "现在" : dayTitle(day))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(TVBrand.wave.opacity(0.85))
                Text(dayNumber(day))
                    .font(.system(size: 54, weight: .thin, design: .serif))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                Text("\(weekday) · \(monthDay)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(portalSecondaryInk)
                Text("\(selectedPrograms.count) 档节目 · \(catchupChannels.count) 个频道可回看")
                    .font(.system(size: 9))
                    .foregroundStyle(portalTertiaryInk)
                    .lineLimit(1)
                Button {
                    crossDay()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("穿越")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(LinearGradient(colors: [TVBrand.wave,
                                                        Color(red: 0.72, green: 0.45, blue: 1)],
                                               startPoint: .leading, endPoint: .trailing),
                                in: Capsule(style: .continuous))
                    .shadow(color: TVBrand.wave.opacity(0.45), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(width: r * 1.35)
        }
        .frame(width: side, height: side)
        .allowsHitTesting(true)
    }

    /// 日期数据条：所选日期的日期 / 星期 / 节目数 / 可回看频道 / 时段。
    private var portalDataBar: some View {
        HStack(spacing: 14) {
            portalDataCell("日期", day.formatted(.dateTime.month(.defaultDigits).day()))
            portalDataCell("星期", day.formatted(.dateTime.weekday(.wide)))
            portalDataCell("节目", "\(selectedPrograms.count) 档")
            portalDataCell("可回看", "\(catchupChannels.count) 个频道")
            if let first = selectedPrograms.first, let last = selectedPrograms.last {
                portalDataCell("时段", "\(clock(first.start)) – \(clock(last.end))")
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 9, weight: .semibold))
                Text("拖动光环或点日期换日")
                    .font(.system(size: 9))
            }
            .foregroundStyle(portalHintInk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private func portalDataCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(portalHintInk)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isLight ? Color.black.opacity(0.78)
                                         : Color.white.opacity(0.76))
        }
    }

    /// 沿光环拖动换日：按角度找最近的日期节点。
    private func portalDrag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let index = portalIndex(at: value.location, side: side),
                      days.indices.contains(index) else { return }
                guard !Calendar.current.isDate(days[index], inSameDayAs: day) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    day = days[index]
                }
            }
    }

    private func portalIndex(at point: CGPoint, side: CGFloat) -> Int? {
        let center = CGPoint(x: side / 2, y: side / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard hypot(dx, dy) > side * 0.26 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        var best = 0
        var bestDelta = 360.0
        for (index, date) in days.enumerated() {
            var marker = portalAngle(for: date)
            while marker < 0 { marker += 360 }
            while marker >= 360 { marker -= 360 }
            let raw = abs(angle - marker)
            let delta = min(raw, 360 - raw)
            if delta < bestDelta {
                bestDelta = delta
                best = index
            }
        }
        return best
    }

    /// 时间门上的角度：今天在正上方，明天在右、昨天在左、前天在下方。
    private func portalAngle(for date: Date) -> Double {
        let today = Calendar.current.startOfDay(for: Date())
        let target = Calendar.current.startOfDay(for: date)
        let offset = Calendar.current.dateComponents([.day], from: today, to: target).day ?? 0
        // 四个节点均分一圈：今天在正上方，明天在右、昨天在左、前天在下方。
        let step = 360.0 / Double(max(1, days.count))
        return -90 + Double(offset) * step
    }

    private func portalArrow(_ symbol: String,
                             enabled: Bool,
                             help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Color.white.opacity(0.82)
                                         : Color.white.opacity(0.20))
                .frame(width: 26, height: 22)
                .background(Color.white.opacity(enabled ? 0.07 : 0.03),
                            in: Capsule(style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// 穿越：门向前一冲、白光扩散，节目列表从底部重新淡入。
    private func crossDay() {
        guard !portalTravel else { return }
        store.showToast("穿越到 \(dayTitle(day)) · \(selectedChannel?.name ?? "")")
        crossTick += 1
        withAnimation(.easeIn(duration: 0.2)) { portalTravel = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            withAnimation(.easeOut(duration: 0.46)) { portalTravel = false }
        }
    }

    private var selectedIndex: Int {
        days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) } ?? 0
    }

    private func dayNumber(_ date: Date) -> String {
        Self.portalDayFormatter.string(from: date)
    }

    private static let portalDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d"
        return formatter
    }()

    private func stepDay(_ delta: Int) {
        guard !days.isEmpty else { return }
        let target = min(days.count - 1, max(0, selectedIndex + delta))
        selectDay(days[target])
    }

    private func selectDay(_ date: Date) {
        guard !Calendar.current.isDate(date, inSameDayAs: day) else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            day = date
        }
    }

    private func tunnelProgramRow(channel: TVChannel, program: TVEPGProgram) -> some View {
        let past = program.end <= Date()
        let live = program.isLive
        let future = program.start > Date()
        let catchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        return Button {
            if live {
                store.openTVChannel(channel)
            } else if catchUp {
                store.openTVCatchup(channel, program: program)
            } else if future {
                tv.toggleReminder(program, channel: channel)
            }
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.16),
                                                  Color.black.opacity(0.35)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    }
                Text(clock(program.start))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(live ? TVBrand.signal : TVBrand.gold)
                    .frame(width: 44, alignment: .leading)
                Text(program.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int(program.duration / 60)) 分")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(live ? "直播" : (catchUp ? "回看" : (future ? (reminded ? "已预约" : "预约") : "已结束")))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(live ? TVBrand.onGold
                                          : (catchUp ? TVBrand.onGold
                                                     : (future ? TVBrand.gold : Color.secondary.opacity(0.6))))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(live ? TVBrand.signal
                                     : (catchUp ? TVBrand.gold
                                                : Color.clear),
                                in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(future ? TVBrand.gold.opacity(0.45) : Color.clear,
                                      lineWidth: 0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(live ? TVBrand.signal.opacity(0.08) : TVBrand.surface,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(live ? TVBrand.signal.opacity(0.35) : TVBrand.stroke, lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!live && !catchUp && !future)
        .opacity(past && !catchUp ? 0.55 : 1)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索节目", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 9)
        .frame(width: 176, height: 24)
        .background(TVBrand.panel, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.hairline, lineWidth: 0.6))
    }

    private func messageState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func dayTitle(_ date: Date) -> String {
        DateText.relativeDayOffset(date) ?? date.formatted(.dateTime.weekday(.abbreviated))
    }

    private func clock(_ date: Date) -> String {
        Self.catchupClockFormatter.string(from: date)
    }

    private static let catchupClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
