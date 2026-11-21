import SwiftUI

/// 导入网络资源：三步合一，但必须完成「首页 / 详情 / 封面」三项校验才允许添加。
/// 站点地址支持一次填多个：逗号、空格、换行都能作为分隔符。
struct CatalogWizardView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var imported: [ImportedSource] = []
    @State private var isWorking = false
    @State private var progressText: String?
    @State private var errorMessage: String?
    @State private var enableAfterAdd = false
    @State private var allowInsecure = false
    @State private var importMode: ImportMode = .fongmi

    /// 两种接入方式：FongMi 兼容配置，或直接给网页站点的地址。
    private enum ImportMode: String, CaseIterable, Identifiable {
        case fongmi
        case site

        var id: String { rawValue }
        var title: String {
            switch self {
            case .fongmi: return "FongMi 配置"
            case .site: return "直接站点地址"
            }
        }
        var placeholder: String {
            switch self {
            case .fongmi: return "https://…/huangguo_fongmi_config.json"
            case .site: return "https://91quanji.com/  https://javcl.com/  https://javgg.com/  https://madou.club/\n多个地址可用逗号、空格或换行分隔"
            }
        }
    }

    private struct Check: Identifiable {
        enum State: Equatable { case ok, failed }
        let id = UUID()
        var text: String
        var state: State
    }

    /// 一次导入可能包含多个站点：每个地址保留自己的解析结果与校验项。
    private struct ImportedSource: Identifiable {
        let id = UUID()
        var address: String
        var source: CatalogSource?
        var checks: [Check] = []

        var failed: Bool { source == nil || checks.contains { $0.state == .failed } }
        var name: String { source?.name ?? "无法解析" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    field
                    if !imported.isEmpty {
                        results
                    }
                    if let errorMessage {
                        callout(errorMessage, color: .red, icon: "exclamationmark.triangle.fill")
                    }
                    callout("该资源内容由第三方站点提供，App 不内置、不托管任何内容或密钥。"
                            + "启用后仅在本机展示与播放，不写入照片图库索引；请自行确认来源合规与内容分级。",
                            color: LumaBrand.amber, icon: "lock.shield")
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 700)
        .onChange(of: allowInsecure) { _, value in
            guard imported.count == 1, var source = imported.first?.source else { return }
            source.allowsInsecureTLS = value
            imported[0].source = source
            CatalogTrust.setTrusted(source.host, value)
            Task {
                let checks = await validate(source)
                if !imported.isEmpty { imported[0].checks = checks }
            }
        }
        .onDisappear {
            // 向导取消时清掉临时放行，只保留已保存源自己的信任设置。
            CatalogTrust.sync(sources: catalog.sources)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("导入网络资源")
                    .font(.system(size: 15, weight: .semibold))
                Text("支持 FongMi 兼容配置，或直接填网页站点地址（可一次填多个）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var intro: some View {
        Text(importMode == .fongmi
             ? "填写单站点配置文件（例如 huangguo_fongmi_config.json）或其指向的脚本地址。"
                + "Luma 会读取站点地址、分类与封面解密参数，不会执行脚本。"
             : "直接填写站点首页地址，可以一次填多个：用逗号、空格或换行分隔。"
                + "Luma 会解析站点导航作为分类、列表卡片作为条目，详情页里的播放器作为分集；"
                + "站点改版时以页面结构为准。")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("接入方式", selection: $importMode) {
                ForEach(ImportMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .disabled(isWorking)
            .onChange(of: importMode) { _, _ in
                imported = []
                progressText = nil
                errorMessage = nil
            }

            // 地址可能有好几条：用多行输入框，回车换行不会被当成「立即提交」。
            TextField(importMode.placeholder, text: $urlText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(2...5)
                .disabled(isWorking)

            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.mini)
                    Text(progressText ?? "正在读取配置并验证站点…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("解析并校验") { runImport() }
                    .disabled(Self.splitAddresses(urlText).isEmpty || isWorking)
            }
        }
    }

    // MARK: - 解析结果

    private var availableCount: Int {
        imported.filter { !$0.failed }.count
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("解析结果")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(availableCount) 个可添加")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            VStack(spacing: 10) {
                ForEach(imported) { entry in
                    resultRow(entry, showAllChecks: imported.count == 1)
                }
            }
            if imported.count == 1, imported.first?.source != nil {
                singleSourceOptions
            } else {
                Toggle("添加后立即启用", isOn: $enableAfterAdd)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func resultRow(_ entry: ImportedSource, showAllChecks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.failed ? Color.red : Color.green)
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                Text(entry.source?.host ?? entry.address)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let source = entry.source {
                    Text("· \(source.categories.count) 个分类")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            let visible = showAllChecks ? entry.checks : entry.checks.filter { $0.state == .failed }
            ForEach(visible) { check in
                HStack(spacing: 6) {
                    Image(systemName: check.state == .ok ? "checkmark" : "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(check.state == .ok ? Color.secondary : Color.red)
                    Text(check.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(check.state == .ok ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                .padding(.leading, 19)
            }
        }
    }

    private var singleSourceOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 1)
            HStack(spacing: 10) {
                Text("名称")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                TextField("显示名称", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
            }
            if let source = imported.first?.source {
                HStack(spacing: 10) {
                    Text("分类")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text(source.categories.map(\.title).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Toggle("添加后立即启用", isOn: $enableAfterAdd)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))

            if let source = imported.first?.source {
                Divider().padding(.vertical, 1)

                Toggle("允许不受信任的证书（跳过 \(source.host) 的 HTTPS 校验）", isOn: $allowInsecure)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                Text("仅在该站点证书确实无效、但你确认站点可信时开启；开启后该主机的加密流量可能被中间人截获。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(allowInsecure ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { imported.first?.source?.name ?? "" },
            set: { value in
                guard !imported.isEmpty, var source = imported[0].source else { return }
                source.name = value
                imported[0].source = source
            }
        )
    }

    private func callout(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(imported.count > 1 ? "添加 \(availableCount) 个资源" : "添加资源") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var canAdd: Bool {
        !isWorking && imported.contains { !$0.failed }
    }

    // MARK: - 动作

    /// 逗号（中英文）、分号、空格、换行都算地址分隔符；重复地址只保留一次。
    static func splitAddresses(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;； \t\r\n")
        var seen = Set<String>()
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func runImport() {
        var addresses = Self.splitAddresses(urlText)
        guard !addresses.isEmpty else { return }
        // FongMi 配置文件只有一个，多填时取第一条。
        if importMode == .fongmi { addresses = Array(addresses.prefix(1)) }

        isWorking = true
        progressText = nil
        errorMessage = nil
        imported = []

        Task {
            var results: [ImportedSource] = []
            for (index, address) in addresses.enumerated() {
                progressText = addresses.count > 1
                    ? "正在解析 \(index + 1)/\(addresses.count)：\(shortHost(address))"
                    : "正在读取配置并验证站点…"
                do {
                    var source = try await importOne(address)
                    source.allowsInsecureTLS = allowInsecure && addresses.count == 1
                    results.append(ImportedSource(address: address, source: source))
                } catch {
                    results.append(ImportedSource(address: address,
                                                  source: nil,
                                                  checks: [Check(text: error.localizedDescription,
                                                                 state: .failed)]))
                }
            }
            imported = results

            // 逐项做三项校验：首页 / 详情 / 封面。
            for index in imported.indices where imported[index].source != nil {
                guard var source = imported[index].source else { continue }
                progressText = addresses.count > 1
                    ? "正在校验 \(index + 1)/\(addresses.count)：\(source.host)"
                    : "正在读取配置并验证站点…"
                let checks = await validate(source)
                source.allowsInsecureTLS = allowInsecure && addresses.count == 1
                imported[index].source = source
                imported[index].checks = checks
            }

            if !imported.contains(where: { $0.source != nil }) {
                errorMessage = "没有解析出可用的站点，请检查地址或站点是否可访问。"
            }
            progressText = nil
            isWorking = false
        }
    }

    /// 按地址挑适配器：域名特征优先，其余按 91 站处理。
    private func importOne(_ address: String) async throws -> CatalogSource {
        switch importMode {
        case .fongmi:
            return try await HuangguoCatalogProvider.importSource(from: address)
        case .site:
            let lower = address.lowercased()
            if lower.contains("91porna") {
                return try await NinetyOnePornaCatalogProvider.importSource(from: address)
            } else if lower.contains("xsz-av") {
                return try await XszCatalogProvider.importSource(from: address)
            } else if lower.contains("missav") {
                return try await MissavCatalogProvider.importSource(from: address)
            } else if lower.contains("avple") {
                return try await AvpleCatalogProvider.importSource(from: address)
            } else if lower.contains("shise") {
                return try await ShiseCatalogProvider.importSource(from: address)
            } else if lower.contains("avgle") {
                return try await AvgleCatalogProvider.importSource(from: address)
            } else if lower.contains("rou.video") {
                return try await RouVideoCatalogProvider.importSource(from: address)
            } else if lower.contains("91quanji") || lower.contains("quanji") {
                return try await QuanjiCatalogProvider.importSource(from: address)
            } else if lower.contains("javcl") {
                return try await JavClCatalogProvider.importSource(from: address)
            } else if lower.contains("madou") {
                return try await MadouCatalogProvider.importSource(from: address)
            } else if lower.contains("javgg") {
                return try await JavGGCatalogProvider.importSource(from: address)
            } else {
                return try await NinetyOneCatalogProvider.importSource(from: address)
            }
        }
    }

    private func shortHost(_ address: String) -> String {
        if let host = URLComponents(string: address)?.host { return host }
        return address
    }

    /// 三项校验：首页、详情分集、封面解密。返回的失败项会禁用该条的添加。
    private func validate(_ source: CatalogSource) async -> [Check] {
        var checks: [Check] = [
            Check(text: "配置可访问，站点：\(source.name)", state: .ok),
            Check(text: "解析到 \(source.categories.count) 个分类", state: .ok)
        ]
        CatalogTrust.setTrusted(source.host, source.trustsInsecureCertificate)

        do {
            guard let provider = CatalogProviders.provider(for: source.kind) else {
                throw CatalogError.unsupportedProvider
            }
            let home = try await provider.home(source: source)
            checks.append(Check(text: "首页解析 \(home.items.count) 条",
                                state: home.items.isEmpty ? .failed : .ok))

            // 首页第一条可能是纯图文榜单：往后找一条真正带播放器的条目来验证详情与封面。
            var checked: (item: CatalogItem, detail: CatalogDetail)?
            for candidate in home.items.prefix(5) {
                if let detail = try? await provider.detail(source: source, itemID: candidate.id),
                   !detail.episodes.isEmpty {
                    checked = (candidate, detail)
                    break
                }
            }

            if let checked {
                checks.append(Check(text: "详情页解析 \(checked.detail.episodes.count) 个视频",
                                    state: .ok))
                let cover = checked.item.coverURL.isEmpty
                    ? checked.detail.item.coverURL : checked.item.coverURL
                if cover.isEmpty {
                    checks.append(Check(text: "卡片没有封面地址", state: .failed))
                } else {
                    _ = try await provider.coverData(source: source, urlString: cover)
                    checks.append(Check(text: "封面加载成功", state: .ok))
                }
            } else if !home.items.isEmpty {
                checks.append(Check(text: "前几条都没有可播放的视频，可能站点结构已变化",
                                    state: .failed))
            }
        } catch {
            checks.append(Check(text: error.localizedDescription, state: .failed))
        }
        return checks
    }

    private func add() {
        let usable = imported.filter { !$0.failed }.compactMap(\.source)
        guard !usable.isEmpty else { return }
        var firstID: UUID?
        for var source in usable {
            source.isEnabled = enableAfterAdd
            source.allowsInsecureTLS = imported.count == 1 ? allowInsecure : false
            catalog.addSource(source)
            if firstID == nil { firstID = source.id }
        }
        if let firstID {
            store.navigate(to: .catalogSource(firstID))
        }
        dismiss()
    }
}
