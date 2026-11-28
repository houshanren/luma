# R18.dev dump 管线与可挖掘字段（2026-11）

> 对象：`Tools/catalog_build/import/import_r18_dump.py` + `Tools/catalog_build/refresh_catalog.sh`
> 产物：`raw/r18/r18.sqlite`（本地缓存）、`raw/r18_actresses.json`、`raw/r18_videos.json` → `~/Downloads/catalog.sqlite`
> 相关：[资料库数据体检与补全方案](catalog-data-enrichment-2026-11.md) · [拾光屋架构 §4.4](../architecture/shiguang-house-2026-11.md)

## 1. 一句话

R18.dev 每周二更新一份 CC0 的 PostgreSQL 全量 dump（gzip ≈278MB / 解压 1.5GB，23 张表）。
`import_r18_dump.py` 把它压成两份 JSON：**女优档案**（ID / 头像 / 别名 / DMM 演员 ID）和
**作品**（番号 / 标题 / 日期 / 时长 / 片商 / 系列 / 分类 / 封面 / 缩略图 / 剧照 / 简介 / 导演 / 出演顺位）。
`build_catalog_db.py` 再把 JSON 落进 `catalog.sqlite`。整个过程不下载任何图片、不碰付费内容。

女优分两类处理：**库里已有的**只补字段（R18 ID / 头像 / 假名 / DMM ID），**库里没有的**按名字去重后建档
（地区固定日本，只带名字 / 头像 / R18 主页）；新人物的作品只导番号 / 标题 / 日期 / 封面，不拉剧照与简介。

## 2. 这份 dump 里有什么

本次 dump（2026-11-24）实际行数：

| 表 | 行数 | 说明 | 是否入库 |
|---|---:|---|---|
| `derived_video` | 1,924,865 | 作品主表（标题 / 番号 / 日期 / 时长 / 封面 / 剧照 / 简介 / 站点） | ✅ |
| `derived_actress` | 102,142 | 女优（罗马字 / 汉字 / 假名 / 头像） | ✅ |
| `derived_video_actress` | 2,506,881 | 作品 ↔ 女优（含出演顺位 `ordinality`） | ✅ |
| `derived_video_category` | 9,625,714 | 作品 ↔ 分类 | ✅ |
| `derived_category` | 995 | 分类名（日 / 英） | ✅ |
| `derived_maker` | 6,881 | 片商 | ✅ |
| `derived_label` | 13,153 | 厂牌 | ✅ |
| `derived_series` | 103,957 | 系列 | ✅ |
| `derived_director` | 28,002 | 导演名 | ✅ |
| `derived_video_director` | 823,073 | 作品 ↔ 导演 | ✅ |
| `source_dmm_video_histrion` | 14,100 | DMM 演员 id ↔ 作品（抽样表） | ✅ |
| `derived_site` | 2 | 发行站点（DMM / FANZA） | 只解析未入库 |
| `derived_actor` / `derived_video_actor` | — | 男优 | ❌ 跳过 |
| `derived_author` / `derived_video_author` | — | 原作作者（漫画 / 同人改编） | ❌ 跳过 |
| `machine_translation` | — | 日→英翻译记忆 | ❌ 跳过 |
| `source_dmm_trailer` | — | 预告片 URL（与 `derived_video.sample_url` 重复） | ❌ 跳过 |

## 3. 已经挖进 `catalog.sqlite` 的字段

### 3.1 女优档案（`raw/r18_actresses.json` → `actresses` / `external_ids` / `person_links` / `person_avatars`）

| R18 源字段 | 落到哪里 | 本次规模 |
|---|---|---:|
| `derived_actress.id` | `external_ids(source='r18')` + `person_links`（R18 演员页） | 14,426 条 ID / 19,227 条链接（已有人物） |
| `image_url` | `actresses.image_url` → DMM 官方头像（`pics.dmm.co.jp/mono/actjpgs/…`，96×96） | 9,809 张（已有人物） |
| `name_kanji` / `name_kana` / `name_romaji` | 别名（参与后续所有名字匹配；括号里的写法会拆成独立候选名） | 19,274 条档案（14,430 位库内人物） |
| `source_dmm_video_histrion` 反推的 DMM 演员 id | `external_ids(source='dmm')` + DMM 演员页链接 | 91 位（导出名单内）/ 269 条 ID（含维基来源） |
| 未匹配的 R18 女优 | **新建人物**：名字（主名 + 假名 / 罗马字别名）、头像 URL、R18 主页 / 跨站 ID | **42,608 位**（导出 42,623 条档案；重跑自动复用；库内非 R18 重名跳过 22,100 条） |

### 3.2 作品（`raw/r18_videos.json` → `works` / `work_actresses` / `work_genres` / `work_descriptions`）

| R18 源字段 | 落到哪里 | 本次规模 |
|---|---|---:|
| `content_id` / `dvd_id` | `works.content_id` / `dvd_id` / `code`，`dvd_id` 唯一 | 401,308 部 |
| `title_ja` / `title_en` | `works.title_ja` / `title_en` | 全部 |
| `release_date` / `runtime_mins` | `works.release_date` / `runtime_min` | 全部 |
| `maker_id` → `derived_maker` | `studios`（≥30 部才建档）+ `works.studio_id` | 厂牌合计 1,044 个 |
| `label_id` / `series_id` | `works.label` / `works.series` | 全部有值才写 |
| `derived_video_category` | `works.genres`（JSON，详情页一次取全）+ **`work_genres`**（关系索引，按分类筛选） | 1,861,777 条分类对（其中 31 万部全字段作品带分类） |
| `jacket_full_url` | `works.cover_url` | 401,308 |
| `jacket_thumb_url` | **`works.thumb_url`**（列表页用，比封面小一个数量级） | 401,306 |
| `gallery_thumb_first/last` | **`works.sample_urls`**（JSON，首尾两张剧照） | 213,282 部 |
| `sample_url` | `works.trailer_url`（DMM 试看 mp4） | 64,021 部 |
| `comment_ja` / `comment_en` | **`work_descriptions`**（独立表，详情页按主键取） | 5,702 条 |
| `derived_video_director` | **`works.director`** | 153,629 部 |
| `derived_video_actress.ordinality` | **`work_actresses.position`**（1 = 首要/主演） | 1,375,821 条关系 |

加粗的是 R18 深度挖掘新挖的字段/表。**新建档女优的作品走精简**：只写番号 / 标题 / 日期 / 封面 / 缩略图 / 片商，
不写分类、简介、剧照、试看、导演（约 9 万部），避免长尾作品把库撑大；与已在库女优共演的作品仍走全字段。
数据量变大（库 552MB → 758MB）是刻意的：分类索引、缩略图、剧照 URL 都换来了可直接查询的界面能力。

## 4. 口径与安全阀

1. **以当前库为准，不重复建人**：R18 名字会先拆掉括号别名（「A（B、C）」→ A / B / C），
   任一变体命中**非 R18 来源**的库内人物就整条跳过；只命中上一轮 R18 建的人物则直接复用。
   新建人物的地区固定日本，字段只有名字 / 头像 / R18 ID / 主页链接，不猜生日身高。
2. **新人作品走精简**：只有新人物参演、且库里没有的作品，只写番号 / 标题 / 日期 / 封面 / 缩略图 / 片商；
   与已在库女优共演的作品仍走全字段。用户明确「作品有名称番号就行，大图不要」。
3. **每人最近 100 部**：`--per-actress 100`（默认），`0` = 全部。同一部多人参演只导一次，共演者单独补齐。
4. **`dvd_id` 去重**：同番号可能有多条 `content_id`（普通版 / BOD 蓝光 / 特典），只留一条；
   有普通版时丢掉 `xxxBOD`。选片顺序固定为 `release_date DESC, dvd_id, content_id`，同一份 dump 反复跑结果一致。
5. **同一 content_id 多行**：dump 里存在 `ANPD-01` / `ANPD001` 这类同内容不同番号写法的重复行，只导第一行。
6. **合集保留**：`genres` 里带 `ベスト・総集編`，界面自行过滤（用户明确「数据要全面」）。
7. **DMM 演员 ID 精度优先**：只用「作品恰好 1 位女优 + 恰好 1 位 DMM 演员」的作品投票，
   要求同一映射 ≥2 部、且占该女优一对一作品 ≥60%；宁可少补，不把男优 / 共演者的 id 挂错。
8. **剧照不推测**：dump 只给首尾两张文件名，中间序号不保证连续，所以只导出已知的两张；大图（`gallery_full_*`）不导。

## 5. 怎么用

### 5.1 一键执行（覆盖整条 catalog_build 流水线）

`Tools/catalog_build/refresh_catalog.sh` 是唯一的构建入口，按顺序跑：

| 阶段 | 默认 | 内容 |
|---|---|---|
| 1. 联网抓取 | 关闭（加 `--fetch`） | 22 个 `fetch_*.py` 逐个跑，单步失败只警告，日志 `raw/.pipeline_fetch_*.log` |
| 2. 本地归一 | 开启 | `build_coscd_*` / `build_kkkhai_*` / `build_mms_people` / `build_extra_names` / `build_javbus_map` / `fix_xsnvshen_region`，日志 `raw/.pipeline_derive.log` |
| 3. R18 导出 | 开启（`--skip-r18` 跳过） | `import_r18_dump.py` → 女优 / 作品 JSON |
| 4. 建库 | 开启 | `build_catalog_db.py` → `~/Downloads/catalog.sqlite` |
| 5. 头像 | 关闭（加 `--avatars`） | `fetch_avatars.py` 补齐后自动再建一次库 |
| 6. 打包 | 关闭（加 `--app`） | `./build.sh debug` |

```bash
Tools/catalog_build/refresh_catalog.sh                 # 离线全量重建（约 10 分钟）
Tools/catalog_build/refresh_catalog.sh --fetch         # 先联网刷新全部一手源，再重建
Tools/catalog_build/refresh_catalog.sh --fetch --avatars --app
```

| 参数 | 作用 |
|---|---|
| （无） | 离线：本地归一 + R18 导出 + 重建库（含 R18 新女优建档） |
| `--fetch` | 先联网刷新 22 个一手源（R18 dump 仍需手动下载），单步失败自动跳过 |
| `--skip-derive` | 跳过本地归一，只跑 R18 导出 + 建库（改抓取源后想快一点） |
| `--refresh` | R18 强制重新解析 dump（换 dump / 改了要解析的表时用），约 5–10 分钟 |
| `--refresh --dump 路径` | 指定新的 dump 文件（默认找 `raw/r18/r18dotdev_dump_2026-11-24.sql.gz`） |
| `--skip-r18` | 跳过 R18，只做归一 + 建库 |
| `--existing-only` | 只补已有女优，不给未匹配的 R18 女优建档（旧口径） |
| `--avatars` | 重建后下载缺的头像，再重建一次（约 2.1 万张 / 45 分钟） |
| `--app` | 最后跑 `./build.sh debug`，库自动拷进 `Luma.app` |
| `--strict` | 任一步失败立即退出（默认尽量继续，最后汇总退出码） |

每步完整日志：`raw/.pipeline_derive.log` / `raw/.pipeline_r18.log` / `raw/.pipeline_build.log` / `raw/.pipeline_avatars.log` / `raw/.pipeline_app.log` / `raw/.pipeline_fetch_*.log`。

### 5.2 分步执行

```bash
# 1) 拿 dump（需代理，r18.dev 的 S3 直连很慢；文件名按官方给的日期）
#    下载后放到 Tools/catalog_build/raw/r18/，或下次用 --dump 指定
curl -x http://127.0.0.1:7890 -o Tools/catalog_build/raw/r18/r18dotdev_dump_YYYY-MM-DD.sql.gz <官方 dump 地址>

# 2) 解析 + 导出（缓存存在时只做导出）
python3 Tools/catalog_build/import/import_r18_dump.py --refresh
python3 Tools/catalog_build/import/import_r18_dump.py --stats   # 只看规模 / 匹配率，不写 JSON

# 3) 重建 catalog.sqlite
python3 Tools/catalog_build/build/build_catalog_db.py

# 4) 补头像（可选：下载缺的头像后再重建一次）
python3 Tools/catalog_build/fetch/fetch_avatars.py
python3 Tools/catalog_build/build/build_catalog_db.py

# 5) 打包
./build.sh debug
```

### 5.3 实测耗时 / 体积

| 步骤 | 耗时 | 产物 |
|---|---|---|
| 解析 1.5GB dump | 3–5 分钟 | `raw/r18/r18.sqlite`（约 1.5GB，gitignore） |
| 导出 JSON | 6–10 分钟 | `r18_actresses.json` 19MB / `r18_videos.json` 311MB |
| 重建库 | 约 6 分钟 | `catalog.sqlite` 约 715MB（不含新头像）/ 758MB（补齐后） |
| 头像下载 | 约 45 分钟（7.5 张/秒） | `avatar_images.json` 约 135MB（增量字典） |

> 头像下载默认走 `MONO_PROXY`（默认 `http://127.0.0.1:8118`）。`--avatars` 会先探一下 8118，没开就自动改直连；手动跑时也可 `MONO_PROXY= python3 Tools/catalog_build/fetch/fetch_avatars.py`。

## 6. 报错可以继续吗

结论：**能。默认模式下任何一步失败都不会把已有的数据弄丢；`--strict` 才会中断。**

| 阶段 | 失败会怎样 | 已有数据 | 怎么恢复 |
|---|---|---|---|
| 解析 dump | 缓存先删后建，中断会留下不完整缓存 | **不受影响**（JSON 还没动） | 重新 `--refresh` 全量解析 |
| 解析时遇到坏行 | 字段数不等于 COPY 表头 → 跳过该行 | — | 一般无需处理；若整表 0 行说明 dump 版本变了 |
| 名字归一 | 前后数量不一致会**显式报错退出**（防串人） | 不受影响 | 检查 dump 里是否有带换行的字段，扩展 `clean()` |
| 导出 | 写 JSON 前失败 → 保持旧 JSON | **旧 JSON 可用** | 直接重跑（幂等，只覆盖 JSON；同 dump 结果一致） |
| 建库 | 先删 `catalog.sqlite` 再写，失败会留半成品 | 需要重建 | 重跑 `build_catalog_db.py`（raw 都在，可重复执行） |
| 头像下载 | 单张失败留空，跑完仍算成功 | 不影响库 | 再跑一次 `fetch_avatars.py`，只补缺失的 URL |
| 一键脚本 | 默认：抓取/归一/R18 任一步失败 → 警告后继续；建库失败 → 退出 | 见上 | 看 `.pipeline_*.log`；`--strict` 可快速失败 |

其它韧性设计：

- 抓取脚本（`fetch_*.py`）都有重试与本地缓存，断网重跑不会重复请求；
- `avatar_images.json` 是增量字典，下载失败留空、下次自动重试；
- 建库是**全量重建**（非增量），所以任何时候重跑都会得到一致结果，不存在「跑到一半的脏库」；
- 导出对「上一轮 R18 建的人物」有幂等保护：重跑只会复用，不会把同一批人再建一遍，也不会把精简作品升级成全字段。

## 7. 常用校验 SQL

```sql
-- 规模
SELECT kind, COUNT(*) FROM works GROUP BY kind;              -- photo / video
SELECT COUNT(*) FROM work_genres;                            -- 分类对
SELECT COUNT(*) FROM work_descriptions;                      -- 简介
SELECT COUNT(*) FROM work_actresses WHERE position IS NOT NULL;  -- 有出演顺位的关系
SELECT COUNT(*) FROM actresses WHERE source = 'r18';         -- R18 单独建档的女优

-- 按分类筛作品（走 idx_work_genres_genre）
SELECT w.dvd_id, w.title_ja
FROM work_genres g JOIN works w ON w.id = g.work_id
WHERE g.genre = '巨乳' ORDER BY w.release_date DESC LIMIT 20;

-- 某人的作品（主演排在前面）
SELECT w.dvd_id, w.title_ja, w.release_date, wa.position
FROM work_actresses wa JOIN works w ON w.id = wa.work_id
WHERE wa.actress_id = 4
ORDER BY w.release_date DESC, wa.position;

-- 完整性
PRAGMA integrity_check;
```

## 8. 还能挖但本轮没做的方向

| 方向 | 数据 | 为什么暂缓 |
|---|---|---|
| 男优档案 | `derived_actor` / `derived_video_actor` | 产品是女优 / 写真库，暂无男优入口 |
| 原作 / 同人改编 | `derived_author` / `derived_video_author` | 作品量小，可做「原作」标签但收益低 |
| 发行渠道 | `derived_site` + `derived_video.site_id` | DMM / FANZA 两个站点，筛选价值一般 |
| 日英翻译记忆 | `machine_translation` | `title_en` 已有，暂无中文字段可填 |
| 合集标志 | `genres` 里有 `ベスト・総集編` | 现在用 JSON 过滤；需要专列再做 `works.is_compilation` |
| 评分 / 热度 | — | R18 dump 不提供 |
| 新人档案字段 | DMM / FANZA Web API v3 | R18 只给名字和头像，4.26 万新人的生日 / 身高 / 三围得靠 DMM API（需联盟 key） |

如果以后要做「男优 ↔ 女优共演关系」「原作漫画反查」或「发行渠道筛选」，改 `TABLES` 白名单 + `export()` 即可，缓存不用重新设计。
