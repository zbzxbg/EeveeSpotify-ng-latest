import Orion
import SwiftUI
import UIKit

// Settings integration - only works on non-9.1.x versions
struct SettingsIntegrationGroup: HookGroup { }

class ProfileSettingsSectionHook: ClassHook<NSObject> {
    typealias Group = SettingsIntegrationGroup
    static let targetName = "ProfileSettingsSection"

    func numberOfRows() -> Int {
        return 2
    }

    func didSelectRow(_ row: Int) {
        if row == 1 {
            let rootSettingsController = WindowHelper.shared.findFirstViewController(
                "RootSettingsViewController"
            )!
            
            let navigationController = rootSettingsController.navigationController!

            let eeveeSettingsController = EeveeSettingsViewController(
                rootSettingsController.view.bounds,
                settingsView: AnyView(EeveeSettingsView(navigationController: navigationController)),
                navigationTitle: "EeveeSpotify"
            )
            
            //
            
            let button = UIButton()
            
            if let gitImage = BundleHelper.shared.uiImage("github") {
                button.setImage(gitImage.withRenderingMode(.alwaysOriginal), for: .normal)
            } else {
                button.setImage(UIImage(systemName: "globe"), for: .normal)
            }
            
            button.addTarget(
                eeveeSettingsController,
                action: #selector(eeveeSettingsController.openRepositoryUrl(_:)),
                for: .touchUpInside
            )
            
            //
            
            let menuBarItem = UIBarButtonItem(customView: button)
            
            menuBarItem.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
            menuBarItem.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true

            eeveeSettingsController.navigationItem.rightBarButtonItem = menuBarItem
            
            navigationController.pushViewController(
                eeveeSettingsController,
                animated: true
            )

            return
        }

        orig.didSelectRow(row)
    }

    func cellForRow(_ row: Int) -> UITableViewCell {
        if row == 1 {
            let settingsTableCell = Dynamic.SPTSettingsTableViewCell
                .alloc(interface: SPTSettingsTableViewCell.self)
                .initWithStyle(3, reuseIdentifier: "EeveeSpotify")
            
            let tableViewCell = Dynamic.convert(settingsTableCell, to: UITableViewCell.self)

            tableViewCell.accessoryView = type(
                of: Dynamic.SPTDisclosureAccessoryView
                    .alloc(interface: SPTDisclosureAccessoryView.self)
            )
            .disclosureAccessoryView()
            
            tableViewCell.textLabel?.text = "EeveeSpotify"
            return tableViewCell
        }

        return orig.cellForRow(row)
    }
}
