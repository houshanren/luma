import SwiftUI
import CoreImage

struct EditState: Equatable, Codable {
    var rotation: Int = 0
    var flipH = false
    var flipV = false
    var crop = EditState.fullCrop
    var aspect: CropAspect = .original
    var filter: FilterPreset = .none
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    var vignette: Double = 0
    var noiseReduction: Double = 0
    var autoEnhance = false

    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    var isModified: Bool {
        rotation != 0 || flipH || flipV || crop != EditState.fullCrop || filter != .none
            || exposure != 0 || brightness != 0 || contrast != 0 || saturation != 0
            || highlights != 0 || shadows != 0 || warmth != 0 || tint != 0
            || sharpness != 0 || vignette != 0 || noiseReduction != 0 || autoEnhance
    }

    func cropless() -> EditState {
        var copy = self
        copy.crop = EditState.fullCrop
        return copy
    }
}

extension EditState {
    /// 序列化为 JSON，供复制/粘贴编辑点与再次打开编辑器时恢复。
    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EditState.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

enum EditTool: String, CaseIterable, Identifiable {
    case adjust = "调整"
    case filters = "滤镜"
    case crop = "裁剪"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .filters: return "camera.filters"
        case .crop: return "crop"
        }
    }
}

enum PhotoRenderer {
    private static let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    static func loadBase(url: URL) -> CIImage? {
        if RawFormats.isRaw(url) {
            if let image = RawFormats.ciImage(url: url, maxPixel: 8000) {
                return normalized(image)
            }
        }
        let options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .cacheImmediately: true
        ]
        guard let image = CIImage(contentsOf: url, options: options) else { return nil }
        return normalized(image)
    }

    static func normalized(_ image: CIImage) -> CIImage {
        let extent = image.extent
        if extent.origin != .zero {
            return image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                           y: -extent.origin.y))
        }
        return image
    }

    static func render(base: CIImage, state: EditState, maxPixel: CGFloat?) -> NSImage? {
        guard let cgImage = renderCG(base: base, state: state, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func renderCG(base: CIImage, state: EditState, maxPixel: CGFloat?) -> CGImage? {
        var ci = base

        let steps = (((state.rotation % 360) + 360) % 360) / 90
        if steps != 0 {
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(steps) * .pi / 2))
            ci = normalized(ci)
        }
        if state.flipH {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            ci = normalized(ci)
        }
        if state.flipV {
            ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            ci = normalized(ci)
        }

        if state.noiseReduction > 0 {
            ci = ci.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.01 + state.noiseReduction * 0.08,
                "inputSharpness": 0.4
            ])
        }
        if state.autoEnhance {
            for filter in ci.autoAdjustmentFilters() {
                filter.setValue(ci, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    ci = output
                }
            }
        }
        if state.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: state.exposure])
        }
        if state.highlights != 0 || state.shadows != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": min(1, max(0, 1 - state.highlights)),
                "inputShadowAmount": min(1, max(-1, state.shadows))
            ])
        }
        if state.warmth != 0 || state.tint != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + state.warmth * 2600, y: state.tint * 120)
            ])
        }
        if state.brightness != 0 || state.contrast != 0 || state.saturation != 0 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: state.brightness,
                kCIInputContrastKey: 1 + state.contrast,
                kCIInputSaturationKey: 1 + state.saturation
            ])
        }
        if state.sharpness > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: state.sharpness * 1.2
            ])
        }
        if let filterName = state.filter.ciName {
            ci = ci.applyingFilter(filterName)
        }
        if state.vignette != 0 {
            ci = ci.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: state.vignette * 1.6,
                kCIInputRadiusKey: 1.6
            ])
        }

        let extent = ci.extent
        if state.crop != EditState.fullCrop {
            let rect = CGRect(
                x: extent.minX + state.crop.minX * extent.width,
                y: extent.minY + (1 - state.crop.maxY) * extent.height,
                width: max(1, state.crop.width * extent.width),
                height: max(1, state.crop.height * extent.height)
            ).integral
            ci = ci.cropped(to: rect)
            ci = normalized(ci)
        }

        if let maxPixel {
            let width = ci.extent.width
            let height = ci.extent.height
            let scale = min(1, maxPixel / max(width, height))
            if scale < 1 {
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                ci = normalized(ci)
            }
        }

        return context.createCGImage(ci, from: ci.extent)
    }
}

struct PhotoEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: PhotoItem

    @State private var state = EditState()
    @State private var tool: EditTool = .adjust
    @State private var baseCI: CIImage?
    @State private var basePixelSize: CGSize = .zero
    @State private var preview: NSImage?
    @State private var filterThumbs: [FilterPreset: NSImage] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var dragStartCrop: CGRect?

    // 撤销 / 重做：连续拖动滑块会被合并为一步。
    @State private var history: [EditState] = []
    @State private var redoStack: [EditState] = []
    @State private var pendingSnapshot: EditState?
    @State private var historyTask: Task<Void, Never>?
    @State private var suppressHistory = false
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    previewArea
                    controlPanel
                        .frame(width: 292)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            await load()
        }
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            historyTask?.cancel()
            historyTask = nil
        }
        .onChange(of: state) { oldValue, newValue in
            let suppressed = suppressHistory
            suppressHistory = false

            if tool == .crop {
                var oldAdjusted = oldValue
                oldAdjusted.crop = EditState.fullCrop
                var newAdjusted = newValue
                newAdjusted.crop = EditState.fullCrop
                if oldAdjusted != newAdjusted {
                    refreshPreview()
                }
            } else {
                refreshPreview()
            }

            if !suppressed {
                scheduleHistory(oldValue)
            }
        }
        .onChange(of: tool) { _, _ in
            refreshPreview()
        }
    }

    private var canUndo: Bool { !history.isEmpty || pendingSnapshot != nil }
    private var canRedo: Bool { !redoStack.isEmpty }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("取消") {
                store.closeEditor()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)

            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canUndo ? Color.primary : Color.secondary.opacity(0.45))
            .disabled(!canUndo)
            .help("撤销 (⌘Z)")

            Button {
                redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canRedo ? Color.primary : Color.secondary.opacity(0.45))
            .disabled(!canRedo)
            .help("重做 (⇧⌘Z)")

            Menu {
                Button("复制编辑点") {
                    guard let json = state.jsonString else { return }
                    store.copiedEditRecipe = json
                    store.showToast("已复制编辑点")
                }
                .disabled(!state.isModified)

                Button("粘贴编辑点") {
                    guard let recipe = store.copiedEditRecipe,
                          let pasted = EditState(jsonString: recipe) else { return }
                    historyTask?.cancel()
                    commitPendingHistory()
                    history.append(state)
                    redoStack.removeAll()
                    apply(pasted)
                    store.showToast("已粘贴编辑点")
                }
                .disabled(store.copiedEditRecipe == nil)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("复制 / 粘贴编辑点")

            Spacer()

            Text("编辑")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button("还原") {
                resetAll()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .disabled(!state.isModified && !photo.hasEdits)

            Button {
                save()
            } label: {
                Text(isSaving ? "存储中…" : "完成")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(baseCI == nil || isSaving)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var previewArea: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(tool == .crop ? 1 : 1)

                    if tool == .crop {
                        cropOverlay(container: proxy.size)
                    }
                } else {
                    Text("无法载入照片")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(24)
    }

    private func cropOverlay(container: CGSize) -> some View {
        let imageSize = preview?.size ?? CGSize(width: 1, height: 1)
        let fit = fitRect(imageSize: imageSize, in: container)
        let cropRect = CGRect(
            x: fit.minX + state.crop.minX * fit.width,
            y: fit.minY + state.crop.minY * fit.height,
            width: state.crop.width * fit.width,
            height: state.crop.height * fit.height
        )

        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: container))
                path.addRect(cropRect)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                let thirdW = cropRect.width / 3
                let thirdH = cropRect.height / 3
                for index in 1...2 {
                    let x = cropRect.minX + thirdW * CGFloat(index)
                    path.move(to: CGPoint(x: x, y: cropRect.minY))
                    path.addLine(to: CGPoint(x: x, y: cropRect.maxY))
                    let y = cropRect.minY + thirdH * CGFloat(index)
                    path.move(to: CGPoint(x: cropRect.minX, y: y))
                    path.addLine(to: CGPoint(x: cropRect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: cropRect.width, height: cropRect.height)
                .contentShape(Rectangle())
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartCrop ?? state.crop
                            if dragStartCrop == nil { dragStartCrop = start }
                            let dx = value.translation.width / max(1, fit.width)
                            let dy = value.translation.height / max(1, fit.height)
                            let newX = min(max(0, start.minX + dx), 1 - start.width)
                            let newY = min(max(0, start.minY + dy), 1 - start.height)
                            state.crop = CGRect(x: newX, y: newY, width: start.width, height: start.height)
                        }
                        .onEnded { _ in
                            dragStartCrop = nil
                        }
                )
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tool) {
                ForEach(EditTool.allCases) { tool in
                    Text(tool.rawValue).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            Divider()

            ScrollView {
                Group {
                    switch tool {
                    case .adjust: adjustControls
                    case .filters: filterControls
                    case .crop: cropControls
                    }
                }
                .padding(16)
            }

            Divider()

            VStack(spacing: 6) {
                if photo.hasEdits {
                    Button("还原为原始照片") {
                        resetAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Text("完成时会存储修改后的副本")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    private var adjustControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            adjustSlider("曝光", value: $state.exposure, range: -2...2)
            adjustSlider("亮度", value: $state.brightness, range: -0.5...0.5)
            adjustSlider("对比度", value: $state.contrast, range: -0.5...0.5)
            adjustSlider("饱和度", value: $state.saturation, range: -1...1)
            adjustSlider("高光", value: $state.highlights, range: -1...1)
            adjustSlider("阴影", value: $state.shadows, range: -1...1)
            adjustSlider("色温", value: $state.warmth, range: -1...1)
            adjustSlider("色调", value: $state.tint, range: -1...1)
            adjustSlider("锐化", value: $state.sharpness, range: 0...1)
            adjustSlider("降噪", value: $state.noiseReduction, range: 0...1)
            adjustSlider("晕影", value: $state.vignette, range: -1...1)

            Toggle("自动增强", isOn: $state.autoEnhance)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))

            Button("恢复默认调整") {
                state.exposure = 0
                state.brightness = 0
                state.contrast = 0
                state.saturation = 0
                state.highlights = 0
                state.shadows = 0
                state.warmth = 0
                state.tint = 0
                state.sharpness = 0
                state.noiseReduction = 0
                state.vignette = 0
                state.autoEnhance = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)
        }
    }

    private func adjustSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private var filterControls: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
            ForEach(FilterPreset.allCases) { preset in
                Button {
                    state.filter = preset
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.08))
                            if let thumb = filterThumbs[preset] {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if state.filter == preset {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        Text(preset.title)
                            .font(.system(size: 11))
                            .foregroundStyle(state.filter == preset ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("比例")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(CropAspect.allCases) { aspect in
                    Button {
                        applyAspect(aspect)
                    } label: {
                        Text(aspect.title)
                            .font(.system(size: 11.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(state.aspect == aspect ? Color.accentColor : Color.primary.opacity(0.08))
                            )
                            .foregroundStyle(state.aspect == aspect ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("拖动取景框可调整位置")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            Divider()

            HStack(spacing: 10) {
                transformButton("rotate.left") { rotate(-90) }
                transformButton("rotate.right") { rotate(90) }
                transformButton("arrow.left.and.right.righttriangle.left.righttriangle.right") { state.flipH.toggle() }
                transformButton("arrow.up.and.down.righttriangle.up.righttriangle.down") { state.flipV.toggle() }
                Spacer()
            }

            Button("重置裁剪与旋转") {
                state.rotation = 0
                state.flipH = false
                state.flipV = false
                state.aspect = .original
                state.crop = EditState.fullCrop
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)
        }
    }

    private func transformButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func fitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2,
                      width: width, height: height)
    }

    private var orientedBaseSize: CGSize {
        let rotated = ((state.rotation % 360) + 360) % 360
        if rotated == 90 || rotated == 270 {
            return CGSize(width: basePixelSize.height, height: basePixelSize.width)
        }
        return basePixelSize
    }

    private func applyAspect(_ aspect: CropAspect) {
        state.aspect = aspect
        guard let ratio = aspect.ratio else {
            state.crop = EditState.fullCrop
            return
        }
        let size = orientedBaseSize
        guard size.width > 0, size.height > 0 else { return }
        let imageRatio = size.width / size.height
        var width: CGFloat = 1
        var height: CGFloat = 1
        if ratio > imageRatio {
            height = imageRatio / ratio
        } else {
            width = ratio / imageRatio
        }
        width = min(1, max(0.05, width))
        height = min(1, max(0.05, height))
        state.crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func rotate(_ degrees: Int) {
        state.rotation = (state.rotation + degrees + 360) % 360
        state.aspect = .original
        state.crop = EditState.fullCrop
    }

    // MARK: - 撤销 / 重做

    private func scheduleHistory(_ snapshot: EditState) {
        if pendingSnapshot == nil {
            pendingSnapshot = snapshot
        }
        historyTask?.cancel()
        historyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            commitPendingHistory()
        }
    }

    private func commitPendingHistory() {
        defer { pendingSnapshot = nil }
        guard let pending = pendingSnapshot, pending != state else { return }
        history.append(pending)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
        redoStack.removeAll()
    }

    private func undo() {
        historyTask?.cancel()
        historyTask = nil
        commitPendingHistory()
        guard let previous = history.popLast() else { return }
        redoStack.append(state)
        apply(previous)
    }

    private func redo() {
        historyTask?.cancel()
        historyTask = nil
        pendingSnapshot = nil
        guard let next = redoStack.popLast() else { return }
        history.append(state)
        apply(next)
    }

    private func apply(_ newState: EditState) {
        guard newState != state else { return }
        suppressHistory = true
        state = newState
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = NSApp.keyWindow, event.window === window else { return event }
            guard window.attachedSheet == nil else { return event }
            guard store.editorID == photo.id else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }

            if flags.contains(.shift) {
                redo()
            } else {
                undo()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func load() async {
        isLoading = true
        // 有编辑配方时从原图重建，保证再次编辑是非破坏性的。
        let recipe = photo.editRecipe
        let useOriginal = photo.hasEdits && recipe != nil
        let url = useOriginal ? LibraryPaths.originalURL(for: photo) : LibraryPaths.sourceURL(for: photo)
        guard let ci = PhotoRenderer.loadBase(url: url) else {
            isLoading = false
            preview = nil
            return
        }
        var initial = EditState()
        if let recipe, let restored = EditState(jsonString: recipe) {
            initial = restored
        } else if !photo.hasEdits {
            // 原图可能带非破坏性旋转；编辑渲染结果本身已经是正向的。
            initial.rotation = photo.rotationAngle
        }
        if initial != state {
            suppressHistory = true
        }
        state = initial
        history.removeAll()
        redoStack.removeAll()
        pendingSnapshot = nil
        baseCI = ci
        basePixelSize = CGSize(width: ci.extent.width, height: ci.extent.height)
        preview = PhotoRenderer.render(base: ci, state: state.cropless(), maxPixel: 1600)
        buildFilterThumbs(base: ci)
        isLoading = false
    }

    private func buildFilterThumbs(base: CIImage) {
        let maxSide = max(base.extent.width, base.extent.height)
        guard maxSide > 0 else { return }
        let scale = 160 / maxSide
        let small = PhotoRenderer.normalized(base.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        var thumbs: [FilterPreset: NSImage] = [:]
        for preset in FilterPreset.allCases {
            var smallState = EditState()
            smallState.filter = preset
            if let image = PhotoRenderer.render(base: small, state: smallState, maxPixel: nil) {
                thumbs[preset] = image
            }
        }
        filterThumbs = thumbs
    }

    private func refreshPreview() {
        guard let baseCI else { return }
        let renderState = tool == .crop ? state.cropless() : state
        preview = PhotoRenderer.render(base: baseCI, state: renderState, maxPixel: 1600)
    }

    private func resetAll() {
        if photo.hasEdits {
            history.removeAll()
            redoStack.removeAll()
            pendingSnapshot = nil
            store.revertEdits(photo.id)
            if EditState() != state {
                suppressHistory = true
            }
            state = EditState()
            Task { await load() }
        } else {
            var reset = EditState()
            reset.rotation = photo.rotationAngle
            guard reset != state else { return }
            history.append(state)
            redoStack.removeAll()
            apply(reset)
        }
    }

    private func save() {
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
            store.commitEditedImage(photoID: photo.id,
                                    jpegData: data,
                                    pixelWidth: rendered.width,
                                    pixelHeight: rendered.height,
                                    recipe: renderState.jsonString)
            isSaving = false
        }
    }

    private func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
    }
}
