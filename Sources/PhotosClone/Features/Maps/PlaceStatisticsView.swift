import SwiftUI
import AppKit

/// 「位置」——按城市 / 区县聚合的地点统计卡片墙。
struct PlaceStatisticsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var hoveredID: String?
    @State private var pinchBase: Double?

    var body: some View {
        if let place = store.selectedPlace {
            placeDetail(place)
        } else {
            overview
        }
    }

    // MARK: - 概览

    private var overview: some View {
        VStack(spacing: 0) {
            header
            if store.isResolvingPlaces {
                resolveProgress
            }
            ScrollView {
                if store.placeClusters.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(group.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: columns, alignment: .leading, spacing: cardSize * 0.17) {
                                    ForEach(group.clusters) { cluster in
                                        PlaceCardView(cluster: cluster, isHovered: hoveredID == cluster.id)
                                            .onTapGesture { store.openPlace(cluster) }
                                            .onHover { hovering in
                                                hoveredID = hovering ? cluster.id : (hoveredID == cluster.id ? nil : hoveredID)
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 4)
                    .padding(.bottom, 56)
                }
            }
            .simultaneousGesture(pinchGesture)
        }
        .task { store.resolveMissingPlacesIfNeeded() }
    }

    /// 地点卡片尺寸跟随工具栏缩放（56…360 → 90…400，默认 132 → 约 152）。
    private var cardSize: CGFloat {
        min(400, max(90, CGFloat(store.thumbSize) * 1.15))
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("位置")
                    .font(.system(size: 28, weight: .bold))
                Text("\(store.placeClusters.count) 个地点 · \(store.geoPhotos.count.formatted()) 张带位置的照片")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            searchField
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索地点", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 250)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var resolveProgress: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(store.placeResolveDone),
                         total: Double(max(1, store.placeResolveTotal)))
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text("正在解析地点 \(store.placeResolveDone) / \(store.placeResolveTotal)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有带位置信息的照片")
                .font(.system(size: 13, weight: .medium))
            Text("照片需要包含 GPS 信息才会纳入地点统计。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35), spacing: cardSize * 0.15, alignment: .top)]
    }

    private var groups: [(title: String, clusters: [PlaceCluster])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return store.placeGroups }
        return store.placeGroups.compactMap { group in
            let matches = group.clusters.filter {
                $0.title.lowercased().contains(trimmed)
                    || ($0.subtitle?.lowercased().contains(trimmed) ?? false)
            }
            return matches.isEmpty ? nil : (group.title, matches)
        }
    }

    // MARK: - 某个地点的照片

    private func placeDetail(_ place: PlaceCluster) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        store.closePlace()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("返回位置")
                    .accessibilityLabel("返回位置")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.title)
                            .font(.system(size: 21, weight: .bold))
                        Text("\(store.visiblePhotos.count.formatted()) 张照片"
                             + (place.subtitle.map { " · \($0)" } ?? ""))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        store.navigate(to: store.isSystemScope ? .systemMap : .map)
                    } label: {
                        Label("在地图中查看", systemImage: "map")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    SquarePhotoGrid(photos: store.visiblePhotos, availableWidth: proxy.size.width)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                }
            }
        }
    }
}

private struct PlaceCardView: View {
    let cluster: PlaceCluster
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            cover
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if cluster.count > 1 {
                        Text("\(cluster.count)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(isHovered ? 0.28 : 0.12),
                        radius: isHovered ? 14 : 7,
                        y: isHovered ? 8 : 3)

            Text(cluster.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text("\(cluster.count.formatted()) 张照片")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
        .contentShape(Rectangle())
    }

    private var cover: some View {
        Rectangle()
            .fill(Color.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let photo = cluster.cover {
                    PhotoThumbnailView(photo: photo, purpose: .cover(200))
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.2)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .clipped()
    }
}
