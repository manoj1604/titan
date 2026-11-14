import Foundation

public enum TitanError: Error, Equatable, CustomStringConvertible {
    case runtimeMissing
    case systemStartFailed(Int32)
    case commandFailed(String, Int32)
    case lifecycleFailed(String, Int32)
    case invalidConfig(String, String)
    case unsupported(String)
    case emptyCommand
    case execFailed(String, String)

    public var description: String {
        switch self {
        case .runtimeMissing:
            return "Apple's `container` CLI was not found on PATH.\n  Install it from https://github.com/apple/container/releases (Apple silicon, macOS 26+)."
        case .systemStartFailed(let code):
            return "`container system start` failed (exit \(code))."
        case .commandFailed(let cmd, let code):
            return "`\(cmd)` failed (exit \(code))."
        case .lifecycleFailed(let phase, let code):
            return "\(phase) command failed (exit \(code)). Fix it, then run `titan up` again."
        case .invalidConfig(let path, let reason):
            return "Invalid config \(path): \(reason)"
        case .unsupported(let what):
            return "\(what) is not supported yet."
        case .emptyCommand:
            return "No command given. Usage: titan run -- <command> [args…]"
        case .execFailed(let cmd, let reason):
            return "Could not exec \(cmd): \(reason)"
        }
    }
}
