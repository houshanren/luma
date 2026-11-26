import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

extension PhotoViewerView {
    // MARK: - 画面角标

    /// RAW 照片的画面角标：与「人像」「实况」同一套深色胶囊。
    var rawBadge: some View {
        Text("RAW")
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Color.black.opacity(0.38), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
            }
            .allowsHitTesting(false)
    }

    /// 已命名人物：一行小胶囊打在照片上，超过 3 人折叠成 +N。
    func personNameRow(_ names: [PhotoPersonName]) -> some View {
        HStack(spacing: 5) {
            ForEach(names.prefix(3)) { person in
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(person.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.38), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
                }
            }
            if names.count > 3 {
                Text("+\(names.count - 3)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.38), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
                    }
            }
        }
        .allowsHitTesting(false)
    }

    /// 连拍「进行选择…」：与官方「照片」一致，贴在照片左上角的深色胶囊。
    var burstSelectBadge: some View {
        Button {
            beginBurstSelection()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("进行选择…")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.45), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: LumaControlMetrics.hairline)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("进行选择…")
    }

    /// 实况照片的画面角标：与「人像」同一套深色胶囊，点击即原位播放。
    var liveStageBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: livePlaying ? "pause.fill" : "livephoto.play")
                .font(.system(size: 9.5, weight: .semibold))
            Text("实况")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.black.opacity(0.38), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
        }
    }

    /// 人像照片的角标，与系统「照片」一致：画面左上角的「人像」胶囊。
    var portraitBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Color.white.opacity(0.18), in: Circle())
            Text("人像")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.38), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: LumaControlMetrics.hairline)
        }
    }

    /// 带定位信息的照片：右上角地图图钉，点击打开信息面板查看地点与地图。
    var locationBadge: some View {
        Button {
            withAnimation(settings.motion.overlay) { viewer.showInfoPanel = true }
        } label: {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 26)
                .background(Color.black.opacity(0.38),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help("查看位置信息")
        .accessibilityLabel("查看位置信息")
    }
}
