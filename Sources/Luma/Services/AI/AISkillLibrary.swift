import Foundation

/// 内置技能：一段可复用的任务描述，点一下就能填入输入框或直接执行。
/// 技能不是新工具，只是把「怎么说」沉淀下来；执行仍走计划、审批与撤销。
struct AISkill: Identifiable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    /// 归属模块：图库 / 影院 / 电视 / 跨模块。
    let domain: String
    let prompt: String
    /// 是否包含写操作（界面给「会修改」提示）。
    let writes: Bool
}

enum AISkillLibrary {
    static let skills: [AISkill] = [
        AISkill(id: "month-albums",
                title: "按月份整理相簿",
                summary: "把当前范围按「年份 · 月份」分组，创建相簿并放入照片。",
                symbol: "calendar.badge.plus",
                domain: "图库",
                prompt: "把当前范围里的照片按拍摄月份整理成相簿，标题用「2025 · 03 月」这种格式；"
                    + "先给我计划，确认后再创建。",
                writes: true),
        AISkill(id: "trip-story",
                title: "旅行回忆影片",
                summary: "识别一次旅行，按时间顺序播放回忆影片，并保存为成果物。",
                symbol: "airplane.departure",
                domain: "图库",
                prompt: "找出最近一次旅行，按时间顺序播放回忆影片；播放前先说明这次旅行的地点、日期和照片数量。",
                writes: false),
        AISkill(id: "library-checkup",
                title: "图库月度体检",
                summary: "模糊、相似、大视频与可释放空间，给出一份可执行的清理建议。",
                symbol: "stethoscope",
                domain: "图库",
                prompt: "给当前图库做一次体检：模糊、相似、超大视频与可释放空间各占多少；"
                    + "给出清理建议，但先不要删除任何东西。",
                writes: false),
        AISkill(id: "duplicate-cleanup",
                title: "相似照片清理",
                summary: "找出相似照片，保留每组最清晰的一张，其余移入最近删除。",
                symbol: "square.on.square",
                domain: "图库",
                prompt: "找出相似照片，每组保留最清晰的一张，其余移入最近删除；先列出分组和数量让我确认。",
                writes: true),
        AISkill(id: "keyword-pass",
                title: "关键词补齐",
                summary: "给缺少关键词的照片补上人物、地点、事件三类标签。",
                symbol: "tag",
                domain: "图库",
                prompt: "检查当前范围里没有关键词的照片，按人物、地点、事件补关键词；先说明会改多少张。",
                writes: true),
        AISkill(id: "cinema-organize",
                title: "影院智能整理",
                summary: "扫描本地影院，匹配候选并刮削元数据，生成整理报告。",
                symbol: "popcorn",
                domain: "影院",
                prompt: "扫描本地影院，找出没匹配的影片与剧集，按置信度列出候选；确认后写回匹配结果。",
                writes: true),
        AISkill(id: "cinema-tonight",
                title: "今晚看什么",
                summary: "结合未看完、片单与时长，给出今晚的三部候选。",
                symbol: "moon.stars",
                domain: "影院",
                prompt: "结合我的未看完、片单和今晚可用时间，推荐三部电影，并说明每部的理由和时长。",
                writes: false),
        AISkill(id: "tv-tonight",
                title: "电视今晚节目",
                summary: "汇总今晚值得看的频道节目，按时段排序。",
                symbol: "tv",
                domain: "电视",
                prompt: "看看今晚的电视节目单，按时段列出值得看的节目；如果有我常看的频道，优先列出来。",
                writes: false),
        AISkill(id: "digest",
                title: "今日日报",
                summary: "新照片、新资源、追更与续看，汇总成一页日报。",
                symbol: "newspaper",
                domain: "跨模块",
                prompt: "生成今天的日报：新增照片、网络资源更新、追更与没看完的内容，各用一句话概括。",
                writes: false),
        AISkill(id: "week-report",
                title: "本周回顾",
                summary: "把这一周拍的照片、看过的片与整理结果写成一段回顾。",
                symbol: "chart.bar.doc.horizontal",
                domain: "跨模块",
                prompt: "回顾这一周：拍了哪些照片、看了哪些片、整理了哪些内容；写成一段不超过 200 字的回顾。",
                writes: false)
    ]
}

/// 连接器市场：内置一些常见的 MCP 服务器预设。
/// 只写配置，不自动安装依赖；启动失败会在设置页显示状态。
struct AIConnectorPreset: Identifiable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    let command: String
    let args: [String]
    /// 是否需要用户提供一个本地目录。
    let needsPath: Bool
}

enum AIConnectorMarket {
    static let presets: [AIConnectorPreset] = [
        AIConnectorPreset(id: "filesystem",
                          title: "文件系统",
                          summary: "让助手读写指定目录里的文本文件（不会碰照片原文件）。",
                          symbol: "folder.badge.gearshape",
                          command: "npx",
                          args: ["-y", "@modelcontextprotocol/server-filesystem"],
                          needsPath: true),
        AIConnectorPreset(id: "memory",
                          title: "本地记忆",
                          summary: "一个基于知识图谱的长期记忆服务器，数据留在本机。",
                          symbol: "brain.head.profile",
                          command: "npx",
                          args: ["-y", "@modelcontextprotocol/server-memory"],
                          needsPath: false),
        AIConnectorPreset(id: "git",
                          title: "Git 仓库",
                          summary: "读取指定仓库的提交、分支与文件差异。",
                          symbol: "point.topleft.down.to.point.bottomright.curvepath",
                          command: "uvx",
                          args: ["mcp-server-git", "--repository"],
                          needsPath: true),
        AIConnectorPreset(id: "fetch",
                          title: "网页抓取",
                          summary: "抓取网页并转成 Markdown，适合查资料。",
                          symbol: "globe",
                          command: "uvx",
                          args: ["mcp-server-fetch"],
                          needsPath: false)
    ]
}

extension LibraryStore {
    /// 填入技能：只写输入框，不自动发送。
    func fillAISkill(_ skill: AISkill) {
        aiInput = skill.prompt
        showAISkillsSheet = false
        presentAIWorkspace()
    }

    /// 立即执行技能：填入并发送。
    func runAISkill(_ skill: AISkill) {
        aiInput = skill.prompt
        showAISkillsSheet = false
        presentAIWorkspace()
        sendAIMessage()
    }

    /// 添加连接器预设：写进 mcp.json 后重新加载。
    func addAIConnector(_ preset: AIConnectorPreset, path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset.needsPath, trimmed.isEmpty {
            showToast("请先选择目录")
            return
        }
        var args = preset.args
        if preset.needsPath {
            args.append(trimmed)
        }
        let name = uniqueConnectorName(base: preset.id)
        do {
            try await MCPService.shared.addServer(MCPServerConfig(name: name,
                                                                  command: preset.command,
                                                                  args: args))
            await refreshMCPTools()
            showToast("已添加「\(preset.title)」连接器")
        } catch {
            showToast("写入 mcp.json 失败：\(error.localizedDescription)")
        }
    }

    private func uniqueConnectorName(base: String) -> String {
        let existing = Set(MCPService.shared.configuredServerNames)
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}
