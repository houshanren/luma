import AppKit
import SwiftUI

struct LibraryEntry: Identifiable {
    let id: String
    let url: URL
    let name: String
    let modifiedAt: Date?
    let isNative: Bool
    let isCurrent: Bool

    var title: String {
        var text = name
        if isCurrent { text += "（上次打开）" }
        if isNative { text += "（系统照片图库）" }
        return text
    }
}

/// 按住 Option 启动时弹出的图库选择器（对齐系统「照片」的选取图库）。
struct LibraryPickerView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var entries: [LibraryEntry] = []
    @State private var selection: String?

    private var selectedEntry: LibraryEntry? {
        entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text("选取图库")
                        .font(.system(size: 15, weight: .semibold))
                    Text("从列表中选取照片图库、在电脑上查找其他图库，或创建新图库。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有最近的图库")
                        .font(.system(size: 13, weight: .medium))
                    Text("点「其他图库…」选择一个 .photoslibrary，或新建一个图库。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 168)
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("图库名称") { entry in
                        Text(entry.title)
                    }
                    TableColumn("上次修改时间") { entry in
                        Text(Self.format(entry.modifiedAt))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 168)
            }

            HStack(spacing: 8) {
                Text(selectedEntry?.url.path ?? " ")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let url = selectedEntry?.url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示")
                }
            }

            HStack(spacing: 10) {
                Button("其他图库…") {
                    store.presentLibraryContainerPanel()
                }
                Text("按住 Option 启动可再次打开此面板")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("新建…") {
                    store.presentNewLibraryPanel()
                }
                Button("选取图库") {
                    choose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
        }
        .padding(20)
        .frame(width: 600, height: 400)
        .onAppear {
            reload()
        }
    }

    private func reload() {
        entries = store.knownLibraryEntries()
        if selection == nil || !entries.contains(where: { $0.id == selection }) {
            selection = entries.first { $0.isCurrent }?.id ?? entries.first?.id
        }
    }

    private func choose() {
        guard let entry = selectedEntry else { return }
        store.activateLibrary(entry.url)
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'今天' HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'昨天' HH:mm"
        } else {
            formatter.dateFormat = "yyyy/M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}
