import MapKit
import SwiftUI

/// 足迹回放：按拍摄时间顺序在地图上逐站点亮，把一年的行程播成一条线。
struct FootprintPlaybackView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let photos: [PhotoItem]
    var onClose: () -> Void

    @State private var step = 0
    @State private var playing = true
    @State private var interval: Double = 0.24

    private struct Point: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let date: Date
        let photo: PhotoItem
    }

    /// 最多保留 180 个站点，避免图钉与折线过密；按时间顺序均匀取样。
    private var points: [Point] {
        let sorted = photos
            .filter { $0.latitude != nil && $0.longitude != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard sorted.count > 180 else {
            return sorted.map { point(for: $0) }
        }
        let strideValue = Double(sorted.count) / 180.0
        return (0..<180).map { index in point(for: sorted[Int(Double(index) * strideValue)]) }
    }

    private func point(for photo: PhotoItem) -> Point {
        Point(id: photo.id,
              coordinate: CLLocationCoordinate2D(latitude: photo.latitude ?? 0, longitude: photo.longitude ?? 0),
              date: photo.capturedAt,
              photo: photo)
    }

    private var playedPoints: [Point] {
        Array(points.prefix(min(step + 1, points.count)))
    }

    private var currentPoint: Point? {
        guard !points.isEmpty else { return nil }
        return points[min(step, points.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                header
                Divider()
                mapCanvas
                controls
            }
            .frame(maxWidth: 1000, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 34, y: 16)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
        }
        .onExitCommand { onClose() }
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled, stepsRemaining {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, playing else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = min(step + 1, points.count - 1)
                }
            }
            if !stepsRemaining { playing = false }
        }
    }

    private var stepsRemaining: Bool {
        step < max(0, points.count - 1)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("足迹回放")
                    .font(.system(size: 20, weight: .bold))
                Text(currentPoint.map { Self.monthFormatter.string(from: $0.date) } ?? "没有带位置的照片")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let current = currentPoint {
                PhotoThumbnailView(photo: current.photo, purpose: .preview(120))
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .help(current.photo.displayTitle)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - 地图

    private var mapCanvas: some View {
        Map(initialPosition: .region(PhotoMapRegion.region(for: photos)),
            interactionModes: [.pan, .zoom]) {
            if playedPoints.count > 1 {
                MapPolyline(coordinates: playedPoints.map(\.coordinate))
                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 2.5)
            }
            if let current = currentPoint {
                Annotation("", coordinate: current.coordinate, anchor: .center) {
                    VStack(spacing: 3) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 12, height: 12)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        Text(Self.dayFormatter.string(from: current.date))
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            MapCompass()
            MapZoomStepper()
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 控制条

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    if !stepsRemaining {
                        step = 0
                        playing = true
                    } else {
                        playing.toggle()
                    }
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.16), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(playing ? "暂停" : "播放")

                Slider(value: Binding(
                    get: { Double(step) },
                    set: { value in
                        playing = false
                        step = min(max(0, Int(value.rounded())), max(0, points.count - 1))
                    }
                ), in: 0...Double(max(1, points.count - 1)))
                .tint(Color.accentColor)
                .help("拖动查看某个时间点")

                Text("\(min(step + 1, points.count)) / \(points.count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)

                Picker("", selection: $interval) {
                    Text("慢").tag(0.45)
                    Text("中").tag(0.24)
                    Text("快").tag(0.12)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .help("回放速度")
            }

            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if let current = currentPoint {
                    Button("查看这张") {
                        store.openViewer(current.photo.id)
                        onClose()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .help("在查看器中打开当前站点")
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .padding(.top, 2)
    }

    private var summary: String {
        let places = Set(playedPoints.map { PlaceClusterBuilder.key(for: $0.photo).title })
        return "已走过 \(playedPoints.count) 个站点 · \(places.count) 个地点"
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter
    }()
}
