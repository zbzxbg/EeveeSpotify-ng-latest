import Foundation
import CommonCrypto

enum SponsorBlockHash {
    static func sha256HexPrefix(_ input: String, prefixLen: Int = 5) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(prefixLen))
    }
}
