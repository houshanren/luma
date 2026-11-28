import SwiftUI

/// 标签库的两级标尺：一级「分组」装进一条托盘，二级「具体标签」只用一条细线起头，
/// 两级形态不同，扫一眼就知道是先选大类、再挑具体标签。
struct CatalogTagLevelBand<Content: View>: View {
    let index: Int
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CatalogTagLevelHeader(index: index, title: title)
            CatalogFlowLayout(spacing: 6, lineSpacing: 6) { content() }
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
                }
        }
    }
}

/// 层级标尺头：序号徽章 + 名称 + 向右延伸的细线，两级共用以形成阶梯感。
struct CatalogTagLevelHeader: View {
    let index: Int
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14, height: 14)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
        .padding(.leading, 2)
    }
}
