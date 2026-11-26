import SwiftUI
import CoreImage
import LumaCore
import AppKit
import UniformTypeIdentifiers

extension PhotoEditorView {
    // MARK: - 智能美化

    var beautyControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isBeautifying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在分析画面…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let advice = beautyAdvice {
                if advice.isEmpty {
                    Label("画面已经比较均衡", systemImage: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                            Text("建议")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(advice.reasons, id: \.self) { reason in
                            Text("• \(reason)")
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    adjustSlider("强度", value: $beautyStrength, range: 0.2...1.5)

                    HStack(spacing: 10) {
                        Button(beautyBase == nil ? "应用美化" : "重新应用") {
                            applyBeauty()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if beautyBase != nil {
                            Button("撤销美化") { undoBeauty() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                }
            } else {
                Text("无法分析这张照片")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                analyzeBeauty()
            } label: {
                Label("重新分析画面", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(isBeautifying || baseCI == nil)

            Text("分析只读取缩略图，全部在本机完成；美化结果保存为副本，原图不受影响。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 用当前画面（含已有调整、不含裁剪）渲染一张 512px 预览来分析。
    func analyzeBeauty() {
        guard let baseCI, !isBeautifying else { return }
        isBeautifying = true
        let renderState = state.cropless()
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: baseCI, state: renderState, maxPixel: 512)
            }.value
            var advice: BeautyAdvice?
            if let image {
                advice = await Task.detached(priority: .userInitiated) {
                    PhotoBeauty.advice(image: image)
                }.value
            }
            beautyAdvice = advice
            isBeautifying = false
        }
    }

    func applyBeauty() {
        guard let advice = beautyAdvice, !advice.isEmpty else { return }
        historyTask?.cancel()
        commitPendingHistory()
        if beautyBase == nil {
            beautyBase = state
        }
        history.append(state)
        redoStack.removeAll()
        let base = beautyBase ?? state
        apply(EditState.beautified(base, advice: advice, strength: beautyStrength))
    }

    func undoBeauty() {
        guard let base = beautyBase else { return }
        history.append(state)
        redoStack.removeAll()
        beautyBase = nil
        beautyStrength = 1
        apply(base)
    }

    func save() {
        guard let baseCI, !isSaving else { return }
        guard state.isModified else {
            store.closeEditor()
            return
        }
        isSaving = true
        let renderState = state
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: baseCI, state: renderState, maxPixel: nil)
            }.value
            guard let rendered,
                  let data = jpegData(from: rendered) else {
                isSaving = false
                store.showToast("保存失败")
                return
            }
            if photo.isSystem {
                // 系统照片：整帧作为非破坏性调整写回「照片」。
                store.saveSystemEdit(photoID: photo.id, jpegData: data)
                isSaving = false
                return
            }
            store.commitEditedImage(photoID: photo.id,
                                    jpegData: data,
                                    pixelWidth: rendered.width,
                                    pixelHeight: rendered.height,
                                    recipe: renderState.jsonString)
            isSaving = false
        }
    }

    func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
    }
}
