import Foundation
import Orion
import UIKit

private var eeveeObserverRegistered = false
private let eeveeObserver = EeveeSponsorBlockObserver()

@objc final class EeveeSponsorBlockObserver: NSObject {
    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject) {
        SponsorBlockSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject, fromState oldState: AnyObject) {
        SponsorBlockSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, didEncounterError error: AnyObject) {}
    @objc func player(_ player: AnyObject, didMoveToRelativeTrack relativeIndex: Int) {}
    @objc func player(_ player: AnyObject, queueDidChange queue: AnyObject) {}
}

class ProgressBarSliderHook: ClassHook<UIView> {
    typealias Group = SponsorBlockGroup
    static let targetName = "_TtCO17NowPlaying_ECMKit11ProgressBar6Slider"

    func layoutSubviews() {
        orig.layoutSubviews()
        SponsorBlockOverlay.shared.attach(to: target)
    }
}

class PlayerServiceObserverHook: ClassHook<NSObject> {
    typealias Group = SponsorBlockGroup
    static let targetName = "SPTPlayerServiceImplementation"

    func addPlayerObserver(_ observer: AnyObject) {
        orig.addPlayerObserver(observer)
        if !eeveeObserverRegistered {
            eeveeObserverRegistered = true
            writeDebugLog("[SB] registering observer on service")
            orig.addPlayerObserver(eeveeObserver)
        }
    }
}

struct SponsorBlockGroup: HookGroup {}

func activateSponsorBlock() {
    let opts = UserDefaults.sponsorBlockOptions
    let cls = NSClassFromString("SPTPlayerServiceImplementation")
    writeDebugLog("[SB] activate: enabled=\(opts.enabled ? "Y" : "N") logOnly=\(opts.logOnly ? "Y" : "N") cats=\(opts.enabledCategoriesArray().joined(separator: ",")) server=\(opts.serverURL) class=\(cls == nil ? "<missing>" : "<found>")")
    SponsorBlockGroup().activate()
    writeDebugLog("[SB] hook group activated")
}
