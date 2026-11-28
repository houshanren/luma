import Foundation

extension LibraryStore {
    // MARK: - 上下文胶囊

    /// 把当前范围、选中、搜索、影院与查看器整理成可见胶囊。
    func refreshAIContextCapsules() {
        var capsules: [AIContextCapsule] = []

        // 工作台整页时不能用「助手」当范围名：对话的上下文仍是进入前的那个页面。
        let rangeTitle = aiSurfaceMode == .workspace ? aiWorkspaceOriginTitle : sidebarTitle
        capsules.append(AIContextCapsule(
            kind: .range,
            title: rangeTitle,
            detail: "\(visibleCount.formatted()) 项",
            isEnabled: !aiMutedContextKinds.contains(AIContextKind.range.rawValue)
        ))

        if !selection.isEmpty {
            capsules.append(AIContextCapsule(
                kind: .selection,
                title: "选中 \(selection.count) 项",
                detail: "优先作为候选",
                isEnabled: !aiMutedContextKinds.contains(AIContextKind.selection.rawValue)
            ))
        }

        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty || aiSearchOverview != nil {
            capsules.append(AIContextCapsule(
                kind: .search,
                title: search.isEmpty ? "搜索结果" : "搜索「\(search)」",
                detail: aiSearchOverview.map { "\($0.total) 项" } ?? "",
                isEnabled: !aiMutedContextKinds.contains(AIContextKind.search.rawValue)
            ))
        }

        switch sidebarItem {
        case .cinema, .cloudCinema:
            capsules.append(AIContextCapsule(
                kind: .cinema,
                title: "影院",
                detail: cinemaScopeName(cinemaActiveScope),
                isEnabled: !aiMutedContextKinds.contains(AIContextKind.cinema.rawValue)
            ))
        default:
            break
        }

        if let photo = viewerPhoto {
            capsules.append(AIContextCapsule(
                kind: .viewer,
                title: photo.isVideo ? "正在看视频" : "正在看照片",
                detail: photo.displayFilename,
                isEnabled: !aiMutedContextKinds.contains(AIContextKind.viewer.rawValue)
            ))
        }

        if !aiMentionedPhotoIDs.isEmpty || aiMentionedTimecode != nil {
            var details: [String] = []
            if !aiMentionedPhotoIDs.isEmpty {
                details.append("\(aiMentionedPhotoIDs.count) 项")
            }
            if let timecode = aiMentionedTimecode {
                details.append(Self.aiTimecodeText(timecode))
            }
            capsules.append(AIContextCapsule(
                kind: .mention,
                title: "指认",
                detail: details.joined(separator: " · "),
                isEnabled: !aiMutedContextKinds.contains(AIContextKind.mention.rawValue)
            ))
        }

        aiContextCapsules = capsules
    }

    /// 关掉 / 打开一种上下文：下一轮提示词会真的少这一块。
    func toggleAIContext(_ kind: AIContextKind) {
        if aiMutedContextKinds.contains(kind.rawValue) {
            aiMutedContextKinds.remove(kind.rawValue)
        } else {
            aiMutedContextKinds.insert(kind.rawValue)
        }
        refreshAIContextCapsules()
    }

    func isAIContextEnabled(_ kind: AIContextKind) -> Bool {
        !aiMutedContextKinds.contains(kind.rawValue)
    }

    // MARK: - 入口与呈现

    /// 侧栏是否可用：编辑器与视频全屏一定让位；查看器默认让位，可在设置里关掉。
    var aiDockAvailable: Bool {
        if viewerModel.editorID != nil || viewerModel.videoImmersiveFullScreen { return false }
        let autoHide = UserDefaults.standard.object(forKey: "ai.surface.autoHide") as? Bool ?? true
        if autoHide, viewerPhoto != nil { return false }
        return true
    }

    /// 从其它界面带入一句话：按当前上下文选择侧栏或浮窗。
    func askAI(_ prompt: String) {
        aiInput = prompt
        presentAIWorkspace()
    }

    /// 用户偏好的默认形态：并排 / 叠放 / 浮窗。工作台是页面，不作为「打开助手」的默认形态。
    private var aiPreferredSurface: AISurfaceMode {
        switch UserDefaults.standard.string(forKey: "ai.surface.default") {
        case "floating": return .floating
        case "overlay": return aiDockAvailable ? .overlay : .floating
        default: return aiDockAvailable ? .docked : .floating
        }
    }

    /// 统一的打开入口：按偏好打开；侧栏不可用（看图 / 播放 / 编辑器）时退回浮窗。
    func presentAIWorkspace() {
        // 已经在工作台页：不改变形态，只把焦点送回输入框。
        if aiSurfaceMode == .workspace {
            refreshAIContextCapsules()
            aiFocusRequest &+= 1
            return
        }
        let preferred = aiPreferredSurface
        aiSurfaceMode = (preferred == .docked && !aiDockAvailable) ? .floating : preferred
        refreshAIContextCapsules()
        aiFocusRequest &+= 1
    }

    /// 入口按钮：点一次打开，再点一次收起。
    func toggleAIWorkspace() {
        if aiSurfaceMode == .hidden {
            presentAIWorkspace()
        } else {
            hideAISurface()
        }
    }

    /// 兼容旧调用：⌘J 与入口按钮统一走 toggleAIWorkspace。
    func toggleAIInspector() {
        toggleAIWorkspace()
    }

    /// ⇧⌘J / 展开：同一段对话放进浮窗。
    func expandAISurface() {
        leaveAIWorkspacePageIfNeeded()
        aiSurfaceMode = .floating
        refreshAIContextCapsules()
        aiFocusRequest &+= 1
    }

    /// 叠放：侧栏盖在页面上，不挤压当前布局。
    func overlayAISurface() {
        leaveAIWorkspacePageIfNeeded()
        aiSurfaceMode = aiDockAvailable ? .overlay : .floating
        refreshAIContextCapsules()
        aiFocusRequest &+= 1
    }

    /// 工作台：左侧菜单里的独立一页，整幅对话。
    /// 不清理当前选择与搜索——它们正是用户带进对话的上下文。
    func openAIWorkspacePage() {
        // 看图 / 播放 / 编辑器里没有「整页」可言：页面会被它们的全窗覆盖，统一退回浮窗。
        if viewerPhoto != nil || viewerModel.editorID != nil {
            expandAISurface()
            return
        }
        if sidebarItem != .assistant {
            aiWorkspaceOriginItem = sidebarItem
            aiWorkspaceOriginTitle = sidebarTitle
            sidebarItem = .assistant
        }
        aiSurfaceMode = .workspace
        refreshAIContextCapsules()
        aiFocusRequest &+= 1
    }

    /// 离开工作台页：回到进入前的页面与选择。
    private func leaveAIWorkspacePageIfNeeded() {
        guard aiSurfaceMode == .workspace || sidebarItem == .assistant else {
            aiWorkspaceOriginItem = nil
            return
        }
        let target = aiWorkspaceOriginItem ?? .library
        aiWorkspaceOriginItem = nil
        if sidebarItem == .assistant {
            sidebarItem = target
        }
    }

    /// 控制台 / 菜单的形态切换：四种形态走同一入口。
    func selectAISurface(_ mode: AISurfaceMode) {
        switch mode {
        case .hidden:
            hideAISurface()
        case .docked:
            leaveAIWorkspacePageIfNeeded()
            guard aiDockAvailable else { return }
            aiSurfaceMode = .docked
            refreshAIContextCapsules()
            aiFocusRequest &+= 1
        case .overlay:
            overlayAISurface()
        case .floating:
            expandAISurface()
        case .workspace:
            openAIWorkspacePage()
        }
    }

    /// 浮窗 / 叠放 / 工作台收进并排侧栏；侧栏不可用时直接收起。
    func collapseAISurface() {
        leaveAIWorkspacePageIfNeeded()
        aiSurfaceMode = aiDockAvailable ? .docked : .hidden
        if aiSurfaceMode == .docked {
            refreshAIContextCapsules()
            aiFocusRequest &+= 1
        }
    }

    func hideAISurface() {
        leaveAIWorkspacePageIfNeeded()
        aiSurfaceMode = .hidden
    }

    /// 浮窗 / 叠放 / 工作台统一收成并排侧栏。
    func dockAISurface() {
        leaveAIWorkspacePageIfNeeded()
        aiSurfaceMode = aiDockAvailable ? .docked : .hidden
        if aiSurfaceMode == .docked {
            refreshAIContextCapsules()
            aiFocusRequest &+= 1
        }
    }

    // MARK: - 成果物

    /// 把工具结果转成可保存的成果物卡。规则集中在这里，工具实现不感知 UI。
    func makeAIArtifacts(for call: AIToolCall,
                         args: [String: Any],
                         result: AIToolExecution) -> [AIArtifact] {
        guard !result.artifacts.isEmpty else {
            return derivedAIArtifacts(for: call, args: args, result: result)
        }
        return result.artifacts
    }

    private func derivedAIArtifacts(for call: AIToolCall,
                                    args: [String: Any],
                                    result: AIToolExecution) -> [AIArtifact] {
        switch call.name {
        case "create_albums":
            let specs = AILibraryTools.objectArray(args["albums"])
            let names = specs.compactMap { AILibraryTools.string($0["name"]) }
            guard !names.isEmpty else { return [] }
            let detail = names.prefix(4).joined(separator: "、")
                + (names.count > 4 ? " 等 \(names.count) 个" : "")
            let albumID = firstCreatedAlbumID(from: result.json)
            return [AIArtifact(kind: .album,
                               title: "已创建 \(names.count) 个相簿",
                               detail: detail,
                               count: names.count,
                               albumID: albumID)]

        case "trash_photos":
            let ids = AILibraryTools.stringArray(args["photo_ids"]).compactMap { UUID(uuidString: $0) }
            return [AIArtifact(kind: .cleanupList,
                               title: "清理清单",
                               detail: "已移入最近删除，可随时恢复",
                               count: ids.count,
                               photoIDs: ids)]

        case "library_health_report":
            return [AIArtifact(kind: .report,
                               title: "图库体检报告",
                               detail: result.summary ?? "模糊、相似、大视频与可释放空间",
                               count: result.photoIDs.count)]

        case "today_digest":
            return [AIArtifact(kind: .report,
                               title: "今日日报",
                               detail: result.summary ?? "新资源、追更、续看与今晚节目",
                               count: 0)]

        case "play_trip_memory":
            return [AIArtifact(kind: .memoryMovie,
                               title: "回忆影片",
                               detail: result.summary ?? "已开始播放",
                               count: result.photoIDs.count,
                               photoIDs: result.photoIDs)]

        case "apply_cinema_match", "scrape_cinema", "match_cinema":
            return [AIArtifact(kind: .cinemaReport,
                               title: "影院整理",
                               detail: result.summary ?? "匹配与刮削结果",
                               count: result.photoIDs.count)]

        case "compress_photos", "beautify_photos":
            return [AIArtifact(kind: .report,
                               title: call.name == "compress_photos" ? "压缩结果" : "美化结果",
                               detail: result.summary ?? "处理完成",
                               count: result.photoIDs.count,
                               photoIDs: result.photoIDs)]

        default:
            return []
        }
    }

    private func firstCreatedAlbumID(from json: String) -> UUID? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let albums = root["albums"] as? [[String: Any]] else { return nil }
        for album in albums {
            if let raw = album["id"] as? String, let id = UUID(uuidString: raw) {
                return id
            }
        }
        return nil
    }

    /// 记录成果物；同一标题只保留一份，避免一次任务里反复刷屏。
    func recordAIArtifacts(_ artifacts: [AIArtifact]) {
        guard !artifacts.isEmpty else { return }
        for artifact in artifacts {
            if let index = aiArtifacts.firstIndex(where: {
                $0.kind == artifact.kind && $0.title == artifact.title
            }) {
                aiArtifacts[index] = artifact
            } else {
                aiArtifacts.append(artifact)
            }
            if let index = aiArtifactLibrary.firstIndex(where: {
                $0.kind == artifact.kind && $0.title == artifact.title
            }) {
                aiArtifactLibrary[index] = artifact
            } else {
                aiArtifactLibrary.append(artifact)
            }
        }
        persistAIArtifactLibrary()
    }

    /// 从跨对话成果物库里移除一条。
    func removeAIArtifact(_ artifact: AIArtifact) {
        aiArtifactLibrary.removeAll { $0.id == artifact.id }
        persistAIArtifactLibrary()
        showToast("已从成果物库移除")
    }

    // MARK: - 成果物库持久化

    private var aiArtifactFileURL: URL {
        let dir = LibraryPaths.overlayRoot.appendingPathComponent("ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artifacts.json")
    }

    func loadAIArtifactLibrary() {
        let url = aiArtifactFileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AIArtifact].self, from: data) else {
            aiArtifactLibrary = []
            return
        }
        aiArtifactLibrary = decoded
    }

    func persistAIArtifactLibrary() {
        guard let data = try? JSONEncoder().encode(aiArtifactLibrary) else { return }
        try? data.write(to: aiArtifactFileURL, options: .atomic)
    }

    /// 旧对话里已有的成果物补进成果物库，避免升级后「历史成果物消失」。
    func backfillAIArtifactLibraryFromMessages() {
        var changed = false
        for message in aiMessages {
            for artifact in message.artifacts {
                guard !aiArtifactLibrary.contains(where: {
                    $0.kind == artifact.kind && $0.title == artifact.title
                }) else { continue }
                aiArtifactLibrary.append(artifact)
                changed = true
            }
        }
        if changed { persistAIArtifactLibrary() }
    }

    /// 打开成果物：跳到对应模块；报告类留在对话里。
    func openAIArtifact(_ artifact: AIArtifact) {
        switch artifact.kind {
        case .album:
            if let albumID = artifact.albumID,
               albums.contains(where: { $0.id == albumID }) {
                sidebarItem = .album(albumID)
            } else {
                showToast("相簿已不在当前图库")
            }
        case .cleanupList:
            sidebarItem = .trash
        case .cinemaReport:
            sidebarItem = .cinema
        case .report, .playlist, .memoryMovie, .unknown:
            showToast("\(artifact.kind.title)已保存在对话里")
        }
    }
}
