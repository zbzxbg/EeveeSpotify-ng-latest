import SwiftUI

extension EeveeLyricsSettingsView {

    /// 来源选择器的绑定：额外负责"选中 Musixmatch 但还没令牌"时的手动填写提示。
    ///
    /// 为什么要有它：以前这个提示挂在一个**从来没被 `send` 过**的
    /// `musixmatchTokenInputAlertPublisher` 上（见 `showMusixmatchTokenAlert` 的说明），
    /// 于是选了 Musixmatch 只会看到来源页一个红色感叹号，弹窗永远不出现。
    /// 现在把提示放在"用户真的选中那一刻"，并且**不阻断选择**：
    /// 弹窗只是提醒你现在必须手填令牌（匿名令牌那条路已经删掉）。
    ///
    /// 用 `viewModel.lyricsSource` 作为"旧值"而不是 `UserDefaults.lyricsSource`：
    /// 后者是持久化的那份，`$lyricsSource` 的 `didSet` 才写它，两者在某些时序上会不一致。
    private var lyricsSourceBinding: Binding<LyricsSource> {
        Binding(
            get: { viewModel.lyricsSource },
            set: { newSource in
                let oldSource = viewModel.lyricsSource
                viewModel.lyricsSource = newSource

                if newSource == .musixmatch, !viewModel.isMusixmatchTokenValid {
                    showMusixmatchTokenAlert(oldSource)
                }
            }
        )
    }

    private func lyricsSourceFooter() -> some View {
        var text = "lyrics_source_description".localized

        text.append("\n")
        text.append("petitlyrics_description".localized)

        text.append("\n")
        text.append("spicylyrics_description".localized)

        text.append("\n")
        text.append("netease_description".localized)

        text.append("\n")
        text.append("amll_description".localized)

        text.append("\n")
        text.append("ngzhwm_multi_level_fallback_description".localized)
        
        text.append("\n\n")
        text.append("lyrics_additional_info".localized)
        
        return Text(text)
    }
    
    @ViewBuilder func lyricsSourceSection() -> some View {
        Section {
            Toggle(
                "do_not_replace_lyrics".localized,
                isOn: Binding<Bool>(
                    get: { viewModel.lyricsSource == .notReplaced },
                    set: {
                        viewModel.lyricsSource = $0
                            ? .notReplaced
                            : LyricsSource.defaultSource
                    }
                )
            )
        } footer: {
            Text("do_not_replace_lyrics_description".localized)
        }
        
        if viewModel.lyricsSource.isReplacingLyrics {
            Section(footer: lyricsSourceFooter()) {
                Picker(
                    "lyrics_source".localized,
                    selection: lyricsSourceBinding
                ) {
                    ForEach(LyricsSource.allCases, id: \.self) { lyricsSource in
                        Text(lyricsSource.description).tag(lyricsSource)
                    }
                }

                // 多级回退链路包含 Musixmatch / LRCLIB，所以这两项也要能配置。
                if viewModel.lyricsSource == .musixmatch || viewModel.lyricsSource == .multiLevel {
                    musixmatchTokenField()
                }
                
                if viewModel.lyricsSource == .lrclib || viewModel.lyricsSource == .multiLevel {
                    lrclibURLField()
                }
            }
        }
    }
    
    /// Musixmatch 用户令牌输入框。
    ///
    /// ⚠️ 这里原来还有一个「请求匿名令牌」按钮（`requestAnonymousMusixmatchToken()`，
    /// 带转圈状态与整页 `.disabled`）—— 已整体移除。现在令牌**只能手填**，
    /// 所以那一行红色感叹号的意义更直接了：没填或填错，Musixmatch 就用不了。
    @ViewBuilder private func musixmatchTokenField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("musixmatch_user_token".localized)
            
            TextField("user_token_placeholder".localized, text: $viewModel.musixmatchToken)
                .foregroundColor(.gray)
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: { !viewModel.isMusixmatchTokenValid },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    @ViewBuilder private func lrclibURLField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("lrclib_api".localized)
            
            TextField(LrclibLyricsRepository.originalApiUrl, text: $viewModel.lyricsOptions.lrclibUrl)
                .foregroundColor(.gray)
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: {
                    viewModel.lrclibURLState == .invalidURL
                    || viewModel.lrclibURLState == .unreachableURL
                },
                set: { _ in }
            )
        )
        .icon(
            "checkmark.seal",
            color: .green,
            when: Binding<Bool>(
                get: { viewModel.lrclibURLState == .originalURL },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
