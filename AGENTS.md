# AGENTS.md — 拾光 Luma 开发规范

本文件是本仓库的**架构约定与协作规范**，面向所有参与开发的人与 AI Agent。`README.md` 描述“产品是什么”，本文件描述“代码必须怎么写”。

修改代码前请先读完本文件；若实现与本文冲突，以本文为准并在同一次改动中更新本文。

---

## 1. 技术栈与硬约束

- Swift 5.9，最低 macOS 14，SwiftPM（`Package.swift`），**无第三方依赖**，仅链接系统 `libsqlite3`。
- UI 全部 SwiftUI；必须依赖 AppKit 能力时才 `import AppKit`（`NSOpenPanel`/`NSSavePanel`/`NSWorkspace`/`NSImage` 等）。
- 不引入 Combine 之外的响应式框架；状态由 `LibraryStore`（`ObservableObject` + `@Published`）统一承载。
- 不引入资源目录（`.xcassets`）；图标在 `Resources/AppIcon.icns`，由 `Tools/make_icon.swift` 绘制 1024 PNG 后用 `iconutil` 打包。
- 界面语言为简体中文，代码注释使用中文。

---

## 2. 构建与验证

```sh
./build.sh debug     # 日常开发
./build.sh           # release
open Luma.app
```

- 产物固定为仓库根目录 `Luma.app`（可执行文件 `Luma`，bundle `com.baymax.luma`，显示名「拾光」）。不要修改 `build.sh` 中的产物名。
- 只改代码不跑构建 = 未完成。每次交付前至少保证：
  1. `./build.sh debug` 退出码为 0；
  2. `open Luma.app` 后进程存活（不闪退）；
  3. 手动走一遍被改动的界面路径。
- 纯逻辑（布局、档位等）改动需跑 `swift run LumaCoreChecks`，断言失败会以非零码退出。命令行工具链没有 XCTest，新增纯逻辑优先放进 `Sources/LumaCore` 并在 `Tests/LumaCoreChecks/main.swift` 补断言。
- 临时脚本放 `/tmp`，不要提交。
- 若出现 `error: input file '...' was modified during the build`，说明有另一个构建/编辑进程在同时改动文件；等待数秒后重试，**不要**删除 `.build` 或中断他人构建。
- 需要连通性调试时可临时起本地服务（如 WebDAV 模拟），但不要向仓库添加测试服务器代码。

---

## 3. 架构与数据流

```
SwiftUI View ──读取 @Published / 调用方法──▶ LibraryStore ──▶ MetadataStore(SQLite)
      │                                          │
      └──── ImageLoader（缩略图/大图缓存） ◀──────┘──▶ LibraryPaths（文件系统） / CloudService（网络）
```

- **唯一状态源**：`LibraryStore`。视图不得自己持有照片/相簿数组，不得直接读写数据库或原图目录。
- **大图库浏览走分页窗口**：本地图库超过 `LibraryStore.windowThreshold`（5000）且处于「所有照片」网格时，`pagedQuery` 把范围/筛选/排序下推到 `MetadataStore+Query`，`visiblePhotos` 只返回已加载的窗口（每页 600）。视图里的总数一律用 `store.visibleCount` / `visibleVideoCount`，不要用 `visiblePhotos.count`。
- **唯一落盘入口**：
  - 元数据：`MetadataStore`（由 `LibraryStore.save()` 触发）。
  - 文件：`LibraryPaths` 提供的 URL + `FileManager`，且只能经由 `LibraryStore`/`ImportService`/`ImageLoader` 等服务层执行。
- **唯一路径入口**：`LibraryPaths`（本地）与 `CloudPaths`（网盘缓存）。除 `LibraryPaths.systemThumbs` 外，任何路径都不得在视图层拼接。
- **视图 → Store 单向调用**：Store 不持有任何 View；跨视图通信通过 Store 的 `@Published` 状态（如 `viewerID`、`showLibraryPicker`）。

### 文件职责

详见 `README.md` 的“目录结构”。几个关键点：

| 文件 | 职责 | 不要放什么 |
| --- | --- | --- |
| `Store/LibraryStore.swift` | 存储属性、初始化、持久化 | 具体绘制、Core Image 渲染细节 |
| `Store/LibraryStore+*.swift` | 按领域拆分的查询/组织/导入/系统图库/网盘等方法扩展 | 新的存储属性（extension 不能声明） |
| `Store/SelectionModel.swift` / `ViewerModel.swift` / `CloudBrowserModel.swift` | 选择、查看器、网盘浏览状态，独立 `ObservableObject` | 图库内容状态、业务规则 |
| `Store/LibraryStore+Paging.swift` | 大图库分页窗口：加载、追加、定位、查看器胶片条 | SQL 拼接、视图绘制 |
| `Store/LibraryStore+Intelligence.swift` | 端侧场景/OCR 分析编排、场景统计、相似照片范围 | 直接调用 Vision 请求（放 `PhotoIntelligence`） |
| `Store/LibraryStore+Health.swift` | 图库体检扫描、相似连拍分组、模糊与大视频统计、「值得重看」 | 视图绘制、直接解码原图 |
| `Domain/SceneTags.swift` | 场景目录 `SceneCatalog`、`PhotoAnalysis`、中文检索词表 | Vision/IO、视图状态 |
| `Domain/LibraryHealth.swift` | 图库体检结果模型（模糊项、相似组、大视频） | 扫描逻辑、IO |
| `Services/Media/PhotoIntelligence.swift` | Vision 分类 / OCR / 特征向量提取与归一化 | 业务规则、UI、数据库写入 |
| `Services/Media/PhotoQuality.swift` | 缩略图清晰度评估（拉普拉斯方差） | 缓存策略、业务规则 |
| `Services/Media/PhotoBeauty.swift` | 缩略图 256×256 采样亮度/色彩/清晰度，调用 `BeautyAdvisor` 出建议 | 阈值与业务规则（放 LumaCore）、UI |
| `Store/LibraryStore+Beauty.swift` | 智能美化：扫描推荐分组、批量渲染美化副本、应用前确认 | 视图绘制、SQL 拼接 |
| `Domain/BeautyRecommendation.swift` | 美化候选、分组与报告模型 | 扫描逻辑、IO |
| `Features/Organize/BeautyRecommendView.swift` | 智能美化推荐面板（分组卡片、查看、一键美化） | 扫描算法、路径拼接 |
| `Features/Editor/EditState+Beauty.swift` | 把美化建议按强度叠加到 `EditState` | 视图状态、扫描 |
| `Domain/AIAgentModels.swift` | 智能助手提供商、配置、对话与检索建议模型 | 网络请求、Keychain、视图状态 |
| `Services/AI/AIProviderClient.swift` | OpenAI 兼容的 chat/completions 请求与错误映射 | 业务规则、UI、持久化 |
| `Services/AI/AILibraryContext.swift` | 当前范围快照 → 提示词、检索建议解析 | 直接读数据库、发送请求 |
| `Services/AI/AIImageEncoder.swift` | 发送前把照片压成长边 1024 的 JPEG data URL | 保存图片、修改图库 |
| `Services/AI/AILibraryTools.swift` | 工具定义（搜索/相簿/收藏/关键词/选中）与参数解析 | 直接改图库、弹窗确认 |
| `Services/AI/AIKeychain.swift` | 智能助手 API Key 的钥匙串读写 | 把 Key 写入数据库或日志 |
| `Store/LibraryStore+AIAgent.swift` | 智能助手状态、请求编排、对话持久化、检索建议应用 | 直接拼接 HTTP 请求（放 `AIProviderClient`） |
| `Store/LibraryStore+AITools.swift` | 工具执行与写操作确认；只调用现有 Store 方法 | 绕过 `save()`、直接写 SQLite |
| `Features/AI/AIAssistantView.swift` | 智能助手面板（对话、照片引用、检索建议） | 网络与持久化细节 |
| `Features/Organize/LibraryHealthView.swift` | 图库体检页（指标、卡片、相似组预览、清理入口） | 扫描算法、路径拼接 |
| `Features/Maps/FootprintPlaybackView.swift` | 足迹回放覆盖层（地图折线、进度与调速） | 轨迹数据生成规则（放 Store） |
| `Domain/PhotoQuery.swift` | 可下推的范围/筛选/排序描述与 `SidebarItem` 映射 | SQL、IO |
| `Services/Library/MetadataStore+Query.swift` | `PhotoQuery` → SQL：count / page / index / neighbor / 索引提示 | UI、业务规则 |
| `Sources/LumaCore/` | 无 UI 依赖的纯算法：网格布局、缩略图档位、美化建议（`BeautyAdvisor`） | 任何 AppKit/SwiftUI/模型 IO |
| `Services/Library/LibraryPaths.swift` | 图库与系统路径的唯一入口 | 业务规则、UI |
| `Services/Import/ImportService.swift` | 导入、缩略图生成、预览缩略图 | 业务规则（由 Store 决定） |
| `Services/Media/ImageLoader.swift` | 缩略图/显示图解码与内存缓存 | 视图状态 |
| `Services/Library/MetadataStore.swift` | SQLite schema 与读写 | 直接访问文件系统 |
| `Domain/Models.swift` | 纯数据模型与枚举 | 网络/IO |
| `Features/Gallery/GalleryView.swift` | 网格容器、工具栏、拖放与框选 | 文件写入、缩略图解码细节 |
| `Features/Gallery/PhotoGrids.swift` | 正方形/瀑布流网格布局 | 业务规则 |
| `Components/PhotoCell.swift` | 网格单元格（选择、悬停、拖放、右键菜单） | 缩略图解码细节（复用 `PhotoThumbnailLoader`）、路径拼接 |
| `Components/PhotoThumbnailView.swift` | `PhotoThumbnailView` / `PhotoThumbnailLoader`：所有缩略图取图 | 业务规则、视图状态 |
| `Features/Viewer/InfoPanelView.swift` | 查看器信息面板 + `PhotoInfoContent`（网格浮动信息卡共用同一份完整字段） | 另一套独立的详情字段（新字段只改这里） |
| `Features/Cloud/CloudWizard*.swift` | 网盘接入向导：根视图 + 各接入方式的步骤视图与动作扩展 | 网盘协议实现、凭据持久化 |
| `Features/Gallery/TimelineOverviewView.swift` | 年/月总览卡片 | 数据分组规则（复用 `store.sections`） |
| `Features/Settings/*` | `SettingsKeys`、设置模型 `AppSettings`、设置窗口 | 业务逻辑 |
| `Services/Cloud/CloudProviders.swift` / `WebDAVClient.swift` / `SMBClient.swift` / `CloudSupport.swift` | 网盘协议与接口 | UI |

---

## 4. 状态与持久化规范

- `photos`/`albums`/`folders` 的 `didSet` 只负责刷新视图版本号（`contentRevision`）。**任何修改后必须显式调用 `save()`**，否则重启丢失。
- 修改模型字段时：
  1. 在 `Models.swift` 中给新字段**默认值**（保证旧 JSON/SQLite 记录可解码）；
  2. 在 `MetadataStore` 中同步 `CREATE TABLE`、`photo(from:)` 读取、`write(_:)` 写入；
  3. 旧库升级通过 `addColumnIfNeeded("assets", "列名", "类型")` 补列，禁止让用户重建图库；
  4. 用已有图库启动一次，确认历史数据仍在。
- 一次性迁移逻辑（旧目录 → 分片目录、旧 JSON → SQLite）写在 `LibraryPaths`/`MetadataStore` 的迁移方法中，必须幂等。
- 删除记录时同步清理：原图、缩略图、渲染结果、压缩备份、转码缓存，并 `ImageLoader.invalidate(photo:)`。
- 端侧智能分析结果写在 `asset_analysis` 表（`asset_id` 主键 + `labels` / `text` / `feature` BLOB / `updated_at`），只允许经 `MetadataStore.saveAnalysis(_:)` / `removeAnalysis(_:)` 写入；内存里的 `analysisIndex` 只保留标签与文字，特征向量按需从数据库读，禁止把向量塞进 `PhotoItem`。删除照片时必须同步 `removeAnalysis(_:)` 与 `analysisIndex` 过滤。
- 「最近查看」写在 `assets.viewed_at`，由 `LibraryStore.recordView(_:)` → `MetadataStore.setViewedAt(_:date:)` 单行更新（不要为一次打开触发全量 `save()`）；系统图库的 `viewedAt` 只来自 `Photos.sqlite`，不写回。
- 「值得重看」「图库体检」都是**派生视图**：扫描结果放在 `healthReport`（内存），不新增数据库表；判定阈值集中在 `LibraryHealthTuning`，不要散落到视图里。
- 「智能美化」同样是派生视图：推荐分组放在 `beautyReport`（内存），不落库，换库时由 `resetBeautyState()` 清空；阈值与调整量集中在 `LumaCore/BeautyAdvisor`，App 侧 `PhotoBeauty` 只负责采样。
- 智能美化只生成渲染副本（与编辑器同一条 `commit` 管线：`resources/renders/` + `editRecipe` + `editVersion` + `ImageLoader.invalidate`），绝不覆盖原图；已编辑照片从原图重建编辑点后再叠加建议，不能丢弃用户已有调整。

### 智能助手（AI）

- 配置写当前图库的 `settings`（`ai_config`），对话写 `ai_conversation`；两者都是 **per-library** 数据，切换图库时由 `loadAIState()` 重新读取。API Key 只允许写 Keychain（service `com.baymax.luma.ai`），禁止写入数据库、`UserDefaults`、日志或对话内容。
- 请求只能经 `AIProviderClient`（OpenAI 兼容 `chat/completions`）发出，不引入第三方 SDK；新增提供商只增加 `AIProvider` 的默认 Base URL / 模型与设置项。
- 提示词只能由 `AIContextBuilder` 组装：当前范围摘要 + 最多 40 张候选照片的元数据/本地 Vision 标签/OCR；禁止把整个 `photos` 数组或文件路径序列化给模型。
- 图片默认不发送。开启「图片理解」后，只能经 `AIImageEncoder` 压成长边约 1024 的 JPEG（单次最多 6 张），跳过 RAW、视频与云端照片；不得上传原图。
- 智能助手可通过工具修改图库，工具分为七类：
  - 检索：`search_photos` / `list_albums` / `list_folders` / `list_videos`
  - 浏览：`navigate` / `select_photos` / `open_photo`
  - 相簿：`create_albums` / `add_photos_to_album` / `remove_photos_from_album` / `rename_album` / `delete_album` / `move_album` / `set_album_cover`
  - 文件夹：`create_folder` / `rename_folder` / `delete_folder`
  - 图片与视频：`set_favorite` / `set_hidden` / `add_keywords` / `remove_keywords` / `set_title`
  - 压缩：`compress_photos`
  - 美化：`beautify_photos`
  - 最近删除：`trash_photos` / `restore_photos`
- 工具定义与参数解析集中在 `AILibraryTools`（`writeToolNames` / `describe`），执行在 `LibraryStore+AITools`；新增工具必须同时补齐定义、写操作白名单、确认文案、执行分支与 README/官网说明。
- 所有写操作必须先经用户确认，再调用 `LibraryStore` 现有方法并 `save()`；禁止直接写 SQLite、删除或编辑原图、导入，禁止写官方 `Photos.sqlite`（官方库只允许 `asset_overlays` 的收藏 / 隐藏 / 关键词等补充元数据）。
- 工具参数里的照片 ID 必须验证为当前图库中真实存在且未删除的项目；工具失败或用户取消时，必须把失败结果回传给模型，不能伪造成功。模型回答不得声称未通过工具完成的操作已执行。
- 智能助手不提供永久删除（`trash_photos` 只移入最近删除，可用 `restore_photos` 恢复）、导入、编辑原图与改文件能力，也不支持在只读来源写入。
- `compress_photos` 必须复用 `PhotoCompressor`（与压缩面板同一引擎），禁止在 AI 层另写编解码；只允许本地图库、非视频项目，且只在结果更小时替换原文件（`onlyIfSmaller = true`）。压缩支持 `mode = lossy / lossless`：有损可调质量、长边与格式；无损保持像素与尺寸，JPEG 仅经 `LumaCore/JPEGMetadataStripper` 剥离 EXIF / XMP / IPTC / COM，其它格式重编码为 PNG。压缩参数（模式、质量、长边、格式、备份）由工具参数临时构造 `CompressionSettings`，不得修改用户在压缩面板里的默认设置。
- `beautify_photos` 必须复用 `LibraryStore.applyBeauty(to:strength:)`（与编辑器/美化建议同一管线），只生成可还原的美化副本并保留原图；禁止 AI 层直接写 `editedFilename` 或覆盖原文件，只允许本地图库的非视频项目。

### 缩略图与缓存

- 缩略图统一走 `ImageLoader.thumbnail(for:)`：内存 `NSCache` + 磁盘文件；`cacheKey` 含 `editVersion`，编辑保存后必须 `ImageLoader.invalidate`。
- 视图层取图统一走 `PhotoThumbnailView(photo:purpose:)`（内部 `PhotoThumbnailLoader` 负责缓存命中、快速层与目标档位）：按实际显示尺寸选 `.grid(maxPixel:)` / `.cover(pt)` / `.filmstrip(pt)` / `.preview(pt)`，禁止在视图里另写解码顺序，也禁止封面类一律解码 1200px。
- 不得把 `NSImage` 存入 `PhotoItem` 或任何 `Codable` 模型。
- 网盘缩略图优先服务端缩略图；WebDAV 走 `Range: bytes=0-262143` + EXIF/渐进式探测，禁止为了缩略图整文件下载。

---

## 5. 图库与文件系统不变量

- 图库是 `.photoslibrary` 包；**所有图库（自建库与直接打开的官方「照片」图库）**的数据都写入包内第一层 `database/`、`originals/`、`resources/`、`cloud/`。官方库里的 `Photos.sqlite` 与 Apple 自带原图只读：我们只在 `database/` 下另存 `PhotosClone.sqlite`，`originals/`、`resources/` 里只写自己的分片文件，不修改 Apple 的数据库与文件。
- 旧版 `private/com.lijialong.photosclone/` 的数据由 `migrateSidecarToLibraryRootIfNeeded` 上移（幂等）。**数据库迁移禁止直接搬运 `-wal` / `-shm`**：先把旧库三件套复制到临时目录、用 SQLite 打开做 `wal_checkpoint(TRUNCATE)` 合并，再只把主库文件搬进图库目录；把别的库的日志放进当前库目录会被当成当前库的日志回放，直接覆盖现有数据。
- **没有图库时不允许创建任何固定位置数据**：
  - `LibraryPaths.configure()` 在无图库时不得调用 `prepare()`（除非检测到旧版本地数据用于迁移）；
  - `LibraryStore` 在 `needsLibrarySetup == true` 时不得打开/创建 `MetadataStore`；
  - 主界面被 `RootView` 的建库门禁挡住，此时不应有写操作。
- 切换图库必须经过 `LibraryPaths.switchContainer(to:migratingLocalData:)`，它会处理目录结构与数据迁移；不要手工搬文件。
- 打开任意图库（含官方「照片」图库）都以该图库为准：`activateLibrary(_:)` 统一走 `switchLibraryContainer(_:)`，展示该库自己的内容，元数据写入该库自己的 `database/PhotosClone.sqlite`（官方库中与 `Photos.sqlite` 并列）。打开图库时传 `migratingLocalData: false`，不把上一个库的内容搬进新库；只有建库引导的「迁入旧库」才迁移。侧边栏「系统图库」的 `connectSystemLibrary(_:)` 仍是只读浏览，不切换当前图库。
- 图库选择记录：`UserDefaults["settings.recentLibraries"]`（最多 10 个），由 `rememberLibrary(_:)` 维护；当前图库以 `Application Support/PhotosClone/ContainerPath.txt` 为真源。
- 侧边栏固定三个分区：**拾光**（本地图库范围）/ **系统图库**（`store.systemLibraries`，可保存多个连接，同一时间只有一个处于连接/展开状态，只读）/ **网络存储**（`store.cloudMounts`）。当当前图库就是官方「照片」图库时（`isNativeContainer`），主侧边栏直接展示该库自己的结构（共享 / 媒体类型 / 更多项目 / 所有项目 / 相簿），不再渲染「拾光」「系统图库」两个分区；此时它自己的连接不再需要出现在系统图库列表里（`loadSystemLibraries()` 会剔除当前容器自身）。系统图库的连接列表与该连接状态都是 **per-library** 数据：写在当前图库自己的 `MetadataStore.settings`（`system_libraries` / `system_library_path`），切换图库时必须重新 `loadSystemLibraries()`；`UserDefaults["settings.systemLibraries"]` 只作为旧版全局列表的一次性迁入来源。连接用 `registerSystemLibrary(_:)`（追加或更新），断开用 `removeSystemLibrary(_:)`。网络存储的 `cloud_mounts`、云端收藏 `cloud_favorites` 同样写在图库自己的 settings 里。
- 切换 / 新建图库必须走 `reloadPerLibraryState()`：它会重读图库级设置、视图状态、系统图库连接、网盘挂载与收藏；切换前先调用 `resetCloudStateForLibrarySwitch()` 清空上一个图库的挂载与目录缓存，否则旧挂载会被当成新库的连接写回新库。
- 每个图库只管理自己的数据：照片与元数据、系统图库连接、网盘挂载与收藏、库级设置（视图状态 / 导入选项 / 最近删除保留期 / 系统图库载入上限 / 网格元数据显示）全部写在该图库内。新图库必须以空连接、默认设置启动；只有旧版全局设置会在升级时一次性迁入当时打开的图库。
- 系统「照片」图库的扫描结果（索引与元数据，不含原图）缓存在当前图库的 `resources/system-cache/`，缩略图缓存在 `resources/system-thumbs/`，签名取 `Photos.sqlite` 的大小 + 修改时间；缓存命中直接展示，签名变化才后台重扫。超大图库按 `settings.system.maxAssets`（随图库保存）从新到旧截断载入（0 = 不限制），`SystemLibrarySnapshot.totalAssetCount` 保留真实总数用于提示；禁止为系统图库复制原图，拷贝出口仍走 `importSystem*`。
- 系统图库缩略图必须**优先读官方 `resources/derivatives`**（照片 `_1_105_c.jpeg`、视频 `_1_102_o.jpeg` 封面帧，路径由 `LibraryPaths.systemDerivativePath` 推导，扫描时记录到 `systemThumbnailPath`），只有文件缺失时才从原图 / 视频现场生成到 `system-thumbs/`；生成必须经过 `ImageLoader` 的并发门控（3 路）与同文件去重，禁止为网格滚动同时解码几十张原图。
- 系统图库的相簿 / 文件夹分组缓存键是 `systemStructureRevision`（只随相簿、文件夹变化），不是 `contentRevision`；侧边栏计数统一走 `systemSidebarCounts` 的一次遍历缓存。禁止在扫描过程中按每批照片重建相簿分桶或对每个计数各扫一遍全库。
- 十万级以上的系统图库「所有照片」网格在视图层按 1200 张渐进渲染（`systemRenderLimit`，滚动到底追加），避免 SwiftUI 对整库做 diff；本地大图库仍走 SQL 分页窗口。
- 系统图库侧边栏的相簿与文件夹按 `ZGENERICALBUM.Z_PK`（`sortIndex`）排序并混排，与官方「照片」一致；不要改回按名称排序。打开系统图库默认 `grouping == .all`、`sortKey == .capturedAt` 降序。
- 侧边栏相簿与文件夹默认收起（只记录用户展开过的 `expandedFolders` / `expandedSystemFolders`），不要改成默认展开——系统图库可能有上万个相簿。

---

## 6. 权限矩阵（必须遵守）

| 范围 | 读取 | 写入（改元数据/删/编辑） | 上传/重命名/新建文件夹 |
| --- | --- | --- | --- |
| 本地图库 | ✅ | ✅ | ✅ |
| 官方「照片」图库作为**当前图库**（`isNativeContainer`，`sidebarItem` 为 `.system*`） | ✅ | 仅拾光补充元数据（收藏 / 隐藏 / 关键词 / 查看时间，写 `asset_overlays`） | ❌ |
| 官方「照片」图库作为**额外连接**（只读浏览，`isSystemScope && !isNativeContainer`） | ✅ | ❌ | ❌ |
| WebDAV 网盘 | ✅ | ❌ | ✅ |
| SMB 共享 | ✅ | ❌ | ❌ |
| 阿里云盘 / 百度网盘 | ✅ | ❌ | ❌ |

- 判断统一使用 `store.isSystemScope`、`store.isCloudScope`、`store.isReadOnlyScope`、`store.isNativeContainer`、`store.canEditNativeOverlay`、`store.isCurrentCloudWritable`。
- 智能美化只对本地图库开放（`store.canScanBeauty` = 非系统图库 && 非网盘 && 已建库），菜单项、体检页入口与推荐面板都要用同一个判断；系统图库、网盘与官方「照片」图库不提供美化入口。
- 官方「照片」图库是当前图库时，它是**增强对象**而不是只读浏览：内容读取 `Photos.sqlite`，拾光的补充元数据写在该库的 `PhotosClone.sqlite`（`asset_overlays`，`MetadataStore.saveOverlay(_:_:)`），绝不回写 `Photos.sqlite`；删除、编辑、导入、重命名仍然禁止。
- 任何写操作入口（菜单、右键、快捷键、工具栏）都必须先做权限判断；只读时菜单项应 `disabled`，不要只在执行时弹 Toast。
- 系统图库的拷贝出口：`importSystemSelectionToLibrary` / `importSystemAlbumToLibrary` / `importSystemFolderToLibrary`，目录递归用 `systemFolderAssetIDs`，重复项目按「同名 + 同大小」跳过。

---

## 7. 导入规范

- 统一使用 `ImportService.importFile(_:)`：复制原文件 → 提取 EXIF/视频元数据 → 生成缩略图。不要在别处重复实现。
- 批量导入按 CPU 核数并发（`withTaskGroup`，上限 6），并在内存中积攒后批量落盘：过程中用 `MetadataStore.appendPhotos(_:)` 增量写入新照片，结束/取消时再调用一次 `save()` 同步相簿与文件夹关系，禁止逐张全量重写。
- **导入始终拷贝原文件**，不支持引用原位置（产品决策，勿加“不拷贝”开关）。
- 从系统「照片」导入走 `importSystemPhotos` 私有管线；剪贴板粘贴必须拷贝（临时文件会被清理）。
- 按文件夹生成相簿的结构由 `ImportOptions` 控制；新增导入选项必须同时接入 `ImportView` 与 `LibraryStore.startImport`。
- 导入完成后：`save()`、清理选择、Toast 汇总；大批量导入应显示进度并支持取消。

---

## 8. 时间轴与网格 UI 约定

- `store.isTimelineScope`（仅 `.library` / `.systemLibrary`）才允许「年 / 月 / 所有照片」分段与总览卡片。
- 照片显示形式由 `store.thumbnailAspect`（`ThumbnailAspect`：正方形 / 完整宽高比 / 瀑布流 / 列表）决定，本地图库、系统图库与网盘共用同一设置；新增形式必须同时接入 `GalleryView.sectionGrid` 与 `CloudBrowserView` 的网格分支。
- 非时间轴范围 `store.sections` 必须返回单段（无年/月分段、无段头），保证相簿与文件夹是普通网格。
- 年总览：每年一张拼图卡片（最多 4 张照片），点击 `openMonths(of:)`；月总览：按月分段、按天卡片，点击 `openAllPhotos(at:)` 定位。大图库改用 `store.yearBuckets` / `store.monthGroups`（SQL 分区，最多 4 张样本 + 真实总数），不要为了总览遍历全部照片。
- 网格尺寸只能由 `store.thumbSize`（`LibraryStore.thumbSizeRange` = 56…360，`didSet` 已夹紧）与容器宽度推导；不要写死像素。
- 卡片圆角用 `settings.cardRadius`，小封面用 `settings.smallCoverRadius`；悬停用 `settings.hoverLift` 与 `settings.motion.hover`；页面级动画用 `settings.motion.layout/overlay`。`RoundedRectangle` 统一 `.continuous`。
- 颜色使用语义色（`.primary`/`.secondary`/`.quaternary`/`.background`/`.bar`）或 `Color.accentColor`，禁止硬编码 RGB（图标绘制脚本除外）。
- 强调色统一由 `AppSettings.accentColor` 下发：根视图（`RootView`）、设置窗口与导入窗口同时应用 `.tint(...)` 与 `.accentColor(...)`，前者负责控件、后者让 `Color.accentColor`（选中框、高亮、强调文字、渐变）解析成同一颜色。新增强调色用途一律写 `Color.accentColor`，不要在视图里直接写 `Color.purple` / `.blue` 等固定色，否则会和用户选择的强调色分叉。
- 大列表必须使用 `LazyVStack`/`LazyVGrid`/`List`；单元格使用固定 `frame`，避免布局抖动。

---

## 9. 设置项接入流程

新增一个用户可调项必须**全部**完成：

1. 先判断归属：视图状态、导入选项、最近删除保留期、系统图库载入上限、网格元数据显示、网盘收藏、智能助手配置与对话属于**图库级设置**（写当前图库的 SQLite）；外观、强调色、动效、查看器与视频播放等属于 **App 级偏好**（写 `UserDefaults`）。API Key 属于凭据，只能写 Keychain。
2. `SettingsKeys` 增加键名（`settings.xxx`）；
3. `AppSettings` 增加 `@Published` 属性：图库级用 `persistLibraryFlag` / `persistLibraryInt` / `persistLibraryJSON`，App 级继续写 `UserDefaults`；
4. 图库级属性必须在 `AppSettings.reloadLibraryScopedValues()` 中读取（缺少键时给默认值），并在 `SettingsView` 对应的图库 Tab 或说明中标注「随图库保存」；
5. `AppSettings.init()` 中给出默认值（布尔用 `object(forKey:) as? Bool ?? 默认值`，避免 `bool(forKey:)` 把“未设置”当 `false`）；
6. `SettingsView` 对应 Tab 增加控件与一句说明文案；
7. 在真正消费该设置的地方接入行为（视频自动播放、HDR、动效等），不要只做“装饰性开关”；
8. 更新 `README.md` 的“设置”一节。

只与单个视图相关的轻量状态可用 `@AppStorage`（如幻灯片间隔），但业务设置一律进 `AppSettings`。禁止把图库级设置写进全局 `UserDefaults`，否则切换图库会串数据。

---

## 10. 网盘接入规范

- 新增网盘类型：`CloudKind` 增加 case → 更新 `title`/`supportsWrite` → 在 `CloudService.list/stream` 分派 → 在 `CloudWizard` 增加向导 flow 与凭据步骤 → `CloudMountInfoView` 补充说明。
- WebDAV 请求统一走 `WebDAVClient`（已处理百分号编码、Basic Auth、PROPFIND/MKCOL/PUT/MOVE/DELETE、Range）。
- OAuth：`CloudOAuthStore` 负责钥匙串（service `com.baymax.photosclone.oauth`，旧版 `com.lijialong.photosclone.oauth` 会自动迁移），回调固定 `127.0.0.1:53682`，必须校验 `state`；token 过期由 `CloudService.accessToken(for:)` 自动刷新并回写。
- 网盘凭据禁止写入 `UserDefaults`、日志或 `CloudMount`。
- 网络请求失败必须转为用户可读中文错误（`WebDAVError` / `CloudOAuthError`），不要直接抛英文 `NSError` 文案。
- 网盘目录缓存以 `mountID + path` 为键；退出网盘或切换目录时不要泄漏 `Task`。
- 网络存储网格必须使用 `store.cloudVisiblePhotos`（已统一处理搜索、筛选、排序并缓存），不要直接遍历 `cloudPhotos` 生成可见列表；`CloudBrowserModel.revision` 参与缓存失效。
- 云照片的「收藏」只写入当前图库的 `MetadataStore.settings`（`cloud_favorites`，键为 `mountID|path`），不得写回 NAS 或网盘；`makeCloudPhoto` 创建时叠加收藏状态，切换收藏后要同步当前列表与 `cloudDirectoryCache`。系统图库 / 只读网盘的写操作（改名、删除、隐藏、相册、编辑）仍禁止。
- SMB 走 `SMBClient`：用系统 `NetFSMountURLSync` 挂载（`mountpath` 传 `nil`，由系统挂到 `/Volumes/<共享名>`），再用 `getmntinfo`（`resolvedMount(host:share:)`）找到实际挂载点后以 `FileManager` 读目录/文件；**不要把挂载点指定到应用私有目录**（普通用户无权限，NetFS 会返回 EPERM/EINVAL）。只读，不支持上传、重命名与删除。密码只走钥匙串，禁止拼进命令行、日志或 `CloudMount`。自动发现依赖 `Info.plist` 的 `NSBonjourServices`（`_smb._tcp`）；共享列表通过 `SMBShareDiscovery` 调用系统 `smbutil view`，密码只经伪终端写入，禁止进入 argv / 环境变量 / 日志；「整个共享」递归扫描结果与目录浏览共用 `cloudDirectoryCache`，缓存键需带 `tree` 前缀避免冲突。

---

## 11. 并发与性能

- 磁盘/网络/图片解码等耗时操作用 `Task.detached(priority:)` 或 `await` 的 async API；UI 状态更新回到主线程。
- 批量任务必须可取消（参考 `importTask`/`compressionTask` 模式），并在 `Task` 内检查 `Task.isCancelled`。
- 网盘缩略图并发限制由 `CloudConcurrencyGate(limit: 3)` 控制；新增高开销资源加载需复用或新增同类门控。
- 大图库不允许在视图或 Store 里对 `photos` 全量 `filter` / `sorted` 来生成可见列表：走 `pagedQuery` + `MetadataStore.page`。新增排序键必须同时接入 `MetadataStore+Query.orderExpression` 与对应的 `(排序键, id)` 复合索引，否则 SQLite 会对全表临时排序。
- 年 / 月总览走 `MetadataStore.yearBuckets` / `monthGroups`（窗口函数按年/月/日分区，样本上限 4 张），分段标题用 `count` 而不是 `photos.count`。
- 查看器单步翻页在分页模式下用 `MetadataStore.neighbor`（keyset 查询），不要用 `LIMIT 1 OFFSET n` 做长按连翻。
- `MetadataStore.readLibrary` **不按文件是否存在过滤**照片：外置盘未挂载或文件临时不可达时，过滤出的空结果一旦被 `save()` 写回就会清空整库元数据；缺失文件交给缩略图占位。
- 避免在 `body` 中做重计算；视图内允许的仅有轻量映射（如按月内照片分天分组）。
- 预览图 `maxPixel` 上限：查看器 2600（`ImageLoader.displayImage`）、全尺寸 6000（`fullNSImage`，打印/编辑用）、网格缩略图 1200、快速缩略图 260，不要随意调大。

---

## 12. 文案、图标与交互

- 所有面向用户的文案为简体中文；使用 SF Symbols 图标，尺寸与项目现有风格一致（`font(.system(size:))`）。
- 可点击控件提供 `.help("…")` 说明；有默认动作的弹窗按钮使用 `.keyboardShortcut(.defaultAction)`。
- 危险操作（永久删除、清空最近删除）必须二次确认；破坏性菜单项使用 `role: .destructive`。
- 新增快捷键必须同步 `ShortcutHelpView`（`Features/Viewer/ShortcutHelpView.swift`）与 `README.md` 快捷键表。
- 空状态、错误状态都要有文案（参考 `EmptyStateView`、`ToastView`）。

---

## 13. 禁止事项

- ❌ 引入第三方依赖或资源包。
- ❌ 在视图层直接读写文件、数据库或拼接路径。
- ❌ 直接修改 `photos`/`albums`/`folders` 后不调用 `save()`。
- ❌ 在没有图库（`needsLibrarySetup`）时创建固定位置目录或数据库。
- ❌ 对系统图库 / 官方网盘提供写操作入口。
- ❌ 为缩略图下载整个 WebDAV 原文件。
- ❌ 把 `NSImage`、`CIImage` 等运行时对象放进 `Codable` 模型。
- ❌ 硬编码 `/Users/...`、`~/Pictures/...` 等绝对路径（测试脚本除外）。
- ❌ 只做“装饰性设置项”（开关没有任何行为）。
- ❌ 提交含密钥、token、临时调试代码的改动。
- ❌ 把 API Key、OAuth token 写入图库数据库、`UserDefaults`、日志或智能助手对话记录。
- ❌ 让智能助手绕过工具确认直接修改图库，或绕过 `LibraryStore` 写文件与数据库。

---

## 14. 常见陷阱

- **产物名不一致**：SwiftPM 可执行目标叫 `PhotosClone`，打包后 App 叫 `Luma.app` / 进程名 `Luma`；`pkill -x Luma`，不要用 `PhotosClone`。
- **多进程改文件**：本仓库可能被多个会话同时编辑；遇到编译期“file modified during the build”只需等待重试。
- **`metadataFile` 位置**：`<图库根目录>/database/PhotosClone.sqlite`（官方「照片」图库同样在它包内第一层 `database/`，与 `Photos.sqlite` 并列），不是 `Application Support`；无图库时 `root` 指向 `Application Support/PhotosClone`，仅用于迁移旧数据。
- **官方图库识别**：`isNativeLibrary` 以是否存在 `database/Photos.sqlite` 判定；`isLibraryContainer` 只看扩展名与是否目录。
- **ATS**：`Info.plist` 已允许任意加载与本地网络；新增域名/端口无需再改，但不要把该配置用于生产收紧以外的场景。
- **HDR 开关**：关闭时查看器把图像转 8 位 sRGB（`ImageLoader.sdrImage`），不要把这个转换加到网格缩略图上（性能）。
- **视频自动播放**：受 `settings.autoPlayVideo` 控制，转码后播放同样遵循该设置。
- **`systemPhotos` 只读**：系统图库的 `PhotoItem.source == .system`，`sourceURL` 指向官方包内文件，禁止写回。
- **导入窗口**：`ImportSheetView` 在独立 `Window(id: "import")` 中，新增状态需经 `LibraryStore` 传递，不要用 `@State` 跨窗口共享。

---

## 15. 提交前检查清单

- [ ] `./build.sh debug` 通过，`open Luma.app` 正常启动
- [ ] 改动涉及的三类范围（本地图库 / 系统图库 / 网盘）权限行为正确
- [ ] 修改过的数据在重启后仍然存在（`save()` / schema 迁移验证）
- [ ] 新增设置项有默认值、有持久化、有实际行为
- [ ] 新增 UI 使用语义色、`settings.cardRadius` 与 `settings.motion`
- [ ] 新增快捷键已同步快捷键面板与 README
- [ ] README / AGENTS 与实际实现一致（功能、限制、文件职责）
- [ ] 无新增编译警告（尤其未使用变量、Sendable 捕获）
- [ ] 未提交临时脚本、调试输出、密钥或大文件

---

## 16. 文档维护

- `README.md`：产品能力、构建方式、目录结构、图库结构、快捷键、已知限制。**功能变化必须同步**。
- `AGENTS.md`（本文件）：架构不变量、编码规范、流程与清单。新增架构级约定时同步更新。
- 文档中的路径、类名、命令必须与代码一致；重构后若改名，先改代码再改文档，并在同一次改动中完成。
