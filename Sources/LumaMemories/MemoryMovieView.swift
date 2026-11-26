import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaContentCore
import LumaDomain

/// 全窗口回忆影片：Ken Burns 推进 + 交叉淡入淡出。
/// 宿主能力由 `MemoryHost` 注入，不直接依赖 App 的 `LibraryStore`。
package struct MemoryMovieView<Host: MemoryHost>: View {
    @EnvironmentObject private var host: Host

    package let memory: PhotoMemory

    package init(memory: PhotoMemory) {
        self.memory = memory
    }

    @State private var index = 0
    @State private var isPlaying = true
    @State private var progress: Double = 0
    @State private var images: [Int: NSImage] = [:]
    @State private var keyMonitor: Any?
    @State private var kenBurnsScale: CGFloat = 1
    @State private var kenBurnsOffset: CGSize = .zero
    @State private var style: MemoryStyle = .classic
    @State private var isExporting = false
    @State private var exportProgress: Double = 0

    private let slideDuration: Double = 4.0
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var photos: [PhotoItem] { memory.photos }
    private var current: PhotoItem? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    package var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = images[index] {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(kenBurnsScale)
                        .offset(kenBurnsOffset)
                        .clipped()
                }
                .ignoresSafeArea()
                .id(index)
                .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            if style.showsLetterbox {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Color.black.frame(height: proxy.size.height * 0.09)
                        Spacer(minLength: 0)
                        Color.black.frame(height: proxy.size.height * 0.09)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(20)

            if isExporting {
                exportOverlay
            }
        }
        .onAppear {
            style = memory.style
            preload(after: 0)
            loadImage(at: 0)
            startKenBurns()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onReceive(timer) { _ in
            guard isPlaying, !isExporting else { return }
            progress += 0.05 / slideDuration
            if progress >= 1 {
                advance(1)
            }
        }
        .onChange(of: index) { _, newValue in
            loadImage(at: newValue)
            preload(after: newValue)
            startKenBurns()
        }
    }

    private var exportOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: exportProgress)
                .frame(width: 240)
                .tint(.white)
            Text("正在导出回忆影片… \(Int(exportProgress * 100))%")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
            Text("导出期间请保持窗口打开")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
    }

    /// 按当前风格推进 Ken Burns，切换风格或换页都会重新开始这一段动画。
    private func startKenBurns() {
        let range = style.zoomRange
        kenBurnsScale = range.start
        kenBurnsOffset = .zero
        let horizontal: CGFloat = index % 2 == 0 ? 1 : -1
        let vertical: CGFloat = index % 4 < 2 ? 1 : -1
        let travel = style.panAmount * 900
        withAnimation(.easeInOut(duration: slideDuration)) {
            kenBurnsScale = range.end
            kenBurnsOffset = CGSize(width: horizontal * travel, height: vertical * travel * 0.5)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text(memory.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()

            Menu {
                ForEach(MemoryStyle.allCases) { option in
                    Button {
                        style = option
                        startKenBurns()
                    } label: {
                        if option == style {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Label(option.title, systemImage: option.icon)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: style.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(style.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("回忆风格")

            Button {
                exportMovie()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isExporting)
            .help("导出为视频…")

            Button {
                host.activeMemory = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.16), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isExporting)
            .help("退出回忆 (Esc)")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: max(0, proxy.size.width * min(1, progress)))
                }
            }
            .frame(height: 3)

            HStack(spacing: 18) {
                controlButton("backward.end.fill", help: "上一张 (←)") { advance(-1) }
                controlButton(isPlaying ? "pause.fill" : "play.fill",
                              help: isPlaying ? "暂停 (空格)" : "播放 (空格)") {
                    isPlaying.toggle()
                }
                controlButton("forward.end.fill", help: "下一张 (→)") { advance(1) }
                Spacer()
                if !photos.isEmpty {
                    Text("\(min(index + 1, photos.count)) / \(photos.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .disabled(isExporting)
    }

    /// 把当前回忆渲染为无声 mp4，尺寸 1280×720、24fps。
    private func exportMovie() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = memory.title + ".mp4"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let wasPlaying = isPlaying
        isPlaying = false
        isExporting = true
        exportProgress = 0
        // 渲染 + 编码是分钟级任务：登记到统一任务中心，导出期间切页也能看到进度。
        let jobID = host.beginSourceJob(
            SourceJob(sourceID: .library(host.memoryJobPath),
                      kind: .export,
                      title: "导出回忆影片",
                      isCancellable: false),
            cancel: nil
        )

        let snapshot = memory
        let chosenStyle = style
        Task {
            do {
                try await MemoryExporter.export(memory: snapshot, style: chosenStyle, to: url) { value in
                    Task { @MainActor in
                        exportProgress = value
                        host.updateSourceJob(jobID,
                                             completed: nil,
                                             total: nil,
                                             message: "正在导出 \(Int((value * 100).rounded()))%",
                                             fraction: value)
                    }
                }
                await MainActor.run {
                    isExporting = false
                    isPlaying = wasPlaying
                    host.finishSourceJob(jobID, message: "已导出 \(url.lastPathComponent)")
                    host.showToast("已导出「\(url.lastPathComponent)」")
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    isPlaying = wasPlaying
                    host.failSourceJob(jobID, message: error.localizedDescription)
                    host.showToast("导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func controlButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.12), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func advance(_ delta: Int) {
        guard !photos.isEmpty else { return }
        progress = 0
        withAnimation(.easeInOut(duration: 0.6)) {
            index = (index + delta + photos.count) % photos.count
        }
    }

    private func loadImage(at position: Int) {
        guard images[position] == nil, photos.indices.contains(position) else { return }
        let photo = photos[position]
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                MemoryFrameLoader.image(for: photo, maxPixel: 2600)
            }.value
            if let loaded {
                images[position] = loaded
            }
        }
    }

    private func preload(after position: Int) {
        guard !photos.isEmpty else { return }
        let next = (position + 1) % photos.count
        loadImage(at: next)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = NSApp.keyWindow, event.window === window else { return event }
            guard window.attachedSheet == nil else { return event }
            // 导出期间不响应快捷键，避免误关窗口打断写入。
            if isExporting { return nil }

            if event.keyCode == 53 {
                host.activeMemory = nil
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.contains(.command), flags.intersection([.option, .control]).isEmpty else {
                return event
            }
            switch event.keyCode {
            case 123, 126:
                advance(-1)
                return nil
            case 124, 125:
                advance(1)
                return nil
            case 49:
                isPlaying.toggle()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
