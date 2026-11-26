import AppKit
import Foundation
import LumaContentCore

extension IPTVBrowserModel {
    // MARK: - 拉取

    func refreshIfNeeded() {
        guard enabled, !hasLoaded, !isLoading else { return }
        // 清单 6 小时内直接用库里的缓存，避免每次启动都全量拉一遍；
        // 源库里的「刷新」是显式操作，不受这个 TTL 限制。
        if let refreshedAt,
           Date().timeIntervalSince(refreshedAt) < 6 * 3600,
           !channelCache.isEmpty {
            hasLoaded = true
            rebuildChannels()
            return
        }
        refresh()
    }

    func refreshIfNeeded(forcePlaylist id: UUID) {
        guard enabled, channelCache[id] == nil else { return }
        refresh()
    }

    func refresh() {
        guard enabled else { return }
        tasks.cancel(.tvLoad)
        let targets = playlists.filter(\.isEnabled)
        guard !targets.isEmpty else {
            channels = []
            error = "所有电视源都被关闭了，打开至少一条后再刷新。"
            return
        }

        isLoading = true
        error = nil
        sourceError = nil
        failedPlaylistIDs = []

        tasks.adopt(.tvLoad, Task { [weak self] in
            var failures: [UUID] = []
            var firstError: SourceError?

            await withTaskGroup(of: (UUID, Int, Result<TVSourceSnapshot, SourceError>).self) { group in
                for playlist in targets {
                    group.addTask {
                        let started = Date()
                        do {
                            let snapshot = try await IPTVService.load(for: playlist)
                            let ms = Int(Date().timeIntervalSince(started) * 1000)
                            return (playlist.id, ms, .success(snapshot))
                        } catch let error as SourceError {
                            return (playlist.id, 0, .failure(error))
                        } catch {
                            return (playlist.id, 0,
                                    .failure(SourceError(kind: .unavailable,
                                                         message: error.localizedDescription)))
                        }
                    }
                }
                for await (id, latency, result) in group {
                    guard let self, !Task.isCancelled else { return }
                    switch result {
                    case .success(let snapshot):
                        let list = snapshot.channels
                        self.channelCache[id] = list
                        self.database.replaceChannels(list, for: id)
                        self.applyEPGURL(snapshot.epgURLString, for: id)
                        self.updateHealth(id: id,
                                          latency: latency,
                                          count: list.count,
                                          errorMessage: nil)
                        // 拉到新频道表：该源的修订号自增，旧快照不再可信。
                        LibraryStore.current?.sourceContentCache.bump(.television(id))
                        // 两条源并行拉取：先成功的（通常是国内源）立即上屏，
                        // 不必等另一条超时结束。
                        self.rebuildChannels()
                    case .failure(let failure):
                        failures.append(id)
                        self.updateHealth(id: id,
                                          latency: nil,
                                          count: nil,
                                          errorMessage: failure.message)
                        if firstError == nil { firstError = failure }
                    }
                }
            }

            guard let self, !Task.isCancelled else { return }
            self.rebuildChannels()
            self.failedPlaylistIDs = Set(failures)
            self.isLoading = false
            self.hasLoaded = true
            if self.channels.isEmpty, let firstError {
                self.sourceError = firstError
                self.error = firstError.message
            } else if let firstError {
                self.error = "部分电视源加载失败：\(firstError.message)"
            }
            if !self.channels.isEmpty {
                let now = Date()
                self.refreshedAt = now
                self.database.setSetting("refreshedAt", String(now.timeIntervalSince1970))
                UserDefaults.standard.set(now, forKey: Keys.refreshedAt)
            }
            self.persistPlaylists()
        })
    }

    func cancelLoading() {
        tasks.cancel(.tvLoad)
        isLoading = false
    }

    // MARK: - 连接检查（串行队列）

    /// 把源加入检测队列：一次只测一条，避免同时打多个站点；任务条里能看到进度。
    func enqueueConnectionChecks(_ ids: [UUID]) {
        guard enabled else { return }
        let pending = Set(checkQueue)
        for id in ids where !pending.contains(id) && !checkQueue.contains(id) {
            checkQueue.append(id)
        }
        guard !checkQueue.isEmpty else { return }
        isChecking = true
        guard !tasks.isRunning(.tvCheck) else { return }
        tasks.adopt(.tvCheck, Task { [weak self] in
            while let self, !Task.isCancelled {
                guard !self.checkQueue.isEmpty else { break }
                let id = self.checkQueue.removeFirst()
                await self.performConnectionCheck(id)
            }
            guard let self else { return }
            self.tasks.finish(.tvCheck)
            self.isChecking = false
        })
    }

    func checkAllSources() {
        enqueueConnectionChecks(playlists.filter(\.isEnabled).map(\.id))
    }

    func cancelChecks() {
        checkQueue.removeAll()
        tasks.cancel(.tvCheck)
        isChecking = false
    }

    /// 清空任务中心里的历史检测记录（不影响源本身的状态）。
    func clearCheckHistory() {
        jobCenter?.clearFinished(kind: .connectivity)
        onJobChange?()
    }

    func performConnectionCheck(_ id: UUID) async {
        guard let playlist = playlist(for: id), playlist.isEnabled else { return }
        let job = SourceJob(sourceID: .television(id),
                            kind: .connectivity,
                            title: "检测 \(playlist.name)")
        let jobID = jobCenter?.begin(job)
        onJobChange?()

        let started = Date()
        do {
            let snapshot = try await IPTVService.load(for: playlist)
            let list = snapshot.channels
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            channelCache[id] = list
            database.replaceChannels(list, for: id)
            applyEPGURL(snapshot.epgURLString, for: id)
            updateHealth(id: id, latency: ms, count: list.count, errorMessage: nil)
            rebuildChannels()
            persistPlaylists()
            if let jobID {
                jobCenter?.finish(jobID, message: "\(list.count) 个频道 · \(ms) ms")
            }
        } catch {
            let message = (error as? SourceError)?.message ?? error.localizedDescription
            updateHealth(id: id, latency: nil, count: nil, errorMessage: message)
            persistPlaylists()
            if let jobID {
                jobCenter?.fail(jobID, message: message)
            }
        }
        onJobChange?()
    }

    func updateHealth(id: UUID,
                              latency: Int?,
                              count: Int?,
                              errorMessage: String?) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].lastCheckedAt = Date()
        playlists[index].lastLatencyMilliseconds = latency
        playlists[index].lastChannelCount = count
        playlists[index].lastError = errorMessage
    }
}
