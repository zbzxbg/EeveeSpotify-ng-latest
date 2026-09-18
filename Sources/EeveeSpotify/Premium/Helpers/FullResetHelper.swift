import Foundation
import Security

class FullResetHelper {

    static func wipeSpotifyState() {
        let counts = WipeCounts()
        wipeKeychainSpotifyOnly(counts)
        wipeUserDefaults(counts)
        wipeSandboxDirs(counts)
        wipeSpotifyGroupContainers(counts)
        NSLog("[FULL_RESET] keychain=%d defaults=%d files=%d groups=%d",
              counts.keychain, counts.defaults, counts.files, counts.groups)
    }

    private class WipeCounts {
        var keychain = 0
        var defaults = 0
        var files = 0
        var groups = 0
    }

    private static func looksLikeSpotifyItem(_ attrs: [String: Any]) -> Bool {
        let fields: [CFString] = [
            kSecAttrService, kSecAttrAccount, kSecAttrLabel,
            kSecAttrAccessGroup, kSecAttrDescription,
        ]
        for f in fields {
            if let v = attrs[f as String] as? String,
               v.lowercased().contains("spotify") {
                return true
            }
            if let d = attrs[f as String] as? Data,
               let s = String(data: d, encoding: .utf8),
               s.lowercased().contains("spotify") {
                return true
            }
        }
        return false
    }

    private static func wipeKeychainSpotifyOnly(_ c: WipeCounts) {
        let classes: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity,
        ]

        for cls in classes {
            let query: [CFString: Any] = [
                kSecClass: cls,
                kSecMatchLimit: kSecMatchLimitAll,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny,
                kSecReturnAttributes: true,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let items = result as? [[String: Any]] else { continue }

            for attrs in items where looksLikeSpotifyItem(attrs) {
                var dq: [CFString: Any] = [
                    kSecClass: cls,
                    kSecAttrSynchronizable: kSecAttrSynchronizableAny,
                ]
                if let s = attrs[kSecAttrService as String]     { dq[kSecAttrService]     = s }
                if let a = attrs[kSecAttrAccount as String]     { dq[kSecAttrAccount]     = a }
                if let g = attrs[kSecAttrAccessGroup as String] { dq[kSecAttrAccessGroup] = g }
                if SecItemDelete(dq as CFDictionary) == errSecSuccess { c.keychain += 1 }
            }
        }
    }

    private static func wipeUserDefaults(_ c: WipeCounts) {
        let std = UserDefaults.standard
        for key in std.dictionaryRepresentation().keys {
            std.removeObject(forKey: key)
            c.defaults += 1
        }
        std.synchronize()

        if let bid = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bid)
        }
    }

    private static func wipeSandboxDirs(_ c: WipeCounts) {
        let fm = FileManager.default
        let dirs: [URL?] = [
            fm.urls(for: .libraryDirectory,            in: .userDomainMask).first,
            fm.urls(for: .documentDirectory,           in: .userDomainMask).first,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fm.urls(for: .cachesDirectory,             in: .userDomainMask).first,
            URL(fileURLWithPath: NSTemporaryDirectory()),
        ]
        for url in dirs.compactMap({ $0 }) {
            removeChildren(of: url, c: c)
        }
    }

    private static func wipeSpotifyGroupContainers(_ c: WipeCounts) {
        let candidates = [
            "group.com.spotify.client",
            "group.com.spotify.client.shared",
            "group.com.spotify.client.ryuk",
            "group.com.spotify.client.ryuk.shared",
            "8W66MEA7DD.com.spotify.client",
        ]
        let fm = FileManager.default
        for gid in candidates {
            guard let url = fm.containerURL(forSecurityApplicationGroupIdentifier: gid) else { continue }
            c.groups += 1
            removeChildren(of: url, c: c)
        }
    }

    private static func removeChildren(of url: URL, c: WipeCounts) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        for item in items {
            do {
                try fm.removeItem(at: item)
                c.files += 1
            } catch {
                walkAndRemove(url: item, c: c)
            }
        }
    }

    // Per-file fallback so one EPERM (iOS-protected dirs like Library/Caches,
    // Library/Preferences) doesn't abort the rest of the subtree.
    private static func walkAndRemove(url: URL, c: WipeCounts) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue,
           let kids = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for k in kids { walkAndRemove(url: k, c: c) }
        }
        if (try? fm.removeItem(at: url)) != nil { c.files += 1 }
    }
}
