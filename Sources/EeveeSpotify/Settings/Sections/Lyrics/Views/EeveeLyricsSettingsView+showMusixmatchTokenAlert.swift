import SwiftUI

extension EeveeLyricsSettingsView {

    /// 选中 Musixmatch 但还没有合法令牌时的手动填写弹窗。
    ///
    /// ⚠️ 这个弹窗**不再提供**「请求匿名令牌」那个选项 —— 匿名令牌整条路径已移除。
    /// 原来的签名是 `showMusixmatchTokenAlert(_ oldSource:, _ showAnonymousTokenOption:)`，
    /// 第二个参数只用来决定"要不要多一个匿名令牌按钮 + 多一段说明文案"，
    /// 按钮没了它就没有任何作用，一并删掉（少一个恒为常量的参数）。
    ///
    /// 保留的是**手动填令牌**这条路，它是现在唯一的令牌来源：
    ///   · 从 Musixmatch 官方 App 的「设置 > 获取帮助 > 复制调试信息」里整段粘进来
    ///     （`getMusixmatchTokenFromDebugInfo` 会从 `[UserToken]: xxx` 里抠出来）；
    ///   · 或者直接贴 54 位小写十六进制的令牌。
    /// 两者都识别不了就还原原来的来源选择 —— 不留下"选了 Musixmatch 但其实没令牌"的状态。
    ///
    /// ⚠️⚠️ **它以前从来没被调用过。** 唯一的调用点是
    /// `EeveeLyricsSettingsView.swift` 里的
    /// `.onReceive(viewModel.musixmatchTokenInputAlertPublisher)`，
    /// 而那个 `PassthroughSubject` 全工程**没有任何一处 `send`** ——
    /// 也就是说"选了 Musixmatch 却没有令牌"时根本不会提示，只在来源页
    /// 留一个红色感叹号。现在改由 `lyricsSourceBinding` 在选中的那一刻直接调用。
    func showMusixmatchTokenAlert(_ oldSource: LyricsSource) {
        let alert = UIAlertController(
            title: "enter_user_token".localized,
            message: "enter_user_token_message".localized,
            preferredStyle: .alert
        )

        alert.addTextField() { textField in
            textField.placeholder = "---- Debug Info ---- [Device]: \(UIDevice.current.isIpad ? "iPad" : "iPhone")"
        }

        alert.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel) { _ in
            viewModel.lyricsSource = oldSource
        })

        alert.addAction(UIAlertAction(title: "OK".uiKitLocalized, style: .default) { _ in
            let text = alert.textFields!.first!.text!

            guard let token =
                viewModel.getMusixmatchTokenFromDebugInfo(text)
                ?? viewModel.getMusixmatchToken(text)
            else {
                viewModel.lyricsSource = oldSource
                return
            }

            viewModel.musixmatchToken = token
            UserDefaults.lyricsSource = .musixmatch
        })

        WindowHelper.shared.present(alert)
    }
}
