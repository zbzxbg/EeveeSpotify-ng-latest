# Changelog

## 2026-09-18 — 合并基线：Reincarnated 底座 + Reborn-ng 歌词

本仓库此前的源码与 `EeveeSpotifyReborn-ng` 逐字节相同，本次按下列规则完成合并。

### 底座
全部代码换为 `SideloadLabs/EeveeSpotifyReincarnated`：SponsorBlock、App Icon、
真实随机播放（TrueShuffle）、覆盖配置（overwriteConfiguration）、广告/推广拦截、
会话保护（SessionProtection）、彻底重置（FullResetHelper）、27 种语言本地化、
`Tests/`、`Tools/`、`build-ipa-local.sh` / `setup-build-ipa.sh` 等全部保留。

### 歌词：全部按 EeveeSpotifyReborn-ng
- 覆盖 `Sources/EeveeSpotify/Lyrics/**` 与 `Settings/Sections/Lyrics/**`：
  NetEase、AMLL TTML、multiLevel 多级回退、Apple Music 风格逐词歌词、罗马音中文/日文/韩文三个开关。
- 删除 B 的 Karaoke 模块与其设置项（`Sources/EeveeSpotify/Karaoke/**`、
  `KaraokeLyricsDto`、`KaraokeLyricsStore`、`KaraokeOptions*`，以及 Makefile 里的
  Metal shader 编译步骤）——逐词歌词统一由 ng 的实现提供。
- 删除「展示回退原因」（`show_fallback_reasons`）的代码、选项与全部 27 份文案。
- 保留 B 的 `LyricsUncensorFill`（SpicyLyrics 星号消音回填）。
- **genius 回退默认值由开启改为关闭。**

### 调试 / 日志：全部按 EeveeSpotifyReborn-ng
- `writeDebugLog` 换成 ng 实现：受「启用日志记录」开关控制，关闭时不写统一日志、不写导出文件；
  新增配套的 `writeErrorLog`（`.error` 级 + `[ERROR]` 前缀）。
- 设置页「调试」段换成 ng 版：开关 + 导出 + 清除，导出/清除都带空日志提示。
- 新增本地化键 `enable_log_recording`、`enable_log_recording_description`、
  `no_log_to_clear`、`no_log_to_clear_ok`（zh-CN / zh-TW 为中文，其余语言暂用英文）。
- 删除 B 的 `LogHelper` 与 `EeveeProbes`。

### 9.1.74 适配（依据 IPA 主二进制取证）
对 `C:\dsh\ipa\EeveeSpotify-6.6.8-9.1.74.ipa` 里的 223 MB Spotify 主二进制做了类名/选择器扫描：

- **仍存在**：`NowPlaying_ScrollImpl.NPVScrollViewController`、`NowPlayingScrollDataSourceImplementation`、
  `$__lazy_storage_$_scrollDataSource`、`NowPlaying_PlatformImpl.StatefulPlayerImplementation`、
  `StatefulPlayerTrackPositionImplementation`、`Lyrics_FullscreenElementPageImpl.FullscreenElementViewController`、
  `SPTDataLoaderService`、`Settings_PlatformImpl.SettingsListViewController`、`SPTEncoreLabel`；
  `playbackPosition` / `currentPlaybackTime` / `currentTrackTimeSecs` 三个进度候选也都在。
- **已消失**：`NowPlaying_ScrollImpl.NowPlayingScrollViewController`、
  `provideScrollViewControllerWithDependencies:`、`Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController`、
  `Lyrics_NPVCommunicatorImpl.ScrollProvider`、`ProfileSettingsSection`、
  `SPTFreeTierArtistHubRemoteURLResolver`、`RootSettingsViewController`。

因此 9.1.x 分支只激活 ng 的 `BaseLyricsGroup` + `ModernLyricsGroup`；指向已消失类的 hook
由 `EeveeSpotify.handleError` 以非致命方式记录后跳过；逐词歌词走仍在的
`Lyrics_FullscreenElementPageImpl.FullscreenElementViewController` 宿主。
另外 `CustomLyrics+HideOnError` 对 `collectionView()` 的调用补了 `responds(to:)` 检查
（B 曾在 9.1.74 上因该选择器缺失而崩溃），ng 歌词仓库依赖的
`setSpotifyAccessToken` / `spotifyAccessTokenSnapshot` 也已移植进 B 的 DataLoader hook 并加锁。
