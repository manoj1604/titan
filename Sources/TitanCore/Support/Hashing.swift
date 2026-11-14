import CryptoKit
import Foundation

enum Hashing {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ string: String) -> String { sha256(Data(string.utf8)) }
}

/// POSIX-shell quoting, used for display and for generated scripts.
public func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) {
        return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public func shellJoin(_ args: [String]) -> String { args.map(shellQuote).joined(separator: " ") }
