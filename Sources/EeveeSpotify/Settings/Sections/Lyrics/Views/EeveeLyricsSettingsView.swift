import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()

    var body: some View {
        List {
            wordByWordLyricsSection()

            // 「更好的逐词歌词」是「开启逐词歌词」的子项：**必须紧跟主开关**，
            // 中间不插别的 section。主开关没开时整项不展示
            // （与下面 NetEase 那几项同一套写法）。
            if viewModel.wordByWordLyrics {
                betterWordByWordLyricsSection()
            }

            lyricsSourceSection()
            
            // 「禁用歌词功能」作为「禁用歌词替换功能」的二级菜单：
            // 仅当「禁用歌词替换功能」开启（lyricsSource == .notReplaced）时显示，
            // 写法与下方两个 NetEase 设置的条件显示一致。
            if viewModel.lyricsSource == .notReplaced {
                disableLyricsSection()
            }
            
            if viewModel.lyricsSource == .netease {
                neteaseRomajiLocalSection()
                neteaseHideTranslationSection()
            }
            
            if viewModel.lyricsSource != .notReplaced {
                // 「AMLL 优先」已删除（2026-09-25，用户反馈"没什么用"）：AMLL 仍然是
                // 来源选择器里的一个普通来源，只是不再有"先试 AMLL 再回退"的那条链。
                
                // Genius 回退保持原有条件：多级回退链路本身以 Genius 收尾，
                // 不再重复提供该开关；来源为 Genius 时自己回退给自己没有意义。
                if viewModel.lyricsSource != .genius && viewModel.lyricsSource != .multiLevel {
                    geniusFallbackSection()
                }
                
                hideOnErrorSection()
                syntheticLineTimingSection()
                injectLyricsCardElementSection()
                // 「隐藏官方歌词」已写死启用（见 `NgzhwmSettingsViewModel` 里那个
                // getter），不再有开关。
                romanizationSection()
                
                // 多级回退链路包含 Musixmatch，其语言项同样可配置。
                if viewModel.lyricsSource == .musixmatch || viewModel.lyricsSource == .multiLevel {
                    musixmatchLanguageSection()
                }
            }
            
            removeInterludeSymbolSection()
            
            NonIPadSpacerView()
        }
        // ⚠️ 这里曾经有一个 `.onReceive(viewModel.musixmatchTokenInputAlertPublisher)`，
        // 用 `showAnonymousTokenOption` 决定弹窗里要不要显示「请求匿名令牌」。
        // 那个 publisher 全工程没有任何一处 `send`（死订阅），而匿名令牌选项本身
        // 也已整体移除 —— 两个一起去掉。
        // 手动填令牌的弹窗保留，改由下面这个绑定在"选中 Musixmatch 那一刻"调用。
        .listStyle(GroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }
    
    @ViewBuilder private func wordByWordLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_word_by_word_lyrics_description".localized)
        ) {
            Toggle(
                "ngzhwm_word_by_word_lyrics".localized,
                isOn: $viewModel.wordByWordLyrics
            )
        }
    }

    /// 「更好的逐词歌词」：**跟着主开关显示/隐藏的子项**，不单独占一个平级位置。
    ///
    /// 与文件里其它条件项同一套写法（例如
    /// `if viewModel.lyricsSource == .netease { ... }`）：
    /// 逐词歌词没开时它没有任何意义，所以整项不展示，而不是置灰。
    ///
    /// 页脚里把"开启后自动带上什么"说清楚，免得用户去找已经不存在的
    /// 模糊封面 / 系统材质开关（那两个已改为跟随本项自动启用）。
    ///
    /// ⚠️ 文案 key 是 `_description` 而不是 `_footer`：本文件里所有页脚都用
    /// `<开关名>_description`（逐词歌词、更好的逐词歌词、禁用歌词、多级回退……一致）。
    /// 这里曾经多出一个 `ngzhwm_better_word_by_word_lyrics_footer`，是**同一个开关
    /// 两份文案** —— 改文案时只改一处、另一处悄悄过期，正是那种"看起来改过了、
    /// 界面上还是旧话"的坑。现在合并成一条。
    @ViewBuilder private func betterWordByWordLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_better_word_by_word_lyrics_description".localized)
        ) {
            Toggle(
                "ngzhwm_better_word_by_word_lyrics".localized,
                isOn: $viewModel.betterWordByWordLyrics
            )
        }
    }
    
    @ViewBuilder private func disableLyricsSection() -> some View {
        Section(
            footer: Text("ngzhwm_disable_lyrics_feature_description".localized)
        ) {
            Toggle(
                "ngzhwm_disable_lyrics_feature".localized,
                isOn: $viewModel.disableLyricsFeature
            )
        }
    }
    
    @ViewBuilder private func geniusFallbackSection() -> some View {
        Section {
            Toggle(
                "genius_fallback".localized,
                isOn: $viewModel.lyricsOptions.geniusFallback
            )
            
        } footer: {
            Text("genius_fallback_description"
                .localizeWithFormat(viewModel.lyricsSource.description))
        }
    }
    
    // 已移除 `amllPreferredSection()`（2026-09-25）：「AMLL 优先」整条链一起去掉，
    // 连带 en / zh-CN 的 `ngzhwm_amll_preferred(_description)` 两个键也删了。
    
    @ViewBuilder private func romanizationSection() -> some View {
        Section(
            footer: Text("ngzhwm_romanization_description".localized)
        ) {
            Toggle("ngzhwm_chinese_romanization".localized, isOn: $viewModel.chineseRomanization)
            Toggle("ngzhwm_japanese_romanization".localized, isOn: $viewModel.japaneseRomanization)
            Toggle("ngzhwm_korean_romanization".localized, isOn: $viewModel.koreanRomanization)
        }
    }

    @ViewBuilder private func hideOnErrorSection() -> some View {
        Section {
            Toggle(
                "hide_lyrics_on_error".localized,
                isOn: $viewModel.lyricsOptions.hideOnError
            )
        } footer: {
            Text("hide_lyrics_on_error_description".localized)
        }
    }

    /// 「给无时间轴的歌词补时间轴」。
    ///
    /// 故意**没有 footer**：这个开关的用途是排查"不补时间轴会怎样"，
    /// 不需要一段解释文字（与页面上其它开关不同，它们都有 `_description`）。
    @ViewBuilder private func syntheticLineTimingSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_synthetic_line_timing".localized,
                isOn: $viewModel.syntheticLineTiming
            )
        }
    }

    /// 「给没有歌词卡片的曲目补一个卡片元素」。
    ///
    /// 同样**没有 footer**。它的用途是判定"404 曲目上那张「即将发布/预收藏」卡
    /// 是不是这个元素渲出来的"：关掉 → 那张卡消失而歌词卡还在 = 确实是它。
    @ViewBuilder private func injectLyricsCardElementSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_inject_lyrics_card_element".localized,
                isOn: $viewModel.injectLyricsCardElement
            )
        }
    }

    // 已移除一个 Section（2026-09-25）：`hideOfficialLyricsSection()` ——
    // 它的开关价值只在"验证修复有没有用"那一步，验证完就写死启用了。
    // 那个 l10n 键也一并删除（见 en/zh-CN 的 Localizable.strings）。
    // 同批删掉的 `syntheticLineTimingSection()` 与 `injectLyricsCardElementSection()`
    // 均已恢复，见上面两个方法。

    @ViewBuilder private func neteaseRomajiLocalSection() -> some View {
        Section(
            footer: Text("ngzhwm_netease_romaji_local_description".localized)
        ) {
            Toggle(
                "ngzhwm_netease_romaji_local".localized,
                isOn: $viewModel.neteaseRomajiLocal
            )
        }
    }

    @ViewBuilder private func neteaseHideTranslationSection() -> some View {
        Section(
            footer: Text("ngzhwm_netease_hide_translation_description".localized)
        ) {
            Toggle(
                "ngzhwm_netease_hide_translation".localized,
                isOn: $viewModel.neteaseHideTranslation
            )
        }
    }

    @ViewBuilder private func removeInterludeSymbolSection() -> some View {
        Section(
            footer: Text("ngzhwm_remove_interlude_symbol_description".localized)
        ) {
            Toggle(
                "ngzhwm_remove_interlude_symbol".localized,
                isOn: $viewModel.removeMxmInterludeSymbol
            )
        }
    }

    @ViewBuilder private func musixmatchLanguageSection() -> some View {
        Section {
            HStack {
                Text("musixmatch_language".localized)
                
                Spacer()
                
                TextField("en", text: $viewModel.lyricsOptions.musixmatchLanguage)
                    .frame(maxWidth: 20)
                    .foregroundColor(.gray)
            }
            .icon(
                "exclamationmark.triangle.fill",
                color: .yellow,
                when: $viewModel.showMusixmatchInvalidLanguageWarning
            )
        } footer: {
            Text("musixmatch_language_description".localized)
        }
    }
}
