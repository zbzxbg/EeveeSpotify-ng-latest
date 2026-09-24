# 歌词模块：面 A 已修复，面 B 待攻（含实测日志清单）

**数据**：`C:\dsh\readlog\eeveespotify_debug{ 2 (2), 3, 4, 5, 6, 7}.log`（2026-09-24）

---

## 0. 结论（先看这里）

**Spotify 有两个独立的"歌词面"，必须分开谈。**

| | 面 A：单行歌词 | 面 B：歌词预览卡片（**目标**） |
|---|---|---|
| 位置 | 封面与歌名**之间** | 与**「关于艺人」并列** |
| 类名 | `Lyrics_TextComponentImpl.LyricsView` | `Lyrics_CardElementImpl.CardView` |
| 判据 | **数据驱动**：有可用的歌词 payload 就建 | **另有门控**（见第 3 节） |
| 现状 | ✅ **已修复**（合成时间轴，干净 A/B 证实） | ❌ **仍未解决** |

- **面 A 修好了。** 关掉合成时间轴 → 面 A 三首全无；打开 → 三首全有
  （内容分别是可滚动歌词 / 纯音乐 / 未找到歌词，**全部来自我们注入的 payload**）。
- **面 B 依然是"有些歌完全没有"的元凶。** 它不受合成时间轴影响。
- 关键推论：**注入通路本身完全正常**——面 A 能渲染出我们写的"纯音乐"、"未找到歌词"，
  说明 payload 被 Spotify 正常接收解析。面 B 缺的是**另一个开关**。

---

## 1. 日志清单（务必按版本区分，之前踩过坑）

| 日志 | Spotify | 条件 | 备注 |
|---|---|---|---|
| 1 | 9.1.86 | AMLL 优先开 | 14 秒阻塞样本 |
| 2 | 9.1.86 | AMLL 优先开 | |
| 3 | 9.1.86 | AMLL 优先**关**，旧构建 | 三首**有**请求 |
| 4 | **9.1.6** | 合成开 | 三首**无**请求 |
| 5 | **9.1.6** | 合成关 | 三首**无**请求 |
| 6 | 9.1.86 | 合成**开** | 有效 A/B ✅ |
| 7 | 9.1.86 | 合成**关** | 有效 A/B ✅ |

> ⚠️ **日志 3 vs 4/5 不是有效 A/B** —— Spotify 版本不同（9.1.86 vs 9.1.6）。
> 版本由 `build-ipa-with-orion.yml` 的 `ipa_url` 输入决定，工作流**不下载也不校验** Spotify。
> 建议加 `expected_spot_version` 断言，避免再次静默换版本。

---

## 2. 面 A：已修复（实测 A/B）

**Jersey（纯音乐占位）**这一首最干净：

| | 日志 6（合成 **开**） | 日志 7（合成 **关**） |
|---|---|---|
| 注入 payload | 3 行占位 + **合成时间轴** | 3 行占位，无时间轴 |
| 日志 | `synthetic line timing applied — 3 line(s), duration=150000ms, lastOffset=112500ms` | （无） |
| **面 A** | ✅ `inline host found: Lyrics_TextComponentImpl.LyricsView` | ❌ `inline host not found` |
| 肉眼 | 显示**纯音乐** | 什么都不显示 |

**用户确认**：合成关时，除对照组外三首**均未展示面 A**；合成开时三首**都展示**
（可滚动歌词 / 纯音乐 / 未找到歌词）。

→ 取证报告证据 4 的"无时间轴 → 判为不可用"**由此证实**（在面 A 上）。

**实现位置**：`LyricsDto.toSpotifyLyricsData` 的 `SynthesizesTiming` 分支 +
`SyntheticLyricTiming.applying`；设置项「合成行级时间轴」控制，可在设置里 A/B。

---

## 3. 面 B：未解决，两个候选假说

同一会话（日志 6）里：**SECRET 面 B 出现，另外三首都不出现。**

| | 假说 | 支持 | 反证 |
|---|---|---|---|
| **H1** | 面 B 由 track 元数据 **`has_lyrics`** 决定（Spotify 服务端判定这首歌有没有词） | 与"SECRET 有 / 三首没有"完全对应；`has_lyrics` 确为真实元数据键 | 暂无 |
| **H2** | 面 B 要求**真同步**歌词，合成时间轴不算 | SECRET 是 34 行真 yrc | 7 行那首也是真歌词 + 合成轴，仍不出面 B |

**倾向 H1。** `SPTPlayerTrackHook`（`CustomLyrics+AllTracksLyrics.x.swift`）就是为强行把
`has_lyrics` 写成 `"true"` 而存在的，但：

- `Tweak.x.swift` 的启动校验列表（6 项，全是鉴权类）里**没有** `SPTPlayerTrack`，
  所以这条覆写**历史上从未被验证过**；
- 取证报告的二进制分析（证据 5）认为 9.1.x 上 `metadata()` 选择器可能不存在。

**若 H1 成立**，正主就是这条覆写的绑定，与 payload 形状无关。

---

## 4. 版本差异：9.1.6 上"零请求"

| 版本 | 三首冷门曲目是否有 `color-lyrics/v2` 请求 |
|---|---|
| 9.1.86 | **有**（日志 3、6、7） |
| 9.1.6 | **无**（日志 4、5，只有 `watch-feed` / `merch-npv`） |

→ "请求门控"是 **9.1.6 特有**的，9.1.86 上不存在。**该线索可以归档**，
不要再拿 9.1.86 的日志去讨论门控。

---

## 5. 本轮新增的两处诊断（纯日志，不改行为）

**① 逐首 dump `has_lyrics`** — `Lyrics/LyricsBackdropArtworkView.swift:47-64`

原来用 `didLogMetadataDump` **只 dump 一次**，打到的永远是碰巧第一首
（三份日志恰好都是 SECRET），拿不到"有词 / 没词"的对照。现在改成**换歌就打**：

```
[Artwork] has_lyrics=<值> track=<id> keys=[...]
```

**② 验证 `SPTPlayerTrack` 覆写能否绑上** — `Tweak.x.swift:400-415`

```
[INIT] SPTPlayerTrack: metadata=<bool> URI=<bool>
[INIT] MISSING SPTPlayerTrack — has_lyrics 覆写必然无效
```

**判读**：三首 `has_lyrics=false/nil` + SECRET `true` → H1 成立；
`metadata=false` → 直接确认覆写绑不上，不必再猜。

> ⚠️ 取日志必须**先开日志记录 → 杀掉 Spotify → 重开**，
> 否则拿不到 `[INIT]` 段（日志 4/5 就缺这一段）。

---

## 6. 其他已查明 / 已修正

- **"每首歌请求两次"已解开**：第二次的 URL 多带 **`vocalRemoval=true`**
  （`…/color-lyrics/v2/track/<id>?clientLanguage=zh&vocalRemoval=true`）。
  日志只打 `url.path`，把 query 吃掉了才显得一样。第二次总命中缓存，非性能问题。
- **AMLL 优先务必保持关闭**：日志 1/2 里 `api.amll.dev` TLS 失败 ×2 = **11 秒**纯浪费，
  导致响应被按住 **14 秒**。关掉后降到 ~1 秒。**问题独立于面 A/面 B，但同样真实。**
- ❌ 作废：**"延迟是模块不出现的（唯一）主因"** —— 关掉 AMLL 后延迟正常，模块依旧不出现。
- ❌ 作废：**门控假说**（曾列为"权重最高"）—— 在 9.1.86 上不成立；仅 9.1.6 观察到。
- ❌ 作废：**"日志 3 vs 4/5 说明我们的构建引入了门控回归"** —— 版本不同，对照无效。
- ❌ 笔误：`LYRICS_MODULE_FINDINGS.md` 里的 ID `1GS3H8cVOmaTDM32X35GGu` 应为
  `1GS3H8cVOmaTDM32X35GQu`（结尾 **u**）。

---

## 7. 代码改动记录

**A. 移除运行时类名探针**（`Tweak.x.swift`）
`eeveeTrackProbeEnabled` / `schedulePlayerTrackProbeIfEnabled` / `logPlayerTrackCandidates`
整段删除。前两条是**致命编译错误**：重复声明 `struct EeveeSpotify: Tweak`，
以及引用已不存在的 `trackProbeNamePrefixes`（早先 `strip_probe_block.py` 误删了定义留下引用）。
同步移除 `UserDefaults.enableTrackProbe`、设置界面开关、`en`/`zh-CN` 两条文案。

**B. 本轮新增诊断** —— 见第 5 节。

**C. 两次括号事故（均已修复，教训记下）**
删探针 Toggle 时多删了 `Section` 的闭括号；`Tweak.x.swift` 删调用点时多删了一个 `}`。
**在没有编译器的会话里改括号密集区域，必须逐处复核**——`edit` 只做字面替换，不校验结构。

> ⚠️ **以上改动均未经编译验证**（会话内 shell 执行器故障 `0xC0000142`）。
> 需要一次真实构建确认。

---

## 8. `Tools/eevee-hookfinder/` 脚本

门控假说在 9.1.86 上已不成立，这些脚本当前没有目标，**先不跑**，留着备查
（`find_player_track_class.py`、`extract_player_track_class.py`、
`audit_lyrics_gate.py`、`find_lyrics_gate.py`）。运行需要 `C:\dsh\ipa\` 下那份
9.1.86 解密 IPA（仍在）。`strip_probe_block.py` 任务已完成，可删。
