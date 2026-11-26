# 拾光 Luma · 代码开发文档

> 本文按**当前仓库的真实目录与常量**编写，文中每个文件名、表名、阈值都能在源码里直接核对。
> 规范类硬约束以 [AGENTS.md](../AGENTS.md) 为准；本文负责「地图 + 机制」，AGENTS.md 负责「规矩 + 边界」。
> 两者冲突时以 AGENTS.md 为准，并在同一次改动里同步两份。

---

## 0. 先看这里：这份文档怎么用

| 你想做的事 | 看哪一节 |
| --- | --- |
| 找某个界面的代码 | §4 目录清册 → `Features/<模块>/` |
| 找某个状态 / 方法 | §4.6 `Store/` + §6 状态与数据流 |
| 新增一张表、一次查询 | §8 数据层 + §9 分页常量 |
| 改搜索 | §10 搜索 |
| 改播放器 | §14 播放内核 |
| 跑测试 / 看界面性能 | §19 测试 |
| 打包 / 签名 / 排查构建 | §18 构建与发布 + §21 排错 |

**同步规则**：新增或移动文件后，必须同时更新 §4 清册与 AGENTS.md 的「文件职责」表；否则下一个人（或 Agent）会照着过期路径找你根本不存在的东西。这是本项目最容易被忽略的一条。

---

## 1. 硬约束

- Swift 5.9 / SwiftPM，最低 **macOS 14**，零第三方依赖。
- 链接的系统库只有三个：`libsqlite3`、`NetFS`、`Photos`（见 `Package.swift` 的 `linkerSettings`）。
- UI 全部 SwiftUI；只有需要系统面板或图片桥接时才 `import AppKit`（`NSOpenPanel` / `NSSavePanel` / `NSWorkspace` / `NSImage`）。
- 不使用 `.xcassets`。图标是 `Resources/AppIcon.icns`，源图 `Resources/icon_1024.png`，由 `Tools/make_icon.swift` 生成后 `iconutil` 打包。
- 界面文案与代码注释统一简体中文。
- 产物固定为仓库根目录 `Luma.app`（可执行文件 `Luma`，bundle id `com.baymax.luma`，显示名「拾光」）。
- `LumaCore` / `PlaybackCore` / `LumaContentCore` 三个库**不得** import SwiftUI / AppKit。

---

## 2. 仓库根清单（实际）

```
photos/
├── Package.swift              # 12 个 target，唯一产物 Luma
├── build.sh                   # 组装 Luma.app（支持 preview / PACKAGE / NOTARIZE）
├── README.md                  # 对外的产品介绍
├── AGENTS.md                  # 开发规范（硬约束、文件职责、权限矩阵、行数上限）
├── CHANGELOG.md
├── .gitignore
├── Resources/                 # 随包资源，见 §2.1
├── Sources/                   # 八个 target 的源码，见 §4
├── Tests/                     # 三个可执行断言 target
├── Tools/                     # 构建 / 素材 / 资料库脚本，见 §2.2
├── Vendor/                    # 构建时下载的 ffmpeg，不入库
├── docs/                      # 本文档 + 产品 / UI 文档 + 设计底稿
├── website/                   # 官网与手册（index.html / manual.html + PDF）
├── Luma.app                   # 构建产物
└── Luma-2.0.0-macOS-dev.zip   # 本地开发包，不是源码的一部分
```

### 2.1 `Resources/`

| 路径 | 内容 |
| --- | --- |
| `Info.plist` | bundle 元信息：`com.baymax.luma`、显示名「拾光」、`LSMinimumSystemVersion 14.0`、`photoslibrary` 文档类型、相册 / 局域网权限说明 |
| `AppIcon.icns` · `icon_1024.png` | 应用图标 |
| `Luma.entitlements` | 正式签名用的权限（仅 `CODESIGN_IDENTITY` 分支使用） |
| `PrivacyInfo.xcprivacy` | 隐私清单 |
| `CloudIcons/` | `aliyun.png` `baidu.png` `quark.png` `pan115.png`，网盘品牌图标 |
| `Catalog/catalog.sqlite` | 内置资料库：演员 / 片商 / 标签 / 头像，详情页与标题识别直接读，不联网 |
| `Models/YOLO11n/` | Core ML 目标检测模型 |
| `Models/Places/world-cities.json` | 离线城市库 |
| `Models/SigLIP2Assets/` | 场景识别的文本塔与词表（tokenizer 三个 bin + `tags.json` + `tag_embeddings.bin`） |
| `Models/manifest.json` · `NOTICE.txt` | 模型清单与许可 |
| `NSFW.mlmodel` · `NSFW-LICENSE.txt` | 内容分级模型与其许可 |

### 2.2 `Tools/`

| 文件 | 用途 |
| --- | --- |
| `catalog_build/` | 资料库流水线：`fetch_*.py` 抓取、`build_*.py` 归一化、`build_catalog_db.py` 生成 `Resources/Catalog/catalog.sqlite`、`t2s.swift` 简繁转换 |
| `make_icon.swift` | 画 1024 图标 |
| `brand_hero_gif.py` | 生成 README 顶部的品牌动图 `docs/design/assets/brand-hero.gif` |
| `bundle_ffmpeg.py` | 整理 ffmpeg 运行时依赖 |
| `make_vendor_runtime.sh` | 从本机 Homebrew 生成 `Vendor/ffmpeg-dv`（ffmpeg-full + libplacebo + MoltenVK + 全部 dylib） |
| `avplayer_probe.swift` · `media_matrix.py` | 片源能力探测与媒体矩阵实验 |
| `playback_log_report.py` | 播放日志归因报告 |
| `ui_perf.py` | 启动应用内界面性能基准并汇总 FPS / 慢帧 / 缩略图 p95；`--report` 只解析已有 JSON |
| `ui_trace.sh` | 用 `xctrace` 录 Instruments trace，同时跑同一套基准并输出 JSON |
| `quick_app.sh` | 快速重启辅助脚本 |

`Vendor/` 下的 `ffmpeg/`、`ffmpeg-dv/` 都是 `build.sh` 现场生成或下载的，不进版本库。

---

## 3. 十二个 target

`Package.swift` 只有 1 个 product（`Luma` 可执行文件），其余是库与可执行检查器。

| target | 类型 | 路径 | 依赖 | 备注 |
| --- | --- | --- | --- | --- |
| `Luma` | executable | `Sources/Luma` | `LumaCore` `PlaybackCore` `LumaContentCore` `LumaDomain` `LumaPersistence` `LumaAI` `LumaUI` | 链接 sqlite3 / NetFS / Photos |
| `LumaCore` | library | `Sources/LumaCore` | — | 纯算法，无 UI、无 IO |
| `PlaybackCore` | library | `Sources/PlaybackCore` | — | 仅 Foundation + AVFoundation + AVKit |
| `LumaContentCore` | library | `Sources/LumaContentCore` | `LumaCore` `PlaybackCore` | 只有契约，没有实现 |
| `LumaDomain` | library | `Sources/LumaDomain` | `LumaCore` `PlaybackCore` `LumaContentCore` | 模型 / 查询描述 / 格式判定，无 AppKit、无 IO |
| `LumaPersistence` | library | `Sources/LumaPersistence` | `LumaDomain` `LumaCore` `LumaContentCore` | SQLite 与图库 / 电视 / 资源站库表 |
| `LumaAI` | library | `Sources/LumaAI` | `LumaDomain` | 模型后端契约 / OpenAI 兼容实现 / 提示词上下文 / 工具定义 |
| `LumaUI` | library | `Sources/LumaUI` | `LumaDomain` | 设计 token / 通用视图修饰器 / 拖放 · 键盘 · 窗口胶水 |
| `TestSupport` | library | `Tests/TestSupport` | — | 命令行断言记录器 |
| `LumaCoreChecks` | executable | `Tests/LumaCoreChecks` | `TestSupport` `LumaCore` `PlaybackCore` | 命令行断言 |
| `LumaContentChecks` | executable | `Tests/LumaContentChecks` | `TestSupport` `LumaContentCore` `PlaybackCore` | 命令行断言 |
| `LumaDataChecks` | executable | `Tests/LumaDataChecks` | `TestSupport` `LumaDomain` `LumaPersistence` | 领域模型与 SQLite 边界断言 |

---

## 4. `Sources/Luma` 目录清册

5 个一级目录：`App` / `Features` / `Services` / `Store` / `UI`。
`LumaDomain` / `LumaPersistence` / `LumaAI` / `LumaUI` 是独立 target，清单见 §4.3。
下面按目录列全部文件——**新增文件就加在这里**。

### 4.1 `App/`（6）

```
AboutWindowView.swift      LibraryPickerView.swift   LibrarySetupView.swift
LumaApp.swift              RootView.swift
Shortcuts/ShortcutCatalog.swift
```

- `LumaApp`：`@main`、窗口与菜单、启动流程（是否进建库引导 / 选库面板），也是组合根：注入 `LibraryUserInteraction` 等端口。
- `RootView`：主界面骨架、覆盖层（查看器 / 搜索 / 播放器）的门禁；`store.needsLibrarySetup` 为真时直接渲染 `LibrarySetupView`。
- `Shortcuts/ShortcutCatalog`：快捷键清单与帮助页数据源。

### 4.2 `UI/`（14，通用界面层）

```
Components/    AnimatedImageView.swift   Components.swift          PhotoCell.swift
               PhotoMarqueeSelection.swift                        PhotoThumbnailView.swift
Platform/      PhotoPicker.swift         PrintSupport.swift
Shared/        AppKitLibraryUserInteraction.swift                 LibraryInteraction.swift
               LumaStateViews.swift       ModuleReadoutBar.swift    SourceErrorView.swift
               SourceJobStatusBar.swift   SourceTransferMenu.swift
```

- `Components/`：跨页面复用的通用视图组件。`PhotoThumbnailView` / `PhotoThumbnailLoader` 是全应用**唯一**取缩略图的入口；`ThumbnailPurpose` 四种：`.grid(maxPixel:)` `.cover(_:)` `.filmstrip(_:)` `.preview(_:)`。
- `Platform/`：需要 Store 或 App 服务的系统胶水——系统照片选择器（`PhotoPicker`，注入 `LibraryStore`）与打印（`PrintSupport`，依赖 `ImageLoader`）。零依赖的拖放 / 键盘 / 窗口访问已移入 `LumaUI`（见 §4.3.3）。
- `Shared/`：页面级共享视图 + 交互端口。`LibraryInteraction` 定义文件面板 / 确认弹窗的协议与请求模型；`AppKitLibraryUserInteraction` 是其 AppKit 实现，由 `LumaApp` 组合根注入，Store 不直接创建弹窗。
- `PhotoGrids.swift` 不在这个目录，在 `Features/Gallery/`。

### 4.3 `Sources/LumaDomain`（独立 target，41 个文件）

```
AIAgentModels              AssetOverlay               BeautyRecommendation
CacheRecords               CatalogDiscoveryModels     CatalogModels
CatalogPageSnapshot        CinemaModels               CloudBrand
CloudIndexState            CloudInsight               CloudModels
CloudPhotoEXIF             CloudWizardModels          Duplicates
ExportOptions              FavoritesDigest            ImportTypes
LibraryData                LibraryHealth              LibraryHealthTuning
LibraryOverview            LibraryVault               LocalPerson
MediaTypeSupport           Models                     NetworkCinemaModels
PersonInsight              PhotoQuery                 PhotoTags
PlaceInsight               PlaceSupport               RevisitInsight
SceneTags                  SearchQuery                SmartAlbum
SystemQuery                TVEPGModels                TVModels
VideoFormats               VideoHub
```

- 只放可序列化模型、查询描述、派生 DTO 与格式判定；不 import AppKit / SwiftUI，不读写文件、不发网络请求。
- `Models.swift`：`SidebarItem`（`library` / `cloudMount(UUID)` / `iptv` …）、`PhotoItem` 等基础模型。
- `PhotoQuery` / `SystemQuery` / `SearchQuery`：三个可下推的查询描述，分别对应自建库、系统图库、搜索。
- `VideoFormats` / `MediaTypeSupport`：导入与网盘浏览共用的媒体类型判定（白名单 + UTType + 蓝光镜像）。
- `PlaceSupport`：坐标校验、地点聚类与 GCJ-02 / BD-09 坐标换算，纯计算。
- `SourceKind`（`library` / `cloudMount` / `cinemaFeed` / `catalogSite` / `iptv`）定义在 `Sources/LumaContentCore/Source/Source.swift`，不在本目录。
- `CatalogProviderKind.supportsNetworkCinema` 在 `CatalogModels.swift`，决定一个资源站是「网络影院」还是「网络资源」。

### 4.3.1 `Sources/LumaPersistence`（独立 target，17 个文件）

```
CatalogDatabase            CatalogPaths              LibraryPaths
MetadataStore              MetadataStore+CloudIndex  MetadataStore+DerivedCache
MetadataStore+Query        PersistenceLog            SQLite
SystemIndex                SystemIndex+Direct        SystemIndex+DirectQuery
SystemIndex+DirectSets     SystemIndex+Metadata      SystemIndex+Query
SystemPhotosLibrary        TVDatabase
```

- `SQLite` 是全仓库唯一 import `SQLite3` 的地方；`MetadataStore` / `SystemIndex` / `TVDatabase` / `CatalogDatabase` 是各领域仓库。
- `LibraryPaths` / `CatalogPaths` 收口所有本地路径；Domain 不得依赖它们（`CatalogPaths` 因此从 Domain 移到这里）。
- `PersistenceLog` 是数据层日志出口，由 `LumaApp` 组合根把 `Diagnostics.record` 注入 `sink`；数据层不得反向引用 App 的 `Diagnostics`。

### 4.3.2 `Sources/LumaAI`（独立 target，12 个文件）

```
AICapability                AIChatProvider             AIChatProviderFactory
AILibraryCatalogTools       AILibraryCinemaTools       AILibraryContext
AILibraryNetworkCinemaTools AILibraryTools             AILibraryTVTools
AITool                      LocalRuntimeScanner        OpenAICompatibleProvider
```

- 只依赖 `LumaDomain`；模型后端契约（`AIChatProvider` / `AIChatRequest` / `AICompletion`）、OpenAI 兼容实现、提示词上下文与工具定义都在这里。
- `AITool`：`AIToolExecution` / `AIToolProvider` / `AIToolRegistry`；provider 是否处理某个工具由定义列表推导（`handles`），不再单独维护名字集合。
- 每个业务域一个定义文件，自带工具定义、写操作白名单与确认文案：`AILibraryTools`（图库基础 + 参数解析 / 风险判定 / `describe` 兜底）、`AILibraryCatalogTools`、`AILibraryCinemaTools`、`AILibraryNetworkCinemaTools`、`AILibraryTVTools`。
- 需要 `LibraryStore` 的执行侧留在 App：`Services/AI/Integrations/AIIntegration.swift`、`Services/AI/Tools/AIToolProviders.swift`（执行分派）、`Store/AI/LibraryStore+AITools*.swift`（各业务域执行）。

### 4.3.3 `Sources/LumaUI`（独立 target，5 个文件）

```
DragSupport        KeyboardMonitor           LumaDesign
ViewSupport        WindowAccessor
```

- 只依赖 `LumaDomain`，不依赖 Store 或任何功能模块；跨 target 成员统一用 `package` 标注，不再逐个写 `public`。
- `LumaDesign`：`LumaMetrics`（间距 / 圆角 / 侧边栏尺寸）、`LumaBrand`（官网六色与渐变）、环境光背景、磨砂卡片 / 胶囊、行高亮、面包屑。
- `ViewSupport`：`searchableIf` 与 `PhotoColorLabel` / `PhotoFlag` 的展示色。
- `DragSupport` / `KeyboardMonitor` / `WindowAccessor`：站内拖拽、窗口级按键监听与粘贴快捷键兜底、窗口尺寸访问。
- 依赖 Store 的界面胶水仍留在 `UI/Platform/`：`PhotoPicker`（注入 `LibraryStore`）、`PrintSupport`（依赖 `ImageLoader`）。

### 4.4 `Features/`（21 个子目录，144 个文件）

```
AI/            AIAssistantView
Catalog/       CatalogAvatarView · CatalogCalendarView · CatalogChannelComponents
               CatalogChannelView · CatalogDetailView · CatalogFollowingView
               CatalogHistoryView · CatalogHubView · CatalogPalette
               CatalogPersonProfileView · CatalogPlaylistViews · CatalogPlaylistsView
               CatalogRankingView · CatalogResourceConsole · CatalogSidebarRow
               CatalogSourceEditorSheet · CatalogSourcesOverviewView
               CatalogTalentLibraryView · CatalogWizardView
Cinema/        CinemaArtworkPicker · CinemaCardViews · CinemaDetailSupport
               CinemaDetailView · CinemaLibraryView · CinemaLibraryView+CardMode
               CinemaLibraryView+Folders · CinemaLibraryView+List
               CinemaLibraryView+Shelves · CinemaLibraryView+States
               CinemaLibraryView+Wall · CinemaMatchSheet · CinemaPanels
               CinemaPersonViews · CinemaPosterCards · CinemaSeriesDetailView
               CinemaSheets · CinemaShelfViews · CinemaToolbarConsole
               CinemaTrailerOverlay
Cloud/         CloudBrandIcon · CloudStoragesCinemaView · CloudStoragesHub
               CloudStoragesPhotosView · CloudViews · CloudWizard
               CloudWizard+AList · CloudWizard+Cookie · CloudWizard+OAuth
               CloudWizard+SMB · CloudWizard+WebDAV
Collections/   CollectionAlbumComponents · CollectionOverviewViews · CollectionsView
               FavoritesDigestView · KeywordGalleryView · LibraryHubView
               SystemCollectionsView · TripStoryView
Compression/   PhotoCompression
Editor/        EditAdvanced · EditPoster · EditPro · EditState+Beauty
               EditStudio · PhotoEditor
Gallery/       DeleteConfirmView · DuplicatesView · GalleryChrome
               GalleryView · GalleryView+Chrome · GalleryView+Content
               GalleryView+Keyboard · GalleryView+ModuleReadout
               GalleryView+VideoHub · PhotoGrids · SearchResultsPage
               TimelineOverviewView
Import/        ImportView
Maps/          FootprintPlaybackView · MapCanvas · MapPlaceGridView
               PhotoMapView · PlaceDetailView · PlaceStatisticsView
Memories/      MemoryMovieView
NetworkCinema/ NetworkCinemaDetailView · NetworkCinemaHubPages
               NetworkCinemaHubView · NetworkCinemaPersonView
               NetworkCinemaSidebarRow
Organize/      BatchChangeView · BeautyRecommendView · ExportOptionsView
               LibraryHealthView · OrganizeStudioView · SmartAlbumEditorView
People/        PeopleLocalView · PersonInsightViews · PersonMapPanel
Revisit/       RevisitView
Search/        SearchPanel
Settings/      AboutBrandHeroView · AppModules · AppSettings
               CinemaSettingsSection · LocalModelsSettingsSection
               ProductizationSettingsView · SettingsKeys · SettingsModels
               SettingsView · ShortcutSettingsView · VaultSettingsView
Shared/        LumaStateViews · ModuleReadoutBar · SourceErrorView
               SourceJobStatusBar · SourceTransferMenu
Sidebar/       CloudMountDetailView · CloudMountSidebarRow · NamePromptSheet
               SidebarDropSupport · SidebarSectionComponents
               SidebarStateStorage · SidebarView · SourceSidebarRow
               SystemFolderOrganizeSheet · SystemToolsSheet
TV/            TVBrand · TVHubView · TVRecordingsPanel · TVSourceWizardView
               TVTimeRingStage
Videos/        VideoHoverPreview · VideoHubView
Viewer/        FilmstripView · InfoPanelView · LivePhotoLayerView
               PhotoViewer · ShortcutHelpView · SlideshowView
               TVChannelActions · TVPlaybackOverlay
               VideoPlayback · VideoPlaybackUI · VideoScrubThumbnails
```

分工要点：

- `Gallery/` 是图库主界面：`GalleryView` 是容器（网格 / 工具栏 / 拖放 / 框选），`+Content` `+Chrome` `+Keyboard` `+ModuleReadout` `+VideoHub` 是它的扩展；`PhotoGrids` 是四种网格布局；`SearchResultsPage` 是搜索结果页（虽然叫 Search，但它属于图库页）。
- `Viewer/` 同时承载图片查看器与视频播放界面：`PhotoViewer`、`FilmstripView`、`InfoPanelView`、`SlideshowView` 是图片侧；`VideoPlayback` / `VideoPlaybackUI` / `VideoScrubThumbnails` / `TVPlaybackOverlay` 是视频侧。
- `Catalog/` = 网络资源（站点聚合、海报墙、详情、演员、片单、追更）；`NetworkCinema/` = 网络影院（影视源聚合）；两者数据源同类但页面不同，不要互相引用视图。
- `Settings/AppModules.swift` 定义 `AppModule` 的 5 个模块（`library` / `cloud` / `catalog` / `television` / `cinema`），控制侧边栏入口、搜索来源与文案；关闭模块不删数据。

### 4.5 `Services/`（20 个子目录，138 个文件）

```
AI/            Integrations/ · Media/ · Tools/
AI/Integrations/ AIIntegration
AI/Media/      AIImageEncoder · AIKeychain
AI/Tools/      AIToolProviders
App/           Diagnostics · UpdateChecker
               UIBenchmarkRunner · UIPerformanceMonitor · UIPerformanceMetrics
Catalog/       AvgleCatalogProvider · AvpleCatalogProvider · CatalogArtworkCache
               CatalogArtworkMemory · CatalogClient · CatalogCrypto
               CatalogMaintenance · CatalogNameDictionary
               CatalogNameParser · CatalogPersonInfoService
               CatalogSnapshotStore · CatalogStore · FoFoCatalogProvider
               FoFoCloudflareGate · HuangguoAddressResolver
               HuangguoCatalogProvider · IKanPPCatalogProvider
               IYFCatalogProvider · JavClCatalogProvider · JavGGCatalogProvider
               MacCMSCatalogProvider · MadouCatalogProvider · MissavCatalogProvider
               NinetyOneCatalogProvider · NinetyOnePornaCatalogProvider
               QuanjiCatalogProvider · RouHLSProxy · RouVideoCatalogProvider
               ShiseCatalogProvider · WebCatalogSupport · XszCatalogProvider
               CatalogAvatarStore · CatalogPortraitLoader
Cinema/        AssrtSubtitleClient · CinemaArtworkCache · CinemaIntroDetector
               CinemaIntroOnline · CinemaKeychain · CinemaMetadataSource
               CinemaNFO · CinemaScraper · DoubanClient · DoubanTrailerClient
               NetworkCinemaSnapshotStore · OpenSubtitlesClient
               SubtitleProviderService · TMDBClient · TVDBClient
Cloud/         AliyunCookieAuth · CloudEXIF · CloudProviders · CloudScanner
               CloudSecretStore · CloudSupport · CloudThumbnailResult
               JPEGMetadata · Pan115Drive · QuarkDrive · SMBClient
               WebDAVClient · WebDAVResourceLoader
Compression/   PhotoCompressor
Import/        ImportCandidate · ImportService
Infrastructure/ KeychainAccess · LumaKeychainVault · SourceTransfer
Library/       LibraryOverviewService · LibraryVaultService · LocalCinemaWatcher
Media/         ArtworkCache · EditLUTLoader · FFmpegPrewarm · ImageLoader
               ImageTransform · ObjectDetector · PersonAvatarLoader
               PersonPalette · PhotoBeauty · PhotoHasher · PhotoIntelligence
               PhotoKitBridge · PhotoKitThumbnailProvider · PhotoQuality
               RawSupport · SigLIPEngine · SigLIPTokenizer
               ThumbnailFileIndex · VideoSupport
Memories/      Memories · MemoryExporter · Trips
Maps/          BaiduTileService
Models/        ModelInstaller · ModelManifest · ModelRegistry
People/        FaceClustering
Places/        WorldCityIndex
Playback/      PlaybackSourceResolver · SourcePlaybackProgressStore
Search/        LibrarySearchCrossLibrary · SearchCenter · SearchProviders
               SearchSessionStore · SearchTypes
TV/            IPTVService · TVCatchupURL · TVClipRecorder
               TVEPGService · TVLogoCache · TVPreviewCache · TVReminderCenter
UseCases/      CinemaMetadataEnricher · ContentRepositories
               EnrichedContentRepository · LibraryIngestService
               NetworkCinemaMetadataEnricher · SnapshottedContentRepository
               SourceContentCache · SourceErrorMapper · SourceSessions
Video/         DisplayModeMatcher · EmbeddedSubtitleLoader · NowPlayingCenter
               PlaybackCoreBridge · SubtitleLoader
```

边界：

- 数据仓库（SQLite / 图库元数据 / 系统索引 / 三套库表）在独立 target `LumaPersistence`，本目录只留服务与编排。
- AI 的模型后端契约、OpenAI 兼容实现、提示词上下文与工具定义在独立 target `LumaAI`；本目录 `AI/` 只留需要 `LibraryStore` 的执行侧。
- `Library/` 是图库服务；`Media/` 是解码与视觉计算；`Cloud/` 是协议；`Catalog/` 是资源站抓取；`Cinema/` 是刮削与字幕；`TV/` 是 IPTV；`Video/` 是播放器的 App 侧胶水（把 `PlaybackCore` 接到 UI 与系统能力）。
- `Infrastructure/` 只放系统能力适配（Security.framework 钥匙串、分享文件编解码），不持有业务状态；`UseCases/` 放跨模块业务编排（内容仓库包装、快照缓存、元数据补全、入库、会话适配、错误归一）。
- `Services/Infrastructure/KeychainAccess.swift` 是全应用唯一直接调用 Security.framework 的地方；`LumaKeychainVault` 在其上做统一凭据保险库。
- `Services/App/UpdateChecker` 是唯一对外网络访问（GitHub Releases）；`Diagnostics` 生成不含照片与凭据的诊断报告。
- `Services/App/UIBenchmarkRunner` 只在 `LUMA_UI_BENCH` 环境变量下运行，正常启动不注册 display link、不采样图片加载；`UIPerformanceMonitor` 采样帧间隔并驱动 NSScrollView，`UIPerformanceMetrics` 记录缩略图 / 海报加载耗时。

### 4.6 `Store/`（59 个文件，其中 50 个 `LibraryStore+*` 扩展；按领域分 7 组）

```
Library/   LibraryStore.swift
           LibraryStore+Beauty · +Burst · +CompressionExport · +Deletion
           +EditorStyle · +Favorites · +Hashing · +Health · +Import
           +Intelligence · +Maintenance · +Metadata · +Organize · +Paging
           +People · +PlaybackHooks · +Query · +Revisit · +SearchBridge
           +Selection · +Stacking · +SystemAlbums · +SystemCache
           +SystemImport · +SystemLibrary · +SystemMedia · +Undo
           +Vault · +VideoHub · +Viewer
           SelectionModel · ViewerModel
AI/        LibraryStore+AIAgent · +AICinemaTools · +AIContext
           +AINetworkCinemaTools · +AITools · +AIToolsCatalog · +AIToolsCinema
           +AITVTools
Catalog/   CatalogBrowserModel · CatalogBrowserModel+Discovery · LibraryStore+Catalog
Cinema/    LibraryStore+Cinema · +CinemaBrowse · +CinemaDetail · +CinemaFiles
           NetworkCinemaModel
Cloud/     CloudBrowserModel
           LibraryStore+AliyunCookie · +Cloud · +CloudCache · +CloudInfo
           +CloudInsight · +CloudLocal · +CloudSnapshot · +Pan115 · +Quark
Shared/    LibraryStore+SourceJobs · +SourceRegistry · SourceHubModel
TV/        IPTVBrowserModel · LibraryStore+TV
```

**分组规矩**：`Library/` 是图库本身的读写与派生（默认落点）；其余目录只放该领域的扩展与状态对象，跨领域共用逻辑放 `Shared/`。

独立状态对象（各自 `ObservableObject`，避免一张照片的选择触发整页重算）：

```
CatalogBrowserModel · CatalogBrowserModel+Discovery · CloudBrowserModel
IPTVBrowserModel · NetworkCinemaModel · SelectionModel
SourceHubModel · ViewerModel
```

**扩展的硬规矩**：存储属性只能写在 `LibraryStore.swift`（Swift 的 extension 不能声明存储属性）；新领域一律新建 `LibraryStore+Xxx.swift`，不要塞回主文件。

---

## 5. 分层与依赖方向

```
Luma (SwiftUI / AppKit / Store / Services)
 ├─ LumaContentCore  ── PlaybackCore ── LumaCore
 ├─ LumaDomain       ── PlaybackCore ── LumaCore
 ├─ LumaPersistence  ── LumaDomain ── LumaContentCore ── LumaCore
 └─ LumaCore
```

- 依赖只向下。UI 不直接 import `PlaybackCore` 的内部类型，统一走 `Services/Video/PlaybackCoreBridge`。
- Luma 内部固定为 `Features → Store → Services（UseCases → Infrastructure）→ LumaPersistence（MetadataStore / SystemIndex / TVDatabase / CatalogDatabase / SQLite）→ SQLite / 文件 / 网络`；`LumaPersistence` 只依赖 `LumaDomain` 与路径入口，不得反向引用 Store、Services 或视图。
- `LumaDomain` 只依赖 `LumaCore` / `PlaybackCore` / `LumaContentCore`；跨回 Luma 时一律通过组合根注入（`PersistenceLog.sink`、`PhotoTagCatalog.resourceResolver`）。
- `PlaybackCore` 不碰文件路径、不写日志、不读 UserDefaults：缓存目录、ffmpeg 路径、日志与进度落盘由 App 注入。
- `LumaContentCore` 只有契约：`Source` / `SourceSession` / `Content` / `PlaybackContract` / `PlaybackCoordinator` / `ContentSnapshot` / `SourceRevision` / `SourceJob` / `CommandPolicy` / `HTTPTransport` / `SourceError` / `M3U` / `IngestService`。
- 具体源实现留在 `Luma/Services/*`，不要往 `LumaContentCore` 里加协议实现。

---

## 6. 状态与数据流

```
SwiftUI View ──读 @Published / 调方法──▶ LibraryStore(@MainActor) ──▶ MetadataStore(Luma.sqlite)
      │                                        │
      │                                        └──▶ LibraryPaths（本地文件）
      └── PhotoThumbnailView ◀── ImageLoader ◀── LibraryPaths / CloudPaths / 网络
```

- **唯一状态源**：`LibraryStore`（`@MainActor` + `ObservableObject`，见 `Store/Library/LibraryStore.swift`）。
- 视图不持有照片 / 相簿数组，不自己开数据库、不自己拼路径；总数用 `store.visibleCount` / `visibleVideoCount`，不要用 `visiblePhotos.count`（分页窗口下两者不同）。
- 视图 → Store 单向调用；Store 不持有任何 View。跨视图通信用 `@Published` 状态（`viewerID`、`showLibraryPicker`、`pendingLibraryOpen`、`needsLibrarySetup` 等）。
- 唯一落盘入口：元数据走 `MetadataStore`（由 `LibraryStore.save()` 触发）；文件走 `LibraryPaths` / `CloudPaths` 提供的 URL，且只允许在 Store / `ImportService` / `ImageLoader` 里做。
- 唯一路径入口：`LibraryPaths`（本地与图库内缓存）、`CloudPaths`（`Services/Cloud/CloudSupport.swift`，网盘缓存）。视图层不得拼路径。

### 6.1 设置作用域

| 作用域 | 存放 | 例子 |
| --- | --- | --- |
| App 级 | `UserDefaults`（`Features/Settings/AppSettings`） | 默认网格密度、动效、诊断开关 |
| 图库级 | 当前图库 `Luma/database/Luma.sqlite` 的 `settings` 表 | 外观 / 强调色、视图状态、导入选项、缓存预算、系统图库连接、网盘挂载、AI 配置与对话、影院与电视开关 |

`AppSettings` 持有 `libraryReader` / `libraryWriter` 两个闭包（由 `LibraryStore` 注入）：有图库时读写 `settings` 表，没有图库时退回 `UserDefaults`。切库由 `reloadPerLibraryState()` 整体重读，所以主题会跟着图库变。

新增设置项先判断作用域：跟图库走的写 `settings` 表，跟 App 走的写 `AppSettings`。

---

## 7. 图库文件布局与迁移

```
My.photoslibrary/                     # 官方库的情况
├── database/Photos.sqlite            # Apple 的库（只读）
├── originals/ · resources/           # Apple 的原图与派生图（只读）
├── scopes/cloudsharing/              # 共享相簿
└── Luma/                             # 拾光的旁挂数据，一律写这里
    ├── database/Luma.sqlite          # 自建库的元数据 + 图库级 settings
    ├── originals/                    # 自建库原图
    ├── resources/derivatives         # 自建库缩略图与派生图
    ├── resources/renders             # 编辑结果
    ├── resources/transcodes          # 转码产物
    ├── resources/backups             # 备份（Vault）
    ├── resources/presets.json        # 用户编辑预设（跟库走）
    ├── resources/luts/               # 导入的 3D LUT
    ├── resources/catalog/            # 网络资源的源、续看、片单、更新日历
    ├── resources/tv/Television.sqlite# 网络电视源与频道
    ├── resources/tv/playlists/       # 复制进库的 M3U
    ├── resources/system-cache/       # 系统图库扫描结果 + import-manifest.json
    ├── cloud/thumbs/                 # 网盘缩略图
    ├── tv-logos/ · tv-previews/      # 台标与预览图
    └── source-snapshots/             # 网络源内容快照
```

**刻意不放在图库里的两处**（都落在 `~/Library/Application Support/Luma/resources/`）：

- `system-thumbs/`：系统图库的格子小图。图库常在外置盘上，为每个格子往同一块盘写小文件会拖慢滚动。
- `system-index/SystemIndex-<hash>.sqlite`：系统图库的只读索引库，按图库路径哈希命名，可以同时缓存多个系统图库。

迁移与定位规则：

- 当前图库的真源是 `Application Support/Luma/ContainerPath.txt`（`LibraryPaths.bootstrapFile`）；最近图库记录在 `UserDefaults["settings.recentLibraries"]`（`LibraryPaths.recentLibrariesKey`）。
- 只有 `LibraryPaths.requiresLibrarySetup` 为假才允许创建数据；`needsLibrarySetup == true` 时 `LibraryStore` 不打开 `MetadataStore`，`RootView` 用 `LibrarySetupView` 挡住界面。
- 切库必须走 `LibraryStore.activateLibrary(_:)`（`LibraryStore+SystemLibrary.swift`），不要手搬文件。
- 旧版 `private/com.lijialong.photosclone/` 与摊在库根的数据由 `LibraryPaths.migrateSidecarToLibraryRootIfNeeded` 幂等上移；旧库路径 / 旧文件名由 `existingMetadataFile(in:)` 兼容读取。
- **迁移 SQLite 禁止直接搬 `-wal` / `-shm`**：先把三件套复制到临时目录、`wal_checkpoint(TRUNCATE)` 合并，再只搬主库文件。`LibraryPaths.migrateMetadataFileIfNeeded` 已经这么做，不要另写一套。
- 官方库的缩略图优先复用 `resources/derivatives/<首字符>/<UUID>_1_105_c.jpeg`（视频是 `_1_102_o.jpeg`），共享相簿走 `scopes/cloudsharing/...`，缺失才生成到 `system-thumbs/`。

---

## 8. 数据层

项目里有 4 个 SQLite，职责完全分开：

| 库 | 位置 | 谁写 |
| --- | --- | --- |
| `Luma.sqlite` | 图库内 `Luma/database/` | `MetadataStore`（自建库元数据、系统库识别缓存、网盘缓存、影院条目、图库级设置） |
| `Television.sqlite` | 图库内 `Luma/resources/tv/` | `TVDatabase` |
| `SystemIndex-<hash>.sqlite` | `Application Support/Luma/resources/system-index/` | `SystemIndex`（系统图库只读索引） |
| `catalog.sqlite` | `Resources/Catalog/`（只读内置） | `CatalogDatabase` 读取 |

### 8.1 `MetadataStore` 的表（16）

```
assets  folders  albums  album_assets  settings
people  person_assets  scanned_faces
asset_analysis  asset_overlays
system_analysis  derived_reports
cloud_assets  cloud_people  cloud_person_assets
cinema_entries
```

| 表 | 用途 |
| --- | --- |
| `assets` | 自建库媒体：文件名、原始文件名、时间、大小、相机 / 镜头、GPS、时长、宽高、哈希等 |
| `folders` / `albums` / `album_assets` | 文件夹、相簿、相簿关系（含手动排序） |
| `settings` | 图库级键值：视图状态、连接、主题、AI 配置… |
| `people` / `person_assets` / `scanned_faces` | 人物、人物照片、已扫描人脸 |
| `asset_analysis` | 端侧识别结果（场景、OCR、特征） |
| `asset_overlays` | 拾光补充元数据：收藏、隐藏、关键词、标题等，不改 Apple 的表 |
| `system_analysis` | 系统图库识别缓存，按 `library_path` 分区 |
| `derived_reports` | 派生报告缓存（体检、美化、收藏摘要），按范围 key + signature |
| `cloud_assets` / `cloud_people` / `cloud_person_assets` | 网盘 EXIF、识别、特征、查看记录、人物，按 `mount_id + path` |
| `cinema_entries` | 本地 / 网盘影院刮削条目 |

`MetadataStore+CloudIndex` 另建 3 张网盘目录索引表：`cloud_index_folders`、`cloud_index_assets`、`cloud_index_state`（各自带 parent / captured 索引）。

主要索引：`assets` 的 `captured_at`、`added_at`、`deleted_at`、`content_hash`、`rating`，四个「live」组合索引（captured / added / size / title + id），`album_assets(album_id)` 与 `(asset_id)`，`system_analysis(library_path)`，`cloud_assets(mount_id)`。

### 8.2 `TVDatabase` 的表（3）

`tv_playlists`、`tv_channels`（带 `idx_tv_channels_source(playlist_id, position)`）、`tv_settings`。

### 8.3 写入纪律

- 元数据写入统一走 `LibraryStore.save()`，业务代码不直接开 SQLite。
- 任何缓存都必须带失效条件：系统库用 `systemCacheSignature`（`Photos.sqlite` 大小 + 修改时间），网盘用远端文件大小，断开挂载时 `purgeCloudAssets`。
- 查询构建器 `PhotoQuery`：范围 / 筛选 / 关键词 / 排序 / 评分 / 旗标 / 色标全部下推 `MetadataStore+Query`。

### 8.4 `SystemIndex` 的两种模式

| 模式 | 入口 | 行为 |
| --- | --- | --- |
| 直连 | `SystemIndex.openDirect` | 只读连 `Photos.sqlite`，实时查询；`+DirectQuery` 出 SQL，`+DirectSets` 处理连拍 / 相簿 / 人物 / 导入会话 |
| 索引 | `SystemIndex` + `system-index` 缓存 | 把关键字段同步到本机索引库，查询走 `SystemIndex+Query`；签名变化即重建 |

- 相簿 / 文件夹 / 人物是纯元数据，先由 `albumMetadata` / `peopleMetadata` 读出来展示，扫描完成后再替换。
- 拾光补充数据以 overlay 合并展示；**绝不写 Apple 的表**。真实编辑 / 删除 / 相簿写回只能经 `PhotoKitBridge`。
- 直连模式的日期条件必须直接比较 `ZDATECREATED`（Core Data 秒）；写成表达式会失去 Apple 的日期索引（实测 0.37s → 66s）。

---

## 9. 查询、分页与渲染

| 常量 | 值 | 位置 |
| --- | --- | --- |
| `LibraryStore.windowThreshold` | 5000 | `LibraryStore.swift` |
| `LibraryStore.windowPageSize` | 600 | `LibraryStore.swift` |
| `LibraryStore.systemStreamDisplayLimit` | 40 000 | `LibraryStore+SystemLibrary.swift` |
| `GalleryView.systemRenderLimit` | 1200（每次 +1200） | `GalleryView.swift` / `+Content` |
| `LibraryStore.thumbnailPrewarmLimit` | 300 | `LibraryStore+Organize.swift` |
| `LibraryStore.cloudPeoplePageSize` | 300 | `LibraryStore+CloudInfo.swift` |
| `LibraryStore.largeVideoBytes` | 300 MB | `LibraryStore+Health.swift` |

- 本地图库超过 5000 张且处于「所有照片」网格时启用分页窗口：范围 / 筛选 / 排序下推 SQL，`visiblePhotos` 只持已加载窗口，每页 600。
- 窗口按查询指纹 `query.key` 失效重建；`systemQueryCache` 缓存 `SystemQuery` 与其 key，避免 SwiftUI body 反复拼长 SQL。
- 全量操作用 `index.allIDs(query)` 只取 UUID，再 `photos(ids:)` 每 500 张一批取回。
- 系统图库网格先渲染 1200 张，滚动到底再加 1200（`systemRenderLimit += 1_200`）；索引构建期间用 `systemStreamDisplayLimit` 缓冲先显示。
- 打开相簿 / 文件夹时 `prewarmOpenedCollection` 预热前 300 张**快速层**缩略图。
- 视图层禁止对整库 `filter` / `sorted`；百万级库的 `LIKE '%x%'` 无法走索引，必须放后台任务并接受较慢（这是"结果完整"的代价）。

---

## 10. 搜索

```
搜索框 / ⌘F
  └─ SearchCenter（防抖 260ms；六来源并发；结果流式落地；同词复用）
       └─ SearchProviders.makeAll
            ├─ LibrarySearchProvider        当前库 + 其它已接入图库（跨库只读）
            ├─ CloudSearchProvider          cloud_index_assets / folders
            ├─ CinemaSearchProvider         本地 / 网盘影院索引
            ├─ NetworkCinemaSearchProvider  影视源并发检索
            ├─ TelevisionSearchProvider     频道 + EPG 节目
            └─ CatalogSearchProvider        资源站统一检索
```

- `SearchSection` = 命中数组 + `kindCounts` + `total`；`SearchHitKind` 7 种：`photo` `video` `album` `folder` `person` `scene` `place`。
- **任何来源都不做条数截断**：去掉所有 `prefix(limit)` 与 channelBudget，命中多少返回多少。展示与速度可以优化，但结果必须完整。
- 图库命中字段：文件名 / 原始文件名 / 标题 / 相机镜头 / 地名 / 官方关键词（`ZKEYWORD`）/ 端侧场景标签与 OCR。
- 系统图库把关键词与 AI/OCR 命中换算成资产 UUID，作为该 token 的 OR 条件并入 SQL（`SystemQuery.tokenKeywordIDs`）。
- 关键词查询走 `SystemIndex.nativeKeywordAssetIDs`：先筛小表 `ZKEYWORD` 拿到 PK，再按 PK 关联 `Z_1KEYWORDS` / `ZADDITIONALASSETATTRIBUTES` / `ZASSET`；`limit == 0` 时不拼 LIMIT（整表 join 要 7 秒，先筛小表 0.03 秒）。
- **当前模块不含图库数据时的坑**：浏览网络影院 / 电视 / 资源时，`store` 里没有图库内容（`sidebarItem` 不在系统图库范围、`photos` 为空）。所以 `storeServesLibrary = store.isSystemScope || !store.isNativeContainer`；为假时当前图库也改走只读直连，否则图库来源永远 0 命中。
- 系统图库分页窗口是异步装填的：搜索词一变先清空再跑 SQL。统计前必须 `waitForSystemWindow(store:)`（最多 2.5s，120ms 轮询），否则大库上会瞬间得到「图库 0」并被会话缓存住。
- 跨库打开：`openSearchResultInLibrary(path:pending:)` → 切 / 连目标库 → `consumePendingLibraryOpenIfReady()` 在原查看器打开（`Store/Library/LibraryStore+SearchBridge.swift`）。
- 会话缓存：`SearchSessionStore` 以「关键词 + 来源集合」为键保留最近 **4** 轮，返回搜索页不重跑。
- 已知性能债：文件名与关键词是 `LIKE` 全表扫描。后续可建 FTS 表提速，但不得改变「结果完整」的语义。

---

## 11. 源与模块

- `AppModule`（`Features/Settings/AppModules.swift`）5 个：`library` `cloud` `catalog` `television` `cinema`。每个模块带标题、副标题、关闭说明、SF Symbol、双色渐变、`UserDefaults` key、对应 `SourceKind`。图库模块始终开启。
- `SourceKind`（`Sources/LumaContentCore/Source/Source.swift`）5 种：`library` `cloudMount` `cinemaFeed` `catalogSite` `iptv`。
- `SourceDescriptor` 是侧边栏统一行模型（`Store/Shared/LibraryStore+SourceRegistry.swift`）；新增来源 = 新增 provider + 注册表条目 + 能力位，不改侧边栏结构。
- 归类看 `CatalogProviderKind.supportsNetworkCinema`（`maccms` / `fofo` / `ikanpp` / `iyf`）：它们只进「网络影院」，不再在「网络资源」重复出现；网盘里的影片随「网络存储」，不算影院模块。
- 侧边栏分区：拾光 / 系统图库 / 网络存储。当前库本身就是官方库（`isNativeContainer`）时，主分区直接展示该库结构。

---

## 12. 权限与写入边界

| 范围 | 读 | 改元数据 / 删除 / 编辑 | 上传 / 重命名 / 新建文件夹 |
| --- | --- | --- | --- |
| 自建图库 | ✅ | ✅ | ✅ |
| 官方库作为**当前图库** | ✅ | 补充元数据写 `asset_overlays`；编辑 / 删除 / 相簿写回经 PhotoKit | ❌ |
| 官方库作为**额外连接**（只读） | ✅ | ❌ | ❌ |
| WebDAV | ✅ | ❌ | ✅ |
| SMB | ✅ | ❌ | ❌ |
| 阿里云盘 / 百度 / 夸克 / 115 | ✅ | ❌ | ❌ |

- 系统图库写入前必须 `prepareSystemLibraryWrite()`（权限 + 样本校验），且 `canWriteSystemOriginals` / `canDeleteSystemPhotos` / `canManageSystemAlbums` 为真。
- 禁止用 SQL 改 `Photos.sqlite`；禁止对额外连接的系统库做真实写入。

---

## 13. 网络、影视与直播

- 网盘：`CloudProviders` + `SMBClient` / `WebDAVClient` / `AliyunCookieAuth` / `Pan115Drive` / `QuarkDrive`；密钥在 `CloudSecretStore`（转调 `LumaKeychainVault`）。
- EXIF：SMB 直读挂载文件；WebDAV 用 `Range: bytes=0-262143`；官方网盘用直链 + Range。结果写 `cloud_assets` 并回填目录缓存（`CloudScanner` / `MetadataStore+CloudIndex`）。
- 资源站：`Services/Catalog/*CatalogProvider`（苹果 CMS、FoFo、爱看、爱壹帆、黄果、MissAV、JavCI、JavGG、麻豆、91 系、视色、AVple、Avgle、全集、肉等），统一经 `CatalogClient` / `CatalogDatabase` / `CatalogSnapshotStore`；海报缓存 `CatalogArtworkCache`（内存层 `CatalogArtworkMemory`）；标题识别走 `CatalogNameParser` + `CatalogNameDictionary`。
- 影院：`CinemaScraper` + `TMDBClient` / `DoubanClient` / `TVDBClient` / `AssrtSubtitleClient` / `OpenSubtitlesClient`，结果落 `cinema_entries` 与 `NetworkCinemaSnapshotStore`。
- 电视：`IPTVService` + `TVDatabase` + `TVEPGService` + `TVCatchupURL` + `TVReminderCenter` + `TVClipRecorder`。

---

## 14. 播放内核（`Sources/PlaybackCore`，23 个文件）

| 文件 | 职责 |
| --- | --- |
| `VideoPlayerModel` | 播放器门面：状态、seek、字幕、音轨、倍速、进度 |
| `PlaybackSession` · `VideoStreamSession` | 会话、边下边播、断流重建 |
| `StreamPlanner` · `SeekPlanner` · `HTTPByteRange` · `RemoteRangeSource` | 片源计划：直连 / Range / HLS |
| `LocalHLSServer` · `PlaybackCache` · `BufferAdaptationState` · `BufferProfile` | 本地 HLS、缓存与缓冲策略 |
| `TranscodeProfile` · `PlaybackFilters` · `BluraySource` · `VideoFraming` · `PlaybackOutputOptions` | 转码、HDR 映射、蓝光、画幅、输出 |
| `SubtitleCore` · `SubtitlePreference` | 字幕解析与偏好 |
| `PlaybackTimeline` · `PlaybackHooks` · `PlaybackEnvironment` · `PlaybackMode` · `PlaybackModels` | 时间轴、钩子、环境注入、模式与模型 |

- **逐级加速**：`VideoPlayerModel.seekStep(_:base:isRepeat:)`，倍率 `seekAccelSteps = [1, 2, 3, 4, 6, 8]`；同方向且间隔 < 1.2s 才升级，换向或停顿 1.2s 回到 1×；单步上限 600s（10 分钟）；`isRepeat` 时限频 0.12s。
- **按住重复**：UI 侧 `HoldRepeatGesture`（`Features/Viewer/VideoPlayback.swift`）按下立刻执行一次，然后每 0.30s 一次，间隔每拍减 20ms，降到 0.14s 后匀速。阈值与内核的倍率阶梯是两套机制：UI 决定「多久点一次」，内核决定「这次点多大一步」。
- 4K50/60 `hev1` 直连不可解码时自动改走重编码，避免「有声音没画面」。
- 内置 ffmpeg 由 `build.sh` 提供（优先 `Vendor/ffmpeg-dv`：ffmpeg-full + libplacebo + MoltenVK，支持杜比视界 Profile 5；否则静态包带 zscale + tonemap），运行时可回退系统 ffmpeg。
- 按片源帧率匹配显示器刷新率：`Services/Video/DisplayModeMatcher`。

---

## 15. 缩略图与缓存

- 唯一入口 `ImageLoader`；`PhotoThumbnailView(photo:purpose:)` 只选档位（`.grid` / `.cover` / `.filmstrip` / `.preview`），禁止视图里另写解码顺序。
- 三级内存池：`cache` 384MB（网格缩略图）、`fullCache` 512MB、`displayCache` 192MB。
- 并发自适应 `ThumbnailPrefetchTuner`：按实测「读盘 + 解码」EWMA 调并发——≤18ms 用 4 路、>18ms 用 3 路、>45ms 用 2 路；单批上限 160 / 120 / 80 张。机械盘与网络盘上自动缩小，避免抢可见格子的 IO。
- 显示层预取另有 `DisplayPrefetchLimiter`（上限 2 个并发）与 `ThumbnailGenerationGate`（同文件去重）。
- `cacheKey` 含 `editVersion`；编辑保存后必须 `ImageLoader.invalidate`。
- 不得把 `NSImage` 放进 `PhotoItem` 或任何 `Codable` 模型。

---

## 16. 端侧智能与助手

- 识别：`Services/Media/PhotoIntelligence`（Vision 分类 / OCR / 特征）、`SigLIPEngine` / `SigLIPTokenizer`、`ObjectDetector`、`PhotoQuality`、`PhotoBeauty`；模型由 `ModelInstaller` / `ModelManifest` / `ModelRegistry` 管理。
- 人物：`FaceClustering` 聚类，`LibraryStore+People` 编排；`PersonPalette` / `PersonAvatarLoader` 管头像与色调。
- 编排层 `LibraryStore+Intelligence` 只做调度，不直接发 Vision 请求。
- 助手：配置与对话是**图库级**数据；API Key 只进钥匙串（`AIKeychain` → `LumaKeychainVault`）；请求只经 `AIChatProvider`（默认 `OpenAICompatibleChatProvider`，由 `AIChatProviderFactory` 选择）；提示词只由 `AILibraryContext` / `AIContextBuilder` 组装。
- 工具定义在 `LumaAI`：`AILibraryTools`（图库基础 + 参数解析 / 风险判定 / 确认文案兜底）与同目录的 `AILibraryCatalogTools` / `AILibraryCinemaTools` / `AILibraryNetworkCinemaTools` / `AILibraryTVTools`，每个域文件自带写操作白名单与确认文案；执行分派在 `AIToolProviders`（`handles` 由定义列表推导）。图库基础工具在 `LibraryStore+AITools`，网络资源与影院分别拆在 `+AIToolsCatalog` / `+AIToolsCinema`，影院个人状态在 `+AICinemaTools`，网络影院在 `+AINetworkCinemaTools`，电视在 `+AITVTools`。所有写操作先确认，失败结果必须回传模型；MCP / 技能 / 快捷指令等外部能力实现 `AIIntegration` 后只注册工具 provider。

---

## 17. 并发与性能守则

- UI 与状态 `@MainActor`；扫码、索引、哈希、解码、网络在 `Task.detached` / 后台队列，完成后回主线程写状态。
- body 里只读派生值；查询 key、日期格式化、大数组排序在 Store 层缓存。
- 长任务可取消，并进任务中心（`SourceJob*` / `LibraryStore+SourceJobs`）。
- 视图里禁止：整库 `filter` / `sorted`、拼 SQL、解码原图、为系统图库复制原图。
- 单文件 2000 行是硬上限；超了先按职责拆（见 AGENTS.md）。

---

## 18. 构建、预览与发布

```sh
./build.sh              # release 构建 → Luma.app
./build.sh debug        # debug 构建
./build.sh preview      # 增量编译 + 只替换可执行文件 + 重启 App
swift run LumaCoreChecks
swift run LumaContentChecks
swift run LumaDataChecks
```

`build.sh` 的实际行为（按执行顺序）：

1. `swift build -c <config> --product Luma`。
2. 删除旧 `Luma.app`，重建 `Contents/MacOS` 与 `Contents/Resources`，拷贝可执行文件、`Info.plist`、`PkgInfo`。
3. 拷贝 `AppIcon.icns`、`PrivacyInfo.xcprivacy`、`CloudIcons/*.png`、`Catalog/*.sqlite`、`Models/*`。
4. ffmpeg：优先复制 `Vendor/ffmpeg-dv/{bin,lib}`（缺失则先跑 `Tools/make_vendor_runtime.sh` 现场生成），并附 `FFmpeg-VERSIONS.txt` 与 GPL `FFmpeg-NOTICE.txt`；没有 dv 运行时才下载静态 `ffmpeg` / `ffprobe` 到 `Vendor/ffmpeg` 并拷进 `Contents/Resources/bin/`。
5. 签名：**先签内嵌 dylib，再签 ffmpeg / ffprobe，最后签外层 App**（hardened runtime 不允许未签名的嵌套可执行文件）。
6. 可选打包与公证。

签名分支（容易误解，按源码为准）：

| 条件 | 实际签名 |
| --- | --- |
| 设置了 `CODESIGN_IDENTITY` | `codesign --force --deep --options runtime --timestamp --entitlements Resources/Luma.entitlements`，用你的开发者证书 |
| 未设置，但 `ensure_local_signing` 成功 | 固定本地自签身份 **`Luma Local Dev`**，证书在 `~/Library/Keychains/LumaDev.keychain-db`。这样重编译不会因为身份（=二进制哈希）变化而反复弹钥匙串授权 |
| 以上都失败 | ad-hoc（`codesign --sign -`） |

| 环境变量 | 作用 |
| --- | --- |
| `PACKAGE=1` | 额外生成 `Luma-<CFBundleShortVersionString>-macOS.zip`（`ditto -c -k --keepParent`） |
| `NOTARIZE=1` | 需要 `APPLE_ID` / `TEAM_ID` / `APP_PASSWORD`，`notarytool submit --wait` 后 `stapler staple` |

`preview` 分支只做 `swift build -c release -Xswiftc -no-whole-module-optimization --product Luma`，把二进制覆盖到 `Luma.app/Contents/MacOS/Luma`，然后 `quit` + `open` 重启。它**不复制资源、不签名、不下载 ffmpeg**——改了 `Resources/` 或签名相关的东西必须跑完整构建。

版本号真源是 `Resources/Info.plist`：当前 `CFBundleShortVersionString 2.1.1`、`CFBundleVersion 9`。

**两个已知的坑**：

- `build.sh` 里 `Models/` 的排除条件是目录名 `SigLIP2`，而仓库里的实际目录叫 `SigLIP2Assets`，所以现在它会被打进包内。若要按注释的意图「按需下载、不内置」，需要同时改脚本与目录命名。
- 出现 `error: input file '...' was modified during the build` 说明有另一个进程在写源码：等待后重试，**不要删 `.build`**。

---

## 19. 测试

命令行工具链没有 XCTest，测试是「可执行 target + 断言」：三个检查器把每条断言打印成 `PASS` / `FAIL`，只要有一项失败就以退出码 1 结束，可以直接串进脚本或 CI。用例按领域拆文件，避免单个 `main.swift` 持续膨胀。

### 19.1 运行

```sh
swift run LumaCoreChecks        # 纯算法：布局 / 转码 / 播放决策 / 字幕 / 导入规则
swift run LumaContentChecks     # 内容契约：源语义 / 传输 / 播放协调 / 网络资源 / IPTV
swift run LumaDataChecks        # 领域模型 + SQLite 读写
echo $?                         # 0 = 全过；1 = 有断言失败
```

- 三个 target 互不依赖，可以并行跑；单个 target 全量在秒级完成。
- 检查器不读真实图库、不联网、不写用户目录，用例需要的输入都在文件内就地构造。
- `swift run` 与 `./build.sh` 共用 `.build`；同时跑会撞上 `input file '...' was modified during the build`，等一边结束再跑另一边。

### 19.2 断言 API（`Tests/TestSupport/CheckContext.swift`）

| API | 说明 |
| --- | --- |
| `expect(条件, "描述")` | 布尔断言；失败累加计数并打印 `FAIL 描述` |
| `expectEqual(实际, 期望, "描述")` | 相等断言，失败时打印实际值与期望值 |
| `expectClose(实际, 期望, accuracy: 精度, "描述")` | `CGFloat` 近似相等，用于几何 / 布局 |
| `CheckRecorder.shared.finish()` | 汇总失败数并以非零码退出；每个 `main.swift` 末尾必须调用 |

`expect` 的参数是 `@autoclosure`，只有真正断言时才求值；断言失败不会中断后续用例，一次能看到全部问题。

### 19.3 检查器清单

- `Tests/TestSupport/CheckContext.swift`：检查器共用的断言记录器（PASS / FAIL 汇总、非零退出）。
- `Tests/LumaDataChecks/main.swift`：`LumaDomain` / `LumaPersistence` 的公开边界回归——视频 / RAW 格式判定、坐标校验、地点聚类、UUID 分片、SQLite 读写与 `MetadataStore` 的照片 / 设置往返。
- `Tests/LumaCoreChecks/`：
  - `ChecksLayout.swift`：缩略图档位、网格与瀑布流、行程分段。
  - `ChecksMediaInsight.swift`：美化建议、JPEG 元数据剥离、票据 / 证件文字、地标、感知哈希。
  - `ChecksFootprint.swift`：足迹回放与连续巡航时间轴。
  - `ChecksVideoPlanning.swift`：转码档位、滤镜链、缓冲档位、音频策略、失败分类、原生直读与画面比例。
  - `ChecksBluray.swift`：蓝光原盘输入、MPLS 章节、多角度与字幕语言偏好。
  - `ChecksPlaybackRuntime.swift`：缓冲自适应、HLS 缓存键 / 清理、电视线路重试、seek 决策与时间轴。
  - `ChecksVideoMatrix.swift`：媒体矩阵的纯决策回归（可直通编码、hvc1 / DV 标签、降档、HDR 映射、多音轨、直播参数）。
  - `ChecksSubtitles.swift`：SRT / VTT / ASS 解析、样式、时间命中与烧录路径转义。
  - `ChecksImport.swift`：视频 / RAW 扩展名、实况照片配对、媒体归类、蓝光失败文案与 EXIF 时间。
- `Tests/LumaContentChecks/`：
  - `ChecksSource.swift`：源激活语义、能力位、错误恢复、任务中心、任务耗时与内容模型。
  - `ChecksTransport.swift`：HTTP 重试、Mock 传输、快照与修订号。
  - `ChecksPlayback.swift`：播放协调器、占位仓库与 provider 解析失败。
  - `ChecksCatalogPlayback.swift`：网络资源的播放目标、请求画像、续看进度与适配器解析契约。
  - `ChecksIPTV.swift`：M3U 解析 / 多线路排序、频道名本地化与省份归类。

### 19.4 新增一条检查

1. 纯逻辑先落到库里：算法 → `Sources/LumaCore`，播放 → `Sources/PlaybackCore`，内容契约 → `Sources/LumaContentCore`，数据层 → `Sources/LumaDomain` / `Sources/LumaPersistence`。**不要在 `Sources/Luma` 里加只给测试用的分支。**
2. 在对应 target 已有的 `Checks<领域>.swift` 里加 `func runXxxChecks()`，内部用 `expect*`；同一领域沿用已有文件，不要为一条用例新建文件（每个 `Checks*.swift` 控制在 400 行以内，超了按子领域再拆）。
3. 新文件才需要在 `Tests/<target>/main.swift` 里加一行调用；已存在的文件只需在函数里补断言，并在 `finish()` 之前执行。
4. `swift run <target>` 跑绿后，再跑另外两个 target，确认没有互相影响。

约定：

- 检查器只覆盖「不依赖真实样片 / 网络 / 用户库」的决策与契约。容器 × 编码 × HDR × 音轨的真实解码矩阵仍用 `Tools/media_matrix.py`；检查器负责把矩阵结论固化成断言（可直通编码、hvc1 / DV 标签、降档、映射、多音轨），防止结论与代码漂移。
- 站点 HTML / 直链提取属于适配器层，需要真实页面样本才能验证；播放链路本身的公共语义放在 `ChecksCatalogPlayback.swift`。
- 涉及数据层的行为优先写进 `Tests/LumaDataChecks`（临时目录 + `MetadataStore(url:)`），不再依赖手工验证。
- 导入规则（扩展名、实况照片配对、媒体归类、蓝光文案、EXIF 时间）只有 `Sources/LumaCore/ImportRules.swift` 一份实现，App 与 `ChecksImport.swift` 共用；不要在 App 层另写一套。

### 19.5 手工回归清单

建库引导（浅 / 深 / 自动 × 极端强调色）、百万级滚动、统一搜索六来源、跨库打开、播放器按住加速与字幕、切库后主题与设置、系统图库只读边界。

### 19.6 界面性能基准（应用内采集）

没有 Instruments 也能量化图库滚动与缩略图加载。基准在 App 内执行，Python 只负责启动、等待与汇总：

```sh
./build.sh
python3 Tools/ui_perf.py                                       # 全部场景，单轮 5 秒
python3 Tools/ui_perf.py --scenes grid-square,cinema-wall --seconds 8
python3 Tools/ui_perf.py --min-fps 55 --max-slow-ratio 0.03    # 不达标退出码 1
python3 Tools/ui_perf.py --build                               # 先完整构建再跑
python3 Tools/ui_perf.py --report /tmp/luma-ui-trace-xxx.json  # 只解析已有报告
```

`ui_perf.py` 参数：

| 参数 | 默认 | 作用 |
| --- | --- | --- |
| `--scenes` | 五个全跑 | 逗号分隔的场景名 |
| `--seconds` | 5 | 单轮滚动秒数（每个场景跑两轮） |
| `--out` | `/tmp/luma-ui-perf-<时间戳>.json` | 报告路径 |
| `--report` | — | 只解析已有 JSON，不启动应用 |
| `--min-fps` / `--max-slow-ratio` | 不校验 | 阈值；任一不满足则退出码 1 |
| `--timeout` | 360 | 等报告的秒数 |
| `--build` | 关 | 启动前跑一次 `./build.sh` |
| `--allow-running` | 关 | 允许已有 Luma 实例（单实例下新进程会直接退出，不建议） |

场景（`--scenes` 的可选值）：

| 场景 | 实际在测什么 |
| --- | --- |
| `grid-square` | 图库方形网格：`LazyVGrid` + 快速层缩略图 |
| `grid-actual` | 图库原始比例网格：不同高度单元格的重排 |
| `grid-masonry` | 瀑布流：列高计算与增量布局 |
| `cinema-wall` | 影院海报墙：`poster.poster` 封面加载 |
| `catalog-channel` | 网络资源频道货架：远程封面与列表加载 |

应用侧实现在 `Sources/Luma/Services/App/`，三段职责：

| 文件 | 职责 |
| --- | --- |
| `UIBenchmarkRunner.swift` | 编排：切场景 → 找可滚动视图 → 跑两轮 → 写 JSON → 退出；由 `RootView` 的 `.task` 在检测到环境变量时触发 |
| `UIPerformanceMonitor.swift` | 用 `CADisplayLink` 采样真实刷新节奏，并按 1800pt/s 驱动底层 `NSScrollView` 的 clip view |
| `UIPerformanceMetrics.swift` | 线程安全地收集缩略图 / 海报加载耗时；正常启动时 `collecting == false`，记录是空操作 |

环境变量（通常由 `ui_perf.py` / `ui_trace.sh` 注入，手工调试时才自己设）：

| 环境变量 | 作用 |
| --- | --- |
| `LUMA_UI_BENCH` | 报告 JSON 路径；设置后启动即进入基准模式，跑完自动退出 |
| `LUMA_UI_BENCH_SCENES` | 逗号分隔场景名；非法或为空时退回全部 |
| `LUMA_UI_BENCH_SECONDS` | 单轮滚动秒数（默认 5） |

采集口径：

- 帧间隔来自 `CADisplayLink` 的 `timestamp`；`expectedFrameMs` 取首帧的 `link.duration`，60Hz / 120Hz 屏各按自己的刷新率计算。
- 慢帧阈值 `max(1.5 × 帧间隔, 24ms)`；丢帧按 `round(间隔 / 帧间隔) - 1` 折算；`p50 / p95 / p99 / max` 都按同一套向上取整分位口径。
- 滚动到片尾会跳回顶部，保证整轮持续有新格子进入可视区，形成真实渲染负载；走的仍是 SwiftUI `LazyVGrid` / `LazyVStack` 的创建、复用与图片加载路径。
- 每个场景跑两轮：`pass1` 偏冷（首次解码 / 磁盘读）、`pass2` 偏热（缓存命中）；两轮的图片加载分开统计。
- 图片加载按 key 聚合：`grid.quick`（快速层）、`grid.target`（目标档位）、`cover.target`（封面）、`poster.poster`（海报），各给 `count / failures / p50 / p95 / max`。
- 场景状态：`ok` = 有数据且滚动出帧；`skipped` = 数据不足（空库 / 无已刮削条目 / 无已启用网络资源）；`failed` = 内容高度不足或没有收到 `CADisplayLink` 回调。
- 数据与图库规模、海报数量、网络响应强相关。**只比较同一图库、同一版本下同场景的差异**，不要跨机器比绝对值。

报告结构（`schemaVersion: 1`）：

```
{ appVersion, osVersion, architecture, libraryPath, libraryPhotoCount, generatedAt,
  scenes: [ { scene, status, note, itemCount, scrollable,
              passes: [ { frame: { label, seconds, frames, fps, expectedFrameMs,
                                   p50Ms, p95Ms, p99Ms, maxMs,
                                   slowFrameCount, slowFrameRatio, estimatedDroppedFrames,
                                   documentHeight, viewportHeight, startOffset, endOffset },
                          imageLoads: [ { key, count, failures, p50Ms, p95Ms, maxMs } ] } ] } ] }
```

### 19.7 Instruments trace（需要完整 Xcode）

`Tools/ui_trace.sh` 用 `xctrace` 录制 trace，同时用同一套环境变量触发应用内基准，一次拿到「Instruments 时间线 + JSON 数字」：

```sh
./build.sh
Tools/ui_trace.sh                                              # Animation Hitches，全部场景
Tools/ui_trace.sh --template "Time Profiler" --scenes grid-square --seconds 6
Tools/ui_trace.sh --template "Metal System Trace" --output /tmp/luma-metal.trace
```

| 参数 | 默认 | 作用 |
| --- | --- | --- |
| `--template` | `Animation Hitches` | `xcrun xctrace list templates` 里的模板名 |
| `--scenes` | 五个全跑 | 与 `ui_perf.py` 同名的场景 |
| `--seconds` | 5 | 单轮滚动秒数 |
| `--output` | `/tmp/luma-ui-trace-<时间戳>.trace` | trace 路径；同名 `.json` 报告并排生成 |

- 模板选择：掉帧 / 卡顿看 `Animation Hitches`，CPU 热点看 `Time Profiler`，GPU 与合成看 `Metal System Trace`，内存增长看 `Allocations`。
- 脚本结束会自动调 `ui_perf.py --report` 打印同一份数字；trace 用 `open <x.trace>` 在 Instruments 里看。
- 录制上限按「场景数 ×（2 轮 + 准备余量）」估算，最长 10 分钟，避免异常时一直录。

前置（缺 `xctrace` 时脚本会打印同样的指引并以退出码 2 结束）：

```sh
# 方式一：App Store 搜索 Xcode，或 https://developer.apple.com/download/all/ 下载
# 方式二：xcodes CLI（安装时会交互提示输入 Apple ID / app 专用密码）
xcodes install --latest --select

sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcrun xctrace list templates      # 应能看到 Animation Hitches / Time Profiler
```

注意：`xctrace record` 首次会申请录制权限；应用是单实例，录之前先退出正在运行的 Luma。

### 19.8 新增埋点或基准场景

- **新增图片加载埋点**：在加载路径记下 `CFAbsoluteTimeGetCurrent()` 起始时间，完成后调用 `UIPerformanceMetrics.shared.record(kind:tier:seconds:success:)`。`tier` 只有 `quick / target / poster`，新类型优先复用 `kind` 区分而不是加 `Tier`；没开基准时调用是空操作。
- **新增基准场景**：在 `UIBenchmarkRunner.Scene` 加 case（`rawValue` 就是 `--scenes` 用的名字），在 `prepare(_:store:)` 里切好界面并等到有数据，滚动与采样交给现有逻辑；再把场景名补进 `ui_perf.py` 的 `DEFAULT_SCENES` 和 `ui_trace.sh` 的默认 `SCENES`，最后更新 19.6 的场景表。

---

## 20. 编码规范

- 注释解释「为什么」，尤其是性能与并发的取舍；不复述「是什么」。
- 单文件按领域拆分；`LibraryStore` 主文件只放存储属性与生命周期。
- 命名：类型 UpperCamelCase、方法 / 属性 lowerCamelCase；SwiftUI 私有视图用 `private struct`。
- 新增可配置项先判断作用域（App 级 → `AppSettings`；图库级 → `settings` 表）。
- 不引入第三方框架，不新增资源目录，不改产物名。

---

## 21. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动落在建库引导 | 上次图库被移动 / 外置盘未挂载 / `ContainerPath.txt` 失效 | `⌥⌘O` 重选图库 |
| 图库搜索很慢 | 百万级 `LIKE '%x%'` 全表扫描，用不上索引 | 等待完成；关键词 / 相簿 / 文件夹命中会先返回 |
| 图库搜索为 0 | 当前模块不含图库数据、窗口未装填、或场景 / 人物还没跑识别 | 检查 `storeServesLibrary` 与 `waitForSystemWindow`；先跑识别 |
| 只有 10 张图 | 历史上跨库配额截断（已移除） | 确认走的是当前版本：搜索不做任何条数限制 |
| 播放黑屏有声 | 4K50/60 `hev1` 直连不可解码 | 自动改重编码，等待准备 |
| 缩略图不更新 | `editVersion` 未变或未失效 | 保存后调用 `ImageLoader.invalidate` |
| 构建被并发改动打断 | 另一个进程在写源码 | 等待后重试，不要删 `.build` |
| 重编译后反复弹钥匙串授权 | 用了 ad-hoc 签名（身份随二进制变） | 让 `ensure_local_signing` 生效，用固定 `Luma Local Dev` 身份 |

---

## 22. 变更同步清单

改完代码，至少问自己这五句：

1. 新增 / 移动 / 删除了文件？→ 更新 §4 清册 + AGENTS.md 文件职责表。
2. 新增了表、索引、缓存目录？→ 更新 §7 / §8，并写明失效条件。
3. 改了口径（阈值、防抖、倍率、分页）？→ 更新 §9 / §10 / §14。
4. 改了构建、签名、打包？→ 更新 §18，并实际跑一遍 `./build.sh`。
5. 改了检查器、基准场景或性能埋点？→ 更新 §19 的清单 / 场景表 / 参数表，并跑一遍对应 target。
