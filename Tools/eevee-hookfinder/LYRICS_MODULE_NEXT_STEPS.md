# 歌词模块：卡片由 payload 驱动；`timeSynchronized` 决定走哪个面

**数据**：`C:\dsh\readlog\eeveespotify_debug{ 2 (2), 3 … 13}.log` + 两份 `.ips`（2026-09-24/25）

---

## 0. 结论（先看这里）

**Spotify 有两个互斥的歌词展示面，由 payload 的 `timeSynchronized` 决定走哪个。**

| 注入的 payload | 面 A：单行歌词 | 面 B：歌词卡片（**目标**） |
|---|---|---|
| `timeSynchronized = true` | ✅ | ❌ |
| `timeSynchronized = false` | ❌ | ✅（显示我们的文案） |

- 面 A = 封面与歌名**之间**那**一行**（`Lyrics_TextComponentImpl.LyricsView`）
- 面 B = 与**「关于艺人」并列**的「歌词」卡片（`Lyrics_CardElementImpl.CardView`，歌词区 342x256）

**卡片是被我们注入的 payload 驱动的。** 卡片底部显示的 provider 是 **`EeveeForce…`**
—— 那是排障实验里我们自己写死的名字。**Spotify 侧"这首歌有没有词"根本不是门控。**

→ 因此以下全部排除：`has_lyrics` 元数据、`enable_has_lyrics_check_bypass`、
服务端判定、本地离线歌词库、`SPTPlayerTrackHook` 覆写。

**⚠️ 推论（重要）**：「合成行级时间轴」这个**默认开启**的开关把 payload 标成
`timeSynchronized = true`，**这正是把卡片挤掉的东西** —— 它修好了面 A，代价是面 B。

---

## 1. 排障实验（日志 12/13）与它的结论

日志 12 是日志 13 的中途导出（同一次会话）。模式中途切换：
`19:50:31–19:57:54` = placeholder，`19:58:17` 之后 = good。

| 模式 | payload | 面 A | 面 B | 我们的 overlay |
|---|---|---|---|---|
| `placeholder` | 3 行、`timeSynchronized=false` | ❌ | ✅ 显示"纯音乐" + provider `EeveeForce…` | 拒绝挂载（无行级时间轴） |
| `good` | 34 行、真实时间轴 | ✅ | ❌ | **挂错到面 A 上**（3 行盖在封面下缘） |

- 用户肉眼 + 日志一致：`placeholder` 下**卡片确实出现**（多条
  `inline host found: Lyrics_TextElementImpl.LyricsTextView … 342x256`，342x256 正是卡片歌词区尺寸）。
- 照片 `C:\dsh\else\photo_2026-09-25_04-15-09.jpg` 是 `good` 模式：封面下缘被我们 overlay
  画了 3 行 SECRET 的歌词，而底部「关于艺人」之上**没有卡片**。
- **卡片上的 provider 是 `EeveeForce…`** → 卡片渲染的是我们的数据。

### 顺带排除掉的旧假设

| 曾经的假设 | 现状 |
|---|---|
| 面 B 由 `metadata()["has_lyrics"]` 门控 | ❌ 覆写实测生效（返回 true）而卡片仍不出 |
| 面 B 由服务端/本地状态门控 | ❌ 卡片 provider 是我们自己的名字 |
| `has_lyrics` 搭 HTTP 来，可在响应里改 | ❌ 探针扫遍 27 个端点，零命中 |
| 延迟是模块不出现的（唯一）主因 | ❌ 关掉 AMLL 后延迟正常，卡片依旧不出 |

---

## 2. 当前拦路虎：稳定复现的启动崩溃（未解决）

两份 `.ips` 的异常码**同一地址**，即同一个 bug：

```
043507: {"codes":"0x0000000000000001, 0x000000019f2f6f54"}  faultingThread 37
044330: {"codes":"0x0000000000000001, 0x000000019f2f6f54"}  faultingThread 46
```

栈形状（043507）：

```
faulting queue = com.apple.root.user-initiated-qos
libswiftCore : _assertionFailure → swift_unexpectedError
EeveeSpotify.dylib : 4 帧（**未符号化**）
libdispatch  : _dispatch_call_block_and_release …
```

⇒ **我们 dylib 里某个 `try!` 在全局 userInitiated 队列的 block 上抛了错。**
（注意：这和之前记录在案的"运行时探针"崩溃**不是同一个** —— 那次在 `0x19dbe54b4`、
约 291ms、`_CF_forwarding_prep_0`。）

**待做**：取那 4 帧的 `imageOffset`（`imageIndex == 3`），才能定位函数。
`DynamicPremium+ModifyingFunctions.swift:22` 的
`try! BundleHelper.shared.resolveConfiguration()` 是形状最吻合的候选
（启动后台路径 + 可抛），但**无证据**。

---

## 3. 下一步

1. **先解崩溃** —— 否则真机测试全部停摆。
   - 已回退"强制 payload"开关（见第 5 节）：它是崩溃出现的时间点，先排除。
   - 若回退后仍崩 → 查 `try!` 候选，或做符号化。
2. **崩溃解决后，验证第 0 节那条推论**（这是全篇最关键的一次测试）：
   - 同一首歌（建议 `5utfun3R35e5AsBalPSxBe` 最後の希望），把
     **「合成行级时间轴」关掉** → 卡片是否回来？
   - 若回来 ⇒ 该开关的默认值应改为**关**（或用它只在"没有卡片"时兜底面 A）。
3. **注意两个面的取舍**：目前看"有同步时间轴"与"有卡片"不可兼得。
   若确实互斥，就得决定默认给用户哪一个 —— 而你要的是**卡片**。
4. 面 A 的 overlay 挂错宿主（`good` 模式下盖在封面下缘）是**另一个独立缺陷**，
   已在照片里可见，等崩溃解决后单独处理。

---

## 4. 日志清单（务必按版本区分）

| 日志 | Spotify | 条件 | 结论 |
|---|---|---|---|
| 1 / 2 | 9.1.86 | AMLL 优先开 | 14 秒阻塞（`api.amll.dev` TLS 重试 11 秒） |
| 3 | 9.1.86 | AMLL 关，旧构建 | 三首**有**请求 |
| 4 / 5 | **9.1.6** | 合成开 / 关 | 三首**无**请求 → 门控是 9.1.6 特有 |
| 6 / 7 | 9.1.86 | 合成开 / 关 | **有效 A/B → 面 A 由时间轴驱动**（已证实） |
| 8–11 | 9.1.86 | 合成开 | 覆写生效但卡片不出；`has_lyrics` 不在 HTTP 里 |
| **12 / 13** | 9.1.86 | 强制 payload 开/关 | **卡片由 payload 驱动；两面互斥** |

> ⚠️ 日志 3 vs 4/5 **不是**有效 A/B（版本不同）。版本由 `build-ipa-with-orion.yml`
> 的 `ipa_url` 输入决定，工作流**不下载也不校验**；建议加 `expected_spot_version` 断言。

---

## 5. 本轮代码状态

**已回退**（因稳定启动崩溃）：`forcedLyricsPayload` 开关 + 设置界面 Picker +
`CustomLyrics.x.swift` 的短路 + `forcedGoodLines` / `forcedGoodDto()`。
三处都留了说明性注释，**结论保留在注释里**，避免回退把认知一起丢掉。

**仍保留的诊断**：

| 位置 | 说明 |
|---|---|
| `Tweak.x.swift` 的 `[INIT] SPTPlayerTrack: metadata=… URI=…` | 启动期一条，信息量大，建议保留 |
| `SpotifyResponsePatcher.probeHasLyricsKey`（两个 `didReceiveData` 各一处） | **可以删了** —— 已给出确定答案（不在 HTTP 里）；它每次会刷 27 条 `seen path` |
| `LyricsBackdropArtworkView` 的一次性 keys dump | 原样，可留 |

**其它已移除**：运行时类名探针（前两条是致命编译错误：重复 `struct EeveeSpotify`、
引用已不存在的 `trackProbeNamePrefixes`）；`[TrackHook]` 逐次打印（热路径 + 无锁全局）。

**两次括号事故**（均修复）：删探针 Toggle 时多删 `Section` 闭括号；删调用点时多删一个 `}`。
**在没有编译器的会话里改括号密集区域必须逐处复核** —— `edit` 只做字面替换，不校验结构。

> ⚠️ 多轮改动**从未编译验证**（会话内 shell 执行器故障 `0xC0000142`）。每次都靠 CI/本地构建裁决。

---

## 6. 本轮（2026-09-25 白天）：只补判据，不改任何行为

起因是一个待验证的说法：**"9186 上歌词模块出不出现是服务器说了算，不像 910 是本地"**。
现有取证不支持它（§0/§1：卡片由我们注入的 payload 驱动），但**三条证据都不够硬**，
所以本轮只做"把判据补齐"，不动 payload / 不动默认值。

### 6.1 `[Flags]` —— 把"猜的 scope"换成真实 scope（`DynamicPremium+ModifyingFunctions.swift`）

新增 `dumpLyricsFlags()` / `reportLyricsReplacementOutcome()`，在 `modifyAssignedValues`
**改写之前**打印服务器下发的所有含 `lyric` 的 `assignedValues`，并在改写之后打印每条
歌词替换**命中了几条**。形如：

```
[Flags] lyrics flag — scope=<真实 scope> name=enable_lyrics bool=true
[Flags] replacement ios-feature-lyrics.enable_has_lyrics_check_bypass — 0 match(es)
```

两件事一次解决：

1. `setBool` 只在 `name + scope` **都命中**时才生效，命中 0 条是**静默**的 ——
   这一行把"scope 猜错了"从"服务端就是这么下发的"里分开（`0 match(es)` 即是空枪）；
2. **"服务端 flag 是不是闸"的唯一直接判据**：真是闸的话，那条 flag 必然出现在这份
   清单里。清单里没有 → 服务端侧不存在这样一道闸（比日志 12/13 的间接推论硬）。

### 6.2 `[INIT] synthetic line timing: ON/OFF` —— A/B 的分组标记（`Tweak.x.swift`）

以前只能从"有没有 `synthetic line timing applied`"反推开关状态，而**关掉的那一组
恰恰不会打那行** —— 两组日志长得一样，A/B 等于没分组。现在启动即打印这一行
（顺带记下 `official lyrics hidden` / `lyrics feature disabled`，两者同样影响 payload）。

### 6.3 `[ScrollProbe] … hex…` —— 修正 `no needle` 的证据等级（`SpotifyResponsePatcher.swift`）

`no needle`（在 scrollsita 响应里扫不到 `yric`）**不能**当作"服务器没下发歌词元素"：
scrollsita 是 protobuf，元素类型极可能是**枚举整数**，字符串永远不会出现。
现在额外把响应体前 512 字节按 hex 打出来（每 path 最多 3 次、只在体积变大时），
让"两条响应差在哪个字段"可以离线比对。

### 6.4 仍然悬着的事（顺序不能反）

1. **A/B 还没跑**（§3.2）：同曲 `5utfun3R35e5AsBalPSxBe`，设置里关掉「合成行级时间轴」。
   - 卡片**回来** ⇒ §0 那条推论成立：该开关默认值应改为**关**（要的是卡片），
     或改成"只在没有卡片时补时间轴兜底面 A"；
   - 卡片**不回来** ⇒ payload 面这条解释不成立，回到"服务器元素列表"那条线
     （用 6.3 的 hex 比对），再不行才谈自绘。
2. **默认值暂不翻**：没有真机 A/B 之前翻默认值只是换个方向瞎猜，而且会把面 A
   （封面下单行）一起改掉。
3. **启动崩溃**（两份 `.ips` 同一地址）仍是真机验证的前置条件。

### 6.5 本轮验证状态（说清楚）

- **没有编译验证**：本会话 shell 执行器再次故障（`pwsh` 一律 `0xC0000142`），
  连括号配平检查都跑不了。三处改动是**人工逐处复核**的：
  改动均为"新增函数 + 新增日志行"，唯一的控制流改动是 `modifyAssignedValues`
  的头部多一次 `dumpLyricsFlags(values)`、尾部多一次 `reportLyricsReplacementOutcome(values)`；
- 因此**必须由 CI/本地构建裁决**，且这三条日志要真机各跑一次才有结论。

---

## 7. 真机回报（2026-09-25 07:46–07:48，日志 18 + 照片 07:49）

**构建已验证**：日志 18 里 §6.1/6.2/6.3 三条新日志全部出现 → 这一次的改动编译并运行通过
（`EnumValue` 那处笔误已修；`[Flags] replacement … — N match(es)`、`[ScrollProbe] … hex…B=` 都打出来了）。

### 7.1 A/B 跑了一半：ON 组有结论，OFF 组只差一张截图

| 组 | 时间 | 日志证据 | 视觉结果 |
|---|---|---|---|
| ON | 07:46:22 启动（`synthetic line timing: ON`） | `synthetic line timing applied — 7 line(s)` → `timeSynchronized=true` | 照片：封面下**单行**歌词、「关于艺人」上方**没有**歌词卡片 |
| OFF | 07:48:20 启动（`synthetic line timing: OFF`） | NetEase `Unsynced lyrics fallback (7 line(s))`，**没有**补时间轴 → `timeSynchronized=false`（**卡片合格 payload**） | **没有截图 → 未知** |

→ OFF 组是本次 A/B 的**唯一缺口**：payload 确实按预期变成了"无时间轴"，但没人看那一刻的界面。

### 7.2 `[Flags]` 首批结果：真实 scope 拿到了，"空枪"也坐实了

```
[Flags] lyrics flag — scope=ios-feature-lyrics name=enable_lyrics bool=true
[Flags] replacement ios-feature-lyrics.enable_has_lyrics_check_bypass — 0 match(es)
[Flags] replacement *.enable_has_lyrics_check_bypass — 0 match(es)
```

- `ios-feature-lyrics` **就是真 scope** ✔（`enable_lyrics` 1 match，`setBool` 生效）；
- **`enable_has_lyrics_check_bypass` 服务器根本没下发**（两个 scope 都试了）→ 从 9.1.86 的 flag **表**
  里读到名字 ≠ 服务端会赋值。这一枪是空的（FINDINGS 证据 2 的预判成立），而且**服务端不存在
  "这首歌有没有词"这道闸** —— 到此，"服务端说了算"的最后一个变体也排除了。

服务端实际下发的歌词 flag 全清单（日志 18 行 35–48），其中**唯一的 `false`**：

```
ios-feature-lyrics                          lyrics_entry_point_enabled            = false   ← 首选嫌疑
ios-feature-lyrics                          enable_lyrics                         = true
ios-feature-lyrics                          is_get_lyrics_v2_enabled              = true
ios-feature-lyrics                          lyrics_offline_enabled                = true
ios-feature-lyrics                          is_lyrics_cache_v2_enabled            = true
ios-feature-lyrics                          lyrics_context_menu_toggle_enabled    = true
ios-feature-lyrics                          enable_lyrics_character_count_fix     = true
ios-nowplaying-contentlayers-impl           lyrics_under_cover_art_enabled        = true   ← 名字＝照片里那行
ios-nowplaying-contentlayers-impl           is_lyrics_cover_art_refactor_enabled  = true
ios-feature-canvas                          lyrics_on_canvas_enabled              = true
ios-zephyr                                  sync_lyrics_enabled                   = true
ios-campfire-properties-impl                chat_lyrics_sticker_request_enabled   = true
ios-campfire-chatcontentpickerpage-impl     entity_type_lyrics_stickers_enabled   = true
ios-campfire-properties-impl                lyrics_sticker_suggestions_enabled    = true
```

两个候选的解释力最强：

1. `lyrics_entry_point_enabled = false` —— "歌词**入口**"正是与「关于艺人」并列的
   **歌词卡片**（点进去才是全屏歌词）；服务端把它关了。**它是唯一 false，且 scope 已知**，
   所以这一枪现在是"把已存在的值钉成 true"，不是臆造数据。
2. `lyrics_under_cover_art_enabled = true` —— 名字与照片里那行"封面下歌词"逐字对应；
   若卡片与它互斥，把它关掉可能换回卡片（代价是失去面 A）。

### 7.3 scrollsita 解码：**先判死，又翻案（同一份数据，两次结论）**

**第一版结论（错，作废）**：我拿 ON 组与 OFF 组的同一首 hex **逐字节相同**，就写下"服务端没有随
payload 切换任何东西 ⇒ 服务器决定卡片这条假设可以判死"。
**错在哪**：ON/OFF 是**同一首**曲目，它只能证明"服务端不随**我们的 payload** 变"，**不能**证明
"服务端不按**曲目**下发不同元素"。该比的是**有词曲目 vs 没词曲目** —— 也就是 FINDINGS 里
那个探针最初的设计初衷。

**按正确口径重解（日志 18 三条 hex 全部解码，均为同一套 wire format）**：

| 曲目 | color-lyrics | 元素列表（内层字段号 → 内容） |
|---|---|---|
| `7dUKNjRiLxS2OXRldCIjH4`（SECRET） | **200** | **5**（只含 `spotify:track:…`，section `…Gq21`）, 2（关于艺人）, 3（探索 MIMI）, 4（canvas + 2 artist） |
| `5utfun3R35e5AsBalPSxBe`（最後の希望） | 404 | 2（关于艺人）, 3（探索 CYPARISS）, 4（canvas + 2 artist） |
| `1MbA2hu0f2NCnO114X1BP6` | 404 | 2（关于艺人）, 3（探索 CYPARISS）, 4（canvas + 3 artist） |

- 那个 `5` **只引用曲目 URI**（不引用艺人），并且**只在 Spotify 有官方歌词的曲目上存在**（3/3 吻合）；
- 每个元素尾部都带自己的 `f23` = section URI，而 section 是**按元素类型固定**的
  （`…Gq1L`=关于艺人、`…DABRtFWApcy61XJEwt`=探索、`…Gq1O`=canvas、`…Gq21`=这一项）；
- `f2` = scroll id（UUID），只有它随会话变化。

由此得到一个能解释**全部**观测的模型：

```
歌词卡片可见    ⟺  元素列表里有 5（服务端认为"这首歌我库里有词"）  AND  payload 无时间轴
封面下单行可见  ⟺  payload 有时间轴（与元素列表无关）
```

逐条对上：

- **03:50**（日志 12/13）：SECRET（有 `5`）+ 强制 placeholder（无时间轴）→ **卡片出现**，
  且卡片上 provider 是我们自己写死的 `EeveeForce…` ⇒ 卡片**内容**来自我们替换的
  color-lyrics，卡片**位置/存在性**来自这份元素列表；
- **今天 OFF 组**（07:48，最後の希望，无 `5` + 无时间轴）→ **什么都没有**（用户实测）；
- **今天 ON 组**（07:46，最後の希望，无 `5` + 有时间轴）→ 只有封面下单行。

⇒ 910 那种"每首歌都有歌词卡片"在 9.1.86 上缺的正是**服务端那一项元素**，而这个响应在我们手上
（HTTP 侧、`shouldModify` 能拦到），所以**可以补**。

### 7.4 下一步

1. ~~补 OFF 组截图~~ → **已由用户实测回答**：关掉「合成行级时间轴」后，单行歌词和卡片**都没有**。
   这直接推翻 §0 的"两面互斥"推论（无时间轴 ≠ 卡片），并催生了上面的模型；
2. 见 §8：把模型做成两个可验证的开关，先关后开跑对照。

---

## 8. 本轮改动（2026-09-25 白天第二轮）：把假设做成可验证的开关

### 8.1 代码

| 文件 | 改动 |
|---|---|
| `Premium/Helpers/ScrollsitaLyricsElementInjector.swift` | **新增**：byte 级往 `scrollsita/v1/scroll/spotify:track:<id>` 的响应里补一个与 SECRET **完全同形**的 `5` 元素 |
| `Premium/Helpers/SpotifyResponsePatcher.swift` | `shouldModify` / `patch` 各加一个分支（**开关关着时零开销，连缓冲都不做**）；新增 `PatchTag.lyricsCardElement` |
| `Settings/ngzhwm/ngzhwmSettingsViewModel.swift` | 新 key `ngzhwm_injectLyricsCardElement` + `isLyricsCardElementInjectionEnabled`（**默认 false**） |
| `Settings/Sections/Lyrics/ViewModels/EeveeLyricsSettingsViewModel.swift` | `@Published injectLyricsCardElement`（初值走默认值 getter） |
| `Settings/Sections/Lyrics/Views/EeveeLyricsSettingsView.swift` | 新 section `injectLyricsCardElementSection()` |
| `en.lproj` / `zh-CN.lproj` | 两条新文案 |
| `Premium/DynamicPremium+ModifyingFunctions.swift` | 把服务端**唯一为 false** 的歌词 flag `lyrics_entry_point_enabled` 钉成 true（scope 来自实发清单，非猜测） |

注入器的安全边界（很重要：猜着改会毁掉整个正在播放页）——
只在**缺 `5`**时追加；全程按 wire format 解析，任何一步不符合预期 → 返回 nil（**原样放行**）；
组装完重新解析自检一遍，过不了也返回 nil。

### 8.2 验证协议（先关后开，别一次动两个变量）

1. **对照组 A**：开关保持默认（关）+「合成行级时间轴」也关 → 播 `最後の希望`（404 曲目）→ 记结果；
2. **实验组 B**：打开「给没有歌词卡片的曲目补上卡片（实验）」→ **重启 App**（响应/缓存需要新会话）
   → 同样条件再播 → 记结果；
3. 日志里 B 组应出现 `[Scrollsita] injected lyrics-card element …`（A 组没有这一行）。

| A（关） | B（开） | 结论 |
|---|---|---|
| 无卡片 | **有卡片** | 假设成立：卡片位置由服务端元素列表决定，注入有效 → 下一步做成默认行为 |
| 无卡片 | 无卡片 | 注入没效果：要么 `5` 不是歌词卡片，要么客户端还要别的字段 → 下一步逐字段对比 SECRET 与注入后的响应 |
| 有卡片 | 有卡片 | 卡片其实是 `lyrics_entry_point_enabled` 那条 flag 开的，与元素列表无关 → 回退注入器 |

### 8.3 老实说

- 注入器**没有编译验证**（本机无 Swift 工具链），也**没有真机验证**；
- "`5` = 歌词卡片"仍是**推断**（3 个样本 + 一次肉眼观察），不是已证事实；
- 因为写成了"解析不过就原样放行"，最坏情况应当是"没效果"而不是"页面坏掉"——但这一点同样没验证过。

---

## 10. 真机回报第二轮：**注入成功**，剩下的黑块是我们自己的配色（2026-09-25 08:37–08:42，日志 19/20）

### 10.1 结论：假设成立

日志 19/20 里，`[Scrollsita] injected lyrics-card element …` + `[HCUS] Patched LyricsCardElement`
成对出现了 **9 次**（`5utfun…`、`6KXIO2…`、`0Ww7IJ…`、`1V12Ql…`、`20uOWz…`、`0OTlye…`、`3kl96W…`、
`6gxObr…`、`4m1ufw…`），用户确认**本来没有卡片的曲目现在有卡片了**（照片里能看到
「歌词」标题栏 + 分享/展开按钮）。→ **卡片的存在性由服务端元素列表决定，补上那一项就能造出卡片。**

→ 顺带再推翻一条：这次 `synthetic line timing: ON`（payload 有时间轴）**也有卡片**，
所以"有时间轴就不建卡片"同样不成立。**元素列表是唯一的门**，时间轴只影响内容怎么画。
另外「封面下单行」与卡片**可以共存**（照片 1 里 `未找到歌词` 那行和卡片同时在）。

### 10.2 黑块的原因：自造颜色分支 + 清背景 alpha

照片 1 / 2（`Montagem Digital 3`，404 曲目）：
- 卡片**在**，标题栏「歌词」+ 图标正常（白色）；
- 卡片内容区**整块黑**；点开全屏也是**全黑、没有字**。

照片 3（`ヒミツ`=SECRET，200 曲目）：
- 卡片正常：深色半透面板 + 浅色歌词文字，当前行更亮。

日志对照（同一份日志 20）：
```
404 曲目：provider: NetEase (EeveeSpotify)
          [Lyrics] injected background FF5C778C -> 005C778C (transparent)   ← 无 "Using original colors"
200 曲目：[Lyrics] Using original colors
          [Lyrics] injected background FF62787D -> 0062787D (transparent)
```

即：**404 曲目必然走"自造颜色"那一支**（拿不到 Spotify 原始颜色），而那一支原本写死
`lineColor = Color.black` + `activeLineColor = Color.white`
（`CustomLyrics.x.swift` 旧 651–655 行），紧接着又把背景 alpha 清成 0（旧 680–690 行）。
清 alpha 的**前提**是"我们的 overlay 会把模糊封面铺在卡片面板下面"；9.1.86 上 overlay
根本挂不上（日志里 `inline host found` 从未出现）→ 清完 alpha 露出来的是**卡片自己的默认黑底**，
再叠上黑字 = 黑压黑。200 曲目之所以没事，是因为它用的是 Spotify 原始颜色（浅色字）。

### 10.3 修复（`Sources/EeveeSpotify/Lyrics/CustomLyrics.x.swift`）

1. 自造颜色分支：字色按**实际底色的明暗**选（`color.brightness < 0.5` → 深底白字 / 浅底黑字），
   与 `LyricsWordByWord.resolveTextColors` 同一约定，不再写死黑字；
2. 当「自造颜色 **且** 补卡片元素开关打开」时**不清背景 alpha** —— 保留不透明的封面主色底，
   并打一条 `keeping synthesized background opaque %08X` 便于真机核对；
3. **200 曲目（原始颜色）路径完全不变**（仍然清 alpha，照片 3 的观感保持原样）。

### 10.4 仍未验证

- 三处改动**没有编译验证**（本机无 Swift 工具链）；
- 修完是什么观感（不透明的封面主色面板 vs 现在的黑块）只有真机照片能判定；
- 若用户更想要"模糊封面"那种半透底，那就得回到"让 overlay 在 9.1.86 上挂上卡片"这条更长的路。

---

## 12. 第三轮：剩下的黑块来自**占位 payload** 那条路（日志 21 + 照片 09:09）

**现象**：日志 21 / 照片 09:09（`NIGHT VIBE`）里仍有一批曲目的卡片与全屏**纯黑**。

**定位**：按"日志里有没有 `keeping synthesized background opaque`"分组，一刀切开：

| 组 | 曲目 | 状态 |
|---|---|---|
| 有该日志行 | `bye bitch!`、`LOVE POTION`（NetEase 给了 synced lyrics） | §10 的修复**生效** ✔ |
| 无该日志行 | `FLUXXWAVE`、`Montagem Digital 3`、`Montagem Digital`、`MONTAGEM HITORI`、`NIGHT VIBE` | 仍然纯黑 |

第二组全都紧跟着 `[NetEase] No usable lyrics` → `[Lyrics] official lyrics hidden — serving our placeholder`
—— 它们走的是**占位 payload** 这条完全不同的路，压根没经过 §10 修的那段代码。

**根因**：占位 payload 由 `makeUnavailableLyrics` 构造，而它原本只在有原始颜色时才设颜色：

```swift
// 颜色沿用 Spotify 原来那份：背景色 / 歌名配色保持原样，看不出被替换过。
if let originalColors { $0.colors = originalColors }
```

404 曲目（Spotify 自己没词）必然 `originalColors == nil` → `colors` **整块空着** → 客户端把卡片与全屏页刷成纯黑。

同一个失败模式在**钩子侧的兄弟函数** `unavailableLyricsBytes` 里早就被防住了，它的注释原话是
"404 场景下没有原始歌词可继承配色，给一套中性配色，避免客户端拿到全 0 颜色把整页刷成纯黑"
—— 只是**仓库这条路没防**。又是"两条路径必须一致、结果却不一致"。

**修复**：配色计算抽成共用的 `synthesizedLyricsColors()`（`CustomLyrics.x.swift`），两条路都调它：

- `makeUnavailableLyrics`：`$0.colors = originalColors ?? synthesizedLyricsColors()`
- `makeLyrics` 的自造颜色分支：直接调用同一个函数（删掉第二份实现，防止再次分叉）

**待验证**：换一首"取不到词"的曲目（`NIGHT VIBE` / `Montagem Digital 3`）看卡片是否变成
封面主色面板 + 可读文字；同时确认取得到词的曲目（`bye bitch!`）观感不变。

**顺带记一笔（本轮没动）**：`unavailableLyricsBytes` 里那套中性配色（`0xFF121212` 面板 + 灰/白字）
会在 `original == nil` 时**覆盖**共用函数算出来的颜色。它可读、不是 bug，
但会让"钩子兜底"与"仓库兜底"两条路观感不同；要统一的话删掉那段覆盖即可。

---

## 14. 第四轮：配色改成"统一深底白字"（日志 22）

**反馈**：`bye bitch!` 这类曲目"每行歌词应该是白的，现在是黑的；正在唱 / 已唱过的行也应该是白的，
现在是全黑"。

**原因**：§10 里我按"底色明暗二选一"（`brightness < 0.5` → 深底白字，否则黑字），
而 `bye bitch!` 的封面主色是 `FF8B8B8B`、亮度 0.545 → 被判成"浅底" →
`lineColor` 与 `activeLineColor` **全给了黑**（日志 22：`keeping synthesized background opaque FF8B8B8B`）。
而期望的从来是**白字** —— Spotify 自己的卡片就是这个观感，对照 200 曲目的原始配色（照片 08:42）：
深色面板 + 浅色行 + 当前行更亮。

**修复**（`synthesizedLyricsColors()`）：

1. 面板：`color.normalized(normalizationFactor).darker(by: 0.45)` —— 保留封面色相，
   统一压暗到足以承载白字（不再出现"纯黑壳"，也不再是浅色壳配黑字）；
2. 文字：`lineColor = Color(white: 0.72)`、`activeLineColor = Color.white` ——
   **不再随明暗翻转**，与真机期望一致；
3. 顺手把重复的 `.normalized(...)` 收成一处，并加日志
   `[Lyrics] synthesized card colors — panel=… line=… active=…`
   （这条同时覆盖占位 payload 那条路 —— 它以前连颜色都没有，更没有日志）。

**待验证**：`bye bitch!` 卡片应为"深色面板 + 白色歌词、当前行更亮"；占位曲目（`NIGHT VIBE`）同上；
200 曲目（走原始配色）不受影响。

---

## 15. 第五轮：`lineColor` / `activeLineColor` 是"未唱 / 已唱"，两个不能一起改

**反馈**：卡片与全屏页**整片全白**。"正常来讲是未唱到的行才黑色，其他的白色；单行歌词没问题。"

**语义**（这次终于钉死，两边代码互相印证）：

| 字段 | 含义 | 正确值 |
|---|---|---|
| `lineColor` | **未唱到**的行 | 黑 |
| `activeLineColor` | **已唱 / 正在唱**的行 | 白 |

- 我们自己的 overlay 就是这么用的：`LyricsWordByWord` 里
  `label.textColor = index <= activeIndex ? activeLineColorValue : lineColor`；
- 单行歌词（面 A）用的是"当前行"那一档，所以它一直是白的、也一直没问题
  —— 这正好解释了为什么早期那版（`lineColor` 黑 / `activeLineColor` 白）下，
  照片 08:37 里单行是白的而卡片是黑块。

**两轮错法**（都记在这里，别再犯）：

| 版本 | `lineColor` | `activeLineColor` | 真机结果 |
|---|---|---|---|
| §10（按底色明暗翻转，`bye bitch!` 判为浅底） | 黑 | **黑** | 整片全黑 |
| §14（统一深底白字） | **白** | 白 | 整片全白 |
| 现在（§15） | 黑 | 白 | 期望：未唱黑、已唱白 |

**修复**（`synthesizedLyricsColors()`）：

- 字色**复原**为 `lineColor = Color.black` / `activeLineColor = Color.white`；
- 面板保持**不透明**、明度为 `color.normalized(normalizationFactor)`（中明度）——
  不再额外压暗，因为黑字（未唱行）需要中明度以上的底才看得见；
- 只保留 §10/§12 两个真修复：**面板不清 alpha** + **占位 payload 也有颜色**。

**待验证**：`bye bitch!`（真实歌词）与 `NIGHT VIBE`（占位）卡片应为"未唱黑 / 已唱白"，
单行歌词维持现状；200 曲目（原始配色）不受影响。

**若观感仍不对**，可调的只有一处：面板明度（`normalizationFactor` 那一步）。
黑字更清楚 → 面板更亮；白字更清楚 → 面板更暗，但两者不可能同时最优 —— 这是取舍，不是 bug。

---

## 39. 真机 A/B：**「补卡片元素」被排除**；剩下唯一嫌疑 `lyrics_entry_point_enabled` 已做成开关（2026-09-26）

**用户原话**：「去试了一下，关闭补元素，合成开启，还是有这个问题」。

这一句把 §34 里排第一的嫌疑**直接证伪**了 —— 关掉 `injectLyricsCardElement`
之后，那张日期早已过期的「即将发布 / 已预收藏」卡**照样出现**。

### 39.1 为什么这条排除是硬的（不是"好像没变化"）

关掉开关后，`SpotifyResponsePatcher.shouldHandle` 里那半条
`isLyricsCardElementInjectionEnabled && ScrollsitaLyricsElementInjector.shouldHandle(url)`
为 false，`injectIfNeeded` 开头也有同一道 guard ⇒ **scrollsita 的字节一个都不动**。

⚠️ 注意：scrollsita **仍然**会被 `BrowsitaSectionStripper.shouldHandle` 命中而进缓冲，
但 `strip()` 在 `dropped == 0` 时返回 nil（§35 的 `[STRIP] KEEP` 日志已证实），
所以最终交给客户端的仍是**服务端原样**。

⇒ 在"响应与服务端逐字节相同"的前提下坏卡还在 ⇒ **坏卡不是我们写进元素列表的**。

### 39.2 那次"修复预览歌词"到底改了什么（git 取证，避免再漏）

`git log --follow` 追两个文件，改动集中在两个提交：

| 提交 | 时间 | 内容 |
|---|---|---|
| `aa71b42` | 09-25 08:00 | **新建** `ScrollsitaLyricsElementInjector`（+192 行）；**新增** flag `lyrics_entry_point_enabled`（`ios-feature-lyrics`，`.setBool(true)`）；新建设置开关与 l10n |
| `d8c96f6` | 09-25 10:56 | 注入器 +71 行；`DataLoaderServiceHooks` / `HttpClientURLSessionHooks` 各加两处 **`isLyricsFeatureDisabled` 分支**（只在"禁用歌词功能"时生效，与坏卡无关） |

也就是说：**能动到正在播放页卡片渲染的我们自家改动只有两处**，
一处已被本次 A/B 排除，只剩下面这条 flag。

顺带排除的一个猜想：担心 `propertyReplacements` 里有"name 为 nil 的通配 `setBool`"
会把 prerelease 类 flag 一并钉成 true —— 查过了，**所有无 `name:` 的条目全是 `.remove`**，
不存在通配 `setBool`。

### 39.3 剩下的嫌疑：`lyrics_entry_point_enabled`

服务端对 `ios-feature-lyrics` 下发的整份歌词 flag 里**只有这一条是 false**（§7 取证），
我们把它钉成 true。

新的怀疑点不是"歌词入口"这四个字的字面意思，而是 **entry point 在正在播放页是一整排**：
歌词入口、预热/预收藏入口、周边入口、演出入口…… 服务端把这个入口区关掉了，
我们把它打开之后，客户端就拿**本地实体缓存**去填这一排 —— 缓存里那张专辑还带着
2021 / 2023 年的 prerelease 记录，于是渲出一张"日期早已过期"的卡。

这也能解释用户描述的两个现象：
- **间歇出现** —— 取决于本地实体缓存里那条 prerelease 记录在与不在；
- **退出重进就没了** —— 重进时 scrollsita 与实体都重新取，缓存被冲掉。

### 39.4 新开关（默认 ON，保持既有行为不变）

| 层 | 改动 |
|---|---|
| key | `NgzhwmSettingsViewModel.lyricsEntryPointFlagKey = "ngzhwm_lyricsEntryPointFlag"` |
| getter | `isLyricsEntryPointFlagForced`（`bool(forKey:defaultValue: true)`） |
| 生效点 | `modifyAssignedValues` 的 `for replacement in propertyReplacements` 循环开头：命中该 flag 名且开关关闭 → `continue`（整条替换跳过，不打钉） |
| 视图 | `EeveeLyricsSettingsView.lyricsEntryPointFlagSection()`，紧跟 `injectLyricsCardElementSection()` |
| l10n | `ngzhwm_lyrics_entry_point_flag`（en: "Force Lyrics Entry Point Flag" / zh-CN: "强制歌词入口开关"） |

**日志怎么读**（`[Flags]` 两行配合看）：

```
[Flags] replacement ios-feature-lyrics.lyrics_entry_point_enabled — 1 match(es)            ← 开关 ON，已钉
[Flags] replacement ios-feature-lyrics.lyrics_entry_point_enabled — 1 match(es) (SKIPPED: switch off)   ← 开关 OFF，没动
[Flags] lyrics_entry_point_enabled — SKIPPED (switch off, A/B)                              ← 启动时打一次
```

⚠️ 命中数是**照常打印**的（服务端确实下发了这条），所以必须看 `(SKIPPED: switch off)`
后缀才能区分"改了"与"没改" —— 这条后缀是专门为了防误读加的。

### 39.5 下一步 A/B（用户操作）

1. 设置 → 歌词 → **关掉**「强制歌词入口开关」，「补全歌词时间轴」保持开启，
   「给没有歌词卡片的歌曲补一张」随便（已排除）；
2. 复现：找一首会出坏卡的歌（KSLV Noh 那几首：`Dog Eats Dog` / `Final Stage` /
   `Live, Love, Lacerate - Live`），进正在播放页，退出重进几轮；
3. **判读**：
   - 坏卡**消失** ⇒ 就是这条 flag。修法是把"钉 true"收窄（例如只在真的拿到自定义歌词时才钉），
     而不是整段删掉 —— 删了会让 9.1.86 上的歌词卡片一起没掉；
   - 坏卡**还在** ⇒ 与我们无关，是 Spotify 自己拿过期的专辑 prerelease 记录渲的。
     此时应停止在注入/flag 上找，转为**只能绕开**：把元素类型 `12` 也纳入可剥离范围，
     或者干脆不管。

---

## 38. 预热卡：78 条 manifest 全解 + 关键字零命中 ⇒ 数据不在我们能看到的网络里，加「全量请求清单 + 日期串」探针（2026-09-26，日志 8 + 照片 8/9）

**材料**：`C:\dsh\readlog\eeveespotify_debug 8.log`（537KB，06:22:52–06:33:14 UTC = 本地 15:22–15:33）、
`C:\dsh\else\8.jpg`（Dog Eats Dog，14:07）、`C:\dsh\else\9.jpg`（Final Stage，15:32）。

### 38.1 三件事被这份日志**排除**（都是硬证据，不是推断）

**（1）假卡不在 scrollsita 的元素列表里。** 整场 **79 条** `[Scrollsita] manifest` 全部解出，
逐条统计后只有两种形状：`2/3/4`（无词曲目）与 `5/2/3/4`（有词曲目，外加少量 `11` 演出 / `6` / `23`）：

```
2enGySbM3Bd38rNywkdkLe (Final Stage)     body=333B has5=false elements=[2,3,4]
2XMcZj3aVmbo1gjUFqQe5e (Dog Eats Dog)    body=373B has5=false elements=[2,3,4]
```

**两条假卡所在的曲目，元素列表里连 `12` 都没有**；整场 `12` 只出现过一次（`6k2NwBLWvFhoNg8etP9EMo`
MONTAGEM KOKORO，即 §36 那张**正版**卡）。⇒ 「服务端下发了一个预热元素」这条彻底没了。

**（2）也不在三个旁路模块里。** `cultural-moments` / `merch-npv` 恒为 404
（`No entrypoint is defined…` / `No artists with merch…`）；`EventCardInfoService` 只在**真有演唱会**
的曲目上 200，体里是 `spotify:concert:` + 场馆 + `2027-01-23T16:30:00+0900` 这种**明文日期**，
没有任何一条提到预热 / 预发行。

**（3）明文关键字层面，整个会话零命中。** `[PreRelease]` 探针（11 个关键字，扫所有响应体）
全库只有 4 处命中，**全在 `bootstrap` / `customize` 的 flag 名字里**
（`ios-prerelease-feature`、`album_presave_second_step_enabled`、`inline_release_date_enabled`、
`ios-upcoming-releaseshubpage-impl`），加上一条 `browsita` 的 `spotify:upcoming-releases` 页面 URI。
⇒ **没有一次业务响应带着"这张专辑要发布 / 已预收藏"的数据。**

### 38.2 「第一次有、重进没有」的差别 = **旁路请求**

同一首 `Fade Away`（`3o0CIpmWd0oLY5I7vvNXuI`）两次加载，manifest **逐字节同形**（373B，`2/3/4`），
差别只在旁路：

| 时刻 | 旁路请求 | 卡 |
|---|---|---|
| 06:23:59 第一次进页面 | `EventCardInfo + cultural-moments + merch` + scrollsita | **在场** |
| 06:29:48 退出重进 | **只有** scrollsita | 没了 |

`watch-feed/v1/discovery-from-seed` 两次都发（每首歌必发一次），所以**不是它**。

而照片 8/9 两张假卡的日期是**绝对日期**（`发布时间：2021年5月27日` / `2023年8月10日`），
正版卡（§36 照片 7）是**相对文案**（`在 6 天内发布`）—— 两种渲染说明假卡拿到的是一份
**带日期的数据**；只是那份数据以 protobuf 字段到达，明文关键字扫不到。

⇒ 剩下两条互斥读法，现有材料**分不开**：

- **读法 A**：数据搭那三个旁路接口之一过来（最像 `EventCardInfoService` —— 它是这一场唯一
  返回 200 且有内容的）；
- **读法 B**：数据在**客户端本地**（实体缓存 / 某条我们看不见的路径），第一场用的是陈旧记录，
  重建页面时被刷新掉。

### 38.3 本轮改动：`[Traffic]` 两支探针（全量请求清单 + ISO 日期串）

| 内容 | 说明 |
|---|---|
| `probeTrafficHeaders(url:response:)` | **每一条**响应一行：`resp #N status= type= len= host= path=`。这是"某条请求到底发生过没有"的唯一直接判据 —— 上一节的对照是人工从 `TokenCapture` 里翻出来的，现在直接可读 |
| `probeTrafficBody(url:taskID:data:)` | ① 该 task 首块体积（响应头常常没有 `Content-Length`）；② 全字节扫 `NNNN-NN-NN` 形状的日期串，命中打 `date= path= ctx=`（前后各 60 字节）；③ `discovery-from-seed` / `EventCardInfoService` / `scrollsita` 三条路径 dump 前 2048 字节 hex |
| 补的盲点 | `[PreRelease]` 探针超过 256KB 会**完全静默** —— 现在把"跳过的大响应"也记一行（最多 8 条），免得再出现"没命中"与"没扫"分不清 |

为什么盯**日期串**：`EventCardInfoService` 的日期是明文的，所以假卡那份数据**如果**来自网络，
它的日期大概率也是明文 —— 扫到就能直接指认是哪条响应在供数据（读法 A 成立）；整场一条都扫不到，
读法 B 就成立，方向换成"本地那面旗子"。

改动点：`SpotifyResponsePatcher.swift` 新增两支探针（`_traffic*` 全是 file-private 状态，
`printableContext` 多一个 `radius: Int = 80` 默认参数，既有调用行为不变）；
`HttpClientURLSessionHooks.x.swift` / `DataLoaderServiceHooks.x.swift` 的
`didReceiveResponse` + `didReceiveData` 各加一处调用（两条 HTTP 栈都要，漏一条就是盲点）。
**只读、只打日志、不参与 `shouldModify`、不改任何字节。**

### 38.4 复现协议（拿到日志怎么读）

1. 装新构建 → 播一首**会出假卡**的歌（`Dog Eats Dog` / `Final Stage`），**第一次进听歌页就截图**；
2. 退出听歌页**再进一次**，确认假卡消失；
3. 导出日志，然后按顺序看：
   - `[Traffic] resp` 清单里，**"卡在场"那一次有、重进那一次没有**的 path 是哪个 → 那就是嫌疑人；
   - `[Traffic] date=` 有没有命中**那首歌专辑的发行日**（`2021-05-27` / `2023-08-10`）；
     命中 → 看 `path=` 与 `ctx=`，读法 A 落地，下一步就是"按日期过滤这条响应"；
   - 一条 `date=` 都没有 → 读法 B，网络层无解，方向换成找本地那面旗子（或直接做"摘卡"层）。

### 38.5 ⚠️ 未验证

- **没有编译验证**：本机没有 Swift 工具链（`swift` / `theos` / `make` 全不存在），本会话的 shell
  也只能读（`pwsh` 跑得动，但改文件必须走一次授权）。改动人工逐处复核：新增的两个函数只用到
  同文件的 `lock` / `writeDebugLog` / `printableContext`，`switch offset { case 4, 7: … }` 走
  `default` 分支，无 `@unknown default` 需求；`_trafficDumped` 是 `[String: Int]` 计数器
  （初版写成 `Set` 时 `.filter{}.count` 的语义是错的，已改）。
- 本轮**没有新增 l10n 键**，没有新增开关，没有改任何数据路径 —— 行为与上一版**逐字节等价**。
- §37 留下的那条 `should_nova_scroll_use_scrollsita — 0 match(es)` 结论未变：那条 `.remove` 是**空枪**
  （服务端根本没下发），与预热卡无关。

---

## 37. 预热卡三条线全部收口：元素/旁路都排除，剩"数据从哪来"—— 加两支探针（2026-09-26，日志 7 + 照片 8）

**材料**：`eeveespotify_debug 7.log`、`C:\dsh\else\8.jpg`。

### 37.1 坏卡长什么样（照片 8，Dog Eats Dog，东京 14:06 / UTC 05:06）

```
即将发布
已发布时间：2021年5月27日          ← 五年前的日期
Dog Eats Dog / 2021・即将发布的新歌
[ 预收藏 + ]                       ← 这一张按钮状态是**对的**（照片 5 那张错成"已预收藏 ✓"）
```

### 37.2 三条候选，两条已被日志否证

1. **元素列表 `12`？否。** 日志 6 的 `MONTAGEM KOKORO` 显示的是**正常**card（"在 6 天内发布" + "预收藏 +"），
   它的元素列表里**有 `12`**；而坏卡出现在**没有 `12`** 的曲目上（Fade Away / Notes of Color / Dog Eats Dog）。
   而且把 `12` 拆开只有 album URI + section URI，**没有日期字段**。
2. **三个旁路模块接口？否。** 日志 7 里它们**全部返回错误**：
   ```
   [NPVModule] status=503 len=0 type=application/grpc …/EventCardInfoService/EventCardInfo
   [NPVModule] status=404 type=application/json /cultural-moments-entrypoints/v1/entrypoint
               {"code":5,"message":"No entrypoint is defined for entity_uri 'spotify:track:2XMcZ…'"}
   [NPVModule] status=404 type=application/json /merch-npv-service/v1/merch/track/2XMcZ…
               {"code":5,"message":"No artists with merch for track_id …, album_id 2AB7cHbpyVmmpAJSwFUIoE"}
   ```
   （上一轮 §36.2 的"请求在不在"推断**是错的** —— 探针这次的作用就是把这条错误的路封掉。）
3. **剩下：数据在本次会话更早的响应里，或在客户端本地。**

**同一首歌两次加载的 HTTP 数据完全一样**（日志 7：05:06:39 与 05:07:35 两行 manifest 逐字节同形，
都是 `373B, elements=[2,3,4], has5=false` → 都注入成 `458B`），而坏卡只在第一次出现 ⇒ 差别不在
"这一次页面请求"里。

**用户提供的关键对位**：第一次的模块是「预览歌词 / **过时预热卡** / 关于艺人 / 制作人」，
重进是「制作人 / **探索** / 关于艺人 / 预览歌词」⇒ **坏卡是顶掉了"探索"那一格**，不是凭空多出来的。
（顺带把映射钉死：`5`=预览歌词卡、`2`=关于艺人、`3`=探索、`4`=**制作人**、`12`=正版预热卡。）

### 37.3 用户提出"是不是 Premium 里的改动造成的" —— 排查结论

| 检查 | 结果 |
|---|---|
| Premium 目录按 mtime | 除本轮三个诊断文件外，**只有 `DynamicPremium+ModifyingFunctions.swift`（9/25 07:58）**，其余全是 9/11 23:05（仓库导入时间） |
| `git log --stat -4`（四个 `test` 提交） | 只有本轮改动的文件，**没有夹带** |
| 9/25 那次改的是什么 | 我们自己的：§6.1 的 flag 诊断 + §7.2 把 `lyrics_entry_point_enabled` 钉成 true |

**但里面确实有一条作用面正好是"正在播放页模块列表"的补丁**（第 366–367 行）：

```swift
// 😡😡😡 spotify, stop changing the scroll logic
EeveePropertyReplacement(name: "should_nova_scroll_use_scrollsita", modification: .remove),
```

问题在于：`.remove` 命中 0 条时是**静默 no-op**，而 `dumpLyricsFlags` 只打名字含 `lyric` 的 flag
（`guard name.lowercased().contains("lyric")`）—— **我们连服务端发不发这条都不知道**。

### 37.4 本轮改动（两支探针，一次写全）

**（1）flag dump 扩面** —— `DynamicPremium+ModifyingFunctions.swift`

| 新增/改动 | 说明 |
|---|---|
| `npvFlagNeedles` | `scroll / nova / prerelease / pre_release / presave / pre_save / moment / merch / card` |
| `isFlagOfInterest(_:)` | lyric 一批 + 上面一批，两处共用 |
| `renderStructuredValue(_:)` | 把原来内联在 `dumpLyricsFlags` 里的 switch 抽出来共用，避免再分叉 |
| `dumpNPVFlags(_:)` | 在**改写之前**打印 `[Flags] npv flag — scope=… name=… bool/int/enum=…`；按 `scope.name=值` 去重，每次启动上限 `npvFlagLogLimit = 60` 行 |
| `reportLyricsReplacementOutcome` | 过滤条件从"含 lyric"改成 `isFlagOfInterest` ⇒ `should_nova_scroll_use_scrollsita` 的 `— N match(es)` 也会打出来 |
| `modifyAssignedValues` | 头部多一次 `dumpNPVFlags(values)` |

**判读**：
- 打出 `[Flags] npv flag … name=should_nova_scroll_use_scrollsita` → 服务端确实下发；
  再看 `[Flags] replacement should_nova_scroll_use_scrollsita — N match(es)`：
  **N=0** 说明 scope 不匹配（我们没改到），**N>0** 说明 `.remove` 真生效 —— 那才值得做"注释掉它"的 A/B；
- **完全没有这条 flag** → `.remove` 是空枪，**这条 patch 与坏卡无关，当场排除**，不用构建 A/B。

**（2）「预热 / 预发行」关键字探针** —— `SpotifyResponsePatcher.probePreReleaseNeedles`

扫**所有**响应字节（不只旁路模块），找 11 个关键字：
`prerelease / pre_release / pre-release / presave / pre_save / pre-save / preorder / pre-order /
upcoming / release_date / releasedate`（全部小写、大小写不敏感）。
命中打一行、同一 `path + needle` 只报一次：

```
[PreRelease] HIT path=… needle=prerelease ctx=…·{"album_id":"…","state":"prerelease"}·…
```

实现要点：按 task 保留 16 字节尾巴**跨块拼接**（避免字符串被 chunk 边界切断 —— 日志 10 的
`has_lyrics` 探针就栽在这上面）；首字节分派表（只有 `p/r/u` 开头的位置才逐个比较）；
单块 >256KB 不扫；命中处前后各 80 字节渲染成可打印上下文。**只读、不改字节。**
调用点在两个钩子的 `didReceiveData`（与其它探针并列）。

**判读**：
- 扫到 → 立刻知道是**哪个响应**在说"这专辑还没发"，下一步看是改它还是挡它；
- 整个会话一个命中都没有 → 数据在客户端本地（keychain / 内存实体缓存），
  网络层无解，方向要换成"改本地那面旗子"（`SPTPlayerTrack.metadata()` 那条）。

### 37.5 ⚠️ 未验证

- **没有编译验证**：本机没有 Swift 工具链，且沙箱里 `python` 一律 `0xC0000142`
  （`git` / `Get-ChildItem` 能跑，`python -c` 不行），所以连"括号配平"这种检查都跑不了。
  改动人工逐处复核：flag 那侧新增的都是 file-private 函数/常量，唯一改到既有函数的是
  `dumpLyricsFlags`（只把内联 switch 换成共用函数）与 `reportLyricsReplacementOutcome`
  （只换过滤条件）；探针那侧全部是新增，只用到同文件的 `lock` / `writeDebugLog`。
- 本轮**没有新增 l10n 键**；§34 留下的 25 个 locale 缺口未动。
- **不要**把「覆盖配置」开关当这次的 A/B：`modifyAssignedValues`（`.remove` 就在里面）
  在 customize 响应上是**无条件**跑的，切那个开关关不掉这些替换。

---

## 36. 预热卡：元素 `12` 是**正版**，坏卡来自旁路模块（2026-09-26，日志 6 + 照片 5/7）

**材料**：`eeveespotify_debug 6.log`、`C:\dsh\else\6.jpg`、`5.jpg`、`7.jpg`。

### 36.1 结论：两类"预热卡"，来源不同

| | 照片 7（**正版**，MONTAGEM FUJIN） | 照片 5（**坏卡**，Notes of Color） |
|---|---|---|
| 日期 | **在 6 天内发布**（相对） | **发布时间：2026年5月30日**（绝对、早已过期） |
| 按钮 | **预收藏 (+)** —— 未收藏，状态正确 | **已预收藏 ✓** —— 实际没收藏，**状态错误** |

**日志 6 的铁证**（04:32:45，`MONTAGEM KOKORO - Dj Samir`，`6k2NwBLWvFhoNg8etP9EMo`）：

```
[Scrollsita] manifest … body=498B has5=false
  elements=[ 2{artist:6U0dJxYVB41L8WDZ02Nwuk,…6cGq1L}
             12{spotify:album:08mBBhkBwUP9MC4C1fjnRe,…6cGq1X}    ← ★
             3{…1XJEwt}  4{track,artist,artist} ]
[Scrollsita] injected lyrics-card element — 498B -> 583B
```

注入后元素列表 = **`5, 2, 12, 3, 4` 共 5 个**；而用户当时数到的模块 = **制作人 / 探索艺人 /
预热卡 / 艺人卡 / 预览歌词卡 共 5 个**，一一对应（`5`=预览歌词卡、`2`=艺人卡、
**`12`=预热卡**、`3`=探索艺人、`4`=制作人）。用户明确说这一张是**"真正的预热卡"**。

⇒ **元素类型 `12` = 正确的「即将发布」卡（引用 album URI + section `…6cGq1X`），不能摘。**
同族对照：日志 3 的 `天気雨` 有 `11`（引用 `spotify:concert:…` + section `…6cGq1W`）＝ 演出卡；
类型号与 section 后缀成对递增。

**坏卡不是它** —— 坏卡出现在**元素列表里没有 `12`** 的曲目上：

| 曲目 | 有 `12` 吗 | 那张卡 |
|---|---|---|
| MONTAGEM KOKORO（日志 6） | **有** | 正版 |
| Fade Away（日志 5） | 没有（只有 2/3/4） | 坏卡 |
| Notes of Color（日志 3，照片 5） | 没有（只有 5/2/3/4） | 坏卡 |

**原理性证据**：把 `12` 那个元素拆开，里面**只有 album URI + section URI**（`62 26 0a 24 …`），
**没有任何日期字段** —— 所以日期与"已预收藏"状态都不是元素带来的，是客户端另取的。
"从元素列表里摘掉它"这条路在原理上就不成立。

### 36.2 坏卡来自三个"旁路模块"接口（请求级对照）

日志 5 的 `Fade Away`（04:20:15–04:20:40）：

```
04:20:17  scrollsita（2/3/4，无 12）→ 注入 5
04:20:18  …/spotify.liveeventdistribution.v1.EventCardInfoService/EventCardInfo
04:20:19  …/cultural-moments-entrypoints/v1/entrypoint?entityUri=spotify:track:3o0CI…
04:20:19  …/merch-npv-service/v1/merch/track/3o0CI…
          ⇒ 用户看到：预览歌词卡 + 坏卡
04:20:40  退出重进：**只**重新请求 scrollsita，上面三个全都没有 ⇒ 坏卡消失
```

对照组：日志 6 的 `MONTAGEM KOKORO` 那一整段（04:32:39–04:33:30）**一个旁路请求都没有**，
显示的是元素 `12` 带来的正版卡。

⇒ **坏卡 = 三个旁路模块之一**。最像的是 `cultural-moments-entrypoints`（它的框架就是"按时间点出卡"，
pre-release 正是其一类，且 `entityUri` 就是当前曲目）；`EventCardInfoService` 是演出、
`merch-npv-service` 是周边，长相都不该是"即将发布 + 预收藏"。

### 36.3 本轮改动：加 NPV 旁路模块探针

| 文件 | 改动 |
|---|---|
| `Premium/Helpers/SpotifyResponsePatcher.swift` | 新增 `isNPVModuleEndpoint(_:)` / `probeNPVModuleHeaders(url:response:)` / `probeNPVModuleBody(url:taskID:data:)`。按上述三个 path 匹配；状态 + Content-Type 同 path 只报一次；响应体**按 task 累积**（≤256KB，体积变大时最多 dump 3 次），打可打印串（≤30 条）+ 前 256B hex |
| `HttpClientURLSessionHooks.x.swift` | `didReceiveResponse` 加 `probeNPVModuleHeaders`；`didReceiveData` 加 `probeNPVModuleBody` |
| `DataLoaderServiceHooks.x.swift` | 同上（两个钩子都要，两条 HTTP 栈都可能在跑） |

**为什么累积而不是只看第一块**：这几个接口的体可能分块到达，"过期日期 / 错误状态"这种字符串
完全可能跨块（日志 10 的 `has_lyrics` 探针就栽在这上面）。探针**只读、不改字节**，
也不参与 `shouldModify`。

### 36.4 下一步判读

复现一次（让坏卡出现），然后看：

1. 三个 path 里**哪个的 `[NPVModule] body … printable=` 里出现"即将发布 / 预发行 / 那个过去的日期 /
   预收藏"字样** → 就是它；
2. 找到之后两条修法：**按日期过滤**（发行日已过就不展示，最贴近用户诉求，前提是日期能从体里解析出来）
   或**整条挡掉那个 moment**（代价是这类卡全没，包括合法的周年卡之类）；
3. 照片 5 vs 7 的差别（**绝对日期 vs "在 N 天内"**）很可能就是"已过期 vs 未到期"的渲染分界 ——
   若成立，则坏卡的本质是**服务端仍在推过期的 pre-release 数据**，修法 1 即正解。

### 36.5 ⚠️ 未验证

本机没有 Swift 工具链，且 pwsh 执行器**本轮再次全程** `0xC0000142`（连 `'probe'` 都是这个码），
**没有编译验证**，`git diff` 与 l10n linter 都跑不了。改动人工逐处复核：新函数只用同文件的
`private static` 成员（`lock` / `printableRuns`），四处调用点分别在两个钩子的
`didReceiveResponse` / `didReceiveData` 作用域内（`probeURL` / `url` + `task` 均在作用域）。
本轮**没有新增 l10n 键**。

---

## 35. 三条诊断日志：每条 scrollsita 的元素清单 / 开关状态 / stripper 的 KEEP-DROP（2026-09-26）

**起因**：用户实测"预热卡一会有一会没有"，而且**第一次进听歌页和退出重进拿到的模块不一样**
（原话：有时候会把歌手信息、预览歌词这些模块重新加载一遍；第一次可能"预热卡 + 歌词卡同时"，
退出重进预热卡又没了）。用户明确说**无法稳定复现**，所以这一轮的目标不是猜，而是
**把判据补齐**——加完日志复现一次就能直接读出结论。

**改动（全部只读、只打日志，不改任何行为）**：

| 文件 | 改动 |
|---|---|
| `Premium/Helpers/ScrollsitaLyricsElementInjector.swift` | 新增 `logElementManifest(url:body:)`：解出**每个元素的类型号** + 该元素内部扫到的 `spotify:` URI（`spotify:section:` 只留末 6 字符），打一行 `[Scrollsita] manifest track=… body=…B has5=… elements=[…]`。元素类型取条目**第一个字段号**（结构性、必须准），内容用**扫 ASCII `spotify:` 串**（不依赖严格 wire format，结构变了也还能看见它引用了哪首曲目） |
| `Premium/Helpers/SpotifyResponsePatcher.swift` | `patch()` 的 scrollsita 分支**最前面**调一次 manifest —— 与开关无关、**永远打**。放在这里是因为 `shouldModify` 已被 `BrowsitaSectionStripper.shouldHandle` 覆盖 `/scrollsita/`，**开关关着时也会走到这里** |
| `Tweak.x.swift` | `[INIT]` 那行加 `card element inject: ON/OFF` |
| `Premium/Helpers/BrowsitaSectionStripper.swift` | 新增 `isVerbose(path)`：**全局 `verboseLog` 或这条 URL 是 scrollsita** 才打详细日志（browsita/casita 的 section 太多，全局打开会刷爆日志）。DROP / KEEP / bail 三处改用它 |

**为什么这三条是"唯一直接证据"**：
- 改动前，"没有注入日志"至少混着三种情况 —— 服务端本来就带 `5`（没动手）／解析不过（不敢动）／
  **客户端走了缓存、我们连响应都没看到**；
- 而"预热卡"要判定，必须比较**同一首歌两次加载各自拿到的元素列表** —— 这两份列表现在会各打一行。

**判读方法（拿到日志后）**：

1. 找同一 `track=` 的**多行** manifest（第一次进页面一行、退出重进一行）；
2. 两次 `elements=[…]` 里"**第一次有、第二次没有**"的那个类型号 = 预热卡；
3. 若两次**完全一样** → 预热卡不是来自元素列表，改查旁路接口。日志里能看到正在播放页的
   旁路只有 `/merch-npv-service/v1/merch/track/<id>`、`/cultural-moments-entrypoints/v1/entrypoint`、
   `spotify.liveeventdistribution.v1.EventCardInfoService/EventCardInfo` —— 都不像"预热/预收藏"，
   所以**大概率就是元素列表里的某个类型**；
4. `[STRIP] KEEP /scrollsita/… idx=N size=…` 会告诉我们 stripper 是否把那个元素判为"不是广告"
   （判 KEEP ⇒ 按现有标记表摘不掉，只能像摘 `5` 那样**按类型号**摘）。

**已有的元素类型样本**（日志 3 解出，供比对）：`2`=关于艺人、`3`=探索、`4`=canvas、
`5`=§7.3 猜的那个（我们注入的也是它）、`11`=演出（内容含 `spotify:concert:`）。

**⚠️ 未验证**：本机没有 Swift 工具链，且本轮 pwsh 执行器**全程** `0xC0000142`
（连 `python -c` 都是这个码），所以**没有编译验证**，也跑不了 l10n linter。
改动是人工逐处复核的：新增函数只用到同文件的 `private static` helper
（`readVarint` / `readLengthDelimited` / `trackURI` / `isURIScalar`），三处调用点都在作用域内。
本轮**没有新增 l10n 键**（§34 留下的 25 个 locale 缺口未动）。

---

## 34. 「补卡片元素」也改回真开关；日志 3 解出的元素清单（2026-09-26）

**材料**：`C:\dsh\readlog\eeveespotify_debug 3.log`（9/26 02:13，Spotify 9.1.86 / iOS 27）、
`C:\dsh\else\5.jpg`（「即将发布 / 已预收藏」卡的照片）、日志 2、日志 28。

### 34.1 起因：404 曲目上会出现一张「即将发布 / 已预收藏」卡

用户报告：预览卡片那块，**部分歌曲**会多出一张「即将发布」卡（照片 5.jpg：`Notes of Color`、
`发布时间：2026年5月30日`、`已预收藏`）。日期早已过期，甚至见过 2021 年的，
而且"没听说过这歌有预热"。这张卡**和歌词卡同时存在**，并且**一会有一会没有**。

### 34.2 日志 3 解出的元素清单（本轮最硬的证据）

把每条 `scrollsita/v1/scroll/spotify:track:<id>` 响应的元素列表按 wire format 拆开
（元素类型 = 每个条目的**第一个字段号**）：

| 曲目 | color-lyrics | 服务端**原生**元素 | 我们注入 |
|---|---|---|---|
| Floria - HIBANA | **200** | **5**, 2, 3, 4 | — |
| Notes of Color - Yono（照片那首） | **200** | **5**, 2, 3, 4 | — |
| 天気雨 - 茉ひる | **200** | **11**(concert)、**5**、2, 3, 4 | — |
| Dog Eats Dog - KSLV Noh | **404** | 2, 3, 4 | **5** ← 我们加的 |
| Don't Hesitate - KSLV Noh | **404** | 2, 3, 4 | **5** ← 我们加的 |

（`2`=关于艺人、`3`=探索、`4`=canvas、`5`=§7.3 猜的那个、`11`=演出/concert 卡。
原生 `5` 的字节结构 = `{字段5{曲目URI}, 字段23{section URI = …Gq21}}`，
与我们合成的那一份**逐字节同形** —— 所以"我们少写了字段"这条假设不成立。）

"`5` ⟺ status 200" 在这份日志里是 **5/5**，比 §7.3 的 3 个样本更硬。

### 34.3 由此得到的两个互斥读法（**尚未判定**）

- **读法 A**：`5` 不是歌词卡，而是一张"内容卡/预热卡"槽位。那么 §7.3/§10 的结论
  （`5` = 歌词卡、补上它就能造出歌词卡）是**误判**，§10 那次"补上就有卡了"只是相关性
  （真正建歌词卡的是"歌词数据到达"，见 `CustomLyrics.x.swift:560-564` 的注释）；
  代价是**我们给每一首 404 的歌都补了一张内容不受我们控制的卡** ——
  卡里的东西（哪一条预热、什么日期）由服务端那份 section 内容决定，我们管不着。
- **读法 B**：`5` 确实是歌词卡，预热卡来自另一条路（另一个接口/section 内容由服务端决定）。
  硬伤是：Don't Hesitate 那份响应里**原生只有 2/3/4**，多出来的只有我们加的 `5`。

**为什么"A"看起来更像**：用户观察到那张卡**一会有一会没有**。而我们的注入有个硬前提 ——
**只有走网络的响应我们才改得到**；客户端从自己的缓存/预取里拿 scroll 时，我们连响应都看不见
（日志 2 的 `6O4oKV` 就是这个形状：01:40:33 / 01:40:41 两次 `NPV scroll` 建立，
**没有对应的 scrollsita 网络请求**，直到 01:40:52 才第一次走网络并被注入）。
"时有时无"和"有没有走网络"是同一个节奏。

**已有的两条相关观察**（见 34.4 的待验证项）：
- 打开「禁用歌词功能」→ 那张预热卡消失。⚠️ 这个开关**同时**改两件事（摘掉 `5` 元素 + 换 payload），
  所以它**不能**单独作为"预热卡 = 元素 5"的证据；
- 用户口径：这张卡**和歌词卡同时存在**；而"禁用歌词功能"能把**歌词卡**藏住 ——
  这反过来说明**歌词卡确实需要那个元素**（否则它应该退化成"未找到歌词"而不是消失），
  这一点对读法 A 不利。

### 34.4 本轮改动：把「补卡片元素」恢复为真开关（默认 ON）

`isLyricsCardElementInjectionEnabled` 此前写死 `true`（§23），用户无法做 A/B。现在：

| 文件 | 改动 |
|---|---|
| `Settings/ngzhwm/ngzhwmSettingsViewModel.swift` | 恢复 `injectLyricsCardElementKey`；getter 改为 `bool(forKey:defaultValue: true)` |
| `…/Lyrics/ViewModels/EeveeLyricsSettingsViewModel.swift` | 恢复 `@Published injectLyricsCardElement`（初值走默认值 getter）+ 加进 `animationValues` |
| `…/Lyrics/Views/EeveeLyricsSettingsView.swift` | 恢复 `injectLyricsCardElementSection()`，在 `syntheticLineTimingSection()` 之后；**无 footer** |
| `…/ViewModels/…+setupBindings.swift` | 恢复 `[Settings] inject lyrics card element -> ON/OFF` |
| `en` / `zh-CN` | `ngzhwm_inject_lyrics_card_element` |
| `Premium/Helpers/SpotifyResponsePatcher.swift` | 只改注释：说明 `shouldModify` 里 `BrowsitaSectionStripper.shouldHandle` **已经覆盖 `/scrollsita/`**，所以关掉开关**不会**影响去广告那一步（旧注释写的是"关着连缓冲都不做"，是错的） |

**判决性实验（用户跑，四种结果的含义）**：

| 关掉注入后 | 预热卡 | 歌词卡 | 结论 |
|---|---|---|---|
| 场景 1 | 没了 | 还在 | 读法 A 成立 → 注入纯粹在造垃圾卡 → **整个去掉** |
| 场景 2 | 没了 | 也没了 | `5` 是歌词卡的必要条件 → 读法 B，问题变成"同一份元素为什么有时渲成预热卡" |
| 场景 3 | 还在 | 还在 | 预热卡与我们完全无关，去查别的接口 |
| 场景 4 | 还在 | 没了 | 说明预热卡另有来源、而我们那个元素确实是歌词卡 |

⚠️ 用户当前设置：`synthetic line timing: OFF`。**做这个 A/B 时不要同时改时间轴开关**，
否则两个变量一起动。

### 34.5 另一件事：「禁用歌词功能」藏不住封面下那行单行歌词（面 A）

用户口径：**预览歌词卡拦得住**（进全屏不行、卡片消失），但**封面与歌手名之间那行单行歌词**
拦不住；且那行**没有"歌词提供者"可看**（那是全屏页底部的东西）。测试曲目是日语歌，
内容看起来是 **Spotify 自己的日区供应商 プチリリ**。

两种可能，**靠日志一句话分开**：

1. 那一刻**没有** `color-lyrics` 请求 → 客户端从**它自己的歌词仓库**渲染
   （`Lyrics_OfflineImpl` / `is_lyrics_cache_v2_enabled=true`；§32 已记过这条路径）。
   没有响应可替换 ⇒ **HTTP 层天生拦不住**，只能改设置说明或去动原生显示层（风险高）。
2. 有请求、也替换成占位了，但单行仍显示真歌词 ⇒ 才是真 bug，说明喂给面 A 的不是这条响应。

**另一个立刻能分辨的观察**：那一刻单行显示的是**真歌词**，还是**"未找到歌词"**四个字？
- "未找到歌词" ⇒ 我们拦住了，只是"藏住"没做到 —— 禁用时交的是**一行占位**而不是**空 payload**
  （`SpotifyResponsePatcher.disabledLyricsPayload`）。改成 0 行即可，改动很小；
- 真歌词 ⇒ 落到上面第 1 或第 2 种，按日志分。

### 34.6 ⚠️ 未验证 / 未做完

- **没有编译验证**：本机没有 Swift 工具链，且本轮 pwsh 执行器又挂了
  （`0xC0000142`，`python Tools/l10n_lint.py` / `git diff` 一律这个码），
  连 l10n linter 都没能跑。改动是**人工逐处复核**的：四处是"新增属性 / 新增调用 + 一个恢复的
  Section"，唯一的行为改动就是那个 getter 从常量变成读 UserDefaults（默认值不变，行为不变）。
- **l10n 只加了 `en` / `zh-CN`**：另外 25 个 locale 现在缺**两个**键
  （`ngzhwm_synthetic_line_timing`、`ngzhwm_inject_lyrics_card_element`）。
  运行期**不会露出 key 名** —— `BundleHelper.localizedString` 在本 locale 查不到时显式回落到
  `enBundle`（`BundleHelper.swift:52-62`）；但 `Tools/l10n_lint.py` 会报 MISSING。
  补法（等 shell 恢复）：把 en 那两行照抄进各 locale 末尾的 `/* AUTO-FILLED (untranslated) */` 块。
- **预热卡到底是谁造的仍未定**：等用户按 34.4 的表跑一次 A/B，以及"预热卡出现/消失各记
  2–3 次本地时间"（日志是 UTC，差 9 小时）后，用 `[Scrollsita] injected lyrics-card element`
  那行去对。**在结论出来之前不要动 `ScrollsitaLyricsElementInjector` 本身。**

---

## 33. 「补时间轴」改回真开关 + 多级回退的署名（2026-09-26）

**材料**：`C:\dsh\readlog\eeveespotify_debug.log`（9/26 00:39–00:42，Spotify 9.1.86 / iOS 27，下文简称日志 29）

### 33.1 起因：日志 29 里唯一一处署名错误

用户报"柏树（CYPARISS）那首歌还是只显示 EeveeSpotify"。逐曲对照（7 首，6 首正常）：

| 曲目 | 来源设置 | 结果 | 卡片底部 |
|---|---|---|---|
| SECRET / 君は花火 | 多级回退 | Musixmatch / PetitLyrics 成功 | 正常 ✔ |
| **最後の希望 - CYPARISS** | **多级回退** | **四源全败 → 占位** | **只有 `EeveeSpotify`** ❌ |
| Fade Away / Dog Eats Dog | 网易云 | NetEase 成功 | 正常 ✔ |
| Don't Hesitate / Live, Love, Lacerate | 网易云 + Genius 回退 | **Genius 兜底成功** | `Genius (EeveeSpotify)` ✔ |

**根因（代码级，不是猜）**：`lastRequestedLyricsSourceDescription` 全仓库**只有一处写入** ——
`CustomLyrics.x.swift` 的 `requestSingleSource` 入口（第 255 行）。而**多级回退那一段自己写了一个
for 循环，从不经过 `requestSingleSource`**，所以这个全局在整个多级回退模式下恒为空串 →
`makeUnavailableLyrics` 的 `providedBy` 永远落到 `"EeveeSpotify"` 那一支。
§31.1 当时只在**单源**路径上验证过（那一节自己写着"日志 27 这一例没有走 Genius 兜底"），
所以看起来是修好了。

**改法**：

1. 多级回退分支入口写 `lastRequestedLyricsSourceDescription = LyricsSource.multiLevel.description`
   → 卡片底部显示 `多级回退 (EeveeSpotify)`（**用户选定**：署这条链本身，而不是最后试的那个源）；
2. 进 `loadCustomLyricsForCurrentTrack` **先清空**它 —— 否则从单源切到多级回退后失败，
   会显示 `NetEase (EeveeSpotify)`，把一个**这次根本没被问过**的源写成"没找到词"。
   单源路径在 `requestSingleSource` 入口写回，不受影响。

⚠️ **已知遗留（本轮没做）**：这个全局被并发的歌词请求共享（日志 29 里同一首 7 秒内请求两次、
不同曲目也可能重叠），严格说仍有竞态；彻底修法是把它变成随请求传递的上下文。

### 33.2 「补时间轴」恢复为开关（用户要求："干脆不要写死"）

§23 曾把它写死成 `true`，现在改回读 UserDefaults：

| 文件 | 改动 |
|---|---|
| `Settings/ngzhwm/ngzhwmSettingsViewModel.swift` | 恢复 `syntheticLineTimingKey`；getter 改为 `bool(forKey:defaultValue: true)` |
| `…/Lyrics/ViewModels/EeveeLyricsSettingsViewModel.swift` | 恢复 `@Published syntheticLineTiming`（初值必须走默认值 getter）+ 加进 `animationValues` |
| `…/Lyrics/Views/EeveeLyricsSettingsView.swift` | 恢复 `syntheticLineTimingSection()`，位置在 `hideOnErrorSection()` 之后；**无 footer**（用户："介绍不需要了"） |
| `…/ViewModels/…+setupBindings.swift` | 恢复 `[Settings] synthetic line timing -> ON/OFF` |
| `en` / `zh-CN` | `ngzhwm_synthetic_line_timing`（`Fill in Missing Lyric Timing` / `补全歌词时间轴`） |

**默认 ON**（与最初引入时一致）：保持"Genius 这类纯文本源也能出模块"的既有行为；
关掉它才是实验组。启动那行 `[INIT] synthetic line timing: ON/OFF` 仍是 A/B 的分组标记。

**对"关掉会怎样"的预判（未验证）**：
- `LyricsDto.swift:81` 会把 `timeSynchronized` 算成 `false`（Genius / Petit 纯文本 / 占位）；
- 卡片**应该还在** —— 存在性由 scrollsita 的 `5` 元素决定，注入是写死启用的；
  最接近的先例是日志 12/13 的强制占位实验（`timeSynchronized=false` 的 payload 确实显示在卡片里）；
- §7.4 那次"07:48 关掉合成 → 单行和卡片都没有"**不能用来预测现在** —— 那是在补卡片注入
  （§8 引入、§10 才真机验证有效）**之前**。

**两个必须先补的日志盲点**（否则这次 A/B 只能靠肉眼反推）：
1. 交出去的 payload 的 `timeSynchronized` / 带 offset 的行数**从来没打印过**
   （`synthetic line timing applied` 只在"补了"的时候打，关掉的那一组完全静默）；
2. 占位那条路（`makeUnavailableLyrics`）补时间轴时**不打任何日志**。

### 33.3 ⚠️ 未验证 / 未做完

- **没有编译验证**：本机没有 Swift 工具链（`swift` / `xcrun` / `theos` / `make` 全都不存在），
  且本轮 pwsh 执行器又挂了（`0xC0000142`，`git log`、`Get-Content` 一律这个码），
  连 `Tools/l10n_lint.py` 都没能跑。改动是**人工逐处复核**的：四处是"新增属性 / 新增调用"，
  唯一的控制流改动是 `loadCustomLyricsForCurrentTrack` 头部多一次赋值（不改变分支结构）。
- **l10n 只加了 `en` / `zh-CN`**：另外 25 个 locale 缺 `ngzhwm_synthetic_line_timing`。
  运行期**不会露出 key 名** —— `BundleHelper.localizedString` 在本 locale 查不到时会显式回落到
  `enBundle`（`BundleHelper.swift:52-62`）；但 `Tools/l10n_lint.py` 会把这 25 个报成 MISSING。
  补法（等 shell 恢复）：把 en 那一行照抄进各 locale 末尾的 `/* AUTO-FILLED (untranslated) */` 块。
- 日志 29 里另外几个**本轮没动**的真问题：多级回退里 Genius 只给 3s（它自己两次请求各 10s 上限，
  所以每次都是"超时"而非被评估）；LRCLIB 的 `semaphore.wait()` 无超时 + `LrclibSong.instrumental`
  是非可选（404 的错误体被当歌词解码 → `DecodingError`），叠加本次环境的 TLS `-1200`，
  每轮白烧 3s；多级回退链路里**没有网易云**（同一场日志里网易云 3/3 成功）。
- 另外记一笔：`[Shell] ⚠️ stand-in unavailable` 在日志 29 里出现 8 次，对应 6 首歌，
  **与歌词源无关** —— 它出现在"关闭全屏歌词页"那一刻，而这一场每一首都是
  `attach declined — no word-level timing`（§30 的设计），我们那层根本没挂，自然拍不出替身。
  只有当某首**真有逐词数据**时才需要担心"关闭时一闪"是否因此回归。

---

## 32. 「壳写着新歌名、歌词还是上一首的」= 切歌没来歌词请求时的陈旧行模型（2026-09-25，日志 28）

用户原话：waka 那首歌（Planetarium）**底子是 Spotify 自己的 PetitLyrics，我们那层只盖住
一小部分，而且内容还是上一首的**；不是稳定复现，属于小概率事件。

### 日志证据（两件事是**两个**原因，别混）

现场是 `Planetarium - waka`（NetEase 只给行级：`Applied official romaji (23 line(s))`）
与 `ただ声一つ - Rokudenashi`（有 yrc：31/33 行带词级时间轴）来回切：

```
15:16:12  stale attachment cleared — the layer is not in any window (wasFullscreen=false)
15:16:12  legacy overlay attached — host=…LyricsTextView 342x256 shell=false level=word
15:16:12  [Shell] legacy metadata "Planetarium" — "waka"        ← 壳：这一首
15:16:13  word-level judge: 31/33 … render mode=word             ← 模型：上一首的 33 行
15:16:14  t=48309ms line=8 w8=" ni"@48010ms                      ← 画的是 48s 的上一首内容
（15:16:59 切回 Planetarium 再来一次，一模一样）
```

关键：这两次切回 Planetarium **没有** `[Lyrics] Request for /color-lyrics/v2/…`，
所以 `resetWordByWordLyrics()` 没被调用，`currentLyricsDto` 一直是上一首的。

| 现象 | 原因 | 归属 |
|---|---|---|
| **内容是上一首的** | 切歌不一定来歌词请求（客户端命中自己的歌词存储 / 离线歌词）→ `resetWordByWordLyrics()` 不跑 → dto 陈旧；而壳上的曲名是每帧从播放器实时读的，于是"壳新、词旧" | **我们的 bug** ✔本轮回修 |
| **底子是 PetitLyrics，我们只盖住一小部分** | 那次**根本没有网络响应**（Spotify 用自己存的歌词直接渲染）→ 替换 payload 的钩子没机会跑 → 露出来的是官方歌词（日区 = プチリリ）；而我们的层只占歌词控件那一块（卡片里的 342x256），不是整页 | Spotify 侧的路径，我们目前**替换不了**（见下） |

### 回修：给行模型记"归属曲目"，两层每帧比对

AM 层早就有这条判据（`AppleMusicLyricsOverlayHost.hasForeignLineModel` +
`currentModelTrackId`，在 `tick` 里每帧比对）；**旧层一直缺**，所以这个 bug 只在
"普通逐词"那条路上出现（日志 28 里用户就是 AM 关）。

| 文件 | 改动 |
|---|---|
| `Lyrics/LyricsWordByWord.x.swift` | 新增全局 `currentLyricsDtoTrackId`（这份 dto 属于哪一首） |
| 同上 → `LyricsWordByWordOverlayView` | 新增 `liveTrackIdentifier` / `belongsToAnotherTrack` / `handBackToNative()`；`setCurrentTime` 每帧先查归属，**不属于这一首 → 整层交还原生**，并打一行节流日志 `line model belongs to another track (model=…, live=…) — handing back to Spotify's own lyrics` |
| 同上 → `WordByWordHost` | 新增 `lineModelIsForeign`；`refreshForCurrentLyrics` 里**一个挂载点都不试**（否则挂上去画的就是上一首的），并 `detach()` 掉已经挂着的 |
| `Lyrics/CustomLyrics.x.swift` | `storeLyricsDto` 写入 `currentLyricsDtoTrackId`（优先请求里的曲目 id，退回播放器实时读）；`resetWordByWordLyrics` 一起清空 |

顺带把手写三遍的"交还原生"收成一个 `handBackToNative()` —— 以前是逐处抄，漏一处
就是"层撤了但底色还在"。

### 还没解决的那一半（PetitLyrics 当底）

我们只在**网络响应**上做替换（`color-lyrics/v2` 的 `didReceiveResponse`/`didReceiveData`）。
Spotify 若是从它**自己存的歌词**（离线歌词 / 内存缓存）直接渲染，就没有响应可替换，
露出来的必然是官方歌词（日区 `プチリリ`，不带 `(EeveeSpotify)`）。
本轮的改动至少保证了：**不会再显示上一首的歌词**（宁可是这首歌的官方歌词）。

要连这一半也解决，只有两条路（都还没做，也没验证过）：

1. 找到"让客户端重新取一次歌词"的内部入口（`NPV scroll — enabling local track URI override`
   那类调用已经在用类似手段），在检测到"切歌了但没有歌词请求"时主动触发一次 ——
   只要它走网络，就会经过我们的钩子；
2. 或者勾到歌词**渲染层**（`Lyrics_TextElementImpl` 一类），直接把行模型塞进去 ——
   那是"接管原生视图"那条被真机否掉过的路，风险高。

**未验证**：没有本地编译（无 Swift 工具链），也没有真机复测。

---

## 31. 日志 27 的两件事：占位署名、AM 全屏进度条拖不动（2026-09-25）

### 31.1 取不到词时，`歌词提供者` 只剩 "EeveeSpotify"

日志 27 的现场（`FLUXXWAVE / AKXNESHIVA`）：

```
[Lyrics] Single source: NetEase
[NetEase] No usable lyrics
[Lyrics] NetEase failed: 未找到歌曲
[Lyrics] official lyrics hidden — serving our placeholder
```

占位 payload 把 `providedBy` **写死**成 `"EeveeSpotify"`（`CustomLyrics.makeUnavailableLyrics`），
而 Spotify 原生歌词页/卡片底部那行 provider 是**直接照 payload 的 `providedBy` 显示**的
（证据：本文件开头那段 `forcedLyricsPayload` 实验 —— 卡片底部显示的就是我们写死的名字）。
于是用户看到 `歌词提供者：EeveeSpotify`，像是"歌词源设置没生效"。

改法：新增文件作用域 `lastRequestedLyricsSourceDescription`，在 `requestSingleSource` 入口
写一次（"这一次我们问的是谁"），占位署名改成和正常路径
（`LyricsDto.toSpotifyLyricsData(source:)` 的 `"<源> (EeveeSpotify)"`）**完全一致**：

```swift
$0.providedBy = lastRequestedLyricsSourceDescription.isEmpty
    ? "EeveeSpotify"
    : "\(lastRequestedLyricsSourceDescription) (EeveeSpotify)"
```

日志 27 这一例没有走 Genius 兜底（没有 `falling back to Genius`），所以会显示
`歌词提供者：NetEase (EeveeSpotify)`；如果哪天走了 Genius 兜底，署的就是 Genius ——
与"提供者必须与正在渲染的那份数据同源"这条既有原则一致。

### 31.2 AM 全屏的进度条拖不动（普通逐词能拖）

两份壳用的是**同一段代码**（`AppleMusicLyricsProgressBar`）：
· 普通逐词那条路 —— `LyricsShellFooterHost` 挂在**独立的** `UIHostingController`
  （`LyricsShellHosts`，底部 210pt 条）上；
· AM 那条路 —— 同一个 view 变成 `AppleMusicLyricsPage` 里的一份 `footerContent`（AnyView）。
"一个能拖一个不能拖"说明差异在**触摸是否落到那条带上**，而它只有 4pt 轨道 / 11pt 圆点。

本次改动（第一嫌疑 + 埋点）：

| 改动 | 目的 |
|---|---|
| `contentShape(Rectangle())` → `contentShape(Rectangle().inset(by: -8))` | 命中区域上下各撑 8pt（≈27pt 高），**外观与布局完全不变** |
| `seek bar drag began (width=…, duration=…)` | 日志里一眼看出"手势到底有没有开始" |
| `seek bar drag ended — fraction=…, target=…s` | 手势结束了、seek 也发了 |
| `seek bar drag ended but duration=0 — no seek issued` | **旧代码在这种情况下静默跳过 `onSeek`**：拖了没反应。这条日志专治它 |

判读方式（下一次日志）：

- 有 `drag began` + `drag ended … target=…s` → 手势与 seek 都正常，问题在别处（比如
  seek 之后被播放器回写覆盖）；
- 有 `drag began` 但只有 `duration=0` 那一条 → `AppleMusicLyricsPlaybackProjection.duration`
  在 AM 全屏下没读到；
- **两条都没有** → 触摸根本没到这条带上（那就要查 AM 页面里谁盖住了 footer：ScrollView 的
  `simultaneousGesture`、`allowsHitTesting`、或干脆是另一条原生进度条"看着像我们的"）。

**未验证**：没有本地编译（无 Swift 工具链），也没有真机；31.2 是"第一嫌疑 + 埋点"，
不是已证实的根因。

---

## 30. 逐行歌词不再套"逐词那套壳"：没有逐词数据就整首交还原生（2026-09-25）

用户给的四张真机对照图（`C:\dsh\else\1..4.jpg`）把口径定死了：

| 图 | 是什么 |
|---|---|
| 1 | 全屏**实际**：我们的旧层壳（没有原生关闭/标题，自己的进度条+三键偏低，行下还有译文） |
| 2 | 预览卡**实际**：AM 开着 → payload 不带译文 → 原生卡上没有 文A |
| 3 | 预览卡**想要**：原生卡（`歌词` + 文A/分享/展开；行是"唱过的变灰、当前亮、未唱暗"） |
| 4 | 全屏**想要**：原生页（⌄ + 居中歌名/歌手 + 底部 文A/分享/… + 原生进度条/播放键） |

### 之前为什么会变成图 1

`WordByWordHost.attach` 的挂载判据是**行级**（`hasUsableLineLevelData`）：没有逐字、
但有逐行时仍然由我们那层渲染（"降级档：当前行整行点亮"）。网易云一大批歌没有 yrc
（`yrc absent → falling back to line-synced (lrc)`），整首只有行级时间轴 → 那层照样挂上
→ 全屏就是图 1，卡片也带着我们自己的行色。

### 现在：判据从"逐行"收回到"逐词"

| 数据 | 「更好的逐词歌词」 | 谁在画 |
|---|---|---|
| 逐词 + iOS 26+ | 开 | AM 页（不变） |
| 逐词 | 关 | 旧层逐字高亮（不变） |
| **只有逐行 / 无时间轴** | 任意 | **Spotify 原生那页/那张卡**（新） |

关键理由：行级数据**没有一行是我们非画不可的** —— 原生本来就会照 payload 的
`offsetMs` 做逐行高亮 + 自动滚动（官方歌词就是它渲染的），罗马字也在 payload 里
（`Applied official romaji` 直接把主页词行替换成罗马字），所以交还之后就是图 3 / 图 4，
而且"全屏有译文"这个症状也跟着消失（AM 开时 payload 不给译文，原生页就没有译文行）。

### 改动清单

| 文件 | 改动 |
|---|---|
| `Lyrics/LyricsWordByWord.x.swift` → `attach` | 挂载 guard 从 `lineLevelUsable` 改成 `usable`；`lineLevelUsable` 降级为"只用于记账/日志" |
| 同上 → `refreshForCurrentLyrics` | AM 分支**之后**加一道 `hasUsableWordLevelData` 提前返回（顺手 `detach()` 旧层），并打节流日志 `handing back to Spotify's native lyrics page/card — no word-level timing` |
| 同上 → `setCurrentTime` | 撤层 guard 同步改成 `hasUsableWordLevelData`（否则会出现"attach 不挂了、早先挂上的层还在自己画"） |
| 同上 → `configureBackdropIfNeeded` | 底色 guard 与挂载判据保持一致 |
| 同上 → `logWordLevelJudgeOnce` | `render mode=` 只剩 `word` / `handback-to-native` 两档 |
| `Lyrics/CustomLyrics+AllTracksLyrics.x.swift` | 看门狗（1.5s 轮询）判据改成 `hasUsableWordLevelData`：逐行的歌不再白遍历视图树、不再刷 `attach declined` |
| `Lyrics/Models/LyricsDto.swift` → `toSpotifyLyricsData` | `suppliesTranslation` 从"看 AM 开关"改成 `!hasUsableWordLevelData(self)`：**谁在画谁负责译文** —— 我们画就不给（免得亮起点了没反应的翻译按钮），交还原生就给（原生 文A 才会出现，图 3/4） |

### 注意（别改回去的点）

- `hasUsableLineLevelData` **保留但只用于记账**：日志里的 `line timing 32/32 -> line-level=Y`、
  以及 `attach` 被拒时那句 `line-level usable=…`。它**不再是任何挂载判据**。
- 三处判据必须同口径（`attach` / `refreshForCurrentLyrics` / `setCurrentTime`+底色），
  否则会留下"没人管但还在画"的旧层。
- 历史反转：§20/§21 里"行级本来就该走旧层"是当时的结论，**已被这一节推翻**；
  官方供应商那一层不用担心，它由 payload 侧的「隐藏官方歌词」兜住（写死启用）。
- `hasUsableWordLevelData` 里带 `dto.timeSynced` 判据：源声明 `timeSynced=false` 的
  纯文本（Genius / 占位）也走"交还原生"，与合成时间轴那条路一致。

**未验证**：本机没有 Swift 工具链（shell 仍常 0xC0000142），这次改动**没有编译验证**。

---

## 29. IPA 构建拆成**两个工作流文件**：no patch / patched（2026-09-25）

用户原话：「把构造 patched 和 no patched 做成两个 yml 文件，而不是一个 yml」。

| 工作流文件 | 产物 | artifact 名 |
|---|---|---|
| `.github/workflows/build-ipa-with-orion.yml` | `EeveeSpotify-<v>-<spot>-orion.ipa`（**无 patch**） | `EeveeSpotify-IPA-orion-nopatch` |
| `.github/workflows/build-ipa-with-orion-patched.yml` | `EeveeSpotify-<v>-<spot>-orion-patched.ipa`（+ `zxPluginsInject`） | `EeveeSpotify-IPA-orion-patched` |

- 两个文件**各自独立、自包含**：Actions 里就是两个入口，点哪个只跑哪条流水线、
  只出一个 IPA（顺便省掉一半 CI 时间）。
- 起因：以前一个文件里出两份、还塞进**同一个** artifact —— 而 GitHub 的 artifact
  **一定是 zip**，于是下到的是"压缩包里套两个 ipa"，还得自己分辨哪个该装。
- 差别只有四处，全部标了 `[PATCHED 差异]` 注释，`git diff` 一眼能看清：
  1. `Install build tools`：patched 多装 `ipapatch`；
  2. `Build zxPluginsInject.dylib`：只有 patched 有（nopatch 不再白跑这一步）；
  3. 末尾 `LC-inject zxPluginsInject (patched)`：`mv` 成 `-patched.ipa` 再 ipapatch；
  4. 上传 / summary / filebin 的文件清单（各自只传自己那份）。
- 防漂移：`diff` 这两个文件应**只**看到 name、头部注释和上面四处不同。
- 为什么不用 `workflow_call`（可复用工作流 + 瘦调用方）：那样两个文件之间有隐藏
  耦合，删掉/改坏一个会连带另一个；用户要的就是"两个入口 = 两条独立流水线"。
- 产物内容（两个文件的公共部分完全一致）：tweak 本体 = Orion.framework +
  `EeveeSpotify.dylib` + `EeveeSpotify.bundle` + `EeveeSwiftProtobuf.framework`；
  patched 那份额外 LC 注入 `zxPluginsInject.dylib`（keychain 重定向 / group
  container / CloudKit stub）→ **TrollStore / Sideloadly / AltStore 装 patched**。
- `build-ipa-local.sh`（本地）保持**一次跑出两份**（`<name>.ipa` +
  `<name>-patched.ipa`）：本地没有排队成本，一起出更省事；`Watch.app` 剔除对两份循环。

**未验证**：照旧没有本地构建（无 Theos，shell 还经常 0xC0000142），YAML 逻辑靠肉眼检查；
patched 那份的公共步骤是从 no-patch 那份逐行复制的。

---

## 28. IPA 不再依赖越狱路径（`NO_JBROOT=1`）：TrollStore / 侧载能装了（2026-09-25）

起因：用户问「这 patched 能给巨魔/越狱用户用吗」。查下来是**不能**。

### 问题

IPA 里 `Payload/Spotify.app/Frameworks/EeveeSpotify.dylib` 的来源是：

```
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1   # 旧的 IPA 构建
  └─ Makefile 走 else 分支 → EeveeSpotify_LDFLAGS += -lroot
       └─ dylib 的 LC_LOAD_DYLIB 里多一条 /var/jb/usr/lib/libroot.dylib
```

libroot 是**加载期**依赖，不是运行时才用：dyld 在 `dlopen` 这个 dylib 时就要解析它。
而 TrollStore / 侧载设备上根本没有 `/var/jb`（那是越狱方案的路径前缀），于是
`dlopen` 失败、App 直接起不来 —— 日志里往往只剩一句 dlerror。

工作流里没有任何一步把 libroot 塞进 IPA（只注入 dylib / bundle / framework /
Orion），所以「rootless deb 掏出来的 dylib 直接用在非越狱设备上」这个组合必挂。

| 目标设备 | 旧的 orion IPA | 说明 |
|---|---|---|
| rootless 越狱 | ✅ | 有 `/var/jb`，但装 deb 更合适 |
| RootHide 越狱 | ⚠️ | 需要 `-roothide.deb`；IPA 里链的是 libroot，与 roothide 环境不匹配 |
| TrollStore（无越狱） | ❌ | 没有 `/var/jb` → 加载期就挂 |
| 侧载（Sideloadly/AltStore，无越狱） | ❌ | 同上 |

### 修法：构建期关掉越狱路径（方案 B）

选 B（构建期不链 libroot）而不是 A（把 libroot.dylib 一起塞进 IPA 再
`install_name_tool -change`）：libroot 会把路径解析成 `/var/jb/...`，在一个
没有越狱的沙盒里那是**错的答案**，等于带进去一个必然出错的依赖；而
`EeveeJBRootPath()` 的调用点本来就带兜底（`BundleHelper` 先找 main bundle）。

三处改动：

| 文件 | 改动 |
|---|---|
| `Makefile` | 新增 `NO_JBROOT ?= 0`；`ifeq ($(NO_JBROOT),1)` 时**不加** `-lroot`、改加 `EeveeSpotify_CFLAGS += -DNO_JBROOT`；roothide 分支同理不参与 |
| `Sources/EeveeSpotifyC/Tweak.m` | `#if NO_JBROOT` 时不 `#import <libroot.h>`，`EeveeJBRootPath()` 原样 `return path` |
| `.github/workflows/build-ipa-with-orion.yml` **和** `…-patched.yml` | 两个 IPA 工作流都带 `NO_JBROOT=1`；verify 步骤都加断言 `otool -L "$DY" \| grep -Ei 'libroot\|roothide\|/var/jb\|\.jbroot'` → **命中就 fail** |
| `build-ipa-local.sh` | 同样带 `NO_JBROOT=1`（本地脚本版） |

关键点：这份 deb **只当 dylib 的来源、不发布**（越狱包由 `builddeb.yml` 出），
所以按无越狱模式编它没有副作用。CI 断言是防回归的：谁把 `NO_JBROOT=1` 删了/漏传，
构建立刻红，而不是等用户装上才发现。

不需要改的地方：`EeveeSwiftProtobuf.framework` 在 rootless 下的 install_name 是
`@rpath/EeveeSwiftProtobuf.framework/EeveeSwiftProtobuf`（见
`Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh:26`），本来就不含 `/var/jb`；
只有 roothide 那份才是 `@loader_path/.jbroot/...`。

**未验证**：本机没有 Theos / Swift 工具链（shell 还经常 0xC0000142），
`NO_JBROOT=1` 这条构建路径没跑过；`otool` 断言只能等 CI 验证。

---

## 27. 第十四轮：版本检查改用 Reborn-ng 的实现（2026-09-25）

来源：[EeveeSpotifyReborn-ng](https://github.com/zbzxbg/EeveeSpotify-ng-latest)（逐字移植）

| 面向 | 旧（本仓库） | 新（Reborn-ng 那套） |
|---|---|---|
| 版本比较 | 按 `.` 切三段的 Int 比较 | `SemanticVersion`（SemVer：`v`/`V` 前缀、`+build` 元数据剥离、预发布标识符按数字/文本混排比较） |
| 请求失败 | `loadVersion() async throws` + `try await`；失败后 `latestVersion` 停在 nil → **永远停在转圈** | 非抛错 + **15 秒超时**；超时 / 失败 / tag 不认识 → `latestVersion = 当前版本`（不提示更新，也不卡住） |
| 提示条件 | `isNewerVersion`（三段比较） | `latest > current`（SemVer 严格大于；预发布版不会被误判为更新） |
| 更新链接 | 上游 `jaydenjcpy/EeveeSpotifyReincarnated/releases` | **本仓库** `zbzxbg/EeveeSpotify-ng-latest/releases` |
| 数据源 | 上游 `repos/jaydenjcpy/…/releases/latest` | **本仓库** `repos/zbzxbg/EeveeSpotify-ng-latest/releases/latest` |
| 日志 | 无 | `[GitHub] GET …` / `[GitHub] … -> N bytes` / `[VersionCheck] Failed to fetch latest release: …` |

**有意保留的差异（本仓库这两处更好）**：

- footer 仍显示 `v<version> (build <buildNumber>)`（Reborn-ng 只显示版本号）；
- `contributors` 的 API 与 `contributors.json` 仍走构建时生成的
  `EeveeSpotify.repoSlug` + `GeneratedConfig.branchName`（Reborn-ng 写死了仓库名和分支 `swift`）
  —— 换分支/换 fork 不用改代码。

**⚠️ 一个预期内的现象**：本仓库的 CI 只出 Actions artifacts、不建 GitHub release，
所以 `releases/latest` 会 404 → 版本检查结论永远是"无更新"（好处是**不会再卡转圈**）。
想让"发现可用更新"真的弹出来，需要在本仓库打一个 tag 化的 release；
或者把 `GitHubHelper.getLatestRelease()` 的 slug 换成真正发 release 的仓库
（那样要连同 `EeveeSettingsVersionView` 里的 `/releases` 链接一起换）。

**未验证**：无编译验证（本机无 Swift 工具链）。

---

## 26. 迁移其它本地化（2026-09-25）：脚本已就位，等一次能跑的 shell

**任务**：把上游 [SideloadLabs/EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated)
`layout/.../EeveeSpotify.bundle` 里除 en / zh-CN 之外的
**25 个 locale**（ar-EG, az, bg, ca, da, de, de-CH, es, fa, fr, hr, hu, it, ja, ko, np, pl, pt,
pt-BR, ro, ru, tr, uk, vi, zh-TW）迁到本仓库。

**为什么不能直接拷**：上游 locale 明显落后于本仓库的 `en.lproj`（例：`ja` 只有 ~100 个键，
本仓库 en 有 230+）。直接拷会同时制造两类 **error**（`TRANSLATING.md` 与 `Tools/l10n_lint.py` 都把
它们判为 error）：MISSING（en 有、locale 没有）与 EXTRA（locale 有、en 已删）。

**做了**：`Tools/migrate_localizations.py`（新增）

- **逐字保留**源 locale 的每一行（注释 / 空行 / 顺序都不动）—— 译文是人的劳动成果；
- 删掉不在 `en.lproj` 里的键（EXTRA）；
- 把 en 有、locale 缺的键用**英文原值**补在文件末尾 `/* AUTO-FILLED (untranslated) */` 块里
  （MISSING；值逐字取自 en，所以运行期就是英文，不会把 key 名显示给用户），
  以后翻译一条就把它挪到上面相应小节；
- 写完**自检**：重新读回目标文件，确认键集与 en 完全一致、无重复键，否则退出码 1；
- 默认**跳过已存在的目标文件**（`--force` 才覆盖）：人工翻译的成果不会被脚本冲掉。

**Info.plist 不用动**：两边都只有 `CFBundleDevelopmentRegion = English`，
iOS 会自动发现新增 `.lproj`（真机上若不出现，再把语言代码加进 `CFBundleLocalizations`）。

**卡在哪**：本会话的 shell 执行器再次故障（`pwsh` 一律 `0xC0000142`，连 `cmd /c` 也起不来），
所以脚本**没能实际运行**。需要执行（任一即可）：

```bash
python Tools/migrate_localizations.py --dry-run   # 先看报告
python Tools/migrate_localizations.py             # 写入 25 个 locale
python Tools/l10n_lint.py --quiet                 # 复核（迁移后应为 0 error）
```

---

## 25. 第十三轮：删除「AMLL 优先」（2026-09-25，用户："感觉没什么用"）

| 位置 | 删掉的内容 |
|---|---|
| `CustomLyrics.x.swift` → `loadCurrentLyricsForCurrentTrack` 的 `else` 分支 | 整段 `if amllPreferred { … }`：先向 AMLL 要逐词歌词，`hasUsableWordLevelData` 不合格就回退到用户选的那个源（并把"请求失败"与"拿到了但不够逐词"分开记日志） |
| `NgzhwmSettingsViewModel` | `amllPreferredKey` + `isAmllPreferred` |
| `EeveeLyricsSettingsViewModel` | `@Published amllPreferred`（含写 UserDefaults 的 `didSet`） |
| `EeveeLyricsSettingsView` | `amllPreferredSection()` 与调用点（原来还带"来源不是 genius / multiLevel / lrclib / amllTtml"的条件） |
| `+setupBindings` | `logBooleanSetting($amllPreferred, …)` |
| `en` / `zh-CN` | `ngzhwm_amll_preferred`、`ngzhwm_amll_preferred_description` |

**保留**：AMLL 仍然是来源选择器里的**普通来源**（`.amllTtml` + `AmllTtmlLyricsRepository` 一行未动），
选了它就只查它（加上可选的 Genius 兜底），与其它来源同一条路。

**顺带修掉一个上一轮埋下的编译错误**：`EeveeLyricsSettingsViewModel.animationValues` 里还列着
已删除的 `amllPreferred` 与已写死启用的 `hideOfficialLyrics` —— 属性都没了，列着就是编译错误
（§23 那次漏掉的），本次一并清掉。

**另一处遗留说明**：`requestSingleSource(allowGeniusFallback:)` 现在没有调用方传 `false`
（唯一那个就是这条被删的链），文档注释已改成如实描述；行为与改动前一致。

**未验证**：无编译验证（本机无 Swift 工具链）。设备上残留的 `ngzhwm_amllPreferred` 键不再被读取（留着无害）。

---

## 24. 本地化同步（2026-09-25）：英文跟上中文那几处改动

中文文件被改过之后，英文同步；现在两个 locale 的 key 集**完全一致**
（lyrics / ngzhwm / UI 三段的键各 42 项）：

| 键 | 中文（用户改的） | 英文（本次） |
|---|---|---|
| `genius_fallback_description` | 前面加"该功能在此版本上体验不佳。"；尾部改为"部分歌曲的**预判**歌词模块会不展示" | "This feature does not work well on this version. If %@ fails to load, lyrics are loaded from Genius. With this option enabled, the **preview** lyrics module may not be displayed for some songs." |
| `ngzhwm_multi_level_fallback_description` | 同样加了"该功能在此版本上体验不佳。" | 同步加上同一句前置 |
| `ngzhwm_lyrics_unavailable_hint` | **删除** | 同步删除（连带下面那处代码改动） |
| `ngzhwm_title` | 中文从来没有 | **删除**：`grep` 全仓库零引用，是死键 |

⚠️ **连带的一处代码改动**（不改就是 bug）：`ngzhwm_lyrics_unavailable_hint` 仍被
`makeUnavailableLyrics` 使用，两个 locale 都删掉之后，`.localized` 会把 **key 名本身**当文案显示。
所以把那一行也删了 —— 占位 payload 从"三行（通知 + 空行 + 提示）"变成"一行（通知）"，
`note` 有值时再追加一行。

要恢复提示：把 `LyricsLineDto(content: "ngzhwm_lyrics_unavailable_hint".localized)` 加回
`makeUnavailableLyrics`，并在 en / zh-CN 两个 `Localizable.strings` 里补回该键。

**顺带一提**：中文那句"预判歌词模块"看着是"预览"的笔误，英文按 **preview** 写。

---

## 23. 第十二轮：三个修复**写死启用**，去掉开关

用户要求（原话）："隐藏官方歌词、补时间轴、补卡片这三个应该就是写在代码里写启用的，而不是靠选项来控制关闭。"

| 原来 | 现在 |
|---|---|
| `isOfficialLyricsHidden`（读 `ngzhwm_hideOfficialLyrics`，默认 true） | 恒 `true`（来源里选「禁用歌词替换」仍是"我要看官方歌词"的正式入口） |
| `isSyntheticLineTimingEnabled`（读 `ngzhwm_syntheticLineTiming`，默认 true） | 恒 `true` |
| `isLyricsCardElementInjectionEnabled`（读 `ngzhwm_injectLyricsCardElement`，**默认 false**） | 恒 `true`（假设已真机验证：补上后卡片出现） |

改动面（都已清干净，`grep` 过没有残留引用）：

- `Settings/ngzhwm/ngzhwmSettingsViewModel.swift`：三个 key 常量删除；三个 getter 改成 `{ true }`，
  文档注明"这是修好的行为，不是可选项"；
- `EeveeLyricsSettingsViewModel`：三个 `@Published` 属性删除（连带写入 UserDefaults 的 `didSet`）；
- `EeveeLyricsSettingsView`：三个 Section 与其调用点删除；
- `+setupBindings`：`logBooleanSetting($hideOfficialLyrics, …)` 删除；
- `en.lproj` / `zh-CN.lproj`：六个键（3 × 标题 + 说明）删除 —— 全仓库只有这两个 locale，保持一致；
- `Tweak.x.swift` 的 `[INIT]` 那行保留：它现在记录的是**实际生效值**（恒 ON）+ 「禁用歌词功能」这个真开关。

**保留为真开关的**：「禁用歌词功能」（`isLyricsFeatureDisabled`）、「更好的逐词歌词」、
「逐词歌词」、来源选择、以及「禁用歌词替换」（`.notReplaced`）。

**未验证**：无编译验证（本机无 Swift 工具链）。三个 getter 变常量后，调用点一行没动
（`if`/`&&` 里的常量会被优化掉）；`shouldModify` 现在对 `scrollsita` 永远返回 true
（会多走一次"缓冲 + 原样回放"），响应只有几百字节，代价可忽略。

---

## 22. 第十一轮：**"原本有逐字的歌突然没有逐字了"** —— 不是数据丢了，是宿主再也挂不上

**先排除数据**：日志 25（NE 源）里三个"有逐字"的歌，仓库侧全都正常返回了逐词数据：

```
[NetEase] eapi /api/song/lyric/v1 → yrc 8854 chars, ytlrc 1072 chars
[NetEase] Word-by-word (yrc) lyrics — 49 line(s)
[AppleMusicLyrics] overlay attached (Apple Music path) host=…CardView     ← 03:18:49，逐词高亮正常
[AppleMusicLyrics] L0 t=0.13 word(6) "Hanabira ga chuu ni uita" …
```

**真正的分水岭是 03:18:57**（切到 `Blue Contrast`，那首 `yrc absent`）：

```
03:18:57 [AppleMusicLyrics] overlay detached
03:18:57 [WordByWord] ⚠️ preview host off-screen (Lyrics_TextElementImpl.LyricsTextView) — will retry
03:18:57 [WordByWord] attach declined — preview host off-screen (likely a recycled cell view) …
… 之后**每 1.5s 一次、再也不成功**，包括 03:19:15 的 SECRET 与 03:19:51 的ただ声一つ（两首都有 yrc）
```

于是屏幕上只剩 Spotify 原生那层（逐行），用户观感就是"**原本有逐字的歌没有逐字了**"。

**根因**（`CustomLyrics+AllTracksLyrics.x.swift` → `InlineLyricsHostLocator.viewHost(in:)`）：
选宿主时用的判据是 `view.window != nil`，并把它当作"真的看得见"**直接 return**。但
**复用中的 cell 仍然持有 window** —— 离屏的复用 cell 因此会被当成命中项返回，
而 `attach` 随后用更严的 `isVisibleOnScreen`（要求中心点在窗口内、≥50% 面积可见）把它拒掉。
两者口径不一致 ⇒ 看门狗每 1.5s 命中同一个离屏宿主、每 1.5s 被拒，**可见那一份永远轮不到**。

**修复**：

1. `viewHost(in:)` 的命中判据升级为 `view.window != nil && WordByWordHost.isVisibleOnScreen(view)`，
   不满足的降级为 `fallback`（继续扫其它候选）；
2. `WordByWordHost.isVisibleOnScreen` 标成 `nonisolated`（纯几何判据），
   否则从非 MainActor 的 `InlineLyricsHostLocator` 调用是编译错误。

**待验证**：切到"没有逐字"的歌再切回"有逐字"的歌，逐词高亮应当照常回来
（而不是永久退化成原生逐行）；日志里 `attach declined — preview host off-screen` 不应再无休止刷。

---

## 21. 第十轮：那张"很怪的全屏"是什么 + 译文到底哪来的

**照片 `10-49-29`（全屏）的判读**：

- 画面上**有中文译文** → 这本身就是判据：译文来自歌词源（网易云 / PL 的 tlyric），保存在
  `currentLyricsDto.translation` 里，而**只有旧层全屏会画它**（`showsTranslation`：全屏 true / 预览 false）。
- 日志 24 同一时段的实锤：
  `[WordByWord] legacy overlay attached — host=UIView 414x896 shell=true sideInset=24 level=line`
  + `[Shell] legacy metadata "Moderate (feat. wanko)" — "MIMI"`
  → 全屏那一刻用的是**旧层**，而且是**行级**（同一批日志里 `word-level judge: 0/43 … word-level=N`，
  即 NetEase 对这几首只给了 lrc）。

所以"没有关闭键 / 没有歌手歌名 / 按键太靠下"不是我们的层坏了，而是**旧层全屏那套壳布局**
（标题栏贴在 overlay 顶部、底部是它自己的进度条 + 三键），与 AM 页那套（标题/歌手/关闭/底部控件）
本来就不是一个样子。这也正好解释了"看起来很奇怪"。

**译文从哪来（回答"我记得我还没接歌词翻译"）**：

- 源的译文一直在数据里，旧层全屏会按行画出来（预览不画）；
- 注入给 Spotify 的那份 protobuf **只在关闭「更好的逐词歌词」时才带译文**：

```swift
// LyricsDto.toSpotifyLyricsData
let suppliesTranslation = !NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled
```

  原因写在注释里：Spotify 只要看到注入数据里有 translation，就会在「歌词」标题栏亮起它自己的
  **翻译按钮**，而 AM 页并不显示译文 —— 按钮点了什么都不会变，纯属误导。

  ⇒ 所以"AM 开着还能看到译文"这件事，反过来正好证明**那一刻用的是旧层** ✔

**§20 的正确读法（该节曾改错并回退）**：**行级数据本来就该走旧层、用 Spotify 默认色**；
那张"怪全屏"是旧层的全屏外壳（标题栏贴 overlay 顶部、底部是它自己的进度条 + 三键），
它看起来"怪"只是因为**它跟 AM 页不是同一套壳** —— 这是设计，不是 bug。
真正要修的只有它**没有把标题/歌手/关闭画出来**那一层（若新构建后仍缺，按 §17 的两个候选查：
"划动收起壳"状态 / 宿主挂错）。

**关于"预览显示上首歌的译文"**：那还是 §18 的陈旧行模型（预览里 `showsTranslation=false`，
所以你看到的"译文"其实是上一首的**罗马化歌词行**，看起来像译文）。§18 的"切歌即清 + 渲染前比对曲目"
正是针对它。

---

## 20. 第九轮：**"内容逐行、壳/背景却是逐词那一套"** —— 闸门收错了

**先回答"是不是有两套逻辑"**：是，确实有**两套渲染器**，壳组件是共用的：

| | Apple Music 页 | 旧 UIKit 层 |
|---|---|---|
| 代码 | `AppleMusicLyricsPage` / `AppleMusicLyricsOverlay` | `LyricsWordByWordOverlayView` |
| 何时用（改前） | 「更好的逐词歌词」开 **且 `hasUsableWordLevelData`（≥50% 行有逐字时间轴）** | 其它情况（只有行级时间轴时就是它） |
| 壳 | `LyricsShellChrome`（标题/歌手/关闭/进度） | **同一份** `LyricsShellChrome`（`LyricsShellHosts` 挂进去） |

所以"两套逻辑"只在**渲染歌词**那部分，壳是共享的 —— 这正是它们看起来相似、却又在细节上对不上的原因。

**症状**：某些来源（只有行级时间轴的那批）出现"**内容逐行、背景与壳却是普通逐词那一套**"。

**根因**：AM 页的闸门用的是**逐字**判据 `usable`，可它自己**本来就支持只有行级时间轴的数据**：

- `SynchronizedLyricText.resolvedText`：`syllables.isEmpty` → 退回普通文本（有渲染低档）；
- `LyricLine.makePseudoSyllables()`：注释原话"均匀按「字」拆分整行时长，**用于没有逐字时间轴的来源（LRCLIB / Genius 等）**"。

**这一轮改错了，已回退（同日）**：我把闸门放宽到行级，结果是"**逐行歌词也套上了 AM 的透明化专辑底**"，
真机反馈原话："怎么逐行歌词的背景变成 am 的了"。

**产品规则（以此为契约，别再放宽）**：

| 条件 | 渲染层 | 背景 |
|---|---|---|
| 「更好的逐词歌词」开 **且** 来源给了**逐词**数据 | Apple Music 页 | 透明化专辑（AM 底） |
| 普通逐词（AM 关，有逐词数据） | 旧层 | **Spotify 自己的默认颜色** |
| 逐行（来源只给行级时间轴） | 旧层 | **Spotify 自己的默认颜色** |

回退点：`WordByWordHost.attach` 的 AM 分支判据回到 `usable`；
`refreshForCurrentLyrics()` 里"全屏层掉了要补挂"的条件回到 `hasUsableWordLevelData`。

**顺带记一笔**：AM 页**确实**能渲染行级数据（`SynchronizedLyricText` 有普通文本回退、
`makePseudoSyllables()` 就是给 LRCLIB / Genius 这类无逐字源用的）—— 但"能渲染"不等于"该用"，
按上面的规则，行级一律走旧层（这也意味着旧层不能退化：它的背景必须是 Spotify 默认色）。

---

## 19. 第八轮：「禁用歌词功能」不生效（两条投递路径都绕过了它）

**选项说明原话**（`ngzhwm_disable_lyrics_feature_description`）："开启后会禁用有关于自定义歌词的
所有功能，**还会阻止 Spotify 返回其自带的歌词**"。

**改前的实际行为**：只有 `getLyricsDataForCurrentTrack` 里那句
`guard !isLyricsFeatureDisabled else { resetWordByWordLyrics(); throw .invalidSource }` 生效，
而两条投递路径把它整个绕过去了：

| 路径 | 改前 | 结果 |
|---|---|---|
| 完成回调（200 那条） | 取词抛错 → `customLyricsData == nil` → `lyricsPayload = buffer` | **Spotify 自带歌词原样放行** → "阻止…"完全没做到 |
| 404 响应（`didReceiveResponse`） | **无条件**合成 200 + `unavailableLyricsBytes` | 开关开着也照样出现我们那份"未找到歌词" |

再叠加 §6/§10 的元素注入（每首歌都有卡片），开关打开后界面照旧有歌词/卡片 —— 观感就是"不生效"。

**修复**：

1. `SpotifyResponsePatcher` 新增 `isLyricsFeatureDisabled` 与 `disabledLyricsPayload(original:)`；
2. 两个钩子（`HttpClientURLSessionHooks` / `DataLoaderServiceHooks`）的 `url.isLyrics` 分支**开头**：
   禁用 → 直接交"没有歌词"的占位（**主动挡住 Spotify 自带歌词**），也不再发起我们的取词；
   日志 `lyrics feature disabled — blocking Spotify's own lyrics`；
3. 两个钩子的 404 分支：禁用 → **放行原始 404**（不取词、不合成），
   日志 `lyrics feature disabled — passing the 404 through`；
4. `ScrollsitaLyricsElementInjector.strippingLyricsElementIfNeeded`：禁用时把服务端下发的
   歌词卡片元素**摘掉**（`shouldModify` 相应把这种 URL 纳入改写范围）—— 否则卡片还在，
   只是内容变成"未找到歌词"，仍然像"没生效"。

**验证**：

- 打开「禁用歌词功能」→ 播一首 Spotify 有官方歌词的歌：**不应**再显示官方歌词（改前照旧显示）；
- 再播一首服务端没下发歌词元素的歌：**不应**再有歌词卡片（元素被摘掉）；
- 关掉开关 → 一切恢复。

**未验证**：无编译验证、无真机验证。

---

## 18. 第七轮：切歌瞬间"预览显示上一首逐词歌词"（PL / MXM / AMLL 三个源都能复现）

**症状**：切歌后，预览（卡片）里显示的是**上一首歌**的逐词歌词；窗口长度 ≈ 取词耗时 ——
PL / MXM 是两次请求、AMLL 要先取 TTML，所以三个源都明显。**与来源无关**这一点本身就说明
问题不在任何仓库里。

**根因**：我们这层的行模型只在 `currentLyricsVersion` 变化后重建，而那个版本号是随
**歌词数据**自增的 —— 切歌到新词到达之间，"歌换了"在我们这层里**根本不可见**；
此时卡片/全屏的壳可能已经换成新歌，我们却把上一首的行模型盖在上面。

**修复（两层，互相兜底）**：

1. **尽早清**（`CustomLyrics.x.swift` → `getLyricsDataForCurrentTrack`）：
   用曲目 id 当切歌信号，命中即 `resetWordByWordLyrics(reason: "track changed (<id>)")` ——
   该方法会摘掉新旧两层 + 清空 dto，看门狗的行级判据随之变假，**不会**拿旧数据把层挂回来。
   日志：`[Lyrics] track changed (<id>) — clearing word-by-word layer`。
2. **渲染前兜底**（`AppleMusicLyricsOverlay.swift`）：行模型带上曲目 id
   （`currentModelTrackId`，重建模型时记下），`update()` 与**每帧** `tick()` 都比对当前播放曲目，
   不是这一首就 `detach()`（`hasForeignLineModel`）。这条兜住"客户端缓存命中、根本没有新请求"
   那种情况；`update()` 里也拒绝重挂，所以不会与看门狗形成 1.5s 的闪烁循环。
   日志：`[AppleMusicLyrics] line model belongs to another track — detaching`。

**注意一个既有守卫**（所以不会出现"把 A 的词当成 B 的"）：`getLyricsDataForCurrentTrack` 里本来
就有 `trackMismatch` 检查 —— 迟到的旧曲目响应会被判 mismatch、**不写入 dto**（改交占位），
因此"上一首的 dto 被盖上当前曲目的 id"这条路不存在。

**设计取舍**：间隙期我们**什么都不画**，露出来的是原生层（Spotify 渲染我们注入的 payload）——
它的内容是正确的，比挂一份别人的行模型好；新词一到（版本号自增）AM 层立刻回来。

**未验证**：无编译验证、无真机验证。

---

## 17. 第六轮：全屏"小概率逐行" + 退出后"永久逐行"（PL 源 + AM 层）

先说架构（用户提问确认过）：AM 层是**覆盖层** —— 自己一条 `UIHostingController` 视图挂到
卡片容器/全屏 vc.view 上、每帧 `bringSubviewToFront`，原生歌词层原样留在下面
（"接管原生视图"那条路被真机否掉过）。所以**原生层跟着每首 payload 走、内容是对的**，
而我们这层的行模型只在 `currentLyricsVersion` 变化后被 `update()` 重建。

### 17.1 全屏开着、我们的层却没挂上 → 层被挂到了全屏底下的卡片

成因链：全屏页出现时歌词还在路上（PL 是两次请求的源，更容易撞上）→
`viewWillAppear` / `viewDidAppear` 两次 `attach` 都因"连行级数据都没有"落空 →
歌词到达时 `refreshForCurrentLyrics()` 里 `isAttached && attachedShowsProviderFooter` 为假 →
代码掉进**预览**分支，把层挂到全屏底下那页的卡片上 → 全屏整场停在原生逐行 + 专辑色背景。

**修复**（`LyricsWordByWord.x.swift` → `refreshForCurrentLyrics`）：在预览分支**之前**加一段
"全屏页开着但我们的层没挂上 → 挂回全屏"。判据不新增状态 —— `fullscreenController` 是弱引用，
且**在 `attach` 开头就记好了**（早于数据判据），所以"它在窗口里、且不在消失中"就等于全屏开着：

```swift
if !isAttached, let controller = fullscreenController,
   controller.isViewLoaded, controller.view.window != nil,
   !controller.isBeingDismissed, !controller.isMovingFromParent { attach(... showsProviderFooter: true) }
```

日志：`[WordByWord] fullscreen is open but our layer is missing — attaching there`

### 17.2 退出全屏后**永久**退化（点了几下歌词行之后，切歌也一样）

成因：`WordByWordHost.isAttached` / `attachedShowsProviderFooter` 是**纯布尔**，
只有我们自己调 `detach()` 时才清。全屏 VC 被拆掉 / `viewWillDisappear` 没赶上时它会残留成
"全屏还挂着"，而看门狗的闸门就是 `guard !fullscreenOverlayIsAttached else { return }`
（`CustomLyrics+AllTracksLyrics.swift`）→ **预览层再也挂不回来**，切歌也一样，重启才恢复。
这正好对上"点了几下歌词行再退出 → 预览与后续每一首都逐行"。

**修复**：

- `WordByWordHost.clearStaleAttachmentIfNeeded()`：标记说挂着、但那一层**不在任何窗口里**时清掉
  （判据与既有的 `inlineOverlayIsLive` **同源**，所以不会误伤"真的全屏中"）→
  日志 `[WordByWord] stale attachment cleared — the layer is not in any window (wasFullscreen=…)`；
- 看门狗 `tick()` 在闸门**之前**调它 → 残留最多 1.5s（一个心跳）自愈。

### 17.3 还有一种"逐行"是**设计如此**，不是 bug

`hasUsableWordLevelData` 要求 **≥50% 的行**带逐词时间轴。PL / 网易云对一部分歌只给行级（lrc）、
或词级数据不足，这时代码**故意**降级成"逐行 + 当前行整行点亮"（走旧层；在
`displayOriginalColors = true` 时，旧层的背景就是**专辑纯色** —— 所以"逐行 + 专辑色背景"
这个组合本身就是旧层的正常样子）。判据日志是
`[WordByWord] word-level judge: … word-level=N`。

### 17.4 复现时看这三行就能分开 17.1 / 17.2 / 17.3

| 现象 | 判据 |
|---|---|
| 数据不够（设计内降级） | `[WordByWord] word-level judge: … word-level=N` |
| 走了旧层（17.1 或 17.3） | `[WordByWord] legacy overlay attached … level=line` |
| 残留标记卡死（17.2） | 退出全屏后切歌，**既没有** `[AppleMusicLyrics] overlay attached`，也**没有** `legacy overlay attached`，而 `word-level=Y`；修复后应能看到 `stale attachment cleared` |

### 17.5 未验证

两处改动**没有编译验证**（本机无 Swift 工具链），也**没有真机验证**。
`isBeingDismissed` / `isMovingFromParent` 在 sheet 关闭动画期间的行为需要真机确认 ——
若动画期间被误判成"全屏还开着"，表现只会是退出动画里闪一下，不会卡死（`attach` 自带 `detach` 前序）。

---

## 16. 历史遗留（原 §9/§11/§13，位置随追加而后移）

- ~~§0 的"两个面互斥、合成时间轴把卡片挤掉"~~ → **作废**，见 §7.3/§7.4：无时间轴并不产生卡片，
  真正决定卡片存在性的是服务端的元素列表；
- `enable_has_lyrics_check_bypass` 那一枪**确认是空的**（服务端根本不下发这个名字，§7.2），
  但代码里的两条 `setBool` 可以留着（无害 no-op），不必再动；
- 启动崩溃（两份 `.ips` 同一地址）仍与歌词问题无关，真机验证前别叠加新 hook。
