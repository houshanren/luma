# 资料库数据体检与补全方案（2026-11）

> 范围：`Resources/Catalog/catalog.sqlite` 与 `Tools/catalog_build/raw`，以及可用于补全的外部数据源。
> 说明：本文只讨论数据与采集，不涉及界面设计。

## 0. 执行清单

| 编号 | 事项 | 状态 |
|---|---|---|
| D0 | 把本方案写入文档 | ✅ 完成 |
| D1 | 扩展 SQLite schema：人物档案字段 / `external_ids` / `person_links` / `person_studios` / `works` 底座 | ✅ 完成（`user_version = 3`） |
| D2 | 现有 raw：补 `hobby`（爱好） | ✅ 完成（3,210 条，javbus + 日文维基） |
| D3 | 现有 raw：日文别名 / 读音回填 | ⚠️ 部分完成（`aliases` 4,187 人 / 7,901 条，含日文维基「別名」；`ruby` 读音仍为空，需 DMM/读音源） |
| D4 | 现有 raw：生日精度与坏日期修复 | ✅ 完成（day 6,947 / year 548 / 无 9,637） |
| D5 | 现有 raw：三围 / 身高 / 生日补缺 | ✅ 完成（身高 7,660、三围齐全 8,401、罩杯 7,123） |
| D6 | 国内增强：Coser 作品链接入库 | ✅ 完成（2,226 条作品链接，1,718 条 works） |
| D7 | 国内增强：角色 / IP 标签入库 | ✅ 完成（509 条） |
| D8 | 国内增强：模特 ↔ 写真机构关系 | ❌ 未做（现有 raw 证据不足，需新抓机构/模特页） |
| D9 | 写入 javbus / javrate / zhwiki / jawiki 等外部 ID 与来源链接 | ✅ 完成（22,343 条 ID / 26,338 条链接） |
| D10 | 重建数据库并核对新增字段 / 关系 / 标签数量 | ✅ 完成（17,132 人 / 464 厂商） |
| D11 | 外部大盘：R18.dev dump + 作品表 | ⛔ 待执行（站点 403，需换镜像/直连通道） |
| D12 | 外部 API：DMM / FANZA 人物与作品字段 | ⛔ 待执行（需联盟 api_id / affiliate_id） |
| D13 | 日文维基人物信息框批量抓取 | ✅ 完成（分类 4,272 页 → 解析 4,070 人 → 合并 3,796 人） |
| D14 | 国内平台：B站 / 微博 / JVID / SWAG | ⛔ 待执行（412 / 风控 / 403） |
| D15 | 欧美：IAFD / ThePornDB / FreeOnes | ⛔ 待执行（403，需账号或代理） |
| D16 | 厂牌品牌图 URL 抓取（og:image / apple-touch-icon） | ✅ 完成（42 个官网 → 34 个 logo URL） |
| D17 | 大陆 Coser / 写真模特 / 福利姬 网页档案 + 作品目录 | ✅ 完成（6 站 2,052 条档案、38,500 条作品、19 位重点人物人工核对） |
| D18 | 大陆长尾补录：更多站点 + 按库内姓名反查匹配 | ✅ 完成（再抓 9 站；缺生日/身高/三围的人从 2,059 降到 1,720） |
| D19 | 来源完整性核查 + 收尾修正 | ✅ 完成（核查 CoserIndex / 艺图湾 / 萌娘 / 百科 / 社交平台；补 3 位人工档案，修 9 条地区误判、11 条展示名） |
| D20 | 换批补录：秀色女神全站档案 + 8 站聚合 + cos2cy 编号页 + 头像批量下载 | ✅ 完成（大陆 2,474 → 5,257 人 + 台湾 1,122 / 香港 206 / 欧美 1,455 归位，大陆生日覆盖 23% → 55%；作品 52,052 → 113,431 条；头像 base64 内嵌 17,927 行） |
| D21 | JavBus 改名双页补图闭环 + 头像增量下载 + v2ph 演员索引 + 同名重复合并 | ✅ 完成（6,221 个「有 JavBus ID + 探活 URL」的人 0 缺图；头像 base64 内嵌 17,927 → 18,951 行；v2ph 全站 403 封锁前已存 2,410 位演员索引，待解后续爬；改名孪生条目合并 73 条，人物 26,470 → 26,397） |
| D22 | 大陆人物重复专项检查 + 跨源同名收敛 | ✅ 完成（`merge_cn_variants`：CJK 核心归一 + xsnvshen 同封面证据，收敛 113 条，人物 26,397 → 26,284，日本区 17,763 分毫未动） |
| D23 | 推广文标题冒充人名清理 | ✅ 完成（`is_title_junk_name` 三特征检测器挂三处：24 条纯删 + 11 条改名 + Yoshinobi 展示名修复，人物 26,284 → 26,253，残留 0） |
| D24 | 头像 base64 拆独立表 | ✅ 完成（`person_avatars` 18,863 / `studio_avatars` 464，主表留 `has_avatar` 标志；app 端 `CatalogAvatarStore` 按主键单条取，启动全量加载不再背 200MB 大文本） |
| D25 | 秀人网镜像全量扩库（写真网红/名模） | ✅ 完成（`fetch_xiurenwang.py`：19,558 篇文章 / 2,206 标签 → 2,244 位写真模特 + 18,560 套图 + 封面；机构标签 40 余个剔除、近重复归并 399 条；人物 26,253 → 27,030（大陆 +763 至 5,857），作品 → 132,018，作品↔人物 → 132,398，头像 → 19,858） |
| D26 | 查询结构加固（反查索引 + 作品去双写） | ✅ 完成（`work_actresses` 加 `idx_work_actresses_actress`，反查由全表扫改走索引；作品只进 `works`+`work_actresses`，`person_links` 只留主页/社交 164,634 → 32,207 条；库 154MB → 135MB） |
| D27 | 界面查询能力补齐（标签表 / 厂牌索引 / 名字搜索） | ✅ 完成（`person_tags` 52,041 对 + `idx_person_tags_tag` 按角色/IP 筛选；`idx_works_studio_release` 厂牌页免排序；`actress_search` FTS5 27,021 行，汉字单字切分让 2 字中文名可搜） |
| D28 | 跨站 ID 重复挂载收敛 | ✅ 完成（27 组重复 `(source, external_id)`：生日一致/姓名互为变体的 9 组按同一人合并（作品/别名一并并入），生日或地区冲突的按 ID 抓串处理、只留给最匹配者，清理 28 条错挂 ID；人物 27,030 → 27,021，重复归零） |
| D29 | 新源勘探（只调研，未抓取） | ✅ 完成（2026-11-26 实测 20 余个候选：Wikidata SPARQL、jvheku、xiurenz、myxiuren、yituwan、七图社、颜蜜社、COS集、麻豆夹等可用；R18 dump 与 IAFD / FreeOnes / Babepedia 仍受限；结论与预期增量见 §4.15） |

### 本轮实际产出（2026-11-25）

**第一轮（raw 榨干 + 国内增强）**

- `catalog.sqlite` 升到 `user_version = 3`。
- 新字段：`birth_precision`、`hobby`、`ruby`、`birthplace`、`blood_type`、`debut_year`、`agency`、`status`、`official_site`。
- 新表：`external_ids`、`person_links`、`person_studios`、`works`、`work_actresses`。
- 国内作品：1,718 条 `works`（coscd 1,391 / kkkhai 327）、1,864 条 `work_actresses`。
- 数据质量：生日改为「日期 / 仅年份」两档；采集站标题里的体积、期数、订阅、资料介绍等已清洗。

**第二轮（日文维基 + 厂牌图）**

- 新增 `fetch_ja_wiki.py`：`Category:日本のAV女優` 4,272 页 → 解析出 4,070 人 → 合并进 3,796 条人物记录。
- 新增 `fetch_studio_logos.py`：42 个厂牌官网 → 34 个真实 logo URL（JVID / Vixen 等 8 个 403 跳过）。
- 人物总数 16,135 → **17,132**；`external_ids` 17,142 → **22,343**（新增 jawiki 3,903 / DMM 241 / XCITY 212）；`person_links` 20,477 → **26,338**。
- 日文维基带来的档案字段：出身地 2,840、血型 2,081、出道年 3,279、事务所 1,712、官网 1,952、爱好 3,210、日文别名 1,212 人。
- 解析期清洗：出身地只留「都道府県/市/町/村」结尾的地名；事务所剔除混入的「趣味/身長/デビュー」等表格残留；剔除「AV女優」等非人物页；官方站剔除 DMM / XCITY / 新闻稿 / archive 链接（其中的演员 ID 转写进 `external_ids`）。
- 未做：模特↔写真机构关系（`person_studios` 暂空）、`ruby` 读音，以及所有需要外部 dump/API 的部分；原因见上方状态表。

**第三轮（大陆 Coser / 写真模特 / 福利姬 网页档案）**

- 新增 `fetch_cn_profiles.py` / `fetch_cn_profiles_more.py`，走 WordPress REST 抓 6 个公开站的档案页，不下载图片。
- 清洗后保留 **2,052 条**可用档案（去作品页、去合集页、去梗词条、去重）：梗语百科 494 / COS社 430 / 秀人 406 / coser喵 310 / 泡面站 282 / 吾爱cos 111，另有 19 位重点人物人工核对（`cn_profiles_manual.json`），人工条目优先覆盖自动抓取值。
- 大陆人物 2,186 → **2,491**；生日 3 → **289**；身高 2 → **331**；三围 1 → **67**；出生地 0 → **572**；头像 2 → **895**。
- 作品底座 1,718 → **38,500** 条（coshe 18,141 / cosmeitu 14,782 / 52cos 3,845 / coscd 1,400 / kkkhai 332）；有作品的国内人物 721 位。
- 社交账号进 `external_ids`：微博 287 / 抖音 34 / Twitter 23 / Instagram 13 / B 站 10 / 小红书 5。
- 来源说明：这些聚合站自己标注「资料来自互联网公开整合，仅供参考」，因此每条都带 `source` 与 `source_url`，不做二次推测；梗语百科混有主播 / 动漫角色 / 日本女优，只用于补已有条目，不新增人物。
- 未做：非自愿泄露的「门事件」当事人档案——这类内容涉及隐私侵害，不做个人数据补录。

**第四轮（长尾补录：更多站点 + 姓名反查）**

- 新增 `fetch_cn_profiles_extra.py`，再抓 9 个公开站：影语阁、乐妖图、图罗记、喵风向、元气领域、虾仁猪心、狐樱社、潮图集、N5次元。
- 这些站的标题多为「某某的 133 期…」这类 SEO 写法，直接用标题当名字会污染数据，因此改成**按库内已有姓名反查**：用库里的主名/别名在标题和简介里做最长匹配，只保留能对上已有条目的记录，不新增来历不明的人。
- 有效结果：web5 571 人、web6 376 人；补进生日 566、身高 621、三围 152、出身地 767、头像 1,108。
- 缺生日/身高/三围的人：2,059 → **1,720**（占大陆人物 69%）；有作品的人从 721 升到 766。
- 顺带修掉 10 条「名字带斜杠」的重复条目（如「咬一口兔娘/Yiko湿润兔」并入主记录）。
- 人工核对再加 8 位（`cn_profiles_manual2.json`）：九曲Jean、虎森森、咬一口兔娘、花铃、弥美Mime、九柒喵、白栎Shirly、羽生三未。

字段明细同步写入 [拾光屋架构文档 §4.4](../architecture/shiguang-house-2026-11.md#44-内容域资料库catalogsqlite字段)。

**第五轮（来源完整性核查 + 收尾）**

逐个核查了还没用过的来源，结论如下：

| 来源 | 可访问 | 能否补生日/身高/三围 | 处理 |
|---|---|---|---|
| CoserIndex（682 位） | 是 | 否（只有别名/社媒/图集数） | 不抓 |
| 艺图湾（6.5 万篇） | 是 | 抽样 10 个缺失名字命中 4 个，页面是作品帖、无字段 | 不抓 |
| 萌娘百科（3 个镜像） | 否（Cloudflare 403） | — | 放弃 |
| 百度百科 | 否（安全验证 403） | — | 放弃 |
| 微博 / 小红书 / 抖音 / B 站接口 | 否（风控 / 412 / 需登录） | — | 放弃 |
| 爱豆之家 / 名站图库 | 否（SSL 握手失败） | — | 放弃 |
| JVID / SWAG | 否（403） | — | 放弃 |

收尾修正：

- 人工补 3 位：Liyuu（1997-01-09 / 169 / 上海 / O 型）、胡桃的朋友圈（1997 / 165 / 84-58-86）、念雪ww（1997 / 浙江杭州）。
- 名字本身是假名 / 谚文的 9 条记录改正地区（けん研 → 日本，JangJoo → 韩国）。
- 人工条目的展示名不再被别名顶掉（11 条，例如 Ristuki → Liyuu、Yiko湿润兔 → 咬一口兔娘）。
- 剔除「英文名」这类被误当人物的字段名。

结论：公开聚合站能抓的已基本抓完；剩下 1,714 位只有名字，来自标签/合集站，没有独立档案页，靠搜索无法合法补齐。

**第六轮（换批补录：秀色女神 + 新 8 站 + cos2cy 编号页）**

放弃第五轮核查剩下的站，另找一批全新来源，17 个候选里筛出 10 个可用（22cos / nvshentk / coserbox / a2cy / eciyuancos 是 JS 渲染站，meitu131 字段无法解析，快懂百科字段藏在 hydrate JSON 里性价比低，均放弃）：

| 来源 | 形态 | 产出 |
|---|---|---|
| 秀色女神 xsnvshen.com | 全站 11,075 位女神结构化档案（`bas-title`/`bas-cont` 字段对） | **11,060 条**：生日 9,581 / 身高 8,800 / 三围 3,737 / 出生地 10,980 / 血型 / 星座 / 爱好 3,213 / 微博 2,209 / 作品 5.2 万条 / 头像 URL 全量 |
| cos2cy 编号页 | `001.html`–`340.html` 人物传记页（350+ 是图集，跳过） | 330 条（生日 160 / 身高 108） |
| cos2cy / sluyu / 女神空 / costuan / tuquge / tuinvlang / qiliguan / fulill | WordPress REST 档案页 | 925 条（生日 735 / 身高 513） |

- 新脚本：`fetch_xsnvshen.py`（列表页翻页 + 资料页字段解析）、`fetch_cn_profiles_round7.py`、`fetch_cn_profiles_round8.py`；代理统一换 Clash 7890（8118 已停）。
- SEO 标题站（round7/round8）继续走 `match_cn_profiles.py` 库内姓名反查：web7 925 → 738（79%）、web8 330 → 263（79%）；xsnvshen 是结构化资料页，直接入档。
- `build_catalog_db.py` 适配：region 透传（xsnvshen 的「出生：韩国…」比代码推断可靠）、hobby 透传、作品真实 URL 优先、sources 清单扩展。
- 收尾修正一（地区归位）：xsnvshen 出生地是「中国 台湾 台北市」这类空格分隔写法，首轮解析按 `startswith("中国")` 全判成大陆，海外出生也兜底成大陆；`fix_xsnvshen_region.py` 用前缀规则归位 **3,016 条**（台湾 1,322 / 香港 212 / 欧美 1,476 / 日本 5 / 韩国 1），大陆 7,997 → 5,257。
- 收尾修正二（头像 URL）：旧 image_url 是猜的 `img.xsnvshen.com/album/{gid}/{gid}.jpg`，无 `thumb_205x308` 前缀全被防盗链 403；`fetch_xsnvshen_covers.py` 翻 446 页列表页拿真实封面（`thumb_205x308/album/{aid}/{aid}.jpg`，封面 album id ≠ girl id），11,060 条全量换掉。
- 最终重建：人物 17,428 → **26,561**（大陆 2,474 → **5,257**、台湾 → **1,122**、香港 → **206**、欧美 → **1,455**、日本 → 17,903、韩国 → 618）；生日 8,116 → **16,294**、身高 8,332 → **15,826**、三围齐全 8,558 → **11,898**、出身地 3,677 → **13,160**、爱好 3,210 → **9,255**、血型 2,081 → **6,606**；作品 52,052 → **113,431** 条（大陆有作品的人物 766 → **3,207**）；人物链接 77,184 → **146,316**、跨站 ID 22,810 → **29,947**。
- 大陆档案缺口（基数 5,257）：生日 568 → **2,902**（55%）、身高 621 → **2,776**（53%）、三围 151 → **1,664**（32%）、出身地 766 → **3,646**（69%）、爱好 → **1,687**（32%）；「生日/身高/三围全无」**1,868**（36%）。
- 头像：库内 image_url 18,214 个（大陆 4,008），`fetch_avatars.py` 走 Clash 7890 代理批量转 96×96 JPEG base64，有效下载 **17,333 张**（含厂牌 34）；重建后 **17,927 行**内嵌（别名行共用同一 URL，另有 287 条 URL 下载失败留空、8,347 人无 URL）。

**第七轮（JavBus 改名双页补图闭环 + 头像增量 + v2ph 索引）**

- **51 人缺图根因闭环**：JavBus 演员改名后会同时保留旧名、新名两个 star 页——旧名页是带括号的全名（`javbus_detail_rows` 据此建条目，有资料没图），新名页是剥括号的现用名（常有头像）。三个环节叠加导致旧名条目永远拿不到图：① `javbus_star_rows` 剥括号后主名先命中孪生条目（`apply_actress_details` 首中即赢）；② `consolidate_actresses` 的合并键保留括号内容，全名 ≠ 现用名永不合并；③ 没有按跨站 ID 的兜底。修复：`javbus_star_rows` 主名改为**全名优先**（现用名降级为回退别名）+ `write_enrichment` 新增按 `external_ids` 反查探活结果直连 UPDATE 的兜底（实际修复 1 已全命中，兜底为安全网）。终验：6,221 个「有 JavBus ID + 探活 URL」的人 **0 缺图**。
- **头像增量下载与 Referer 策略修复**：第六轮 287 条失败 URL 里 276 张是被「统一加站点根 Referer」的策略害的——`pic1.imgdb.cn` 302 跳百度 CDN 后带旧 Referer 被防盗链 403；`hk.66372188.xyz` 带自家根 Referer 直接 403。改为**只有 JavBus 域必须带 Referer，其余第一次裸连、403 后第二次再补**，279/287 成功。加上二次重建，头像 base64 内嵌 17,927 → **18,951 行**（含下方改名孪生合并后的终态）；剩余 5 条是真死链（JavBus `cc4_a.jpg` 用 200+HTML 假装成图、带过期签名的字节图床直链、`&amp;` 未解码的搜狗直链等），已核实放弃。
- **v2ph 演员索引**：`/tmp/fetch_v2ph_actor_index.py` 遍历 `/country/{region}` 分页抓 Model 链接 + JSON-LD Person，原子增量落盘；跑到 400 页 / **2,410 位演员**时全站（us/com/co 及直连）统一 403（同长 3,102 字节 WAF 页，代理出口同封），安全停止等待解封后断点续爬，之后抓 `/actor/{slug}` 档案页生成第二个补丁文件（glob 加载器已支持）。
- **同名重复人物合并**：库里同名多条的摸底——完全同名仅 21 组（罗马字艺名 + miaomengshe 裸标签条目），主体是「剥掉括号注记后同名」的 **91 组 182 行**：JavBus 改名双页让同一个人落成两条（旧名页 `西野花梨（小柳まりん、椎名くるみ）` 有资料无图、新名页有头像），`consolidate_actresses` 收不掉——合并键保留括号内容导致主名对不上，两条的日文名又互换，被「日文名冲突」规则挡下。新增 `merge_rename_twins`：按「剥掉括号段后的归一键」连边合并；地区或生日冲突（归一 YYYY-MM-DD 再比）一律不并，保护同名不同人；括号注记里的别名收进幸存者。因为 `finalize_actresses` 会把建库名（`Chamei`）重选成展示名（`叉魅`），在 `fix_script_regions` 定型后再跑第二次。两次共合并 **73 条**（26,470 → **26,397**），重名组 91 → **30 组**且每组都带地区或生日冲突证据（`Yuna` korea/china、`愛染恭子` 生日差 28 年——JavBus 用括号注记区分的同名不同人），**无冲突未合组 = 0**。

**第八轮（大陆人物重复专项检查）**

- 用户点题「中国大陆的重复好好检查」。摸底三大形态：跨源同名（CJK 核心碰撞 **95 组 214 行**——中英混写「水淼aqua vs 水淼」、站名前缀「模范模特方子萱 vs 方子萱」、相册艺名 vs 微博真名「果儿 vs 张杨果而」全名归一对不上）、品牌前缀 5 条、垃圾标题名 72 条。`consolidate_actresses` 收不掉完全不同名，`merge_domestic_variants` 的变体键 3 字门槛又把「水淼」「呆呆」这类 2 字名挡在门外。
- 新增 `merge_cn_variants`（build 尾部、展示名与地区定型后），按两条身份证据收敛：**规则 1** 剥 `CN_BRAND_PREFIXES` 站名前缀后取 CJK 汉字段为键（「水淼aqua → 水淼」，只对 china 条目，避免日文假名被剥误连）；**规则 2** xsnvshen 相册封面同 URL + 生日一致（月日同、年差 ≤1 视作录入误差）——`img.xsnvshen.com/thumb_205x308/album/{id}/{id}.jpg` 的 album id 每人唯一，是人物指纹；公共图床不算：`picture.avking.xyz` 是日本区几十人共用的占位图，`pic.imgdb.cn` 的「葛征 / Kiren_程程程」共图但生日身高全冲突（假同人）。生日/身高/三围签名冲突的一律不并：「果儿 / 果儿Victoria / 果儿celia」生日三个不同，正确保留三人。
- 调试坑：规则 2 初版读 `image_url`，而 merged 内存记录里头像字段叫 **`image`**（DB 列名才是 image_url），`by_url` 恒空导致规则 2 一条都收不到——修字段名后生效。
- 一次完整重建共收敛 **113 条**（冲突跳过 32 对），人物 26,397 → **26,284**（大陆 5,235 → **5,125**、台湾 1,129 → **1,127**、香港 207 → **206**；日本 17,763 分毫未动）。终验：10 组「同封面 + 同生日」目标对（赵惟依/赵静伟、果儿/张杨果而、孟狐狸/孟旖旎、李波Bobo/熊吖BOBO、陆瓷/姜彦希、唐琪儿/王艳卓、晓茜sunny/李镇姬、吕孝瑶/瑶瑶baby、乔莹/乔梦汐、施佳/小柔SeeU）全部合并、被吸收名进 aliases；库内同 xsnvshen URL 仍多行的残留仅 1 组（美里有紗 1992-07-14 / Arisa Misato 1992-07-04，生日月日不同被冲突保护正确跳过，留待日文区后续处理）。

**第九轮（推广文标题冒充人名清理）**

- D22 摸底时就点出的 72 条垃圾标题名，本轮做掉。成因链路：泡面站这类 WordPress 站的文章标题本身是 SEO 推广文（「爱看动漫的必知！超会还原角色的水淼aqua」「俄罗斯Yoshinobi_精美美图全部」），`fetch_cn_profiles_more.py` 抽不出 person_name 时整标题落库成人物名；后续「库内姓名反查标题」的匹配又会把 costuan 等 SEO 站的链接错挂到这些假人上。
- 新增 `is_title_junk_name()` 检测器，三特征任一命中即判垃圾：**标题标点**（！？：；，""、）、**推广关键词**（必知 / 美图全部 / 谁还不认识 / 天花板 / 次元壁 / 走进 / 探秘…正则）、**长名带「的」且纯中文**（≥12 字、无字母数字）。三处误杀防护：括号内旧名列举剥掉再判（`倉木小夜（村上美咲、樋口啓子）` 不是标题）、撇号不作标点（`Tun'book` 放过）、「的」规则限纯 CJK（`wink是可爱的wink` 混写网名放过）。检测器初版 49 条命中 → 修订后 36 条、误杀 0。
- 挂三个点：`finalize_actresses` 垃圾名分支 or 上 `is_title_junk_name`（有干净别名则改名降级污染名、纯垃圾则整条删除）；`clean_domestic_target` 候选池剔除标题式别名（防「俄罗斯Yoshinobi_精美美图全部」当展示名，Yoshinobi 主名修复 id 5422、37 links 完整保留在真人条目）；垃圾条目 pop 后 `resolve` 无解析目标，99 条错挂的 costuan 链接自动不再落库。
- 一次完整重建：36 条目标全部处理——**24 条纯删**（含「就是这个账号！」）+ **11 条改名**（三井麻由→Mayu Mitsui、本仮屋唯佳并入本假屋唯香、李清娥并入李青儿、中岛莫之子i→中岛莫之子、曉美媽名称辨识→曉美媽等），水淼aqua 真人条目（id 4431）不受影响。重建后残留标题垃圾名 **0**，人物 26,284 → **26,253**（大陆 5,094），链接 146,862 → **146,341**、作品 113,863 → **113,349**。

**第十轮（头像 base64 拆独立表）**

- 动机：头像 base64 内嵌在 `actresses` / `studios` 主表行里，app 端 `CatalogNameDictionary` 启动时全表 SELECT 一遍，18,863 条 ~15KB 大文本整库进内存常驻（约 200MB+），而名字匹配索引根本用不上头像；主表任何不带该列的扫描也背着行放大。
- 建库侧：`build_catalog_db.py` 新增独立表 `person_avatars(actress_id PRIMARY KEY, base64)`（18,863 条）/ `studio_avatars(studio_id PRIMARY KEY, base64)`（464 条），主表列 `avatar_base64` 换成 `has_avatar` 标志（人物 INSERT 改显式 id 关联，JavBus 兜底补图同步写独立表）；`meta` 加 `avatar_count` / `studio_avatar_count`。人物/链接/作品计数与上轮完全一致（26,253 / 146,341 / 113,349）。
- app 侧：新增 `CatalogAvatarStore`——独立只读连接按主键单条取，NSCache 缓存 base64（空串做负缓存），`CatalogActressRecord.avatarBase64` / `CatalogStudioRecord.avatarBase64` 改为按需计算属性，27 处界面引用零改动；人才库的 4 处列表过滤（门头拼贴 / 生日轮换池）改用 `has_avatar`，不在启动路径上触发查表。`CatalogAvatarView` 的 NSImage 解码缓存照旧。启动内存立减 200MB+。

---

## 1. 现状体检（第一轮基线，补全前）

### 1.1 人物字段覆盖（16,135 人）

| 字段 | 有值 | 覆盖率 |
|---|---:|---:|
| 日文名 | 12,386 | 77% |
| 英文名 | 469 | 3% |
| 生日（含 497 条仅年份） | 6,043 | 37% |
| 年龄 | 3,470 | 22% |
| 身高 | 6,233 | 39% |
| 三围齐全 | 7,063 | 44% |
| 罩杯 | 6,128 | 38% |
| 作品数 | 3,723 | 23% |
| 简介 | 2,788 | 17% |
| 头像 | 7,620 | 47% |
| 别名 | 3,640 人 / 5,914 条 | 23% |
| 标签 | 只有 111 种 | — |
| `description` | 54 条 | ≈0% |

### 1.2 地区断层

| 地区 | 人数 | 生日 | 身高 | 三围 | 作品数 | 头像 | 简介 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 日本 | 13,799 | 6,024 | 6,233 | 7,062 | 3,723 | 7,611 | 2,710 |
| 中国大陆 | 2,187 | 3 | 2 | 1 | 1 | 2 | 22 |
| 韩国 | 111 | 14 | 3 | 2 | 0 | 7 | 54 |
| 欧美 | 25 | 0 | 0 | 0 | 0 | 0 | 1 |
| 台湾 | 11 | 2 | 0 | 0 | 0 | 0 | 1 |
| 香港 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |

### 1.3 资料完整度（9 项：生日/身高/三围/罩杯/作品/简介/头像/标签/别名）

| 地区 | 0–2 项 | 3–5 项 | 6–8 项 | 9 项 |
|---|---:|---:|---:|---:|
| 日本 | **6,797** | 3,347 | 1,957 | 1,698 |
| 中国大陆 | **2,176** | 11 | 0 | 0 |
| 韩国 | 61 | 48 | 2 | 0 |

「纯名字」（无生日/身高/作品/简介/头像）：**7,576 人，占 47%**。

### 1.4 厂商

| 指标 | 数值 |
|---|---:|
| 厂商总数 | 464（片商 272 / 写真机构 188 / 平台 4） |
| 有简介 | 14 |
| 有官网 | 42 |
| 有真实 Logo | 0（现为字母头像） |
| 有英文名 | 216 |
| 有作品数 | 249 |
| 只有名字 | 149 |
| 番号前缀 | 45 条，只覆盖 13 个厂商 |
| 完全没有前缀的厂商 | 456 |

### 1.5 补全后对比（2026-11-25 第十轮终态）

| 指标 | 补全前 | 现在 | 变化 |
|---|---:|---:|---:|
| 人物总数 | 16,135 | **27,021** | +10,886 |
| 有生日 | 6,043 | **16,193** | +10,150 |
| 有身高 | 6,233 | **15,717** | +9,484 |
| 三围齐全 | 7,063 | **11,808** | +4,745 |
| 有头像 | 7,620 | **19,863**（URL）/ 19,849（独立表 `person_avatars`，按主键单条取） | +12,243 / 新增独立表 |
| 血型 | 0 | **6,614** | 新增字段 |
| 出身地 | 0 | **13,100** | 新增字段（日文维基 + 国内站） |
| 出道年 | 0 | **3,279** | 新增字段 |
| 所属事务所 | 0 | **1,712** | 新增字段 |
| 官网 | 0 | **1,952** | 新增字段（已剔除非官方链接） |
| 爱好 | 1,801 | **9,249** | +7,448 |
| 有别名（人） | 3,640 | **12,849** | +9,209 |
| 标签种类 | 111 | **157** | +46 |
| 跨站 ID | 17,142 | **29,957** | +12,815 |
| 人物主页/社交链接 | 20,477 | **32,207** | +11,730（作品已改由 `works` 唯一承载） |
| 作品（`works`） | 0 | **132,018** | 国内套图/写真 |
| 厂牌 logo | 0 | **34 / 464**（其余为品牌字母头像） | 新增 |

地区分布：日本 17,767 / 中国大陆 5,852 / 欧美 1,452 / 台湾 1,127 / 韩国 617 / 香港 206。秀色女神出生地按「中国 台湾 台北市」空格写法归位后，台湾 / 香港 / 欧美不再是零头；第十轮秀人网镜像补进 763 位大陆写真模特。

分地区看国内补录效果：

| 大陆指标 | 补录前 | 第四轮 | 现在 |
|---|---:|---:|---:|
| 人物 | 2,186 | 2,474 | **5,852** |
| 生日 | 3 | 568 | **2,877**（49%） |
| 身高 | 2 | 621 | **2,748**（47%） |
| 三围齐全 | 1 | 151 | **1,658**（28%） |
| 出身地 | 0 | 766 | **3,585**（61%） |
| 爱好 | 0 | — | **1,696**（29%） |
| 有作品 | 1 | 766 | **4,276** |
| 生日/身高/三围全无 | 2,059 | 1,714 | **2,510**（占比 69% → 43%） |

第十轮新增的 763 位大陆人物几乎都来自秀人网镜像，站方只提供「名字 + 套图 + 封面」，没有生日/身高/三围，所以「三无」绝对数回升（1,837 → 2,510），但他们都带作品与头像，是有内容的长尾，不是空名字。

---

## 2. 可补的信息角度

### A. 人物身份与生理信息
日文读音、中文名、英文名、本名、旧艺名、出身地、生日、血型、身高、体重、BWH、罩杯、鞋码、惯用手、趣味/特技。

### B. 职业履历
出道年份/出道作、专属厂牌、所属事务所、活动期间、引退/复归、获奖、年度排名、销量。

### C. 官方与社交
官网、X、Instagram、YouTube、TikTok、微博、B站、小红书、OnlyFans、粉丝俱乐部、粉丝数。

### D. 作品（最大的空白）
番号 / `content_id` / `dvd_id`、日/中/英标题、发行日期、时长、导演、片商、label、系列、题材、出演者、共演、封面、剧照、预告、评分、收藏/想看。

### E. 数据关系
人物 ↔ 事务所；人物 ↔ 厂牌；人物 ↔ 写真机构；人物 ↔ 作品 ↔ 系列 ↔ 题材；人物 ↔ 共演者；人物 ↔ 相似人物；厂商 ↔ 母公司/label/系列。

### F. 多图与媒体
主头像、全身、写真、作品封面、剧照、签名。建议存 URL + 本地按需缓存，不再把 base64 塞进 SQLite（当前 41MB 里 28.9MB 是头像）。

### G. 标签体系
现在只有 111 种且偏主观。需要题材、角色、服装、IP、年代、地区、平台、奖项，并做「规范名 + 中日英别名 + 分类」。

### H. 数据质量与溯源
字段级来源、更新时间、置信度；497 条仅年份生日需要精度字段；地区误判（港台/大陆、华裔欧美）需要复核。

---

## 3. 现有 raw 里还没榨干的东西

| raw 文件 | 内容 | 现状问题 |
|---|---|---|
| `javbus_star_details.json` | 9,535 人的生日/年龄/身高/BWH/罩杯/爱好 | 爱好未入库；匹配现有日文人物可补 1,742 条爱好、161 条三围、117 条身高、93 条生日 |
| `javbus_stars_zh.json` | 53,278 条 star_id → 中文名 | 只当译名，未作为别名/发现字典 |
| `javbus_portraits.json` | 5,804 个头像 URL | 对现有日文人物只能再补 3 张，补不齐 6,188 个无头像的人 |
| `javrate_actor_details.json` | 3,715 人：`ja` 读音列表、别名、简介、图片 | 读音/别名已在合并流程中使用；简介用了 2,336 条 |
| `javbus_name_map.json` | 3,709 条日文名 ↔ 中文名 | 可用于别名与去重 |
| `coscd_people.json` + `coscd_posts.json` | 913 人、3,826 篇作品、1,593 条作品链接、角色/IP 标签 | 只取了名字和套数；作品、链接、IP 标签全丢 |
| `coscd_tags.json` | 碧蓝航线 502、原神 180、2B 123、女仆、旗袍等 | 可建 Coser 的「角色/IP」标签 |
| `kkkhai_tag_studios.json` / `brand_studios.json` | 146 个国内写真机构/品牌 | 未能可靠建立「模特 ↔ 机构」关系 |
| `kkkhai_posts_full.json` | 915 篇作品，带日期/期数/机构 | 只用了名字；日期/期数注意不要当正式统计 |
| `kkkhai_studio_details.json` | 194 个机构的风格/是否收新人 | 未入库 |
| `mms_profiles.json` / `mms_tags.json` | 998 篇长文、4,869 个标签 | 长文多为 AI 水文，不建议；标签可挑角色类 |
| `wikidata_actress_dates.json` / `wiki_actress_bios.json` | 496 条生日/身高、745 条中文维基简介 | 已用，但覆盖面小 |

**P0 结论：**
1. 入 `hobby`（1,742 条）
2. 修生日精度（497 条仅年份）
3. 入 Coser 作品链接与角色/IP 标签
4. 建 `external_ids`（javbus / javrate）
5. 模特↔机构关系现有证据不足，需要新抓机构/模特页

---

## 4. 外部资源清单（按性价比）

### 4.1 R18.dev（作品与 ID 的底座）
- 免费单作品 JSON：`https://r18.dev/videos/vod/movies/detail/-/combined=<id>/json`
- 每周 gzip SQL dump，**CC0**：`https://r18.dev/dumps`
- 约 8.5 万女优（DMM id、日文名、别名、缩略图）；作品含 content_id / dvd_id / 标题 / 发行日期 / 时长 / 导演 / 厂牌 / label / 系列 / 出演者 / 题材 / 封面 / 剧照 / 预告。
- 注意：元数据 CC0，封面/剧照版权不属于 CC0，建议只存 URL。

### 4.2 DMM / FANZA Web API v3（人物档案最权威）
- `ActressSearch`：女优 ID、艺名、读音、BWH、罩杯、身高、生日、血型、趣味、出身地、头像、列表页。
- `ItemList`：作品；`MakerSearch` / `SeriesSearch` / `GenreSearch`：厂牌/系列/题材。
- 需要联盟 `api_id` + `affiliate_id`，有站点审核；图片使用有条款。

### 4.3 JavBus（已有基础）
- 演员页：生日、三围、出道年份、全部出演作品。
- 作品页：番号、封面、发行日期、时长、导演、制作商、发行商、系列、类别、演员、样品图。
- 现有 raw 9,535 人；需要限速/代理。

### 4.4 JavLibrary（评分/想看/看过）
- 演员档案、作品、评分、评论、想看/看过；Cloudflare/403 严重，需要代理。

### 4.5 JavDB（中文资料/评分/标签）
- 演员、作品、评分、标签、海报；需要 cookie / Cloudflare 绕过。

### 4.6 Wikipedia（日文/中文）+ Wikidata
- 日文维基信息框：生年月日、出身地、身高/体重、三围、罩杯、出演期间、专属厂牌、所属事务所、获奖、官方账号。
- Wikidata：P569 生日、P19 出身地、P2048 身高、P2002/P2003/P2397 社交、P856 官网。
- 免费、可引用，适合做可信基线。

### 4.7 经纪公司官网
- T-Powers、C-more、Mine's、Life、Prime、Eightman、Vanquish、Bambi、ALIVE、aina 等。
- 现役最权威：生日、身高、三围、出身地、趣味、官方社交。

### 4.8 日文资料站
- 素人系総合 wiki、AV-Wiki、rank1-media、narrow-deep：生日、三围、出道作、出演本数。
- 适合补老女优；准确性参差，需交叉校验。

### 4.9 欧美
- IAFD：生日、出身地、族裔、身高、体重、活动年份、别名、作品履历、获奖。
- ThePornDB / StashDB：GraphQL + API Token，performer / scene / studio / 图片。
- FreeOnes / Babepedia：资料与社交链接。

### 4.10 华语/台湾平台
- JVID：模特页、作品、写真、视频。
- SWAG：创作者页、作品。
- 无公开 API，HTML 抓取。

### 4.11 国内平台与社交
- B站公开 API：昵称、头像、签名、粉丝数。
- 微博 `m.weibo.cn`：昵称、头像、简介、粉丝。
- 小红书/抖音：签名风控，建议只存主页链接。

### 4.12 国内写真机构
- XIUREN、UGirls、ROSI、AISS、ARTGRAVIA、Beautyleg、DKGirl、GGotBBang、BoLoLi、MFStar、Feilin 等。
- 用于「所属机构」「作品系列」「同机构模特」。

### 4.13 榜单与热度
- FANZA 月间/年间女优榜、作品榜；朝日芸能 SEXY 総選挙；FLASH 排行；月刊 FANZA。
- JavLibrary 想看/看过；JavDB 评分；社交粉丝数。

### 4.14 韩国
- 库内 617 人（2026-11-26 基线），几乎没有作品；Playboy Korea、Maxim Korea、Instagram、经纪公司。
- 2026-11-26 实测 **jvheku.com** 聚合了 Bimilstory / LeeheeExpress / Pure Media / 韩国写真等 web pictorial（「韩国写真」标签 661 条、「LeeheeExpress」626 条），是当前最现实的韩系入口；官方站需会员。详见 §4.15。

### 4.15 新源实测（2026-11-26）

> 只做可达性与结构勘探，**没有抓取、没有写库**。规模来自站点 REST 的 `X-WP-Total` 或 sitemap 计数；「重叠」是用当前 27,021 人的库内主名/别名做精确比对后的抽样估算，会被中英日译名差异低估。

#### 可直接抓

| 源 | 形态 | 实测规模 | 与库重叠 | 可补什么 |
| --- | --- | --- | --- | --- |
| **Wikidata SPARQL** | `query.wikidata.org/sparql` | 女性成人演员 **9,191** 人（含男性共 13,914）；生日 7,448 / 身高 2,980 / Instagram 2,488 / Twitter 3,435 | 英/日标签精确命中 877 / 22,025（译名导致低估） | 欧美、韩国、日本档案字段与社交 ID；CC0，最省事的一手源 |
| **jvheku.com** | WordPress REST | **42,841 篇** / 14,321 标签 | 最近 1,000 篇标题只解析出 27 个不同人名头，多为机构合集 | **韩系 web pictorial**（Bimilstory / LeeheeExpress / Pure Media / 韩国写真 661 条）+ 微密圈合集；当前韩系作品为 0 |
| **xiurenz.com.cn** | WordPress，REST 返回 401；sitemap + HTML 可读 | **18,857 篇**（10 个 post sitemap），`/vmhj/` ≥35 页 | 抽 78 个标题，12 个库外（约 85% 已覆盖） | 微密圈 / 觅圈 / 铁粉空间约 600 名网红、秀人旗下合集 |
| **myxiuren.com** | WordPress REST | 20,402 篇 / 613 个人名标签 | 461 命中、152 库外；最近 100 篇的 NO. 号 **97% 已在库** | 约 150 个新模特（Barbie可儿、Cherry绯月樱、程程程-、芭喜mila、柚柚sasa…）+ 少量 2026 新套 |
| **yituwan.com（艺图湾）** | WordPress REST | **65,069 篇** / 6,448 标签 | 前 1,000 标签 542 命中 / 458 库外，库外多为机构 | **100+ 写真机构**（物恋传媒、丝享家、异思趣向、Beautyleg、丽柜、语画界、尤蜜荟、雅拉伊、慕丝女郎、SSA丝社、克拉女神、爱蜜社、花漾、星颜社…）+ 100–300 位新人 |
| **guoxuezy.cn（七图社）** | WordPress REST | 1,618 篇 / 1,472 标签 | 432 个库外标签（混有机构） | 微密圈 / 抖音网红约 300–400 人 |
| **yanmishe.cn（颜蜜社）** | WordPress REST | 1,772 篇 / 1,430 标签 | 400 个库外标签 | 与七图社同源，去重后合计约 500 人 |
| **coserji.com（COS集）** | WordPress REST | 4,968 篇 / 7,330 标签 | 前 2,000 标签 508 命中 / 1,492 库外（大量题材词） | 200–400 位 coser（眼酱大魔王w、雯妹、星澜、小VV、小容仔咕咕咕w…） |
| **madouplus.com（麻豆夹）** | WordPress REST | 30,023 篇 / 2,803 标签 | 前 1,000 标签 358 命中 / 642 库外（多为泛词/机构） | 50–150 位新人 + 秀人系内购套图 |
| **simimiao.com（丝密喵）** | WordPress REST | 1,724 篇 / 1,736 标签 | 人名标签很少（蠢沫沫 33） | 不到 50 人，主要是 JVID / 微密圈合集，低优先 |
| **graphis.ne.jp** | 老式 PHP 页面 | 公开页每页 51 个模特链接 × 3 个 STAGE（约 150） | 未比对 | 日本写真偶像几十人 + 封面；会员区不可见 |

#### 受条件限制

- **R18.dev dump**：官方 CC0、每周二更新，但本站直连 403 / SSL 失败，需代理或手动下载。仍是**日本作品从 0 到十万级**的唯一大路。
- **IAFD**：首页 200，但返回 Cloudflare 挑战页；**ThePornDB** 需 API key；FreeOnes / Babepedia / javdatabase / javdb / avmates / mrcrack 全部 000 或 403。欧美库暂时进不来。
- **Bimilstory / Leehee Express 官方**：会员付费站，首页只能拿到 11 个模特入口 / 69 个专辑码，结构性差。
- **秀人镜像族**（xiurenwa / xiurenren / xiurenwu / xiurenlu）：可达，但与 myxiuren + xiurenwang 高度重复，不建议再抓。

#### 结论

1. **增量估算（去重后）**：人物 +1,200 ～ +3,000；作品 +8,000 ～ +25,000；生日 +3,000 ～ +6,000；身高 +1,500 ～ +3,000；社交 ID +2,000 ～ +4,000；机构 +80 ～ +150。R18 dump 若打通，日本作品与女优档案另算。
2. **去重必须三道指纹**：NO. 号 + 标题指纹 + 封面 URL。myxiuren 最近 100 篇 97% 的 NO. 号已在库，单看「帖子数」会严重高估增量。
3. **抓取纪律**：Wikidata 当前限流 1 请求/分钟；WP 站 1–2 请求/秒；只存封面 URL，不下载付费内容本体；每条保留 `source` / `source_url`。
4. **建议顺序**：P0 = Wikidata 字段补全 + xiurenz 微密圈名单 + 七图社/颜蜜社；P1 = jvheku 韩系 + myxiuren 新人 + yituwan 机构/作品（先定去重规则）；P2 = R18 dump（先解决代理）；P3 = coserji / madouplus / graphis 增量。

---

## 5. 建议的数据结构

```sql
-- 人物档案（在 actresses 上扩列）
hobby, birth_precision, ruby, birthplace, blood_type,
debut_year, agency, status, official_site, popularity

-- 跨站 ID（去重与增量更新的地基）
external_ids(entity_type, entity_id, source, external_id, url)

-- 人物链接（作品 / 主页 / 社交）
person_links(actress_id, source, kind, url, title, published_at)

-- 人物 ↔ 机构
person_studios(actress_id, studio_id, kind, source)

-- 作品
works(id, content_id, dvd_id, code, title_ja, title_zh, title_en,
      release_date, runtime_min, director, studio_id, label, series,
      genres, cover_url, sample_urls, trailer_url, rating, popularity)
work_actresses(work_id, actress_id)

-- 其他
makers / labels / series / genres
social_accounts
images
rankings
relations
field_sources
```

没有 `external_ids` 和 `works`，后续所有补数据都会继续依赖名字模糊匹配，越补越乱。

---

## 6. 优先级路线

### P0（不联网，现有 raw）
- `hobby`、生日精度、Coser 作品链接、角色/IP 标签
- `external_ids`（javbus / javrate）
- 数据质量修复

### P1（外部一手源）
- R18.dev dump → `works` / `makers` / `labels` / `series` / `genres`
- DMM/FANZA API → 读音、血型、趣味、出身地、官方头像
- 日文维基 → 生日、出身地、三围、出道、事务所
- JavLibrary / JavDB → 评分与热度

### P2（区域扩展）
- 国内：B站 / 微博 / JVID / SWAG / 写真机构
- 欧美：IAFD / ThePornDB / FreeOnes
- 韩国：经纪公司 / Instagram

### P3（派生能力）
- 出道周年、引退/复归、专属厂牌时间线
- 同事务所、同机构、共演、相似人物
- 番号 → 本地文件匹配、榜单、趋势

### 2026-11-26 新源优先级（实测后）

- **P0**：Wikidata SPARQL 补欧美/韩国/日本档案与社交 ID；xiurenz 拉微密圈约 600 名网红名单；七图社 + 颜蜜社去重后补约 500 位网红。
- **P1**：jvheku 补韩系 web pictorial（人与作品）；myxiuren 补约 150 位新模特；yituwan 补 100+ 写真机构与作品——先定「NO. 号 + 标题指纹 + 封面 URL」去重规则，否则 works 会虚增。
- **P2**：R18.dev dump（需代理/手动下载）打通日本作品与女优档案。
- **P3**：coserji / madouplus / graphis 做增量人物与封面，优先级最低。

细节、实测规模与重叠率见 §4.15。

---

## 7. 工程与合规注意

- 不要把作品图片塞进 SQLite；当前 41MB 里 28.9MB 是头像。作品封面/剧照会直接爆安装包。
- 作品表建议单独成库或运行时下载；R18 全量是十万级。
- 图片版权：R18 元数据 CC0，但封面/剧照不是；DMM API 对图片有条款。
- 反爬：JavLibrary/JavDB 有 Cloudflare/403，GitHub IP 被封。
- 社交接口有频率限制和 cookie 要求；小红书/抖音签名风控。
- 去重必须用 external_id + 生日 + 读音/别名；现有 497 条仅年份生日需要精度字段。
- 每个字段记录 source / confidence / updated_at。

---

## 8. 外部来源

- [DMM Web API v3 まとめ（2026）](https://web-dev.fun/posts/2026-05-01-dmm-api/)
- [DMM ActressSearch 可取得字段](https://qiita.com/fabsabsfabsabs/items/e8e3b717dc311ac2176d)
- [R18.dev 免费 JSON / 每周 CC0 dump](https://github.com/the-mskd-dev/Flux/issues/390)
- [R18dev SQL 导入说明](https://github.com/javstash/R18dev_SQL)
- [JavLibrary 爬虫](https://github.com/d68fbe50/JavlibraryCrawler)
- [JavBus 作品字段](https://github.com/fireinrain/javbus_scrapy)
- [JavBus 演员页说明](https://javbus.com.cn/)
- [Javinizer 的 JavDB / JavLibrary / DMM 配置](https://javinizer.gitbook.io/docs/configuration/settings)
- [IAFD 数据结构](https://parse.bot/marketplace/6ea5b8f8-2d07-4bd6-b4e1-ca8faebb3864/iafd-com-api)
- [StashDB / ThePornDB 接入](https://guidelines.stashdb.org/docs/faq_getting-started/stashdb/accessing-stash-boxes/)
- [Bilibili 用户信息 API](https://github.com/pskdje/bilibili-API-collect/blob/main/docs/user/info.md)
- [微博 m.weibo.cn 接口](https://gist.github.com/zmwangx/64af488ca4eed04d8a719c7293e2f0a1)
- [JVID 模特中心](https://www.jvidzh.com/stars.html)
- [日文维基 AV 女优信息框示例](https://ja.wikipedia.org/wiki/JULIA_(AV%E5%A5%B3%E5%84%AA))
- [素人系総合 wiki](https://seesaawiki.jp/w/sougouwiki/d/%BD%F7%CD%A5%A5%DA%A1%BC%A5%B8%B0%EC%CD%F7)
- [日文 AV 女优资料站](https://narrow-deep.car.coocan.jp/other/av/index_a.html)

2026-11-26 新源实测（§4.15）：

- [Wikidata Query Service](https://query.wikidata.org/)
- [R18.dev Database dumps](https://bot-api.r18.dev/dumps)
- [jvheku 合集索引](https://www.jvheku.com/)
- [秀人网 · 微密合集（xiurenz）](https://www.xiurenz.com.cn/)
- [秀人网官方镜像 myxiuren](https://www.myxiuren.com/)
- [艺图湾](https://www.yituwan.com/)
- [七图社](https://guoxuezy.cn/)
- [颜蜜社](https://yanmishe.cn/)
- [COS集](https://www.coserji.com/)
- [麻豆夹](https://www.madouplus.com/)
- [丝密喵](https://www.simimiao.com/)
- [GRAPHIS](https://graphis.ne.jp/monthly/)
- [Bimilstory](https://bimilstory.com/)
- [LEEHEE EXPRESS 索引](https://leeheeexpress.org/)
