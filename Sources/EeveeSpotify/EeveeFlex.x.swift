//
//  EeveeFlex.x.swift
//
//  Auto-opens FLEX explorer on first key window. Dormant unless libFLEX.dylib
//  is LC-loaded into the app (wrapper --flex flag). Safe to keep compiled in.
//
import Foundation
import Orion
import UIKit

struct EeveeFlexAutoOpenGroup: HookGroup {}

private var flexAutoOpenedOnce = false

class UIWindowFlexAutoOpenHook: ClassHook<UIWindow> {
    typealias Group = EeveeFlexAutoOpenGroup

    func becomeKeyWindow() {
        orig.becomeKeyWindow()

        guard !flexAutoOpenedOnce else { return }
        guard let mgrClass = NSClassFromString("FLEXManager") as? NSObject.Type else { return }
        let sharedSel = NSSelectorFromString("sharedManager")
        guard mgrClass.responds(to: sharedSel) else { return }
        guard let mgr = mgrClass.perform(sharedSel)?.takeUnretainedValue() as? NSObject else { return }
        let showSel = NSSelectorFromString("showExplorer")
        guard mgr.responds(to: showSel) else { return }

        flexAutoOpenedOnce = true
        NSLog("[EeveeFlex] key window up — scheduling showExplorer")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            mgr.perform(showSel)
            NSLog("[EeveeFlex] showExplorer invoked")
        }
    }
}

func activateEeveeFlexGesture() {
    guard NSClassFromString("FLEXManager") != nil else {
        NSLog("[EeveeFlex] libFLEX NOT loaded — auto-open dormant (run without --skip-build to bake libFLEX into baseline)")
        return
    }
    NSLog("[EeveeFlex] libFLEX loaded — auto-open armed")
    EeveeFlexAutoOpenGroup().activate()
}
