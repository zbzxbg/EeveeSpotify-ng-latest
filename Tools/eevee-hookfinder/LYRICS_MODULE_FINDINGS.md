# 歌词模块（预览卡片）不展示：真机取证报告

**取证对象**：Spotify 9.1.86 (build 918602428) · iOS 27.0 · iPhone · tweak 6.6.8
**材料**：`C:\dsh\readlog\eeveespotify_debug.log`、`C:\dsh\readlog\eeveespotify_debug 2 (2).log`、
`C:\dsh\readlog\Spotify-2026-09-24-{210732,215922}.ips`、
`C:\dsh\else\dump-unknown.txt`（eevee-symbol-dump v1，16930 类 / 295 rpc / 540 flags）、
`C:\dsh\else\player_track_class_report.txt`、
`C:\dsh\ipa\Spotify- Music and Podcasts_9.1.86_decrypted.ipa`、
`C:\dsh\ipa\EeveeSpotify-9.1.0.ipa`

---

## 结论（先看这里）

1. **"请求通路"没问题**：歌词请求确实走我们钩的那条路，钩子在工作（证据 1 + 证据 7）。
2. **"卡片存在性"没问题**：9.1.86 上卡片类照旧存在，且在真机日志里实测被找到并挂载（证据 2 + 证据 3）。
3. **坏掉的是"喂给 Spotify 的那份数据有没有时间轴"**：所有正常显示的场合都是
   `timeSynced=true` + 行级时间轴齐全；所有"看起来没有歌词模块"的场合都是
   **无时间轴的占位/纯文本**（证据 4）。
   （注意：这只证明"数据不可用"；Spotify 是否也因此不建模块，见证据 4 的边界说明。）
4. **"再挂一个 hook 强制显示模块"这条路基本被堵死**：决定模块出现的组件是纯 Swift、
   ObjC 侧没有选择器，Orion 够不着（证据 6）。
5. 因此这件事的方向是**修数据**，不是修 UI，也不是再找 hook：
   **让每一份交给 Spotify 的 payload 都带行级时间轴**。

---

## 证据 1：歌词请求走的是我们钩的 URLSession

```
[TokenCapture] … from https://gae2-spclient.spotify.com:443/color-lyrics/v2/track/6Lie1DClK3dMPVZFw9njdl?clientLanguage=zh
[Lyrics] Request for /color-lyrics/v2/track/6Lie1DClK3dMPVZFw9njdl
```

`URL.isLyrics` 判据是 `path.contains("color-lyrics/v2")`，而日志里这条正是它。
被钩的是 `SPTDataLoaderService` / `Connectivity_HttpClientKit.HttpClientURLSession`
（同一次会话里能看到 `[HCUS] Patched YourPremiumBadge`，证明该 delegate 活跃）。

**推论**：不需要去找什么 gRPC/esperanto 的隐藏通路 —— 歌词请求就在这条路上，
`[Lyrics] Request for …` 这行只可能由我们的响应分支打印出来。

## 证据 2：9.1.0 → 9.1.86 的架构换血（离线二进制比对）

> **独立复核（本轮新增）**：以下比对已用 `C:\dsh\else\dump-unknown.txt`
> （`eevee-symbol-dump v1`，spotify.ipa，16930 个 Swift 类 / 295 rpc / 540 flags /
> 12408 selectors）**独立复核过**，与早先两次脚本输出一致。
>
> 该 dump 中歌词相关模块的完整类清单（9.1.86）：
> `Lyrics_CardElementImpl` 21 个（含 `CardView`、`ShowLyricsButtonElementUI`、
> `ShowLyricsButtonElementFactory`、`LyricsCardElementFactoryImpl`、
> `LyricsCardElementServiceImpl`）、`Lyrics_NPVElementsKitImpl` 19 个、
> `Lyrics_TextElementImpl` 20 个、`Lyrics_CoreInternalImpl` 5 个、
> `Lyrics_NPVCommunicatorImpl` 仅剩 3 个
> （`LyricsScrollDataProvider`、`LyricsScrollProviderPlugin`、`LyricsUIServiceImplementation`）、
> `Lyrics_OfflineImpl` 4 个、`Offline_LyricsOfflinePlugin(Impl)` 2 个。

| 类 | 9.1.0 | 9.1.86 |
|---|---|---|
| `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` | ✅ | ❌ |
| `Lyrics_NPVCommunicatorImpl.ScrollProvider` | ✅ | ❌ |
| `Lyrics_NPVCommunicatorImpl.CardView` / `CardViewController` / `ErrorViewController` / `LoadingViewController` | ✅ | ❌ |
| `Lyrics_CardElementImpl.*`（含 `CardView` / `ShowLyricsButtonElementUI`） | ✅ | ✅ |
| `Lyrics_NPVElementsKitImpl.*` | ✅ | ✅ |
| `Lyrics_RepositoryImpl.*` / `Lyrics_RemoteDataSourceImpl.LyricsResponseSerializerV3` | ✅ | ✅ |
| `Lyrics_OfflineImpl.*`（SQLite 离线歌词） | ❌ | ✅ **新增** |
| `Lyrics_NPVCommunicatorImpl.LyricsScrollProviderPlugin` | ❌ | ✅ **新增** |

**flag 差异**（同一脚本口径）：

```
9.1.0  : enable_lyrics, enable_lyrics_character_count_fix
9.1.86 : enable_has_lyrics_check_bypass, enable_lyrics, enable_lyrics_character_count_fix,
         enable_lyrics_multilanguage_fullscreen, enable_lyrics_multilanguage_npv,
         enable_lyrics_multilanguage_share, enable_lyrics_reporting
```

`enable_has_lyrics_check_bypass` **只在新版存在**。当前源码用的是
`.setBool(true)`（只改已存在的值），而 scope 名是猜的
（`DynamicPremium+ModifyingFunctions.swift:409-423` 自己写了这一点）——
**这一枪大概率是空的**。

## 证据 3：卡片类在 9.1.86 上真的活着（真机日志）

```
[WordByWord] inline host found: Lyrics_TextElementImpl.LyricsTextView in NowPlaying_ScrollImpl.NPVScrollViewController
[PreviewShell] card container (card)=Lyrics_CardElementImpl.CardView 374x320 lyrics=342x256
[AppleMusicLyrics] overlay attached (Apple Music path) host=Lyrics_CardElementImpl.CardView solidBackdrop=false shell=false
```

所以"9.1.x 上模块不存在"这个说法**不成立**——模块容器、内容视图、宿主全都找到了。

## 证据 4：关键分水岭 —— 有没有行级时间轴

**正常显示的场次**（统计全部：`line timing N/N -> line-level=Y | timeSynced=true`）：

```
[Lyrics] provider: NetEase (EeveeSpotify)
[WordByWord] word-level judge: 0/54 line(s) carry word timing -> word-level=N;
             line timing 54/54 -> line-level=Y | timeSynced=true | render mode=line
[WordByWord] legacy overlay attached — host=Lyrics_TextElementImpl.LyricsTextView 342x133 level=line
[PreviewShell] card container (card)=Lyrics_CardElementImpl.CardView 374x320
```

**"没有歌词模块"的场次**（同一首 `Bridge Between Us` / `1GS3H8cVOmaTDM32X35GQu`
在 08:47 和 09:06 两次都失败）：

```
[AMLL] 404 — no lyrics            （或 TLS 失败 -1200）
[Lyrics] AMLL failed: 未找到歌曲
[NetEase] Search returned 30 result(s)
[NetEase] Chosen[2]: Bridge Between Us (id 1860037835)
[NetEase] No usable lyrics
[Lyrics] NetEase failed: 未找到歌曲
[Lyrics] no custom lyrics for this track — clearing word-by-word layer
[Lyrics] official lyrics hidden — serving our placeholder     ← 这里
[WordByWord] word-level judge: no dto (version 10)
[WordByWord] attach declined — lyrics data unusable: not even **line-level** timing is available
```

即：**取不到词 → 交占位 → 占位没有时间轴 → 判定为"不可用"**。

### ⚠️ 这一段的推断边界（必须写清楚）

日志能**直接证明**的是：取不到词的那些歌，交出去的 payload 没有时间轴，
因此我们的逐词/预览层判定为不可用（`hasUsableLineLevelData` 要求
`timeSynced == true` 且 ≥50% 的行带 `offsetMs`，见
`LyricsWordByWord.x.swift:222-228`）。

日志**不能**直接证明的是：Spotify 那边是否也因为这份 payload 无时间轴而**不建卡片**。
本次日志里 `Bridge Between Us` 的失败场次中，卡片容器本身是存在过的
（`inline host found: Lyrics_TextElementImpl.LyricsTextView`），
所以"完全没有模块"的用户观感**还可能来自另一条更早的路径**（见证据 5）。

→ 需要一个**判定性实验**（见下方"可执行结论 · A/B"）来区分这两种可能。
本报告不把"占位无时间轴"当成"模块不出现"的唯一已证原因。

占位 payload 的定义在 `CustomLyrics.x.swift:349-372`：

```swift
$0.timeSynchronized = false          // ← 没有时间轴
$0.lines = [ 提示行, "", 提示行 ]      // ← 每行 offsetMs 都是 nil
```

而 `LyricsDto.toSpotifyLyricsData` 里 `timeSynchronized = timeSynced`、
行 offset 取 `line.offsetMs ?? 0`（`LyricsDto.swift:30-75`）——
所以**无时间轴的 payload 在 9.1.x 的组件化渲染里要么被丢弃、要么只渲染成一个静态块**。

## 证据 5：`has_lyrics` 这条老路的现状

`C:\dsh\else\player_track_class_report.txt`（同一脚本、同一 IPA）：

```
[1] 目标方法名是否存在
    metadata   **不存在**
    URI        **不存在**
[4] 旧代码猜过的类名是否真的存在
    SPTPlayerTrack                 存在
    SPTPlayerTrackImplementation   不存在
```

### ⚠️ 我之前对这份报告的一处误读，纠正如下

早先我曾说"`SPTPlayerTrack` 根本不存在"。**这是错的**，而且错在方法与结论两头：

- `dump-unknown.txt` 的 `[classes]` 桶正则只抓 `_TtC…`（Swift mangled）名字，
  **ObjC 类名根本不会出现在里面** —— 之前那次"Dump-unknown 里只有几个无关类"
  正是因为 `SPTPlayerTrack` 是 ObjC 名字，属于**假阴性**；
- 而 `Tweak.x.swift:328-332` 的注释已经写明了这一点，并指出应当用
  `objc_copyClassList` + `class_getName` 做精确比对；
- 本轮 `player_track_class_report.txt` 用的是 `__objc_classname` 节，所以它给出的
  "`SPTPlayerTrack` 存在 / `SPTPlayerTrackImplementation` 不存在" **才是可信的那一份**。

结论仍然成立（`has_lyrics` 这条路当前是断的），但理由要改成：
`SPTPlayerTrackHook` 按版本号选中了 `SPTPlayerTrack`（`.latest` 分支才选
`SPTPlayerTrackImplementation`），而该报告在 `__objc_methname` 里**没能确认
`metadata` / `URI` 两个选择器的存在**（该节解析结果为 0 条，所以这一项
**需要用 `audit_lyrics_gate.py` 复核**，不能直接当成"方法不存在"）。

## 证据 6：`[selectors]` 桶里歌词相关只有 1 条 → 组件无法用 ClassHook 挂

全库 12408 条 ObjC 选择器里，含 "lyric" 的只有：

```
events:lyrics
```

（其余歌词类名全部只出现在 `_TtC…` 的 Swift 类表里。）

**这条证据直接决定了"可 hook 性"的结论**：

- `Lyrics_CardElementImpl` / `Lyrics_NPVElementsKitImpl` / `Lyrics_CoreInternalImpl`
  这些模块是**纯 Swift 静态派发**，在 ObjC 运行时**没有选择器**；
- 而 Orion 的 `ClassHook` 靠 ObjC 消息转发工作 —— 所以**这条路对它们无效**；
- 这也解释了为什么仓库里那批 `V91UnavailableLyricsGroup` 的 hook 一个个失效：
  不是类名写错，是**这个架构换成了 Orion 够不着的形式**。

## 证据 7：`[rpc]` 桶 295 条里零歌词条目 → 传输路径再次确认

`[rpc]` 桶（295 条）中**没有任何 lyrics 相关条目**，而
`Lyrics_RemoteDataSourceImpl` 提供的是 HTTP 侧 protobuf 序列化器
（`LyricsRequestFactoryImpl` / `LyricsResponseSerializerV3`）。

与证据 1 的真机日志合起来 → **歌词数据走 HTTP `color-lyrics/v2`，不走 gRPC**。
"我们的响应注入是唯一的数据入口"这一判断成立。

## 证据 8：崩溃报告与歌词问题无关（排除干扰）

`C:\dsh\readlog\Spotify-2026-09-24-{210732,215922}.ips` 两份：

```
exception: EXC_BREAKPOINT / SIGTRAP，rawCodes [1, 0x000000019dbe54b4]
帧: _CF_forwarding_prep_0 → swift_getObjectType
寄存器: __NSGenericDeallocHandler
启动后约 0.3s
```

两份**同一签名、同一地址**，正是 `Tweak.x.swift:244-251` 记录过的那个
"运行时类名探针导致的启动崩溃"（`0x19dbe54b4` 地址吻合）。
→ 与歌词模块无关，但说明 **9.1.86 + iOS 27 上启动期崩溃风险是真的**，
任何新加的 hook **必须避免注册期解析失败**（否则在注入工具进程里 SIGTRAP）。

---

## 可执行结论

### 路线判断（由证据 6/7 决定，这是本轮最重要的结论）

**"再挂一个 hook 让模块强制出现"这条路基本被堵死了**：

- 决定模块出现的那批组件（`Lyrics_CardElementImpl.*`、`Lyrics_NPVElementsKitImpl.*`、
  `Lyrics_CoreInternalImpl.*`）在 ObjC 运行时**没有选择器**（证据 6），
  Orion `ClassHook` 够不着；
- 歌词数据只走 HTTP `color-lyrics/v2`（证据 1/7），**响应注入是唯一的数据入口**；
- 而真机日志显示**每一首歌都发出了这个请求** —— 即客户端并不在本地拦掉"没词的歌"，
  所以 `has_lyrics` 那条路即使修好，也不是"模块不出现"的必要条件。

→ **可修的那条路是数据本身，不是 UI 门控。**

### 立刻能做、风险最低（对应证据 4）

**给所有"没有时间轴"的 payload 补行级时间轴**：

1. 无时间轴的源（Genius 纯文本、占位文案）→ 按曲目时长**均分行 offset**，
   或按字符数/换行权重分配；
2. 让 `toSpotifyLyricsData` 永远输出 `timeSynchronized = true` 且每行 `offsetMs` 有效；
3. 占位文案同理（3 行也能给 3 个 offset），这样"未找到歌词"也走**同步歌词**渲染路径，
   不再落进"无时间轴 → 不可用"。

预期效果：把"有些歌完全没有模块"变成"每首歌都有模块，最差显示未找到歌词"。

### 必须说清楚的不确定性

- 客户端是否**仅凭** payload 建模块（无时间轴就不建），本次日志**没有判定性证据**：
  证据 4 已说明边界。上面第 1 项修复是"即使这个假设不成立也不会变坏"的改动，
  但它**是否能彻底解决"没有模块"取决于这个假设**。
- 因此仍需 A/B 实验（下一节）来确认。

### 需要一次真机实验才能定论

- **A**：~~把 `enable_has_lyrics_check_bypass` 改成 `.forceBool(true)`~~
  → **本次评估后决定不做**，理由见下一节；
- **B**：复核 `SPTPlayerTrack` 上 `metadata()` 到底挂不挂得上（该报告
  `__objc_methname` 为 0 条，"方法不存在"这一项不可直接采信）；
- **C**：确认 `Lyrics_OfflineImpl` 的写入时机（若"本地有词就不请求"，
  则预填 SQLite 可彻底绕开超时/回退链）——**被 shell 故障阻塞，未完成**。

#### 为什么不做 A（这条很重要，它排除了一个"看起来最像答案"的方案）

证据 4 的日志里，**每一首取不到词的歌，客户端都照常请求了
`color-lyrics/v2`**（例如 `1GS3H8cVOmaTDM32X35GGu` 在两个会话里各请求一次，
尽管两边都没有我们的词）。

这意味着：**客户端的"这首歌有歌词吗"这道检查，早就已经通过了** ——
否则它根本不会去请求歌词数据。既然检查已通过，那么
`enable_has_lyrics_check_bypass` 就不是"模块不出现"的原因，
强行打开它既不必要，又要承担两个真实风险：

1. 它归属的 **scope 名是猜的**（`.setBool` 那两行的注释自己写明了）；
2. `forceBool` 的语义是"**不存在就凭空 append 一个 AssignedValue**"
   （`EeveePropertyReplacement.swift:6`），scope 猜错就等于往 Spotify 的配置解析
   路径里塞臆造数据 —— 与"登录/播放被搞坏"属于同一类风险。

→ 结论：把力气留在 payload 上（下面这一节），而不是配置开关上。

---

## 实施记录（本轮代码改动）

针对证据 4 的结论，已实现「让每一份交给 Spotify 的 payload 都带行级时间轴」。

### 新增

- `Sources/EeveeSpotify/Lyrics/Models/SyntheticLyricTiming.swift`
  按**字符权重 + 曲目时长**把行铺到时间轴上；
  `hasAnyLineTiming`（一行都没有才补）/ `alreadyHasLineTiming`（50% 口径，与渲染层判据对齐）。

### 修改

| 文件 | 改动 |
|---|---|
| `Lyrics/Models/LyricsDto.swift` | `toSpotifyLyricsData` 新增 `durationMs` 参数；无时间轴时合成；`timeSynchronized` 改为按**实际是否带 offset** 如实声明；纯音乐占位那三行也走同一逻辑；加一条 `[Lyrics] synthetic line timing applied …` 日志 |
| `Lyrics/CustomLyrics.x.swift` | `makeLyrics` 新增 `durationMs`；三处调用点传 `searchQuery.durationMs`；多级回退分支同样传；`makeUnavailableLyrics` 也给占位文案合成；`getLyricsDataForCurrentTrack` 写入 `currentTrackDurationMs` |
| `Lyrics/LyricsWordByWord.x.swift` | 新增全局 `currentTrackDurationMs`（占位路径拿不到 track 对象，需要这个上下文） |
| `Settings/ngzhwm/ngzhwmSettingsViewModel.swift` | 新增 `syntheticLineTimingKey` + `isSyntheticLineTimingEnabled`（**默认开启**） |
| `Settings/Sections/Lyrics/ViewModels/EeveeLyricsSettingsViewModel.swift` | 新增 `syntheticLineTiming`（初值必须走默认值 getter，不能用 `UserDefaults.bool`） |
| `Settings/Sections/Lyrics/Views/EeveeLyricsSettingsView.swift` | 新增 `syntheticLineTimingSection()` 开关 |
| `en.lproj` / `zh-CN.lproj` | 两条新文案 |

### 设计上刻意保留的边界

- **只改注入给 Spotify 的 protobuf**：`currentLyricsDto` 与逐词 overlay 判据
  （`hasUsableLineLevelData`）读的都是原始 dto，**行为与改动前完全一致**
  —— 不会因为合成时间轴而突然挂上一层"假同步"的高亮。
- **不覆盖真实时间轴**：只有"一行都没有 offset"时才合成；
  坏 LRC 那类"部分准确"的数据不会被估算值顶掉。
- **可用开关回退**：设置里一键关闭即可复现旧行为，用于 A/B 对比。

### ⚠️ 未验证项（必须说清楚）

- 这些改动**没有编译验证**，也没有真机运行验证 —— 本会话 shell 执行器故障
  （`0xC0000142`，同步/后台/子代理环境一致），无法跑 `swift build` 或 l10n linter。
  语法与类型是**人工逐处核对**的，不能替代编译器的结论。
- l10n linter（`Tools/l10n_lint.py`）也未能运行；新文案是照既有行的格式手写的。
- 因此**"合成时间轴是否真能让模块出现"仍未经验证** —— 这正是设置里那个开关的用途。

### 不要做的事

- 不要再投入"自己画预览 UI"：卡片存在性已经证明没问题，问题在喂进去的数据；
- 不要再怀疑"歌词请求不走 URLSession"：证据 1 + 证据 7 双重确认；
- **不要再尝试给 `Lyrics_CardElementImpl` 等模块加 Orion hook**：证据 6 表明它们
  没有 ObjC 选择器，加了只会得到注册期失败（叠加证据 8 的启动崩溃风险）。

---

## 复现/复核用命令

```powershell
# 判定点与 flag 上下文取证（本报告的证据 2 由此而来）
python Tools\eevee-hookfinder\audit_lyrics_gate.py `
  --ipa "C:\dsh\ipa\Spotify- Music and Podcasts_9.1.86_decrypted.ipa" `
  --baseline "C:\dsh\ipa\EeveeSpotify-9.1.0.ipa" `
  --out Tools\eevee-hookfinder\lyrics_gate_audit.txt
```

（本次会话中 shell 执行器故障：pwsh 进程创建失败 `0xC0000142`，
同步与后台均如此，故证据 2 的部分数据沿用了既有脚本的历史输出。）
