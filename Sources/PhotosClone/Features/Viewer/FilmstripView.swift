import SwiftUI
import AppKit

struct FilmstripView: View {
    let items: [PhotoItem]
    let currentID: UUID
    let onSelect: (UUID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.id)
                        } label: {
                            FilmstripThumb(photo: item, isCurrent: item.id == currentID)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .frame(height: 74)
            // 两端淡出，滚动时不会出现生硬的截断边缘。
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            )
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
            .onAppear {
                proxy.scrollTo(currentID, anchor: .center)
            }
            .onChange(of: currentID) { _, id in
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

struct FilmstripThumb: View {
    @EnvironmentObject private var settings: AppSettings
    let photo: PhotoItem
    let isCurrent: Bool

    private var corner: CGFloat { max(4, settings.smallCoverRadius) }

    var body: some View {
        ZStack {
            PhotoThumbnailView(photo: photo, purpose: .filmstrip(54))
            if photo.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isCurrent ? Color.white : Color.white.opacity(0.12),
                              lineWidth: isCurrent ? 2 : 0.6)
        }
        .shadow(color: .black.opacity(isCurrent ? 0.28 : 0), radius: 6, y: 2)
        .opacity(isCurrent ? 1 : 0.72)
    }
}
