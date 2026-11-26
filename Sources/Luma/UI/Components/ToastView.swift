import SwiftUI

struct ToastView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    /// 轻量识别提示语义：失败类给橙色警告，其余给绿色完成。
    private var style: (icon: String, tint: Color) {
        let text = store.toast ?? ""
        let errorHints = ["失败", "无法", "请先", "错误", "不能", "找不到", "不支持", "已取消"]
        if errorHints.contains(where: { text.contains($0) }) {
            return ("exclamationmark.triangle.fill", .orange)
        }
        return ("checkmark.circle.fill", .green)
    }

    var body: some View {
        VStack {
            Spacer()
            if let toast = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: style.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(style.tint)
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .lumaGlassCapsule()
                .padding(.bottom, 84)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(settings.motion.overlay, value: store.toast)
        .allowsHitTesting(false)
    }
}
