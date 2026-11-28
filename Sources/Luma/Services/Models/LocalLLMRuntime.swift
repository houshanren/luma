import AppKit
import Combine
import Foundation

/// 本地语言模型的「一键装好」流程。
///
/// 点开关后会依次：下载 Ollama 运行时 → 解压到应用目录 → 启动本机服务
/// → 从国内镜像（ModelScope）下载 GGUF → `ollama create` 注册成模型 → 接入 AI 配置。
/// 全程不需要管理员权限，也不依赖用户预先装过 Ollama。
@MainActor
final class LocalLLMRuntime: ObservableObject {
    enum Stage: Equatable {
        case idle
        case checking
        case downloadingRuntime
        case installingRuntime
        case downloadingModel
        case creatingModel
        case startingServer
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloadingRuntime, .installingRuntime, .downloadingModel,
                 .creatingModel, .startingServer:
                return true
            case .idle, .ready, .failed:
                return false
            }
        }
    }

    /// 模型的一个分文件：视觉模型除了语言部分，还要下 `mmproj` 投影器。
    struct ModelFile: Hashable {
        /// 下载到 `.downloads` 下使用的文件名。
        let file: String
        let bytes: Int64
        /// 下载源：按顺序尝试，分片下载时会在多个源之间轮换。
        let urls: [URL]
    }

    struct ModelOption: Identifiable, Hashable {
        /// Ollama 里的模型标签。
        let id: String
        let title: String
        let detail: String
        /// 第一个是语言模型，可选的第二个是视觉投影器（mmproj）。
        let files: [ModelFile]
        /// 视觉模型必须沿用 GGUF 自带的对话模板，否则图片 token 不会被正确拼进提示词。
        let usesBuiltinTemplate: Bool
        /// 注册到 Ollama 的参数（全局默认 + 该模型自己的覆盖）。
        let parameters: [String: Double]
        /// 什么时候该选这一档（来自配置文件，设置页悬浮提示用）。
        let whenToUse: String
        /// 速度与内存占用的简短说明。
        let speed: String
        let memory: String

        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

        var supportsVision: Bool { files.count > 1 }

        var parameterLines: [String] {
            parameters
                .sorted { $0.key < $1.key }
                .map { "PARAMETER \($0.key) \(LocalLLMRuntime.parameterText($0.value))" }
        }

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// `Resources/Models/local-llm.json` 的映射：换镜像、升级 Ollama、增删模型档位
    /// 都只改这个文件，不需要重新编译。
    private struct SourceConfig: Decodable {
        struct Runtime: Decodable {
            let release: String
            let bytes: Int64
            let urls: [String]
        }

        struct Model: Decodable {
            struct File: Decodable {
                let file: String
                let bytes: Int64
                let urls: [String]
            }

            let id: String
            let title: String
            let detail: String
            /// 适用场景 / 速度 / 内存：只影响界面提示，不影响注册参数。
            let when: String?
            let speed: String?
            let memory: String?
            /// `builtin` 表示用 GGUF 自带的对话模板（视觉模型必须），默认用内置 ChatML。
            let template: String?
            /// 单模型覆盖全局参数，比如 8B 用更小的 num_ctx 换内存。
            let parameters: [String: Double]?
            let files: [File]
        }

        let runtime: Runtime
        let models: [Model]
        let defaultModel: String?
        /// 写进 Modelfile 的 PARAMETER，键名与 Ollama 一致（num_ctx / temperature 等）。
        let parameters: [String: Double]?
    }

    enum RuntimeError: LocalizedError {
        case downloadFailed
        case runtimeIncomplete
        case serverTimeout
        case commandFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "运行时分片下载失败"
            case .runtimeIncomplete: return "运行时解压后缺少 ollama 可执行文件"
            case .serverTimeout: return "本地服务启动超时"
            case .commandFailed(let message): return message
            case .timeout: return "操作超时，请重试"
            }
        }
    }

    static let shared = LocalLLMRuntime()

    static let serverPort = 11434
    static var baseURLString: String { "http://127.0.0.1:\(serverPort)/v1" }

    /// 下载源配置，随 App 分发在 `Resources/Models/local-llm.json`。
    private static let sourceConfig = loadSourceConfig()

    /// 运行时固定版本：清单里的体积要和这个包一致，分片下载才能校验。
    static var runtimeRelease: String { sourceConfig.runtime.release }
    static var runtimeURLs: [URL] { sourceConfig.runtime.urls.compactMap { URL(string: $0) } }
    static var runtimeBytes: Int64 { sourceConfig.runtime.bytes }

    /// Luma 的日常用法：整库上下文 + 80 多个工具定义，一次请求常常一两万 token。
    /// Ollama 默认 num_ctx 只有 4096，不改就会直接报 context size 不够。
    private static let defaultParameters: [String: Double] = [
        "num_ctx": 32768,
        "num_predict": 2048,
        "temperature": 0.7,
        "top_p": 0.8,
        "top_k": 20
    ]

    static let options: [ModelOption] = modelOptions(sourceConfig)

    private static func modelOptions(_ config: SourceConfig) -> [ModelOption] {
        let base = config.parameters ?? defaultParameters
        return config.models.compactMap { model in
            let files = model.files.compactMap { file -> ModelFile? in
                let urls = file.urls.compactMap { URL(string: $0) }
                guard !urls.isEmpty, file.bytes > 0, !file.file.isEmpty else { return nil }
                return ModelFile(file: file.file, bytes: file.bytes, urls: urls)
            }
            guard !files.isEmpty, !model.id.isEmpty else { return nil }
            let parameters = base.merging(model.parameters ?? [:]) { _, override in override }
            return ModelOption(id: model.id,
                               title: model.title,
                               detail: model.detail,
                               files: files,
                               usesBuiltinTemplate: model.template == "builtin",
                               parameters: parameters,
                               whenToUse: model.when ?? model.detail,
                               speed: model.speed ?? "",
                               memory: model.memory ?? "")
        }
    }

    private static func loadSourceConfig() -> SourceConfig {
        let bundled = ModelRegistry.bundledResourceURL("local-llm.json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(SourceConfig.self, from: $0) }
        if let bundled, !bundled.runtime.urls.isEmpty, !modelOptions(bundled).isEmpty {
            return bundled
        }
        // 资源缺失或改坏时不能让开关直接失效：退回随代码内置的一份源。
        NSLog("LumaLLM: 读取 local-llm.json 失败，使用内置默认下载源")
        return SourceConfig(
            runtime: SourceConfig.Runtime(
                release: "v0.40.18",
                bytes: 188_838_885,
                urls: ["https://gh-proxy.com/https://github.com/ollama/ollama/releases/download/v0.40.18/ollama-darwin.tgz"]
            ),
            models: [
                SourceConfig.Model(
                    id: "luma-qwen2.5:1.5b",
                    title: "Qwen2.5 1.5B",
                    detail: "轻量：纯对话，占用最小",
                    when: nil,
                    speed: nil,
                    memory: nil,
                    template: nil,
                    parameters: nil,
                    files: [
                        SourceConfig.Model.File(
                            file: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
                            bytes: 1_117_320_736,
                            urls: ["https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf"]
                        )
                    ]
                )
            ],
            defaultModel: "luma-qwen2.5:1.5b",
            parameters: nil
        )
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var detail = ""
    @Published private(set) var isRuntimeInstalled = false
    @Published private(set) var isServerRunning = false
    /// 本机运行时的版本（`v0.40.18` 这种）；和清单不一致时界面会提示升级。
    @Published private(set) var runtimeVersion: String?
    @Published private(set) var installedModels: [String] = []
    @Published var selectedOptionID: String {
        didSet {
            guard oldValue != selectedOptionID else { return }
            UserDefaults.standard.set(selectedOptionID, forKey: Self.optionKey)
            fetchSelectedModelIfNeeded()
        }
    }

    private static let optionKey = "localLLM.selectedOption"

    private var download: SegmentedDownload?
    private var pipelineTask: Task<Void, Never>?
    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var cancelling = false
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7200
        session = URLSession(configuration: configuration)
        let stored = UserDefaults.standard.string(forKey: Self.optionKey)
        let fallback = Self.sourceConfig.defaultModel
            .flatMap { id in Self.options.first { $0.id == id }?.id } ?? Self.options.first?.id ?? ""
        selectedOptionID = stored.flatMap { id in Self.options.first { $0.id == id }?.id } ?? fallback
    }

    // MARK: - 路径

    static var runtimeRoot: URL {
        ModelRegistry.modelsRoot.appendingPathComponent("Runtime/ollama", isDirectory: true)
    }

    static var runtimeBinary: URL {
        runtimeRoot.appendingPathComponent("ollama")
    }

    /// Ollama 自己的模型库放在这里，和 Luma 的其它模型放一起，便于整体删除。
    static var ollamaModelsRoot: URL {
        ModelRegistry.modelsRoot.appendingPathComponent("Ollama", isDirectory: true)
    }

    private static var downloadsRoot: URL { ModelRegistry.downloadsRoot }

    var selectedOption: ModelOption {
        Self.options.first { $0.id == selectedOptionID } ?? Self.options[0]
    }

    var isReady: Bool {
        stage == .ready && ModelRegistry.isEnabled(.localLLM)
    }

    var statusText: String {
        switch stage {
        case .idle:
            if !isRuntimeInstalled { return "未安装 · 点开关自动装好" }
            if !installedModels.contains(selectedOption.id) { return "未安装模型 · 点开关自动下载" }
            return isServerRunning ? "运行中 · 全部在本机" : "已停止 · 点开关启动"
        case .checking: return "检查环境…"
        case .downloadingRuntime: return "下载运行时 \(percentText)"
        case .installingRuntime: return "解压运行时…"
        case .startingServer: return "启动本地服务…"
        case .downloadingModel: return "下载模型 \(percentText)"
        case .creatingModel: return "注册模型…"
        case .ready: return installedModels.contains(selectedOption.id)
            ? "运行中 · 全部在本机"
            : "运行中 · 正在安装所选模型"
        case .failed(let message): return "失败：\(message)"
        }
    }

    private var percentText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    // MARK: - 探测

    func refresh() async {
        isRuntimeInstalled = Self.locateBinary() != nil
        runtimeVersion = await Self.binaryVersion(at: Self.runtimeBinary)
        isServerRunning = await Self.serverVersion(session: session) != nil
        // 开关是关的：把上次残留的本机服务（旧版本没停干净的孤儿）收掉，
        // 否则会出现「已经关了，端口还在跑」。只认 App 自带运行时，不动用户自己的 Ollama。
        if !ModelRegistry.isEnabled(.localLLM), isServerRunning {
            stopResidualServer()
            try? await Task.sleep(nanoseconds: 300_000_000)
            isServerRunning = await Self.serverVersion(session: session) != nil
        }
        installedModels = (try? await Self.tags(session: session)) ?? []
        // 我们的运行时比清单旧：启动时顺手升级，不用等用户去点按钮（用户自己装的 Ollama 不接管）。
        if ModelRegistry.isEnabled(.localLLM), !stage.isBusy,
           FileManager.default.fileExists(atPath: Self.runtimeBinary.path),
           let current = runtimeVersion, current != Self.runtimeRelease {
            _ = await upgradeRuntimeIfNeeded()
            runtimeVersion = await Self.binaryVersion(at: Self.runtimeBinary)
            isServerRunning = await Self.serverVersion(session: session) != nil
            installedModels = (try? await Self.tags(session: session)) ?? installedModels
        }
        // 上次开启过、运行时也还在：顺手把本机服务拉起来，助手不用等用户再进设置点一次开关。
        if ModelRegistry.isEnabled(.localLLM), isRuntimeInstalled {
            await ensureServerRunning()
        }
        // 旧版本按 Ollama 默认 num_ctx=4096 注册的模型：按清单重建一次参数，不重下 GGUF。
        // 不做的话，图库上下文 + 工具定义一长就报「exceeds the available context size」。
        if isServerRunning, ModelRegistry.isEnabled(.localLLM), !stage.isBusy,
           installedModels.contains(selectedOption.id), let binary = Self.locateBinary(),
           await Self.modelParametersMatch(selectedOption, session: session) == false {
            do {
                try await rebuildParameters(selectedOption, binary: binary)
            } catch {
                Diagnostics.record("本地模型：重建参数失败 \(error.localizedDescription)")
            }
        }
        // 启动瞬间可能撞上「上一个实例还没退干净」：最后再确认一次，没了就重新拉起。
        if ModelRegistry.isEnabled(.localLLM), isRuntimeInstalled, !stage.isBusy {
            await ensureServerRunning()
        }
        if isServerRunning, installedModels.contains(selectedOption.id),
           ModelRegistry.isEnabled(.localLLM) {
            stage = .ready
            progress = 1
        } else if !stage.isBusy {
            stage = .idle
        }
    }

    /// 服务没在跑就拉起来，并等它真正可用（探测 + 最多 6 秒）。
    private func ensureServerRunning() async {
        guard await Self.serverVersion(session: session) == nil else {
            isServerRunning = true
            return
        }
        guard let binary = Self.locateBinary() else { return }
        do {
            try startServer(binary: binary)
            Diagnostics.record("本地模型：自动拉起服务 \(binary.path)", level: .standard)
        } catch {
            Diagnostics.record("本地模型：自动拉起服务失败 \(error.localizedDescription)")
            return
        }
        for _ in 0..<20 {
            if await Self.serverVersion(session: session) != nil {
                isServerRunning = true
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        installedModels = (try? await Self.tags(session: session)) ?? installedModels
    }

    // MARK: - 开关

    func enable() {
        guard pipelineTask == nil else { return }
        cancelling = false
        stage = .checking
        progress = 0
        detail = "准备下载"
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 我们自己的运行时比清单旧时先升级（用户自己装的 Ollama 不接管）。
                await self.upgradeRuntimeIfNeeded()
                // 用户自己的 Ollama 已经在跑就直接用，不再重复下载运行时。
                let serverUp = await Self.serverVersion(session: self.session) != nil
                let binary: URL
                if serverUp, let existing = Self.locateBinary() {
                    binary = existing
                } else {
                    binary = try await self.ensureRuntime()
                }
                if !serverUp {
                    try await self.ensureServer(binary: binary)
                }
                let option = self.selectedOption
                try await self.ensureModel(option, binary: binary)
                ModelRegistry.setEnabled(true, for: .localLLM)
                self.stage = .ready
                self.progress = 1
                self.detail = "\(option.title) 已就绪"
                Diagnostics.record("本地模型：\(option.id) 已就绪", level: .standard)
            } catch {
                if self.cancelling {
                    self.cancelling = false
                    self.stage = .idle
                } else {
                    self.stage = .failed(Self.message(for: error))
                }
                self.detail = ""
            }
            self.pipelineTask = nil
        }
    }

    func disable() {
        cancel()
        ModelRegistry.setEnabled(false, for: .localLLM)
        stage = .idle
        // 关掉开关就把相关服务停干净：本进程拉起的进程，以及被接管的外部 ollama，
        // 否则会出现「开关是关的、服务还在跑」。
        stopServer()
        Self.terminateAdoptedOllama()
    }

    /// 换档位后自动把新模型装上：运行时已就绪、只差这一个模型时才触发，
    /// 否则用户切了档位却什么都不会发生，助手还指着旧模型。
    func fetchSelectedModelIfNeeded() {
        guard stage == .ready, pipelineTask == nil else { return }
        let option = selectedOption
        guard !installedModels.contains(option.id), let binary = Self.locateBinary() else { return }
        cancelling = false
        stage = .downloadingModel
        progress = 0
        detail = "\(option.title) · \(option.sizeText)"
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureModel(option, binary: binary)
                self.stage = .ready
                self.progress = 1
                self.detail = "\(option.title) 已就绪"
            } catch {
                self.stage = self.cancelling ? .idle : .failed(Self.message(for: error))
                self.cancelling = false
                self.detail = ""
            }
            self.pipelineTask = nil
        }
    }

    func cancel() {
        cancelling = true
        pipelineTask?.cancel()
        pipelineTask = nil
        download?.cancel()
        download = nil
        if stage.isBusy { stage = .idle }
        progress = 0
    }

    /// 删除运行时与已下载模型，回到「未安装」。
    /// 服务、二进制、模型库、下载缓存一起清掉，开关和助手配置由调用方收尾。
    func uninstall() {
        cancel()
        stopServer()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: Self.runtimeRoot)
        try? fileManager.removeItem(at: Self.ollamaModelsRoot)
        try? fileManager.removeItem(at: Self.downloadsRoot.appendingPathComponent("ollama-darwin.tgz"))
        try? fileManager.removeItem(at: Self.downloadsRoot
            .appendingPathComponent("ollama-runtime.segs", isDirectory: true))
        for option in Self.options {
            for file in option.files {
                try? fileManager.removeItem(at: Self.downloadsRoot.appendingPathComponent(file.file))
                try? fileManager.removeItem(at: Self.downloadsRoot
                    .appendingPathComponent("\(file.file).segs", isDirectory: true))
            }
            // 注册模型时用的 Modelfile 目录。
            try? fileManager.removeItem(at: Self.downloadsRoot
                .appendingPathComponent(option.id.replacingOccurrences(of: ":", with: "-"),
                                        isDirectory: true))
        }
        ModelRegistry.setEnabled(false, for: .localLLM)
        isRuntimeInstalled = false
        isServerRunning = false
        runtimeVersion = nil
        installedModels = []
        progress = 0
        detail = ""
        stage = .idle
        Diagnostics.record("本地模型：已删除运行时与模型", level: .standard)
    }

    /// App 退出时调用：服务跟着 Luma 走，模型文件保留，下次启动会再拉起来。
    func shutdown() {
        stopServer()
    }

    // MARK: - 运行时

    static func locateBinary() -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: runtimeBinary.path) { return runtimeBinary }
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        for path in candidates where fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// 读 `ollama --version` 的版本号，统一成 `v0.40.19` 这种形式。
    static func binaryVersion(at binary: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if let range = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                    continuation.resume(returning: "v" + text[range])
                } else {
                    continuation.resume(returning: nil)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func ensureRuntime() async throws -> URL {
        let fileManager = FileManager.default
        // 我们自己的运行时：版本和清单一致就直接用，旧版本走下面的下载替换。
        let current = await Self.binaryVersion(at: Self.runtimeBinary)
        if current == Self.runtimeRelease {
            isRuntimeInstalled = true
            return Self.runtimeBinary
        }
        // 用户自己装的 Ollama（Homebrew / 官方 App）：直接用，不接管也不升级。
        if !fileManager.fileExists(atPath: Self.runtimeBinary.path),
           let external = Self.locateBinary() {
            isRuntimeInstalled = true
            return external
        }
        let archive = Self.downloadsRoot.appendingPathComponent("ollama-darwin.tgz")
        Diagnostics.record("本地模型：升级 Ollama 运行时 \(current ?? "无") → \(Self.runtimeRelease)", level: .standard)
        if Self.fileSize(archive) != Self.runtimeBytes {
            stage = .downloadingRuntime
            progress = 0
            detail = "Ollama 运行时 \(Self.runtimeRelease) · \(ByteCountFormatter.string(fromByteCount: Self.runtimeBytes, countStyle: .file))"
            try await downloadFile(sources: Self.runtimeURLs,
                                   destination: archive,
                                   expectedSize: Self.runtimeBytes,
                                   workDir: Self.downloadsRoot
                                       .appendingPathComponent("ollama-runtime.segs", isDirectory: true))
        }

        stage = .installingRuntime
        progress = 0
        detail = "解压 Ollama 运行时"
        // 升级时先清掉旧版本，避免旧 dylib / metal 内核混在新包里。
        try? fileManager.removeItem(at: Self.runtimeRoot)
        try? fileManager.createDirectory(at: Self.runtimeRoot, withIntermediateDirectories: true)
        try await Self.extract(archive, into: Self.runtimeRoot)
        // 兼容包里带一层目录的情况。
        if !fileManager.fileExists(atPath: Self.runtimeBinary.path) {
            if let nested = try? fileManager.contentsOfDirectory(at: Self.runtimeRoot,
                                                                includingPropertiesForKeys: nil)
                .first(where: { fileManager.fileExists(atPath: $0.appendingPathComponent("ollama").path) }) {
                try? fileManager.moveItem(at: nested.appendingPathComponent("ollama"),
                                          to: Self.runtimeBinary)
            }
        }
        guard fileManager.fileExists(atPath: Self.runtimeBinary.path) else {
            throw RuntimeError.runtimeIncomplete
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755],
                                       ofItemAtPath: Self.runtimeBinary.path)
        try? fileManager.removeItem(at: archive)
        isRuntimeInstalled = true
        return Self.runtimeBinary
    }

    private func ensureServer(binary: URL) async throws {
        if await Self.serverVersion(session: session) != nil {
            isServerRunning = true
            return
        }
        stage = .startingServer
        detail = "启动 ollama serve"
        try startServer(binary: binary)
        for _ in 0..<60 {
            if await Self.serverVersion(session: session) != nil {
                isServerRunning = true
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw RuntimeError.serverTimeout
    }

    /// 我们自己的运行时比清单旧时就地升级：停服务 → 换二进制 → 重新拉起。
    /// 用户自己装的 Ollama（Homebrew / 官方 App）不接管、不升级。
    @discardableResult
    func upgradeRuntimeIfNeeded() async -> Bool {
        guard FileManager.default.fileExists(atPath: Self.runtimeBinary.path) else { return false }
        let installed: String?
        if let runtimeVersion {
            installed = runtimeVersion
        } else {
            installed = await Self.binaryVersion(at: Self.runtimeBinary)
        }
        guard let installed, installed != Self.runtimeRelease else { return false }
        stopServer()
        do {
            _ = try await ensureRuntime()
        } catch {
            stage = .failed(Self.message(for: error))
            return false
        }
        runtimeVersion = await Self.binaryVersion(at: Self.runtimeBinary)
        try? await ensureServerIfRuntimeReady()
        return true
    }

    /// 升级完把服务拉回来（只有用户之前是开着的时候才拉，避免悄悄常驻）。
    private func ensureServerIfRuntimeReady() async throws {
        guard ModelRegistry.isEnabled(.localLLM) else { return }
        if await Self.serverVersion(session: session) != nil {
            isServerRunning = true
            return
        }
        guard let binary = Self.locateBinary() else { return }
        try? startServer(binary: binary)
    }

    /// 服务被关掉（或重启 App 后没起来）时，助手和设置页都能一键拉起来。
    func startServerIfNeeded() async {
        guard !stage.isBusy else { return }
        await upgradeRuntimeIfNeeded()
        if await Self.serverVersion(session: session) != nil {
            await refresh()
            return
        }
        guard let binary = Self.locateBinary() else {
            stage = .failed("还没下载运行时：先在「本地模型」打开开关")
            return
        }
        stage = .startingServer
        detail = "启动 ollama serve"
        do {
            try startServer(binary: binary)
        } catch {
            stage = .failed(Self.message(for: error))
            return
        }
        for _ in 0..<60 {
            if await Self.serverVersion(session: session) != nil {
                isServerRunning = true
                Diagnostics.record("本地模型：服务已启动", level: .standard)
                await refresh()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        stage = .failed("本地服务启动超时")
    }

    private func startServer(binary: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.ollamaModelsRoot, withIntermediateDirectories: true)
        let logURL = Self.ollamaModelsRoot.appendingPathComponent("server.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()
        // Process 只持有文件描述符，这里要留住 FileHandle，否则它析构时会把日志 fd 关掉。
        serverLogHandle = handle

        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:\(Self.serverPort)"
        environment["OLLAMA_MODELS"] = Self.ollamaModelsRoot.path
        environment["OLLAMA_KEEP_ALIVE"] = "15m"
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        serverProcess = process
    }

    private func stopServer() {
        if let process = serverProcess {
            if process.isRunning {
                process.terminate()
                // 等它真正退出再放行：退出 App 后端口不该还被占着。
                for _ in 0..<20 where process.isRunning {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            serverProcess = nil
        }
        serverLogHandle = nil
        // 上次崩溃 / 被强杀留下的孤儿服务：同一个运行时起的才收掉，别动用户自己装的 Ollama。
        Self.terminateListeners(under: Self.runtimeRoot.path)
        isServerRunning = false
    }

    /// 结束监听本地端口的、由本进程拉起（或已成为孤儿）的 ollama 服务。
    /// 别的 Luma 实例正在用的服务不能动：重复启动时退出的那个实例只是「替身」。
    nonisolated private static func terminateListeners(under root: String) {
        for pid in listeningPIDs() {
            guard let parent = parentPID(of: pid), parent == getpid() || parent == 1 else {
                continue
            }
            guard let command = processCommand(pid), command.contains(root) else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// 关闭开关时调用：端口上还在监听的 ollama（包括复用外部运行时的那份）一起停掉。
    nonisolated private static func terminateAdoptedOllama() {
        for pid in listeningPIDs() {
            guard let command = processCommand(pid),
                  command.lowercased().contains("ollama") else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// 关闭状态下的残留清理：只结束 App 自带运行时目录里的 ollama，不动用户自己装的那份。
    func stopResidualServer() {
        for pid in Self.listeningPIDs() {
            guard let command = Self.processCommand(pid),
                  command.contains(Self.runtimeRoot.path) else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// 本地端口上正在监听的进程号。
    nonisolated private static func listeningPIDs() -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(serverPort)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0) }
    }

    nonisolated private static func parentPID(of pid: Int32) -> Int32? {
        processValue(of: pid, field: "ppid=").flatMap { Int32($0) }
    }

    nonisolated private static func processCommand(_ pid: Int32) -> String? {
        processValue(of: pid, field: "command=")
    }

    nonisolated private static func processValue(of pid: Int32, field: String) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", field, "-p", "\(pid)"]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 模型

    private func ensureModel(_ option: ModelOption, binary: URL) async throws {
        installedModels = (try? await Self.tags(session: session)) ?? []
        if installedModels.contains(option.id) {
            // 已经装过：检查注册时写进去的参数还是不是当前这一套。
            // 旧版本按 Ollama 默认的 num_ctx 4096 注册，升级后要重建，否则大请求依然报错。
            if await Self.modelParametersMatch(option, session: session) { return }
            try await rebuildParameters(option, binary: binary)
            return
        }

        // 视觉模型分两部分（语言模型 + mmproj）：进度按总字节算，不分文件各自从 0 开始。
        var paths: [URL] = []
        var finished: Int64 = 0
        for file in option.files {
            let destination = Self.downloadsRoot.appendingPathComponent(file.file)
            if Self.fileSize(destination) != file.bytes {
                stage = .downloadingModel
                progress = option.bytes > 0 ? Double(finished) / Double(option.bytes) : 0
                detail = "\(option.title) · \(option.sizeText)"
                try await downloadFile(sources: file.urls,
                                       destination: destination,
                                       expectedSize: file.bytes,
                                       workDir: Self.downloadsRoot
                                           .appendingPathComponent("\(file.file).segs", isDirectory: true),
                                       progressBase: finished,
                                       progressTotal: option.bytes)
            }
            finished += file.bytes
            paths.append(destination)
        }

        stage = .creatingModel
        detail = "注册 \(option.id)"
        let directory = Self.downloadsRoot
            .appendingPathComponent(option.id.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelfile = directory.appendingPathComponent("Modelfile")
        try Self.modelfile(option: option, files: paths).write(to: modelfile, atomically: true, encoding: .utf8)

        try await runCommand(binary, ["create", option.id, "-f", modelfile.path], timeout: 900)
        // 注册完成后 GGUF 已经进了 Ollama 自己的库，原件删掉省一份空间。
        for path in paths {
            try? FileManager.default.removeItem(at: path)
        }
        installedModels = (try? await Self.tags(session: session)) ?? installedModels
    }

    /// 换参数不用重新下载 GGUF：`FROM <现有模型>` 再写一遍 PARAMETER 就能重建，
    /// 模型名不变，助手里的配置也不用改。
    private func rebuildParameters(_ option: ModelOption, binary: URL) async throws {
        stage = .creatingModel
        detail = "按新参数重建 \(option.id)"
        let directory = Self.downloadsRoot
            .appendingPathComponent(option.id.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelfile = directory.appendingPathComponent("Modelfile")
        try Self.parameterModelfile(option: option).write(to: modelfile, atomically: true, encoding: .utf8)
        try await runCommand(binary, ["create", option.id, "-f", modelfile.path], timeout: 300)
        installedModels = (try? await Self.tags(session: session)) ?? installedModels
        Diagnostics.record("本地模型：按新参数重建 \(option.id)", level: .standard)
    }

    /// 已注册模型的参数是否和当前清单一致（主要看 num_ctx）。
    private static func modelParametersMatch(_ option: ModelOption, session: URLSession) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/api/show"),
              let ctx = option.parameters["num_ctx"] else { return true }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": option.id])
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        let parameters = root["parameters"] as? String ?? ""
        // /api/show 里是多空格对齐的，用正则容忍空白。
        let pattern = "num_ctx\\s+\(NSRegularExpression.escapedPattern(for: parameterText(ctx)))(\\s|$)"
        return parameters.range(of: pattern, options: .regularExpression) != nil
    }

    /// 模型文件被删掉后也能重建参数的模板：`FROM <同一个模型>`。
    private static func parameterModelfile(option: ModelOption) -> String {
        (["FROM \(option.id)"] + option.parameterLines).joined(separator: "\n")
    }

    /// Qwen2.5 用 ChatML 模板；视觉模型（Qwen3-VL）必须沿用 GGUF 自带的模板，
    /// 自己拼会丢掉图片占位符，模型只能看到文字。
    private static func modelfile(option: ModelOption, files: [URL]) -> String {
        var lines = files.map { "FROM \"\($0.path)\"" }
        if !option.usesBuiltinTemplate {
            lines.append(
                """
                TEMPLATE \"\"\"<|im_start|>system
                {{ .System }}<|im_end|>
                <|im_start|>user
                {{ .Prompt }}<|im_end|>
                <|im_start|>assistant
                \"\"\"
                PARAMETER stop "<|im_end|>"
                PARAMETER stop "<|im_start|>"
                """
            )
        }
        // 统一用 Luma 自己的参数（num_ctx 等）：默认 4096 的上下文装不下图库 + 工具定义。
        lines.append(contentsOf: option.parameterLines)
        return lines.joined(separator: "\n")
    }

    nonisolated private static func parameterText(_ value: Double) -> String {
        value == value.rounded() ? String(Int64(value)) : String(value)
    }

    // MARK: - 下载

    private func downloadFile(sources: [URL],
                              destination: URL,
                              expectedSize: Int64,
                              workDir: URL,
                              progressBase: Int64 = 0,
                              progressTotal: Int64? = nil) async throws {
        guard !sources.isEmpty else { throw RuntimeError.downloadFailed }
        let total = max(progressTotal ?? expectedSize, 1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let download = SegmentedDownload(sources: sources,
                                                   destination: destination,
                                                   expectedSize: expectedSize,
                                                   configuration: session.configuration,
                                                   workDir: workDir,
                                                   progress: { [weak self] received, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = min(1, max(0, Double(progressBase + received) / Double(total)))
                }
            },
                                                   completion: { [weak self] result in
                Task { @MainActor in
                    self?.download = nil
                    continuation.resume(with: result)
                }
            }) else {
                continuation.resume(throwing: RuntimeError.downloadFailed)
                return
            }
            self.download = download
            download.start()
        }
    }

    // MARK: - 进程

    private func runCommand(_ binary: URL, _ arguments: [String], timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:\(Self.serverPort)"
        environment["OLLAMA_MODELS"] = Self.ollamaModelsRoot.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var output = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data) }
        }
        try process.run()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    if !process.isRunning { continuation.resume() }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
                throw RuntimeError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RuntimeError.commandFailed(text.isEmpty ? "ollama 命令执行失败" : String(text.suffix(320)))
        }
    }

    private static func extract(_ archive: URL, into directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", directory.path]
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RuntimeError.commandFailed("运行时解压失败"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - HTTP

    private static func serverVersion(session: URLSession) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/api/version") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? String else { return nil }
        return version
    }

    private static func tags(session: URLSession) async throws -> [String] {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    // MARK: - 工具

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
