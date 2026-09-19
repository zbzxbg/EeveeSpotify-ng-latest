import SwiftUI
import UIKit

// 全屏壳的**共用件**：曲名/歌手、右上角收起键、底部进度条 + 时间 + 三键。
//
// 为什么要有这个文件：旧渲染层（「开启逐词歌词」但不开启「更好的逐词歌词」）
// 原来是**自己用 UIKit 重写了一套壳** —— 结果位置、间距、淡出都和新的对不上
// （真机对比：标题偏高、三键太散、上下淡出难看）。用户的要求是"直接照抄"，
// 那就别抄：两条渲染路径用**同一份代码**。
//
// 分工：
//   · `LyricsShellChrome`   —— 三块**内容**（不含外边距），新层把它交给
//     `AppleMusicLyricsPage` 排版，旧层用下面的 Host 视图按同样的边距排版；
//   · `LyricsShellLayout`   —— 边距/高度这些**常数**的唯一来源，
//     两条路径都必须读这里，改一处两边同时变；
//   · `LyricsShellHeaderHost` / `LyricsShellFooterHost` —— 旧层用的宿主视图，
//     复刻 `AppleMusicLyricsPage` 里那两段的排版（同样的 padding、同样的安全区用法）。

/// 全屏壳的排版常数（唯一来源）。
///
/// 数值来自 `AppleMusicLyricsPage` 的实测：顶部标题两行 62、底部控件栏 116、
/// 标题栏再往上抬 30、上下内容各留 8 / 46 的呼吸。
enum LyricsShellLayout {
    static let headerHeight: CGFloat = 62
    static let footerHeight: CGFloat = 116
    static let headerTopInset: CGFloat = -30
    static let contentTopInset: CGFloat = 8
    static let contentBottomInset: CGFloat = 46
    /// 底部淡出带的宽度（`AppleMusicLyricsPage.fadeBottomBand`）。
    static let fadeBottomBand: CGFloat = 40
    /// 关闭键距安全区顶部的距离（`AppleMusicLyricsPage` 里那个 `.padding(.top, safeArea.top + 6)`）。
    static let closeTopInset: CGFloat = 6
    static let closeTrailingInset: CGFloat = 12
}

/// 三块壳内容（不含外边距）。
enum LyricsShellChrome {

    /// 顶部：曲名 + 歌手（居中）。
    static func header(title: String, artist: String, primaryColor: Color) -> AnyView {
        AnyView(
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                Text(artist)
                    .font(.system(size: 12))
                    .foregroundStyle(primaryColor.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity)
        )
    }

    /// 底部：进度条 + 时间 + 三键。
    static func footer(
        projection: AppleMusicLyricsPlaybackProjection,
        primaryColor: Color,
        onSeek: @escaping (TimeInterval) -> Void
    ) -> AnyView {
        AnyView(
            AppleMusicLyricsControls(
                projection: projection,
                primaryColor: primaryColor,
                onSeek: onSeek
            )
        )
    }

    /// 右上角：关闭全屏。
    ///
    /// ⚠️ 必须是 SwiftUI 的 `Button`，**不能**做成 `UIControl`：
    /// `WordByWordPlaybackControl.dismissFullscreen()` 是按无障碍标签在窗口里找
    /// "原生收起键"的，自己如果也是一个 UIControl，就会点到**自己** → 无限递归
    /// （真机崩过一次，日志里同一秒刷了几百行 `dismiss via native close button`）。
    static func close(primaryColor: Color, onClose: @escaping () -> Void) -> AnyView {
        AnyView(
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        )
    }
}

// MARK: - 旧层用的宿主视图（排版与新层逐一对应）

/// 顶部条：标题栏 + 右上角关闭键。
///
/// 排版照抄 `AppleMusicLyricsPage` 里那段：
///   · 标题栏 `headerContent.padding(.top, safeArea.top + headerTopInset)`
///   · 关闭键 `.padding(.top, safeArea.top + 6).padding(.trailing, 12)`
struct LyricsShellHeaderHost: View {
    let title: String
    let artist: String
    let primaryColor: Color
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let safeArea = geometry.safeAreaInsets
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    LyricsShellChrome.header(
                        title: title,
                        artist: artist,
                        primaryColor: primaryColor
                    )
                    .padding(.top, safeArea.top + LyricsShellLayout.headerTopInset)
                    Spacer(minLength: 0)
                }

                HStack {
                    Spacer()
                    LyricsShellChrome.close(primaryColor: primaryColor, onClose: onClose)
                }
                .padding(.top, safeArea.top + LyricsShellLayout.closeTopInset)
                .padding(.trailing, LyricsShellLayout.closeTrailingInset)
            }
        }
    }
}

/// 底部条：进度条 + 时间 + 三键。
///
/// 排版照抄同一页：`footerContent.padding(.bottom, max(safeArea.bottom, 8))`，
/// 底部对齐。
struct LyricsShellFooterHost: View {
    @ObservedObject var projection: AppleMusicLyricsPlaybackProjection
    let primaryColor: Color
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let safeArea = geometry.safeAreaInsets
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LyricsShellChrome.footer(
                    projection: projection,
                    primaryColor: primaryColor,
                    onSeek: onSeek
                )
                .padding(.bottom, max(safeArea.bottom, 8))
            }
        }
    }
}

// MARK: - 把 SwiftUI 壳挂到 UIKit 层上

/// 把 `LyricsShellHeaderHost` / `LyricsShellFooterHost` 挂进旧渲染层的宿主。
///
/// 只占**上下两条**，中间那段留给歌词的滚动视图 —— 这样壳不会把歌词的触摸吃掉
/// （整片覆盖的话，SwiftUI 宿主视图会挡住下面 UIScrollView 的手势）。
@MainActor
final class LyricsShellHosts {

    private var headerController: UIHostingController<LyricsShellHeaderHost>?
    private var footerController: UIHostingController<LyricsShellFooterHost>?
    /// 顶部条 / 底部条的高度：只要盖住壳本身够用，别多占。
    private let headerStripHeight: CGFloat = 150
    private let footerStripHeight: CGFloat = 210

    private(set) var isAttached = false

    /// 挂到 `host` 上（只挂一次，之后用 `update` 改内容）。
    func attach(
        to host: UIView,
        projection: AppleMusicLyricsPlaybackProjection,
        primaryColor: UIColor,
        onSeek: @escaping (TimeInterval) -> Void,
        onClose: @escaping () -> Void
    ) {
        detach()
        let color = Color(primaryColor)

        let header = UIHostingController(
            rootView: LyricsShellHeaderHost(
                title: "",
                artist: "",
                primaryColor: color,
                onClose: onClose
            )
        )
        let footer = UIHostingController(
            rootView: LyricsShellFooterHost(
                projection: projection,
                primaryColor: color,
                onSeek: onSeek
            )
        )

        for controller in [header, footer] as [UIViewController] {
            controller.view.backgroundColor = .clear
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(controller.view)
        }

        NSLayoutConstraint.activate([
            header.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.view.topAnchor.constraint(equalTo: host.topAnchor),
            header.view.heightAnchor.constraint(equalToConstant: headerStripHeight),

            footer.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            footer.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            footer.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            footer.view.heightAnchor.constraint(equalToConstant: footerStripHeight),
        ])

        headerController = header
        footerController = footer
        isAttached = true
    }

    /// 换歌 / 换曲名歌手时调用。
    func update(title: String, artist: String) {
        headerController?.rootView.title = title
        headerController?.rootView.artist = artist
    }

    func setHidden(_ hidden: Bool) {
        headerController?.view.isHidden = hidden
        footerController?.view.isHidden = hidden
    }

    /// 把两条壳抬到最前（旧层每帧都会重排 subviews）。
    func bringToFront() {
        guard let host = headerController?.view.superview else { return }
        if let header = headerController?.view, host.subviews.last !== header {
            host.bringSubviewToFront(header)
        }
        if let footer = footerController?.view, host.subviews.last !== footer {
            host.bringSubviewToFront(footer)
        }
    }

    func detach() {
        headerController?.view.removeFromSuperview()
        footerController?.view.removeFromSuperview()
        headerController = nil
        footerController = nil
        isAttached = false
    }
}
