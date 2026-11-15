import SwiftUI

/// 系统「照片」图库自己的精选集：只读汇总当前系统图库里的收藏、视频、截屏等分类。
/// 与拾光的「精选集」不同，这里不会切换当前图库，数据全部来自 `store.systemPhotos`。
struct SystemCollectionsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var cards: [SystemCollectionSummary.Card] = []
    @State private var isBuilding = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if isBuilding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在汇总系统图库…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                } else if cards.isEmpty {
                    EmptyStateView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(cards) { card in
                            cardView(card)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.contentRevision) {
            await rebuild()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("精选集")
                .font(.system(size: 27, weight: .bold))
            Text("汇总「\(store.systemLibraryName ?? "系统照片图库")」自己的收藏、视频、截屏等内容（只读）")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func cardView(_ card: SystemCollectionSummary.Card) -> some View {
        Button {
            store.navigate(to: card.target)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                    if card.samples.isEmpty {
                        Image(systemName: card.icon)
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PhotoMosaicView(photos: card.samples)
                            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
                    }
                }
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: card.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(card.tint)
                    Text(card.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(card.subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看系统图库的\(card.title)")
    }

    private func rebuild() async {
        if cards.isEmpty { isBuilding = true }
        let photos = store.systemPhotos
        let cutoff = LibraryStore.recentlySavedCutoff
        guard !photos.isEmpty else {
            cards = []
            isBuilding = false
            return
        }
        let summary = await Task.detached(priority: .utility) {
            SystemCollectionSummary.build(from: photos, savedCutoff: cutoff)
        }.value
        cards = summary.cards
        isBuilding = false
    }
}

/// 一次遍历得出所有精选集卡片与样本，避免每张卡片各扫一遍十几万张系统照片。
enum SystemCollectionSummary {
    struct Card: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let count: Int
        let samples: [PhotoItem]
        let target: SidebarItem
        let tint: Color
    }

    struct Result {
        let cards: [Card]
    }

    static func build(from photos: [PhotoItem], savedCutoff: Date) -> Result {
        var favorites = Bucket()
        var videos = Bucket()
        var selfies = Bucket()
        var panoramas = Bucket()
        var screenshots = Bucket()
        var recentlySaved = Bucket()
        var edited = Bucket()

        for photo in photos {
            guard photo.deletedAt == nil, !photo.isHidden else { continue }
            if photo.isFavorite { favorites.add(photo) }
            if photo.isVideo { videos.add(photo) }
            if !photo.isVideo, photo.kind == .selfie { selfies.add(photo) }
            if photo.kind == .panorama { panoramas.add(photo) }
            if photo.kind == .screenshot { screenshots.add(photo) }
            if photo.addedAt >= savedCutoff { recentlySaved.add(photo) }
            if !photo.isVideo, photo.editedAt != nil || photo.hasEdits { edited.add(photo) }
        }

        let cards: [Card] = [
            make("favorites", "个人收藏", "项", "heart.fill", .pink, .systemFavorites, favorites),
            make("videos", "视频", "个", "video.fill", .purple, .systemVideos, videos),
            make("selfies", "自拍", "项", "person.crop.square", .orange, .systemSelfies, selfies),
            make("panoramas", "全景照片", "项", "pano", .indigo, .systemPanoramas, panoramas),
            make("screenshots", "截屏", "项", "camera.viewfinder", .teal, .systemScreenshots, screenshots),
            make("recentlySaved", "最近保存", "项", "square.and.arrow.down", .blue, .systemRecentlySaved, recentlySaved),
            make("edited", "最近编辑", "项", "slider.horizontal.3", .gray, .systemEdited, edited)
        ]
        .filter { $0.count > 0 }

        return Result(cards: cards)
    }

    private static func make(_ id: String,
                             _ title: String,
                             _ unit: String,
                             _ icon: String,
                             _ tint: Color,
                             _ target: SidebarItem,
                             _ bucket: Bucket) -> Card {
        Card(id: id, title: title,
             subtitle: "\(bucket.count) \(unit)",
             icon: icon, count: bucket.count,
             samples: bucket.samples, target: target, tint: tint)
    }

    private struct Bucket {
        var count = 0
        var samples: [PhotoItem] = []

        mutating func add(_ photo: PhotoItem) {
            count += 1
            if samples.count < 4 { samples.append(photo) }
        }
    }
}
