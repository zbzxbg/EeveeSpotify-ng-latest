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
