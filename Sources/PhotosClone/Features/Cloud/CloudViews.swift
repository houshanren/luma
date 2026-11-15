import SwiftUI

// MARK: - 连接 / 编辑网络存储

struct CloudConnectSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var status: String?
    @State private var statusIsError = false

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

    private func loadExisting() {
        guard let editing else { return }
        name = editing.name
        address = editing.baseURL
        username = editing.username
    }

    private func runTest() {
        status = nil
        statusIsError = false
        isTesting = true
        let secret = effectivePassword
        let target = trimmedAddress
        let account = username
        Task {
            let result = await store.testCloudConnection(address: target,
                                                         username: account,
                                                         password: secret)
            isTesting = false
            status = result.message
            statusIsError = !result.ok
        }
    }

    private func save() {
        if let error = store.saveCloudMount(existing: editing,
                                            name: name,
                                            address: address,
                                            username: username,
                                            password: password) {
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

    private var mountID: UUID? {
        if case .cloudMount(let id) = store.sidebarItem { return id }
        return nil
    }

    private var mountName: String {
        cloud.mounts.first(where: { $0.id == mountID })?.name ?? "网络存储"
    }

    private var mountKind: CloudKind? {
        cloud.mounts.first(where: { $0.id == mountID })?.kind
    }

    private var isScanAll: Bool {
        mountKind == .smb && store.isCurrentCloudScanAll
    }

    private var mediaNote: String {
        if mountKind == .smb {
            return isScanAll
                ? "已递归扫描整个共享，共 \(cloud.photos.count) 个媒体；缩略图按需读取原文件并缓存在本地图库，不会修改 NAS 上的文件。"
                : "SMB 共享为只读浏览：缩略图按需读取共享中的原文件并缓存在本地图库，不会修改 NAS 上的文件。"
        }
        return store.isCurrentCloudWritable
            ? "缩略图按需加载：官方网盘用服务端缩略图；WebDAV 优先读内嵌缩略图，无内嵌时才会下载该文件。"
            : "官方网盘当前为只读浏览，缩略图由服务端提供；上传、重命名、删除请到网盘 App 操作。"
    }

    /// 当前目录的照片经过搜索、筛选与排序后的结果，与其它图库网格保持一致。
    private var photos: [PhotoItem] {
        store.cloudVisiblePhotos
    }

    private var isFiltering: Bool {
        store.photoFilter != .all || !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var pathText: String {
        if isScanAll { return "整个共享" }
        let trail = cloud.trail.map(\.name)
        return trail.isEmpty ? "/" : trail.joined(separator: " / ")
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                content(width: proxy.size.width)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                store.cloudGoUp()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cloud.trail.count <= 1)
            .help("返回上一级")

            VStack(alignment: .leading, spacing: 1) {
                Text(mountName)
                    .font(.system(size: 13, weight: .semibold))
                Text(pathText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if mountKind == .smb {
                Picker("", selection: Binding(
                    get: { store.isCurrentCloudScanAll },
                    set: { store.setCloudScanAll($0) }
                )) {
                    Text("整个共享").tag(true)
                    Text("按文件夹").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("递归扫描整个共享，或按文件夹浏览")
            }

            if let busy = cloud.busyText {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(busy)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else if cloud.loading {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                Button("新建文件夹…") {
                    store.requestCloudNewFolder()
                }
                Button("上传照片/视频…") {
                    store.presentCloudUploadPanel()
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新建文件夹或上传")
            .opacity(store.isCurrentCloudWritable ? 1 : 0)
            .disabled(!store.isCurrentCloudWritable)

            Button {
                store.refreshCloudDirectory()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("刷新当前文件夹")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = cloud.error {
                    errorView(error)
                        .padding(.horizontal, 20)
                }

                if !cloud.folders.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                        ForEach(cloud.folders) { entry in
                            CloudFolderTile(entry: entry)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                if photos.isEmpty, cloud.folders.isEmpty {
                    if cloud.loading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.large)
                            Spacer()
                        }
                        .padding(.top, 90)
                    } else if cloud.error == nil {
                        if isFiltering, !cloud.photos.isEmpty {
                            filteredEmptyView
                        } else {
                            emptyView
                        }
                    }
                } else if !photos.isEmpty {
                    switch store.thumbnailAspect {
                    case .square:
                        SquarePhotoGrid(photos: photos, availableWidth: width)
                            .padding(.horizontal, 20)
                    case .actual:
                        JustifiedPhotoGrid(photos: photos,
                                           availableWidth: width,
                                           targetHeight: CGFloat(store.thumbSize) * 0.92)
                            .padding(.horizontal, 20)
                    case .masonry:
                        MasonryPhotoGrid(photos: photos,
                                         availableWidth: width,
                                         targetWidth: CGFloat(store.thumbSize))
                            .padding(.horizontal, 20)
                    case .list:
                        PhotoListView(photos: photos, availableWidth: width)
                            .padding(.horizontal, 10)
                    }
                }

                if isFiltering, !cloud.photos.isEmpty, photos.count != cloud.photos.count {
                    Text("筛选后显示 \(photos.count) 项（共 \(cloud.photos.count) 项）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }

                if !cloud.photos.isEmpty {
                    Text(mediaNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 18)
        }
        .scrollIndicators(.automatic)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                Button("重试") {
                    store.refreshCloudDirectory()
                }
                .controlSize(.small)
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
            Text("调整筛选或搜索关键词后再试。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("清除筛选与搜索") {
                store.clearFilter()
                store.searchText = ""
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(isScanAll ? "整个共享没有扫描到照片或视频" : "此文件夹没有照片或视频")
                .font(.system(size: 15, weight: .semibold))
            Text(isScanAll ? "确认共享名正确，或切换到「按文件夹」逐层查看。" : "进入其他文件夹，或点按刷新重新读取。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

struct CloudFolderTile: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    let entry: CloudEntry
    @State private var isHovering = false

    var body: some View {
        Button {
            store.enterCloudFolder(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let date = entry.modifiedAt {
                        Text(DateText.dayFormatter.string(from: date))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: 60)
            .background {
                RoundedRectangle(cornerRadius: settings.cardRadius)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0.05))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("打开") {
                store.enterCloudFolder(entry)
            }
        }
        .help(entry.path)
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
                } else {
                    row("授权", "已通过官方 OAuth 登录")
                }
                row("当前路径", cloud.trail.map(\.name).joined(separator: " / "))
                row("内容", "\(cloud.folders.count) 个文件夹 · \(cloud.photos.count) 个媒体")
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
