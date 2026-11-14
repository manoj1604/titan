import Foundation

/// Human-facing output. Everything goes to stderr so stdout stays clean for the
/// commands Titan forwards into the VM.
public struct Console: Sendable {
    public var verbose: Bool
    public var quiet: Bool
    private let color: Bool

    public init(verbose: Bool = false, quiet: Bool = false) {
        self.verbose = verbose
        self.quiet = quiet
        self.color = isatty(2) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    public func step(_ message: String) { if !quiet { write(paint("▸", "36") + " " + message) } }
    public func info(_ message: String) { if !quiet { write(message) } }
    public func success(_ message: String) { if !quiet { write(paint("✓", "32") + " " + message) } }
    public func warn(_ message: String) { write(paint("!", "33") + " " + message) }
    public func error(_ message: String) { write(paint("✗", "31") + " " + message) }
    public func debug(_ message: String) { if verbose { write(paint("· " + message, "2")) } }

    public func paint(_ text: String, _ code: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    private func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

public struct TerminalInfo: Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool

    public init(stdinIsTTY: Bool, stdoutIsTTY: Bool) {
        self.stdinIsTTY = stdinIsTTY
        self.stdoutIsTTY = stdoutIsTTY
    }

    public static var current: TerminalInfo {
        TerminalInfo(stdinIsTTY: isatty(0) == 1, stdoutIsTTY: isatty(1) == 1)
    }
}
