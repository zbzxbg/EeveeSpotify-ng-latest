# 歌词模块不展示：真因已定位（三组实测日志）

**状态**：两个独立问题的机制**均已定位**；其中问题 B 的修复代码**已存在于工作区但从未提交/编译/验证**。
**数据来源**：`C:\dsh\readlog\eeveespotify_debug.log`、`... 2 (2).log`、`... 3.log`（2026-09-24）。

---

## 0. 结论（先看这里）

**这不是一个问题，是两个。**

| | 问题 A：响应被按住 | 问题 B：模块不出现 |
|---|---|---|
| 现象 | 整页模块**一起延迟**出现 | 这首歌**完全没有**歌词模块 |
| 触发条件 | 取词链耗时长（AMLL TLS 重试 ~11 秒） | payload **没有时间轴**（`timeSynchronized = false`，每行 `offsetMs = 0`） |
| 实测 | 日志 1/2：请求 → 占位，**14 秒** | 日志 3：响应 **~1 秒**，payload 已注入，**模块照样不出现** |
| 缓解 | 关掉「AMLL 优先」→ 实测降到 ~1 秒 | **合成行级时间轴**（代码已存在，未提交） |

**关键**：关掉 AMLL 之后延迟问题解决了，**模块问题一点没动**。
所以问题 B 才是"有些歌不展示歌词模块"的正主，而它的修复**从来没被测过**。

**门控假说：结案。** 日志 3 里播放 3 首，**3 首全部有歌词请求**，每首还请求了两次。

---

## 1. 日志 3 的证据（「AMLL 优先」已关闭，旧构建）

| 曲目 | NetEase 结果 | 时间轴 | 耗时 | 模块 |
|---|---|---|---|---|
| `5utfun3R35e5AsBalPSxBe`「最後の希望」 | 若无词 → **Unsynced lyrics fallback（7 行）** | ❌ 全 nil | ~1s | 无 |
| `4EYOrgyfbSGus6sPyAiY6f`「Jersey」 | **Instrumental — returning empty lyrics** → 占位 3 行 | ❌ 全 nil | ~1s | 无 |
| `0GieVByHRrOdpA6U8SFl1J`「BAILA CONMIGO」 | No usable lyrics → **serving our placeholder** | ❌ 全 nil | ~1s | 无 |

三首走的是**三条完全不同的代码路径**（无时间轴歌词 / 纯音乐占位 / 取词失败占位），
但**唯一共同点**就是：`timeSynchronized = false` 且每行 `offsetMs = 0`。

**这是目前最强的证据**：三条互不相关的失败路径，收敛到同一个 payload 特征。

### 与日志 1/2 的对照

日志 1/2 里「AMLL 优先」是开的，失败样本（Bridge Between Us）：
请求 08:47:15 → 占位 08:47:29，**14 秒**，其中 11 秒是 `api.amll.dev` TLS 重试
（`-1200 / -9816`，`interface: utun5`，两次握手超时，退避仅 0.5 秒）。

→ 那一组暴露的是**问题 A**；日志 3 关掉 AMLL 后，**问题 A 消失、问题 B 显形**。

---

## 2. 代码证据

**NetEase 的无时间轴分支**（`NeteaseLyricsRepository.swift:926-934`）：

```swift
fallbackLines.append(LyricsLineDto(content: content, offsetMs: nil))   // 每行 nil
...
timeSynced = false
writeDebugLog("[NetEase] Unsynced lyrics fallback (\(lines.count) line(s))")
```

**旧构建的 `toSpotifyLyricsData`** 直接 `$0.timeSynchronized = timeSynced`，
行 offset 取 `line.offsetMs ?? 0` → 整份 payload 无时间轴。

> ⚠️ **一句会骗人的日志**：`NeteaseLyricsRepository.swift:1030` 的
> `[NetEase] Synced lyrics — N line(s)` 是**无条件打印**的，`timeSynced = false` 时也照打。
> 所以日志里会同时出现 "Unsynced lyrics fallback" 和 "Synced lyrics"。
> 判断有没有时间轴**不要看这一行**，看有没有 `Unsynced lyrics fallback` /
> `synthetic line timing applied`。

> ⚠️ **另一个确认**：`synthetic line timing` 在**全部三份日志里一次都没出现** →
> 被测构建不含 `SyntheticLyricTiming`（与你说的"那些更改没提交测试"一致）。

---

## 3. 下一步：只有一件事

**把工作区里那份未提交的改动编译出来，用同样这三首歌复测。**

理由：问题 B 的修复就是它，而它从未编译、从未上机。

**复测判据（三条都要看）**：

1. 日志里出现 `[Lyrics] synthetic line timing applied — N line(s), duration=...ms, lastOffset=...ms`；
2. 同样的三首歌，**歌词模块出现**（最差显示"未找到歌词"）；
3. 已经关闭的「AMLL 优先」**保持关闭**（问题 A 的缓解别退回去）。

**如果复测后模块仍不出现** → 说明"无时间轴 → 不建模块"这条仍然只是相关性，
那时再回到 payload 之外去找（Swift 层门控 / 服务端实验），并考虑第 5 节的兜底方案。

---

## 4. 之后要做的（按收益排序）

1. **去掉 `didCompleteWithError` 里的同步等待**（`DataLoaderServiceHooks.x.swift`）
   —— 先立刻答缓存/占位，后台再取。问题 A 的根治。
2. **回退链快速失败**：对"网络层不通"类错误（TLS/超时）不要重试，
   AMLL 那种两次握手各 5 秒、退避 0.5 秒的设计纯属浪费。
3. **预取 + 缓存**：把网络请求移出响应路径（当前完全没有预取）。
4. **自绘兜底**（纵深防御）：把预览层的锚点从"歌词卡片容器"放宽到"正在播放页"，
   仅在检测不到卡片时启用。能力已存在（`AppleMusicLyricsOverlay` / `PreviewShell`），
   现在被 `card == nil → 拒绝挂载` 主动关掉了（`LyricsWordByWord.x.swift:1697-1709`）。

---

## 5. 仍未被解释 / 不能排除的

- ⚠️ **"无时间轴 → Spotify 不建模块"依然是相关性，不是已证事实**。
  日志 3 给出了 3/3 的一致证据，但没有判定性实验。
  **第 3 节的复测就是这个实验**：如果补上时间轴后模块出现，假设成立；否则推翻。
- ⚠️ **门控假说未穷尽排除**，但已无任何支持证据：日志 3 的 3/3 全部有请求。
  此前怀疑的 `7dUKNjRiLxS2OXRldCIjH4`（日志 2 开头，无请求）更像是日志窗口边界产物。
- ⚠️ 每首歌被请求**两次**（间隔约 1 秒），原因未查明。
  第二次总是命中缓存，所以不是性能问题，但可能说明有两个消费者（卡片 / 全屏）。

---

## 6. 已作废 / 修正的结论

- ❌ **"延迟是主因"**（本文上一版）—— 修正为"问题 A，独立且已缓解；
  模块不出现是问题 B"。关掉 AMLL 后延迟正常而模块依旧不出现，是决定性反例。
- ❌ **门控假说**（更早版本列为"权重最高"）—— 结案，见第 0 节。
- ❌ `LYRICS_MODULE_FINDINGS.md` 里的歌曲 ID `1GS3H8cVOmaTDM32X35GGu` 是**笔误**，
  实际为 `1GS3H8cVOmaTDM32X35GQu`（结尾 **u**）。检索请用带 u 的 ID。
- ⚠️ `LYRICS_MODULE_FINDINGS.md` 证据 4 的"无时间轴 → 模块不出现"**现在有了较强支持**，
  但仍需第 3 节的复测来定论。

---

## 7. 本轮代码改动：移除运行时类名探针

`Sources/EeveeSpotify/Tweak.x.swift` 里的运行时探针
（`eeveeTrackProbeEnabled` / `schedulePlayerTrackProbeIfEnabled` / `logPlayerTrackCandidates`）
已整段删除。前两条是**致命编译错误**：

1. 重复声明了 `struct EeveeSpotify: Tweak`（原文同时存在两处）；
2. 引用了**已不存在**的 `trackProbeNamePrefixes` —— 早先 `strip_probe_block.py`
   那次"误伤"删掉了定义、留下了引用；
3. 它连续两次造成启动崩溃（EXC_BREAKPOINT/SIGTRAP，见 `Tweak.x.swift:239-257` 留存的说明）。

同步移除支撑代码：`UserDefaults.enableTrackProbe`（含 key）、设置界面开关、
`en` / `zh-CN` 两条本地化文案。

> ⚠️ **本次改动未经编译验证**：会话内 shell 执行器故障（`0xC0000142`），无法 `swift build`。
> 改动全部是删除，已用 grep 确认无残留引用，括号平衡已人工核对，但仍需一次真实构建确认。

---

## 8. `Tools/eevee-hookfinder/` 脚本：现在不需要跑

门控假说已结案，这些脚本（`find_player_track_class.py`、`extract_player_track_class.py`、
`audit_lyrics_gate.py`、`find_lyrics_gate.py`）回答的都是"门控在哪"，**当前没有目标**。
留着备查；运行它们需要 `C:\dsh\ipa\` 下那份 9.1.86 解密 IPA（仍在）。

`strip_probe_block.py` 任务已完成，**可以删**。
