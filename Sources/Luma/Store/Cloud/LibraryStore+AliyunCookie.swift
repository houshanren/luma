import Foundation

// MARK: - 阿里云盘（Cookie / refresh_token 直连）

extension LibraryStore {
    /// 用根目录列表验证 Cookie / refresh_token 是否可用。
    func testAliyunCookie(_ input: String) async -> (ok: Bool, message: String) {
        do {
            let token = try await AliyunCookieAuth.token(from: input)
            let drives = try await AliyunOAuth.drives(accessToken: token.accessToken)
            guard !drives.isEmpty else { throw CloudOAuthError.api("未获取到网盘信息") }
            var folders = 0
            var media = 0
            for drive in drives {
                let entries = try await AliyunOAuth.list(driveID: drive.id,
                                                         parentID: "root",
                                                         accessToken: token.accessToken)
                folders += entries.filter { $0.isDirectory }.count
                media += entries.filter { !$0.isDirectory && $0.isMedia }.count
            }
            let names = drives.map(\.label).joined(separator: " / ")
            return (true, "连接成功：\(names)，根目录合计 \(folders) 个文件夹、\(media) 个媒体文件")
        } catch let error as CloudOAuthError where error.requiresReauth {
            return (false, "登录凭据已失效：请打开 https://alist.nn.ci/tool/aliyundrive/request 重新扫码，复制新的 refresh_token")
        } catch {
            return (false, "连接失败：\(error.localizedDescription)")
        }
    }

    /// 添加或更新阿里云盘的 Cookie 连接。
    func registerAliyunCookieMount(input: String,
                                   name: String = "阿里云盘",
                                   scopes: [CloudScopeRoot]? = nil,
                                   excludes: [CloudScopeRoot]? = nil) async -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "请先粘贴 Cookie 或 refresh_token" }

        let token: CloudToken
        let info: (driveID: String, name: String?)
        do {
            token = try await AliyunCookieAuth.token(from: text)
            info = try await AliyunOAuth.driveInfo(accessToken: token.accessToken)
        } catch {
            return error.localizedDescription
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "阿里云盘" : trimmedName

        if let existing = cloudMounts.first(where: { $0.kind == .aliyun && $0.authMode == .cookie }) {
            updateCloudMountAccess(existing.id, scopes: scopes, excludes: excludes)
            if let index = cloudMounts.firstIndex(where: { $0.id == existing.id }) {
                cloudMounts[index].remoteDriveID = info.driveID
                if !trimmedName.isEmpty { cloudMounts[index].name = finalName }
            }
            CloudCredentials.setPassword(text, for: existing.id)
            CloudOAuthStore.saveToken(token, mountID: existing.id)
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(existing.id.uuidString) }
            cloudVisibleCacheKey = nil
            saveCloudMounts()
            landOnCloudMount(existing.id)
            showToast("已更新「\(cloudMounts.first(where: { $0.id == existing.id })?.name ?? finalName)」的登录凭据")
            return nil
        }

        let mount = CloudMount(kind: .aliyun,
                               name: finalName,
                               remoteDriveID: info.driveID,
                               authMode: .cookie,
                               scopeRoots: scopes ?? [],
                               excludedRoots: excludes ?? [])
        CloudCredentials.setPassword(text, for: mount.id)
        CloudOAuthStore.saveToken(token, mountID: mount.id)
        cloudMounts.append(mount)
        saveCloudMounts()
        showToast("已连接「\(finalName)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    // MARK: - 扫码登录（网页令牌）

    /// 扫码拿到的 refresh_token：换一次网页令牌并读根目录，验证凭据可用。
    /// 不写任何挂载，供向导在「确认」之前做校验。
    func validateAliyunWebCredential(refreshToken: String) async
        -> (ok: Bool, message: String, token: CloudToken?, driveID: String?) {
        let text = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return (false, "没有拿到有效的登录凭据，请重新扫码", nil, nil)
        }
        do {
            var token = try await AliyunWebDrive.refresh(refreshToken: text)
            let drives = try await AliyunWebDrive.drives(accessToken: token.accessToken)
            guard let first = drives.first else {
                throw CloudOAuthError.api("未获取到网盘信息")
            }
            let entries = try await AliyunWebDrive.list(driveID: first.id,
                                                        parentID: "root",
                                                        accessToken: token.accessToken)
            let folders = entries.filter(\.isDirectory).count
            let media = entries.filter { !$0.isDirectory && $0.isMedia }.count
            token.driveID = first.id
            return (true,
                    "扫码成功：\(first.label)根目录 \(folders) 个文件夹、\(media) 个媒体文件",
                    token,
                    first.id)
        } catch let error as CloudOAuthError where error.requiresReauth {
            return (false, "登录凭据已失效，请重新扫码", nil, nil)
        } catch {
            return (false, "登录失败：\(error.localizedDescription)", nil, nil)
        }
    }

    /// 添加或更新扫码接入的阿里云盘：令牌与 refresh_token 都写回同一个挂载。
    @discardableResult
    func registerAliyunWebMount(token: CloudToken,
                                driveID: String?,
                                name: String = "阿里云盘",
                                scopes: [CloudScopeRoot]? = nil,
                                excludes: [CloudScopeRoot]? = nil) -> String? {
        var stored = token
        if let driveID, !driveID.isEmpty { stored.driveID = driveID }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "阿里云盘" : trimmedName

        func applyCredential(to id: UUID) {
            if let refresh = stored.refreshToken, !refresh.isEmpty {
                CloudCredentials.setPassword(refresh, for: id)
            }
            CloudOAuthStore.saveToken(stored, mountID: id)
        }

        if let existing = cloudMounts.first(where: { $0.kind == .aliyun }) {
            updateCloudMountAccess(existing.id, scopes: scopes, excludes: excludes)
            if let index = cloudMounts.firstIndex(where: { $0.id == existing.id }) {
                cloudMounts[index].authMode = .webQR
                if let driveID, !driveID.isEmpty { cloudMounts[index].remoteDriveID = driveID }
                if !trimmedName.isEmpty { cloudMounts[index].name = finalName }
            }
            applyCredential(to: existing.id)
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(existing.id.uuidString) }
            cloudVisibleCacheKey = nil
            saveCloudMounts()
            landOnCloudMount(existing.id)
            showToast("已通过扫码连接「\(existing.name)」")
            return nil
        }

        let mount = CloudMount(kind: .aliyun,
                               name: finalName,
                               remoteDriveID: driveID,
                               authMode: .webQR,
                               scopeRoots: scopes ?? [],
                               excludedRoots: excludes ?? [])
        applyCredential(to: mount.id)
        cloudMounts.append(mount)
        saveCloudMounts()
        showToast("已连接「\(finalName)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    /// 向导「接入范围」的目录读取：扫码凭据走网页接口，其余走开放平台。
    /// 只有一个盘时直接读取真实根目录；多个盘才显示盘列表作为虚拟根。
    func aliyunScopeFolders(cookie: String, containerID: String,
                            preferWeb: Bool) async throws -> [CloudEntry] {
        func webEntries() async throws -> [CloudEntry] {
            let token = try await AliyunWebDrive.refresh(refreshToken: cookie)
            let drives = try await AliyunWebDrive.drives(accessToken: token.accessToken)
            guard !drives.isEmpty else {
                throw CloudOAuthError.api("未获取到网盘信息")
            }
            if containerID.isEmpty {
                if drives.count == 1, let drive = drives.first {
                    return try await AliyunWebDrive.list(driveID: drive.id,
                                                         parentID: "root",
                                                         accessToken: token.accessToken)
                }
                return drives.map {
                    CloudEntry(path: "\($0.id)|root",
                               name: $0.label,
                               isDirectory: true,
                               size: 0,
                               modifiedAt: nil,
                               contentType: nil)
                }
            }
            guard let target = AliyunOAuth.splitPath(containerID, fallbackDrive: nil) else {
                throw CloudOAuthError.api("阿里云盘目录无效，请返回根目录重新进入")
            }
            return try await AliyunWebDrive.list(driveID: target.drive,
                                                 parentID: target.fileID,
                                                 accessToken: token.accessToken)
        }
        func platformEntries() async throws -> [CloudEntry] {
            try await CloudSetupBrowser.folders(flow: .aliyunCookie,
                                                cookie: cookie,
                                                containerID: containerID)
        }
        if preferWeb {
            do {
                let entries = try await webEntries()
                Diagnostics.record("阿里云盘范围读取通道=web container=\(containerID.isEmpty ? "root" : containerID) 条目=\(entries.count)")
                return entries
            } catch {
                Diagnostics.record("阿里云盘范围读取 web 失败，改用开放平台：\(error.localizedDescription)")
            }
            return try await platformEntries()
        }
        do {
            return try await platformEntries()
        } catch {
            let platformError = error
            Diagnostics.record("阿里云盘范围读取开放平台失败，改用 web：\(platformError.localizedDescription)")
            do {
                return try await webEntries()
            } catch {
                Diagnostics.record("阿里云盘范围读取 web 也失败：\(error.localizedDescription)")
                throw platformError
            }
        }
    }
}
