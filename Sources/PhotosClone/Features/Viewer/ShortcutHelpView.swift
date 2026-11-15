import SwiftUI

struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var showsCloseButton = false

    private let gridShortcuts: [(String, String)] = [
        ("← → ↑ ↓", "移动选择"),
        ("空格 / 回车", "打开所选"),
        ("⌘A", "全选"),
        ("⌘C", "复制文件"),
        ("⌘V", "粘贴"),
        ("⌘D", "复制照片"),
        ("⌘R / ⌥⌘R", "向右 / 向左旋转"),
        ("⌘P", "打印"),
        ("⌥⌘P", "幻灯片播放"),
        ("⌘⌫", "移到最近删除（最近删除中为永久删除）"),
        ("⌥⌘⌫", "永久删除"),
        (".", "收藏 / 取消收藏"),
        ("⌘⇧H", "隐藏 / 取消隐藏"),
        ("⌘K", "添加关键词"),
        ("⌘F", "搜索"),
        ("⌘+ / ⌘- / ⌘0", "缩略图放大 / 缩小 / 默认"),
        ("⌘⇧R", "在访达中显示"),
        ("Esc", "取消选择")
    ]

    private let viewerShortcuts: [(String, String)] = [
        ("← → ↑ ↓", "上一张 / 下一张"),
        ("空格", "收起查看器，返回图库"),
        ("+ / - / 0", "放大 / 缩小 / 适应窗口"),
        ("双击", "以点击位置缩放"),
        ("I", "信息面板"),
        ("E", "编辑"),
        ("F", "全屏"),
        ("L", "播放实况照片"),
        (".", "收藏 / 取消收藏"),
        ("⌘R / ⌥⌘R", "向右 / 向左旋转"),
        ("⌘D", "复制照片"),
        ("⌘C / ⌘V", "复制文件 / 粘贴"),
        ("⌘P", "打印"),
        ("⌥⌘P", "幻灯片播放"),
        ("⌘⌫ / ⌥⌘⌫", "移到最近删除 / 永久删除"),
        ("Esc", "关闭查看器")
    ]

    private let editorShortcuts: [(String, String)] = [
        ("⌘Z", "撤销"),
        ("⇧⌘Z", "重做"),
        ("Esc", "关闭编辑器")
    ]

    private let slideshowShortcuts: [(String, String)] = [
        ("← / →", "上一张 / 下一张"),
        ("空格", "暂停 / 继续"),
        ("Esc", "退出幻灯片")
    ]

    private let videoShortcuts: [(String, String)] = [
        ("空格", "收起查看器，返回图库"),
        ("K", "播放 / 暂停"),
        ("← / →", "快退 / 快进 5 秒"),
        ("J / L", "快退 / 快进 10 秒"),
        ("⌘← / ⌘→", "上一个 / 下一个视频"),
        ("M", "静音"),
        ("F", "全屏"),
        ("A", "填充 / 适应画面"),
        (", / .", "上一帧 / 下一帧"),
        ("I", "信息面板"),
        (".", "收藏 / 取消收藏"),
        ("⌘⌫", "移到最近删除")
    ]

    private let fileShortcuts: [(String, String)] = [
        ("⌘I", "导入照片"),
        ("⌥⌘I", "从「照片」导入"),
        ("⌘O", "打开照片图库"),
        ("⌘E", "导出所选"),
        ("⌥⌘B", "批量更改所选"),
        ("⌥⌘C / ⌥⌘V", "复制 / 粘贴编辑点"),
        ("⌘⇧K", "压缩所选"),
        ("⇧⌘N", "新建相簿"),
        ("⌥⇧⌘N", "新建智能相簿"),
        ("⌥⌘N", "新建照片图库"),
        ("⌘/", "打开本快捷键面板")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("键盘快捷键")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if showsCloseButton {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("图库", rows: gridShortcuts)
                    section("照片查看器", rows: viewerShortcuts)
                    section("编辑器", rows: editorShortcuts)
                    section("视频播放", rows: videoShortcuts)
                    section("幻灯片", rows: slideshowShortcuts)
                    section("文件与相簿", rows: fileShortcuts)
                }
            }
            .frame(maxHeight: showsCloseButton ? 520 : 420)
        }
        .padding(16)
        .frame(width: showsCloseButton ? 400 : 330)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows.indices, id: \.self) { index in
                let key = rows[index].0
                let action = rows[index].1
                HStack(spacing: 10) {
                    Text(key)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        .frame(width: 96, alignment: .leading)
                    Text(action)
                        .font(.system(size: 11.5))
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
