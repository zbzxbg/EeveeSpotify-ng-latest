# 歌词模块：面 A 已修复；面 B 的门控不在 ObjC 侧

**数据**：`C:\dsh\readlog\eeveespotify_debug{ 2 (2), 3 … 10}.log`（2026-09-24）

---

## 0. 结论（先看这里）

**Spotify 有两个独立的"歌词面"，必须分开谈。**

| | 面 A：单行歌词 | 面 B：歌词预览卡片（**目标**） |
|---|---|---|
| 位置 | 封面与歌名**之间** | 与**「关于艺人」并列** |
| 类名 | `Lyrics_TextComponentImpl.LyricsView` | `Lyrics_CardElementImpl.CardView` |
| 判据 | **数据驱动**：payload 有行级时间轴就建 | **另有门控，且在纯 Swift 内部** |
| 现状 | ✅ **已修复**（合成时间轴，干净 A/B 证实） | ❌ **仍未解决** |

**面 B 的门控已排除 `has_lyrics`。** 详见第 2 节 —— 这是本轮最重要的否定结果。

---

## 1. 面 A：已修复（实测 A/B，已证实）

| | 合成**开**（日志 6） | 合成**关**（日志 7） |
|---|---|---|
| Jersey 注入 payload | 3 行占位 + 合成时间轴 | 3 行占位，无时间轴 |
| 日志 | `synthetic line timing applied — 3 line(s), duration=150000ms, lastOffset=112500ms` | （无） |
| **面 A** | ✅ `inline host found: Lyrics_TextComponentImpl.LyricsView` | ❌ `inline host not found` |
| 肉眼 | 显示**纯音乐** | 什么都不显示 |

**用户确认**：合成关时三首**均无**面 A；合成开时三首**都有**
（可滚动歌词 / 纯音乐 / 未找到歌词）—— 内容全部来自**我们注入的 payload**。

→ 顺带证明：**注入通路完全正常**，payload 被 Spotify 正常接收解析。
→ 取证报告证据 4 的"无时间轴 → 判为不可用"**由此证实**（在面 A 上）。

---

## 2. 面 B：门控**不是** `has_lyrics`（本轮决定性否定结果）

`SPTPlayerTrackHook.metadata()` 是 whoeevee 时代用来"让每首歌都有歌词模块"的覆写，
它把 `has_lyrics` 强行写成 `"true"`。本轮把它彻底验了：

| 问题 | 实测答案 | 出处 |
|---|---|---|
| 类和方法存在吗？ | **存在** —— `[INIT] SPTPlayerTrack: metadata=true URI=true` | 日志 8/9/10 §INIT |
| 覆写**被调用**吗？ | **被调用** —— 数百行 `[TrackHook] metadata() called` | 日志 9/10 |
| Spotify 给的原始值？ | 失败曲目 `spotify:track:5utfun3R35e5AsBalPSxBe` ⇒ **`false`** | 日志 9/10 |
| 覆写生效后，面 B 出现吗？ | **不出现** —— 面 B 依然只有 SECRET | 日志 9/10 |

> **结论**：覆写每次都返回 `has_lyrics = "true"`，面 B 却依然不出现
> ⇒ **面 B 的门控读的不是这个键，也不是通过 `metadata()` 这个 getter 读的。**

**与取证报告证据 6 完全一致**：面 B 那批组件（`Lyrics_CardElementImpl` 等）是
**纯 Swift 静态派发**，ObjC 运行时里没有选择器。我们的 ObjC getter 覆写改的是
"返回给 ObjC 调用方的字典"，而门控读的是 **Swift 内部字段** —— 两条通路，改不到。

**所以：通过 hook 强行打开面 B 这条路，判死。**

---

## 3. 下一步：去**线上**改，而不是在客户端改

`has_lyrics` 出现在一个 `[String: String]` 字典里，同字典里还有
`image_url` / `title` / `duration` / `popularity` —— **这些都是服务端下发的**。
取证时在 IPA 的 `__cstring` 里搜不到 `has_lyrics`，也符合"键名来自服务端"。

**如果它在线上，就能在响应里改** —— 那样 Swift 解析出来的字段一开始就是 `true`，
门控自然通过。这跟 hook getter 是两回事。

**探针**：`SpotifyResponsePatcher.probeHasLyricsKey`（两个 URLSession 钩子的
`didReceiveData` 里各调一次）。扫 `has_lyrics` / `hasLyrics` 两种拼法，
**只读、只打日志、不改字节**。

### ⚠️ 探针必须带**存活信号**（日志 10 的教训）

第一版只在命中时打日志，于是**空日志无法区分"不在线上"和"根本没编进包里"** ——
日志 10 就卡在这里，白跑一轮。现在补了三条：

```
[HasLyricsProbe] active — scanning response chunks      ← 证明探针活着（一次）
[HasLyricsProbe] seen path=/…                           ← 扫过的端点（最多 40 条）
[HasLyricsProbe] scanned=N chunks, hits=M               ← 每 500 块一次心跳
[HasLyricsProbe] HIT — host=… path=…                    ← 命中
```

**判读**：

| 观察 | 结论 | 下一步 |
|---|---|---|
| 有 `HIT` | `has_lyrics` 是服务端下发的 | 在 `SpotifyResponsePatcher` 里把它改成 `true` → **面 B 每首歌原生出现** |
| 有 `active`/`seen` 但无 `HIT` | 覆盖到了真实流量，确实不在 HTTP 响应里 | 转**自绘兜底**（第 4 节） |
| 连 `active` 都没有 | 探针没进构建 | 先确认包是最新的 |

---

## 4. 兜底方案：自己画面 B（保底能拿到"每首歌都有模块"）

已有整套自绘层（`AppleMusicLyricsOverlay` / `PreviewShell`），**唯一障碍**是它在
找不到原生卡片时**主动拒绝挂载**（日志 9/10 里真实出现）：

```
[PreviewShell] ⚠️ no card container found — caller falls back to the content view
[WordByWord] attach declined — preview host rejected: no card container and this is a foreign Lyrics-named view
```

把这条规则放宽成"找不到卡片就挂到正在播放页上"，面 B 就每首歌都有了 ——
**不依赖 Spotify 的任何门控**。代价是布局要跟着 NPV 走、点击要接自己的全屏页。

---

## 5. 日志清单（务必按版本区分）

| 日志 | Spotify | 条件 | 结论 |
|---|---|---|---|
| 1 / 2 | 9.1.86 | AMLL 优先开 | 14 秒阻塞（`api.amll.dev` TLS 重试 11 秒） |
| 3 | 9.1.86 | AMLL 关，旧构建 | 三首**有**请求 |
| 4 / 5 | **9.1.6** | 合成开 / 关 | 三首**无**请求 → 门控是 9.1.6 特有 |
| **6 / 7** | 9.1.86 | 合成开 / 关 | **有效 A/B → 面 A 修复被证实** |
| 8 | 9.1.86 | 合成开 | `SPTPlayerTrack: metadata=true URI=true` |
| 9 | 9.1.86 | 合成开 | 覆写被调用；面 B 仍不出现 → **H1 否** |
| 10 | 9.1.86 | 合成开 | 探针无输出（但**无法区分**没命中/没构建） |

> ⚠️ **日志 3 vs 4/5 不是有效 A/B** —— Spotify 版本不同。
> 版本由 `build-ipa-with-orion.yml` 的 `ipa_url` 输入决定，工作流**不下载也不校验**。
> 建议加 `expected_spot_version` 断言，避免再次静默换版本。

---

## 6. 其他已查明 / 已作废

- **"每首歌请求两次"已解开**：第二次的 URL 多带 **`vocalRemoval=true`**。
  日志只打 `url.path`，把 query 吃掉了才显得一样。
- **AMLL 优先务必保持关闭**：`api.amll.dev` 两次 TLS 超时 = 11 秒纯浪费，响应被按住 14 秒。
- ❌ 作废：**H1（面 B 由 `metadata()["has_lyrics"]` 决定）** —— 第 2 节证伪。
- ❌ 作废：**"延迟是模块不出现的（唯一）主因"** —— 关掉 AMLL 后延迟正常，模块依旧不出现。
- ❌ 作废：**"门控假说"**（曾列为"权重最高"）—— 9.1.86 上不成立；仅 9.1.6 观察到。
- ❌ 作废：**"日志 3 vs 4/5 说明构建引入了门控回归"** —— 版本不同，对照无效。
- ❌ 笔误：`LYRICS_MODULE_FINDINGS.md` 里的 ID `1GS3H8cVOmaTDM32X35GGu` 应为
  `1GS3H8cVOmaTDM32X35GQu`（结尾 **u**）。

---

## 7. 已清理的诊断日志

以下探针已完成使命并**移除**（避免以后每份日志被刷几百行）：

| 位置 | 状态 |
|---|---|
| `SPTPlayerTrackHook.metadata()` 里的 `[TrackHook]` 逐次打印 | **已移除**（`metadata()` 在热路径上，且去重用的全局变量无锁） |
| `LyricsBackdropArtworkView` 的逐首 `has_lyrics` dump | **已还原**为一次性 keys dump（那里读到的是覆写**之后**的值，会误导） |
| `Tweak.x.swift` 的 `[INIT] SPTPlayerTrack: metadata=…` | **保留**（启动期一条，成本低、信息量大） |
| `SpotifyResponsePatcher.probeHasLyricsKey` | **保留**，等线上结论出来后一并清理 |

---

## 8. 代码改动与风险记录

- 移除运行时类名探针（`Tweak.x.swift`）—— 前两条是**致命编译错误**：重复声明
  `struct EeveeSpotify: Tweak`；引用已不存在的 `trackProbeNamePrefixes`。
- **两次括号事故**（均修复）：删探针 Toggle 时多删了 `Section` 的闭括号；
  删调用点时多删了一个 `}`。**在没有编译器的会话里改括号密集区域必须逐处复核** ——
  `edit` 只做字面替换，不校验结构。
- ⚠️ **多轮改动从未编译验证**（会话内 shell 执行器故障 `0xC0000142`）。
  每次都要靠 CI / 本地构建来裁决。

---

## 9. `Tools/eevee-hookfinder/` 脚本

门控假说在 9.1.86 上已不成立，这些脚本当前没有目标，**先不跑**，留着备查。
运行需要 `C:\dsh\ipa\` 下那份 9.1.86 解密 IPA（仍在）。
`strip_probe_block.py` 任务已完成，可删。
