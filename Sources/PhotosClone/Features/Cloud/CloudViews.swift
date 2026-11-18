import SwiftUI

// MARK: - 连接 / 编辑网络存储

struct CloudConnectSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var trustSelfSigned = false
    @State private var isTesting = false
    @State private var status: String?
    @State private var statusIsError = false

    // WebDAV 子目录筛选（编辑 / 添加时可选择接入哪一层目录）
    @State private var webdavFiltersFolders = false
    @State private var webdavBrowseRoot = ""
    @State private var webdavSubPath = ""
    @State private var webdavFolders: [String] = []
    @State private var isLoadingWebDAVFolders = false
    @State private var webdavBrowseError: String?
    @State private var webdavBrowseToken = 0

    private var editing: CloudMount? { cloud.sheetMount }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSMB: Bool { editing?.kind == .smb }

    private var effectivePassword: String {
        if let editing, password.isEmpty {
            return store.cloudPassword(for: editing.id)
        }
        return password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(editing == nil ? "添加网络存储" : "编辑网络存储")
                    .font(.headline)
                Spacer()
                Button {
                    store.dismissCloudSheet()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(isSMB
                 ? "通过 SMB 浏览与播放照片和视频（只读）。群晖：控制面板 → 文件服务 → 启用 SMB，地址填 smb://NAS地址/共享名。"
                 : "通过 WebDAV 浏览、播放和管理照片与视频（支持上传、重命名、新建文件夹与删除）。群晖：在套件中心安装 WebDAV Server 后，地址填 http://NAS地址:5005/photo（HTTPS 为 5006）。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field("名称") {
                    TextField("显示名称", text: $name)
                }
                field("服务器") {
                    TextField(isSMB ? "smb://192.168.1.10/photo" : "http://192.168.1.10:5005/photo",
                              text: $address)
                }
                field("用户名") {
                    TextField(isSMB ? "SMB 账号" : "WebDAV 账号", text: $username)
                }
                field("密码") {
                    SecureField(editing == nil
                                ? (isSMB ? "SMB 密码" : "WebDAV 密码")
                                : "留空表示不修改", text: $password)
                }
            }

            if !isSMB, trimmedAddress.lowercased().hasPrefix("https://") {
                Toggle("信任自签名证书（NAS 自建 HTTPS 常用）", isOn: $trustSelfSigned)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }

            if !isSMB {
                webdavScopeSection
            }

            if let status {
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(statusIsError ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("密码保存在 macOS 钥匙串，不写入图库数据库。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            Button("用网盘接入向导（SMB / WebDAV / 百度 / 阿里 / 夸克 / 115）") {
                store.presentCloudWizard()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))

            HStack(spacing: 8) {
                Button(isTesting ? "测试中…" : "测试连接") {
                    runTest()
                }
                .disabled(isTesting || trimmedAddress.isEmpty)

                Spacer()

                Button("取消") {
                    store.dismissCloudSheet()
                }
                .keyboardShortcut(.cancelAction)

                Button(editing == nil ? "添加" : "保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedAddress.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: loadExisting)
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content()
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: WebDAV 接入范围（当前全部 / 筛选子目录）

    private var webdavScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("接入范围")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Picker("接入范围", selection: $webdavFiltersFolders) {
                    Text("当前全部").tag(false)
                    Text("筛选子目录").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            if webdavFiltersFolders {
                webdavBrowser
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("接入目录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(webdavSelectedAddress)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("接入当前地址下的全部文件夹与照片。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .onChange(of: webdavFiltersFolders) { _, filtering in
            if filtering {
                webdavBrowseRoot = trimmedAddress
                webdavSubPath = ""
                webdavFolders = []
                webdavBrowseError = nil
                loadWebDAVFolders()
            } else {
                resetWebDAVBrowse()
            }
        }
        .onChange(of: address) { _, _ in
            // 地址本身变了，之前浏览出的层级不再对应，回到「当前全部」。
            if webdavFiltersFolders { webdavFiltersFolders = false }
        }
    }

    private var webdavBrowser: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    webdavBrowseUp()
                } label: {
                    Label(webdavSubPath.isEmpty ? "根目录" : "上一级", systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(webdavSubPath.isEmpty || isLoadingWebDAVFolders)

                Text(webdavBrowseTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isLoadingWebDAVFolders {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("重新读取") {
                    loadWebDAVFolders()
                }
                .controlSize(.small)
                .disabled(isLoadingWebDAVFolders)
            }

            webdavBrowserContent
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    @ViewBuilder
    private var webdavBrowserContent: some View {
        if let error = webdavBrowseError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(error)
                    .font(.system(size: 10.5))
                    .lineLimit(2)
            }
            .foregroundStyle(.secondary)
        } else if isLoadingWebDAVFolders && webdavFolders.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在读取目录…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else if webdavFolders.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("这个目录下没有子文件夹，可直接保存当前目录。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(webdavFolders, id: \.self) { folder in
                        Button {
                            enterWebDAVFolder(folder)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(folder)
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("进入「\(folder)」并以该目录接入")
                    }
                }
            }
            .frame(maxHeight: 168)
        }
    }

    private var webdavBrowseTitle: String {
        guard !webdavSubPath.isEmpty else { return "根目录" }
        return webdavSubPath.replacingOccurrences(of: "/", with: " › ")
    }

    /// 实际接入地址：浏览起点 + 选中的子目录层级。
    private var webdavSelectedAddress: String {
        guard webdavFiltersFolders, !webdavSubPath.isEmpty,
              let base = WebDAVClient.normalizedBaseURL(webdavBrowseRoot) else {
            return webdavBrowseRoot.isEmpty ? trimmedAddress : webdavBrowseRoot
        }
        let escaped = webdavSubPath
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var text = base.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        return text + escaped
    }

    private func resetWebDAVBrowse() {
        webdavBrowseToken += 1
        webdavBrowseRoot = ""
        webdavSubPath = ""
        webdavFolders = []
        webdavBrowseError = nil
        isLoadingWebDAVFolders = false
    }

    /// 读取当前层级的子文件夹；根地址与账号来自表单，密码为空时沿用钥匙串里的已保存密码。
    private func loadWebDAVFolders() {
        let root = webdavBrowseRoot.isEmpty ? trimmedAddress : webdavBrowseRoot
        guard let client = WebDAVClient(baseURLString: root,
                                        username: username,
                                        password: effectivePassword,
                                        allowsSelfSignedCertificate: trustSelfSigned) else {
            webdavBrowseError = "地址格式不正确，请填写 http(s)://主机:端口/路径"
            return
        }
        webdavBrowseToken += 1
        let token = webdavBrowseToken
        let path = webdavSubPath
        isLoadingWebDAVFolders = true
        webdavBrowseError = nil
        Task {
            do {
                let entries = try await client.list(path: path)
                guard token == webdavBrowseToken else { return }
                webdavFolders = entries
                    .filter(\.isDirectory)
                    .map(\.name)
                    .filter { !$0.hasPrefix(".") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                isLoadingWebDAVFolders = false
            } catch {
                guard token == webdavBrowseToken else { return }
                isLoadingWebDAVFolders = false
                webdavFolders = []
                webdavBrowseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func enterWebDAVFolder(_ name: String) {
        webdavSubPath = webdavSubPath.isEmpty ? name : webdavSubPath + "/" + name
        webdavFolders = []
        loadWebDAVFolders()
    }

    private func webdavBrowseUp() {
        var parts = webdavSubPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        parts.removeLast()
        webdavSubPath = parts.joined(separator: "/")
        webdavFolders = []
        loadWebDAVFolders()
    }

    private func loadExisting() {
        resetWebDAVBrowse()
        guard let editing else { return }
        name = editing.name
        address = editing.baseURL
        username = editing.username
        trustSelfSigned = editing.trustSelfSigned
    }

    private func runTest() {
        status = nil
        statusIsError = false
        isTesting = true
        let secret = effectivePassword
        let target = trimmedAddress
        let account = username
        let trust = trustSelfSigned
        Task {
            let result = await store.testCloudConnection(address: target,
                                                         username: account,
                                                         password: secret,
                                                         trustSelfSigned: trust)
            isTesting = false
            status = result.message
            statusIsError = !result.ok
        }
    }

    private func save() {
        // WebDAV 选了子目录时，保存的是「根地址 + 选中的层级」。
        let target = isSMB
            ? address
            : (webdavFiltersFolders ? webdavSelectedAddress : address)
        if let error = store.saveCloudMount(existing: editing,
                                            name: name,
                                            address: target,
                                            username: username,
                                            password: password,
                                            trustSelfSigned: trustSelfSigned) {
            status = error
            statusIsError = true
            return
        }
        store.dismissCloudSheet()
    }
}

// MARK: - 云盘浏览

struct CloudBrowserView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    /// 网盘「位置」页的搜索关键词。
    @State private var placesQuery = ""
    /// 分类卡片墙的悬停项：与图库同一套抬升反馈。
    @State private var hoveredOverview: String?
    /// 渐进渲染上限：网盘清单最多 2 万项，一次把整份数组交给网格会让每次 body 都重算月份分桶。
    @State private var renderLimit = 1_200

    private var mountID: UUID? {
        if case .cloudMount(let id) = store.sidebarItem { return id }
        return nil
    }

    private var mountKind: CloudKind? {
        cloud.mounts.first(where: { $0.id == mountID })?.kind
    }

    /// 当前目录的照片经过搜索、筛选与排序后的结果，与其它图库网格保持一致。
    private var photos: [PhotoItem] {
        store.cloudVisiblePhotos
    }

    /// 实际交给网格渲染的子集：首屏 1200 张，滚到底继续追加。
    private var displayedPhotos: [PhotoItem] {
        photos.count > renderLimit ? Array(photos.prefix(renderLimit)) : photos
    }

    private var isFiltering: Bool {
        store.cloudScope != .all
            || store.similarScope != nil
            || store.photoFilter != .all
            || !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            if let overview = cloud.overview {
                overviewView(overview, width: proxy.size.width)
            } else {
                content(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    // MARK: - 分区总览

    private struct CloudOverviewEntry: Identifiable {
        let id: String
        let title: String
        let icon: String
        let count: Int
        let scope: CloudScope?
        let folderPath: String?
        let cover: PhotoItem?
    }

    private func overviewEntries(_ section: CloudOverviewSection,
                                 counts: CloudScopeCounts) -> [CloudOverviewEntry] {
        switch section {
        case .mediaTypes:
            return [
                CloudOverviewEntry(id: "all", title: "全部项目", icon: "photo.stack",
                                   count: counts.count(for: .all), scope: .all, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "videos", title: "视频", icon: "video",
                                   count: counts.videos, scope: .videos, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "photos", title: "照片", icon: "photo",
                                   count: counts.photos, scope: .photos, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "screenshots", title: "截屏", icon: "camera.viewfinder",
                                   count: counts.screenshots, scope: .screenshots, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "animated", title: "动图", icon: "photo.on.rectangle.angled",
                                   count: counts.animated, scope: .animated, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "raws", title: "RAW", icon: "camera.aperture",
                                   count: counts.raws, scope: .raws, folderPath: nil, cover: nil)
            ]
        case .moreItems:
            return [
                CloudOverviewEntry(id: "favorites", title: "个人收藏", icon: "heart.fill",
                                   count: counts.favorites, scope: .favorites, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "duplicates", title: "重复项目", icon: "square.on.square",
                                   count: counts.duplicates, scope: .duplicates, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "text", title: "包含文字", icon: "text.viewfinder",
                                   count: counts.text, scope: .text, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "keywords", title: "关键词", icon: "tag",
                                   count: counts.count(for: .keywords), scope: .keywords, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "revisit", title: "值得重看", icon: "clock.arrow.circlepath",
                                   count: counts.revisit, scope: .revisit, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "health", title: "图库体检", icon: "stethoscope",
                                   count: counts.health, scope: .health, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "map", title: "地图", icon: "map",
                                   count: counts.located, scope: .map, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "places", title: "位置", icon: "mappin.and.ellipse",
                                   count: counts.located, scope: .places, folderPath: nil, cover: nil),
                CloudOverviewEntry(id: "people", title: "人物", icon: "person.crop.square",
                                   count: counts.people, scope: .people, folderPath: nil, cover: nil)
            ]
        case .scenes:
            let visible = SceneCatalog.categories.filter { (counts.scenes[$0.id] ?? 0) > 0 }
            return visible.map { category in
                CloudOverviewEntry(id: "scene." + category.id, title: category.title,
                                   icon: category.icon, count: counts.scenes[category.id] ?? 0,
                                   scope: .scene(category.id), folderPath: nil, cover: nil)
            }
        case .folders:
            return store.cloudRootFolders.map { node in
                CloudOverviewEntry(id: "folder." + node.path, title: node.name,
                                   icon: "folder", count: node.photoCount,
                                   scope: nil, folderPath: node.path, cover: node.cover)
            }
        }
    }

    /// 与拾光 / 系统图库的分类总览同一套卡片样式：列数跟设置走，宽度按可用空间均分。
    private func overviewView(_ section: CloudOverviewSection, width: CGFloat) -> some View {
        let counts = store.cloudScopeCounts
        let entries = overviewEntries(section, counts: counts)
        let spacing: CGFloat = 22
        let available = max(0, width - 48)
        let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
        let columnCount = min(store.cardColumns, maxFit)
        let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 标题由窗口工具栏统一展示，这里只保留数量，与图库总览一致。
                Text(section == .moreItems
                     ? "\(entries.count) 个入口"
                     : "\(entries.count) 个分类")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                         count: columnCount),
                          alignment: .leading,
                          spacing: 26) {
                    ForEach(entries) { entry in
                        overviewCard(entry, width: itemWidth)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func overviewCard(_ entry: CloudOverviewEntry, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: entry.cover ?? entry.scope.flatMap(cover(for:)),
                            side: width, style: .icon(entry.icon))
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredOverview == entry.id ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredOverview == entry.id && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredOverview)

            HStack(spacing: 5) {
                Image(systemName: entry.icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.count.formatted())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredOverview = hovering
                ? entry.id
                : (hoveredOverview == entry.id ? nil : hoveredOverview)
        }
        .onTapGesture {
            if let folderPath = entry.folderPath {
                store.selectCloudFolder(path: folderPath)
            } else if let scope = entry.scope {
                store.setCloudScope(scope)
            }
        }
        .help("查看\(entry.title)")
        .accessibilityLabel("\(entry.title)，\(entry.count) 项")
    }

    /// 分类卡片封面：取当前目录里属于该范围的第一张。
    private func cover(for scope: CloudScope) -> PhotoItem? {
        switch scope {
        case .all: return cloud.photos.first
        case .videos: return cloud.photos.first { $0.isVideo }
        case .photos: return cloud.photos.first { !$0.isVideo }
        case .screenshots:
            return cloud.photos.first { CloudMediaNaming.looksLikeScreenshot($0.originalName) }
        case .animated: return cloud.photos.first { $0.isAnimatedFile }
        case .raws: return cloud.photos.first { $0.isRAWFile }
        case .favorites: return cloud.photos.first { $0.isFavorite }
        case .text: return cloud.photos.first { !(cloud.analysis[$0.id]?.text.isEmpty ?? true) }
        case .scene: return nil
        case .revisit: return store.cloudRevisitPhotos.first
        case .map, .places: return store.cloudGeoPhotos.first
        case .keywords, .keyword: return store.cloudPhotos.first { !$0.tags.isEmpty }
        case .people: return store.cloudPeople.first.flatMap { person in
            cloud.photos.first { person.assetIDs.contains($0.id) }
        }
        case .duplicates: return store.cloudDuplicateGroups.first?.photos.first
        case .health: return nil
        }
    }

    private var placesSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索地点", text: $placesQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 120)
            if !placesQuery.isEmpty {
                Button {
                    placesQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .help("搜索地点")
    }

    @ViewBuilder
    private func content(width: CGFloat, height: CGFloat) -> some View {
        switch store.cloudScope {
        case .map:
            PhotoMapView()
        case .places:
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    PlaceGranularitySwitch()
                    placesSearchField
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                PlaceStatisticsView(query: $placesQuery)
            }
        case .keywords:
            CloudKeywordGalleryView()
        case .people:
            CloudPeopleView()
        case .duplicates:
            CloudDuplicatesView()
        case .health:
            CloudHealthView()
        default:
            cloudGrid(width: width, height: height)
        }
    }

    // MARK: - 照片网格（与图库同一套按月分段）

    private struct CloudAlbumMonth: Identifiable {
        let id: String
        let title: String
        let photos: [PhotoItem]
    }

    /// 按拍摄月份分段（与系统「照片」时间轴一致，最新在前）。
    private var albumMonths: [CloudAlbumMonth] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        for photo in displayedPhotos {
            let components = calendar.dateComponents([.year, .month], from: photo.capturedAt)
            let year = components.year ?? 0
            let key = year < 1970 ? "unknown" : String(format: "%04d-%02d", year, components.month ?? 0)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(photo)
        }
        return order.map { key in
            let bucket = buckets[key] ?? []
            let title = key == "unknown"
                ? "时间未知"
                : DateText.monthFormatter.string(from: bucket.first?.capturedAt ?? Date())
            return CloudAlbumMonth(id: key, title: title, photos: bucket)
        }
    }

    /// 网格预取键：切换目录 / 挂载、范围变化，或新增约 200 项时重启预取。
    /// 数量做量化，避免扫描期间每批都取消重排预取。
    private var cloudPrefetchKey: String {
        [
            mountID?.uuidString ?? "-",
            cloud.selectedFolderPath ?? "",
            String(describing: store.cloudScope),
            String(photos.count / 200)
        ].joined(separator: "\u{1F}")
    }

    /// 只随目录 / 挂载 / 范围变化：用于把渐进渲染窗口收回首屏。
    private var cloudScopeKey: String {
        [
            mountID?.uuidString ?? "-",
            cloud.selectedFolderPath ?? "",
            String(describing: store.cloudScope)
        ].joined(separator: "\u{1F}")
    }

    private func cloudGrid(width: CGFloat, height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = cloud.error, !photos.isEmpty {
                    errorView(error)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }

                if photos.isEmpty {
                    placeholder
                } else {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(albumMonths) { month in
                            Section {
                                photoGrid(month.photos, width: width)
                            } header: {
                                SectionHeaderView(title: month.title, count: month.photos.count)
                            }
                        }
                    }
                    if photos.count > displayedPhotos.count {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("继续加载更多…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .onAppear { renderLimit += 1_200 }
                    }
                }

                if isFiltering, !cloud.photos.isEmpty, photos.count != cloud.photos.count {
                    Text("筛选后显示 \(photos.count) 项（共 \(cloud.photos.count) 项）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
            }
            .photoMarqueeSelection(fillHeight: height)
        }
        .scrollIndicators(.automatic)
        .onChange(of: cloudScopeKey) { _, _ in renderLimit = 1_200 }
        // 与本地 / 系统图库一致：首屏落位后提前取头部缩略图，滚动时不至于一格一格等网络。
        .task(id: cloudPrefetchKey) {
            guard let task = store.prefetchCloudThumbnails(for: photos) else { return }
            // 离开网盘或切换目录时，把预取一起取消，避免后台继续吃网络。
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error = cloud.error {
            errorView(error)
                .padding(.horizontal, 20)
                .padding(.top, 20)
        } else if cloud.scanPhase.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在扫描网盘… 已发现 \(cloud.scanMediaCount.formatted()) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 90)
        } else if isFiltering, !cloud.photos.isEmpty {
            filteredEmptyView
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 46, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text(cloud.scanPhase == .cancelled ? "扫描已停止" : emptyTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(cloud.scanPhase == .cancelled
                     ? "点工具栏的刷新按钮继续扫描剩余目录。"
                     : "缩略图与 EXIF 按需读取；稍后刷新，或在左侧「相簿」里浏览已扫描的目录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 90)
        }
    }

    private var emptyTitle: String {
        cloud.selectedFolderPath == nil ? "这个网盘里还没有可展示的媒体" : "此相簿没有照片或视频"
    }

    /// 与图库网格同一套上下留白，按月分段后的间距保持完全一致。
    @ViewBuilder
    private func photoGrid(_ photos: [PhotoItem], width: CGFloat) -> some View {
        Group {
            switch store.thumbnailAspect {
            case .square:
                SquarePhotoGrid(photos: photos, availableWidth: width)
                    .padding(.bottom, 26)
            case .actual:
                JustifiedPhotoGrid(photos: photos,
                                   availableWidth: width,
                                   targetHeight: CGFloat(store.thumbSize) * 0.92)
                    .padding(.bottom, 26)
            case .masonry:
                MasonryPhotoGrid(photos: photos,
                                 availableWidth: width,
                                 targetWidth: CGFloat(store.thumbSize))
                    .padding(.bottom, 26)
            case .list:
                PhotoListView(photos: photos, availableWidth: width)
                    .padding(.bottom, 20)
            }
        }
        .padding(.top, 10)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重试") {
                        store.refreshCloudDirectory()
                    }
                    .controlSize(.small)

                    if cloud.needsCloudReauth, let kind = mountKind, kind == .baidu {
                        Button("重新登录…") {
                            store.presentCloudWizard(flow: .baidu)
                        }
                        .controlSize(.small)
                        .help("重新走一遍官方授权，写入一份当前 App 可读取的令牌")
                    } else if cloud.needsCloudReauth, let kind = mountKind,
                              kind == .quark || kind == .aliyun {
                        Button("更新 Cookie…") {
                            store.presentCloudWizard(flow: kind.wizardFlow)
                        }
                        .controlSize(.small)
                        .help("登录凭据已过期：重新登录网页后复制一段新的 Cookie / refresh_token")
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private var filteredEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("没有符合筛选条件的项目")
                .font(.system(size: 15, weight: .semibold))
            Text(store.similarScope != nil
                 ? "没有相似照片，点顶部胶囊退出相似检索，或换一个相簿再试。"
                 : (store.cloudScope.requiresAnalysis && store.cloudAnalyzedCount == 0
                    ? "先在左侧「场景 › 识别内容」完成识别，再按场景或图内文字浏览。"
                    : "调整范围、筛选或搜索关键词后再试。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("清除筛选与搜索") {
                store.setCloudScope(.all)
                store.clearFilter()
                store.searchText = ""
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

// MARK: - 重命名 / 新建文件夹

struct CloudNameSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    let request: CloudNameRequest
    @State private var text: String

    init(request: CloudNameRequest) {
        self.request = request
        _text = State(initialValue: request.initialText)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title)
                .font(.headline)
            TextField(request.isRename ? "新名称" : "文件夹名称", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Text(request.isRename
                 ? "扩展名会保持不变，名称中不能包含「/」。"
                 : "文件夹会创建在当前云端目录下。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") {
                    cloud.nameRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(request.actionTitle) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func commit() {
        store.commitCloudName(request, text: text)
    }
}

// MARK: - 信息面板

struct CloudMountInfoView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    private var mount: CloudMount? {
        guard case .cloudMount(let id) = store.sidebarItem else { return nil }
        return cloud.mounts.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mount {
                Text(mount.name)
                    .font(.system(size: 13, weight: .semibold))
                row("类型", mount.kind.title)
                if mount.kind == .webdav || mount.kind == .smb {
                    row("服务器", mount.baseURL)
                    if !mount.username.isEmpty {
                        row("账号", mount.username)
                    }
                } else if mount.kind == .aliyun {
                    row("授权", "refresh_token（自动续期）")
                } else if mount.kind == .quark {
                    row("授权", "浏览器 Cookie（已登录）")
                } else {
                    row("授权", "已通过官方 OAuth 登录")
                }
                row("当前路径", store.cloudBreadcrumbChain.map(\.name).joined(separator: " / "))
                row("内容", "\(store.cloudRootFolders.count) 个相簿 · \(cloud.photos.count) 个媒体")
                Text(mount.kind == .smb
                     ? "SMB 挂载。只读浏览，原图与视频按需读取，缩略图缓存在本地图库；不支持上传、重命名与删除。"
                     : store.isCurrentCloudWritable
                        ? "WebDAV 挂载。原图与视频按需读取，缩略图写入本地缓存；支持上传、重命名、新建文件夹与删除。"
                        : "官方网盘挂载。原图与视频按需读取，缩略图为服务端生成；当前为只读浏览。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("网络存储")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 网盘人物（端侧聚类，仅内存）

/// 网盘人物页：与本地人物页同一套端侧 Vision 聚类，结果只保存在内存，切换网盘即清空。
struct CloudPeopleView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedPersonID: UUID?

    private var people: [LocalPerson] { store.cloudPeople }

    private var selectedPerson: LocalPerson? {
        guard let selectedPersonID else { return nil }
        return people.first(where: { $0.id == selectedPersonID })
    }

    private var cardSize: CGFloat {
        min(300, max(72, CGFloat(store.thumbSize)))
    }

    var body: some View {
        Group {
            if let person = selectedPerson {
                personDetail(person)
            } else {
                overview
            }
        }
        .onAppear { store.scanCloudPeopleIfNeeded() }
        .onChange(of: people.map(\.id)) { _, ids in
            if let selectedPersonID, !ids.contains(selectedPersonID) {
                self.selectedPersonID = nil
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("人物")
                        .font(.system(size: 28, weight: .bold))
                    Text("端侧识别与聚类 · \(people.count) 位 · 结果缓存在当前图库，不会上传或写回网盘")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if cloud.isClusteringPeople {
                        store.cancelCloudPeopleScan()
                    } else {
                        store.scanCloudPeople()
                    }
                } label: {
                    Label(cloud.isClusteringPeople ? "停止分析" : (people.isEmpty ? "开始分析" : "继续分析"),
                          systemImage: cloud.isClusteringPeople ? "stop.circle" : "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(cloud.isClusteringPeople ? "停止人物分析" : "分析尚未处理过的网盘照片")
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if cloud.isClusteringPeople {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: cloud.peopleProgress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("正在分析 \(Int((cloud.peopleProgress * 100).rounded()))%")
                        Text("· 已识别 \(people.count) 位人物")
                        Spacer()
                        Button("停止") { store.cancelCloudPeopleScan() }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 12)
            }

            if people.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35),
                                                 spacing: cardSize * 0.16, alignment: .top)],
                              alignment: .leading,
                              spacing: cardSize * 0.16) {
                        ForEach(people) { person in
                            personCard(person)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 4)
                    .padding(.bottom, 48)
                }
            }
        }
    }

    private func personCard(_ person: LocalPerson) -> some View {
        Button {
            selectedPersonID = person.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let data = person.coverImageData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.primary.opacity(0.06)
                            Image(systemName: "person.fill")
                                .font(.system(size: cardSize * 0.3))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: cardSize, height: cardSize)
                .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))

                Text(person.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("\(person.assetIDs.count) 张")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: cardSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(person.name)
    }

    private func personDetail(_ person: LocalPerson) -> some View {
        let photos = store.cloudPhotos(for: person)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    selectedPersonID = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("返回人物列表")

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 20, weight: .bold))
                    Text("\(photos.count) 张照片 · 仅本机识别")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 12)

            GeometryReader { proxy in
                ScrollView {
                    SquarePhotoGrid(photos: photos,
                                    availableWidth: proxy.size.width,
                                    viewerContext: photos)
                        .padding(.bottom, 48)
                }
            }
        }
    }
}

// MARK: - 网盘重复项目（只读）

/// 网盘重复项目页：按「文件大小 + 像素尺寸」分组，只读展示。
/// 网盘文件不能在本机合并，界面会提示到网盘 App 中处理。
struct CloudDuplicatesView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    private var groups: [DuplicateGroup] { store.cloudDuplicateGroups }

    private var reclaimable: Int64 {
        groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("重复项目")
                        .font(.system(size: 28, weight: .bold))
                    Text("\(groups.count) 组 · 可释放约 \(formatFileSize(reclaimable)) · 网盘只读，请到网盘 App 中合并")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if groups.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            groupCard(group)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 48)
                }
            }
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Array(group.photos.prefix(4))) { photo in
                    PhotoThumbnailView(photo: photo, purpose: .cover(64))
                        .frame(width: 64, height: 64)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: max(8, settings.smallCoverRadius), style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(group.photos.first?.originalName ?? "重复项目")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("\(group.photos.count) 个副本 · 可释放 \(formatFileSize(group.reclaimableBytes))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("建议保留：\(group.keepReasons.joined(separator: "、"))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("查看") {
                store.openViewer(group.keepID, context: group.photos)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .contextMenu {
            ForEach(Array(group.photos.prefix(6))) { photo in
                Button("打开「\(photo.originalName)」") {
                    store.openViewer(photo.id, context: group.photos)
                }
            }
        }
        .help("网盘只读，合并请到网盘 App 操作")
    }
}

// MARK: - 网盘图库体检（只读）

/// 网盘图库体检：对当前目录逐张取缩略图检查清晰度、归并相似连拍、统计过大视频。
/// 全部在本机完成，结果缓存在当前图库的 `derived_reports`；网盘只读，因此只做检查与预览，不提供清理动作。
struct CloudHealthView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    private var report: LibraryHealthReport? { cloud.healthReport }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if cloud.isScanningHealth {
                    progress
                } else if let report {
                    summary(report)
                    blurrySection(report)
                    similarSection(report)
                    videoSection(report)
                    Text("网盘只读：体检只做检查与预览，清理请到网盘 App 操作。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("图库体检")
                    .font(.system(size: 27, weight: .bold))
                Text("在本机检查当前网盘目录的模糊照片、相似连拍与过大视频，不上传、不修改网盘")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if cloud.isScanningHealth {
                Button("停止") { store.cancelCloudHealthScan() }
                    .controlSize(.small)
                    .help("停止本次体检")
            } else {
                Button {
                    store.showBeautyPanel = true
                } label: {
                    Label("智能美化", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.small)
                .disabled(!store.canScanBeauty)
                .help("按画面偏差推荐可美化的照片，美化副本会保存到拾光本地图库")

                Button {
                    store.scanCloudHealth()
                } label: {
                    Label(report == nil ? "开始体检" : "重新体检", systemImage: "stethoscope")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.small)
                .disabled(!store.canScanCloudHealth)
                .help("用缩略图检查当前网盘目录")
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: cloud.healthScanProgress)
                .progressViewStyle(.linear)
            Text("正在检查照片清晰度与相似度… \(Int(cloud.healthScanProgress * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有体检结果")
                .font(.system(size: 16, weight: .semibold))
            Text("体检会用当前目录的缩略图评估清晰度，并顺带提取特征向量归并相似连拍。首次扫描需要逐张读取网盘缩略图。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Button("开始体检") { store.scanCloudHealth() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private func summary(_ report: LibraryHealthReport) -> some View {
        HStack(spacing: 12) {
            metric(title: "可能模糊", value: "\(report.blurry.count) 张", icon: "camera.metering.unknown")
            metric(title: "相似备选", value: "\(report.similarDuplicatePhotos.count) 张", icon: "square.on.square")
            metric(title: "可释放", value: formatFileSize(report.reclaimableBytes), icon: "internaldrive")
            metric(title: "已检查", value: "\(report.scannedCount) 张", icon: "checkmark.seal")
        }
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private func blurrySection(_ report: LibraryHealthReport) -> some View {
        if !report.blurry.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("可能模糊")
                    .font(.system(size: 15, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(report.blurry.prefix(12)) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            PhotoThumbnailView(photo: finding.photo, purpose: .cover(110))
                                .frame(height: 96)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(finding.photo.originalName)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                            Text("清晰度 \(Int(finding.score))")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func similarSection(_ report: LibraryHealthReport) -> some View {
        if !report.similarGroups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("相似连拍分组")
                    .font(.system(size: 15, weight: .semibold))
                ForEach(report.similarGroups.prefix(6)) { group in
                    HStack(spacing: 10) {
                        PhotoThumbnailView(photo: group.best, purpose: .cover(96))
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("建议保留：\(group.best.displayTitle)")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text("\(group.duplicates.count) 张备选 · 相似度 \(Int(group.similarity * 100))%")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        ForEach(group.duplicates.prefix(4)) { photo in
                            PhotoThumbnailView(photo: photo, purpose: .cover(56))
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .opacity(0.75)
                        }
                    }
                    .padding(9)
                    .background(Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func videoSection(_ report: LibraryHealthReport) -> some View {
        if !report.largeVideos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("过大视频")
                    .font(.system(size: 15, weight: .semibold))
                ForEach(report.largeVideos.prefix(8)) { photo in
                    HStack(spacing: 10) {
                        PhotoThumbnailView(photo: photo, purpose: .cover(72))
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(photo.originalName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Text(formatFileSize(photo.fileSize))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
    }
}


