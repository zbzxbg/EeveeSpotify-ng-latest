import Foundation

// Off-by-default debug probe: dumps /casita/ and /browsita/ response bodies
// to the app tmp dir and logs the first 256 bytes as hex. Flip `enabled` to
// inspect new ad surfaces, then flip back before shipping.
enum CasitaResponseProbe {
    static var enabled: Bool = false

    private static let lock = NSLock()
    private static var buffers: [Int: Data] = [:]
    private static var dumpDirReady = false
    private static var sequence: Int = 0

    static func shouldProbe(_ url: URL) -> Bool {
        guard enabled else { return false }
        let p = url.path.lowercased()
        return p.contains("/casita/") || p.contains("/browsita/")
    }

    static func append(_ data: Data, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        buffers[task.taskIdentifier, default: Data()].append(data)
    }

    static func flush(_ task: URLSessionTask, url: URL) {
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier)
        sequence += 1
        let seq = sequence
        lock.unlock()
        guard let body = data, !body.isEmpty else {
            NSLog("[CASITA] %@ <no-body>", url.path)
            return
        }

        let dir = ensureDumpDir()
        let slug = url.path.replacingOccurrences(of: "/", with: "_")
        let filename = "\(String(format: "%03d", seq))\(slug).bin"
        let fullPath = (dir as NSString).appendingPathComponent(filename)
        do {
            try body.write(to: URL(fileURLWithPath: fullPath))
        } catch {
            NSLog("[CASITA] write-failed %@: %@", fullPath, "\(error)")
        }

        let hex = body.prefix(256).map { String(format: "%02x", $0) }.joined()
        NSLog("[CASITA] %@ size=%d dump=%@", url.path, body.count, fullPath)
        NSLog("[CASITA][HEX] %@", hex)
    }

    private static func ensureDumpDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("eevee_casita")
        if !dumpDirReady {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            dumpDirReady = true
            NSLog("[CASITA] dump dir = %@", dir)
        }
        return dir
    }
}
