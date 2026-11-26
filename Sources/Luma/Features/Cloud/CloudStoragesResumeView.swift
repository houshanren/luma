import SwiftUI
import AppKit
import Foundation
import LumaContentCore

// MARK: - 续播页

/// 续播页：跨存储汇总未看完的视频，按最近观看排序；底部保留刚看完的记录。
struct CloudStoragesResumeView: View {
    @Environment(LibraryStore.self) var store

    var continueRecords: [CinemaProgressRecord] { store.cloudMountContinueRecords }
    var finishedRecords: [CinemaProgressRecord] { Array(store.cloudMountFinishedRecords.prefix(6)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if continueRecords.isEmpty {
                    LumaEmptyState(symbol: "play.circle",
                                   title: "还没有未看完的视频",
                                   message: "在任意网盘的影院里播放视频后，进度会出现在这里，可以直接接着看。",
                                   style: .card)
                } else {
                    CloudHubPanel(spacing: 0) {
                        ForEach(continueRecords.indices, id: \.self) { index in
                            resumeRow(continueRecords[index])
                            if index < continueRecords.count - 1 {
                                Divider().opacity(0.35).padding(.leading, 142)
                            }
                        }
                    }
                }

                if !finishedRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LumaBrand.mint)
                            Text("最近看完")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(store.cloudMountFinishedRecords.count) 条")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        CloudHubPanel(spacing: 0) {
                            ForEach(finishedRecords.indices, id: \.self) { index in
                                finishedRow(finishedRecords[index])
                                if index < finishedRecords.count - 1 {
                                    Divider().opacity(0.35).padding(.leading, 112)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func resumeRow(_ record: CinemaProgressRecord) -> some View {
        let mountName = mountName(for: record)
        return HStack(alignment: .center, spacing: 16) {
            // 刮削封面优先取横版剧照（backdrop），按 16:10 裁切才不会把人像挤没。
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 9)
                .frame(width: 108, height: 66)

            VStack(alignment: .leading, spacing: 8) {
                Text(record.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.quaternary)
                    }
                    Text(mountName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                CloudHubProgressBar(fraction: record.fraction, tint: LumaBrand.coral)
                    .frame(maxWidth: 360)
                HStack(spacing: 7) {
                    Text(CloudHubFormat.remaining(record.remainingSeconds))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(Int((record.fraction * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumaBrand.coral)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text(CloudHubFormat.relative(record.updatedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 16)

            CloudHubCapsuleButton(title: "继续观看", symbol: "play.fill",
                                  tint: LumaBrand.coral, prominent: true) {
                resume(record)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { resume(record) }
        .contextMenu {
            Button("继续观看") { resume(record) }
            if let mountID = record.mountID {
                Button("打开这个存储的影院") {
                    store.activateCinemaScope(.mount(mountID))
                    store.navigate(to: .cloudCinema(mountID))
                }
            }
        }
    }

    func finishedRow(_ record: CinemaProgressRecord) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 7)
                .frame(width: 80, height: 50)
                .opacity(0.72)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(mountName(for: record))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text("看完于 \(CloudHubFormat.relative(record.updatedAt))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 16)
            CloudHubTag(text: "已看完", tint: LumaBrand.mint)
            CloudHubCapsuleButton(title: "重看", symbol: "arrow.counterclockwise",
                                  tint: LumaBrand.mint) {
                resume(record)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return store.cloudMounts.first { $0.id == mountID }?.name ?? "网络存储"
    }

    func resume(_ record: CinemaProgressRecord) {
        guard let mountID = record.mountID else { return }
        store.activateCinemaScope(.mount(mountID))
        if let entry = store.cinemaIndexes[.mount(mountID)]?[record.photoID] {
            store.openCinema(entry)
        } else {
            // 刮削索引被清掉时仍能回到该网盘影院，续播记录不会丢。
            store.navigate(to: .cloudCinema(mountID))
        }
    }
}
