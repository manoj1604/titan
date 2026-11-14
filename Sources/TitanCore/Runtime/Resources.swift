import Foundation

/// One `container stats` sample. Counters are cumulative since the VM booted.
public struct VMStats: Equatable, Sendable {
    public var cpuUsageUsec: UInt64
    public var memoryUsageBytes: UInt64
    public var memoryLimitBytes: UInt64
    public var processes: Int
    public var blockReadBytes: UInt64
    public var blockWriteBytes: UInt64
    public var networkRxBytes: UInt64
    public var networkTxBytes: UInt64

    public init(cpuUsageUsec: UInt64 = 0, memoryUsageBytes: UInt64 = 0, memoryLimitBytes: UInt64 = 0,
                processes: Int = 0, blockReadBytes: UInt64 = 0, blockWriteBytes: UInt64 = 0,
                networkRxBytes: UInt64 = 0, networkTxBytes: UInt64 = 0) {
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.processes = processes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
    }
}

/// What a VM was actually created with.
public struct VMResources: Equatable, Sendable {
    public var cpus: Int
    public var memoryBytes: UInt64
    /// Digest of the image index the VM was created from.
    public var imageDigest: String?

    public init(cpus: Int, memoryBytes: UInt64, imageDigest: String? = nil) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.imageDigest = imageDigest
    }
}

/// Totals across all images in the local store.
public struct ImageStoreUsage: Equatable, Sendable {
    public var count: Int
    public var sizeBytes: UInt64
    public var reclaimableBytes: UInt64

    public init(count: Int, sizeBytes: UInt64, reclaimableBytes: UInt64) {
        self.count = count
        self.sizeBytes = sizeBytes
        self.reclaimableBytes = reclaimableBytes
    }
}

public enum Resources {
    static let gib: UInt64 = 1 << 30
    public static let maxDefaultMemoryBytes: UInt64 = 8 * gib

    /// Half the Mac's RAM, capped at 8 GiB and at least 1 GiB, in whole GiB.
    /// `container` itself defaults to 1 GiB, which OOM-kills real builds (Rust, Java, webpack).
    public static func defaultMemory(hostBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        "\(max(1, min(hostBytes / 2, maxDefaultMemoryBytes) / gib))G"
    }

    /// Parses `container`-style sizes: "512M", "8G", "1g", "1073741824".
    public static func parseBytes(_ text: String) -> UInt64? {
        let s = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let m = s.wholeMatch(of: /(\d+)\s*([KMGT]?)(I?B)?/), let n = UInt64(m.1) else { return nil }
        let shift: UInt64 = switch m.2 { case "K": 10; case "M": 20; case "G": 30; case "T": 40; default: 0 }
        return n << shift
    }

    /// Binary units, labelled the way people read them: "74 MB", "1.0 GB".
    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        if unit == 0 { return "\(bytes) B" }
        return value < 10 ? String(format: "%.1f %@", value, units[unit]) : String(format: "%.0f %@", value, units[unit])
    }

    /// CPU use between two samples; 100% means one full core.
    public static func cpuPercent(_ first: VMStats, _ second: VMStats, interval: TimeInterval) -> Double {
        guard interval > 0, second.cpuUsageUsec >= first.cpuUsageUsec else { return 0 }
        return Double(second.cpuUsageUsec - first.cpuUsageUsec) / (interval * 1_000_000) * 100
    }
}
