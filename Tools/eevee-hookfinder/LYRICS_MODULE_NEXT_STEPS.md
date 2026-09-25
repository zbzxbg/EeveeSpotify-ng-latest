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

## 13. 历史遗留（原 §9/§11，位置随追加而后移）

- ~~§0 的"两个面互斥、合成时间轴把卡片挤掉"~~ → **作废**，见 §7.3/§7.4：无时间轴并不产生卡片，
  真正决定卡片存在性的是服务端的元素列表；
- `enable_has_lyrics_check_bypass` 那一枪**确认是空的**（服务端根本不下发这个名字，§7.2），
  但代码里的两条 `setBool` 可以留着（无害 no-op），不必再动；
- 启动崩溃（两份 `.ips` 同一地址）仍与歌词问题无关，真机验证前别叠加新 hook。
