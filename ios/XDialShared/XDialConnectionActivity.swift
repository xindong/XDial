import ActivityKit
import Foundation

/// 连接状态的实时活动：锁屏横幅和灵动岛共用这一份数据。
/// 状态文案由主 App 按当前语言写进来；主 App 用 VPN 的流量计数更新网速。
struct XDialConnectionAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable, Sendable {
        /// 正在连接、检查线路或重连。
        case working
        case connected
        /// 已连接但需要处理（线路自检没过、等待授权）。
        case attention
    }

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        /// 「已连接」「正在连接…」这一行。
        var title: String
        /// 当前所选场景名（是选择，不代表已验证的出口地区）。
        var scenarioName: String
        /// 连上的时刻，用来计时；没连上时为空。
        var connectedAt: Date?
        /// 实时网速（字节/秒）；还没有采样时为空。
        var downloadBytesPerSecond: Double?
        var uploadBytesPerSecond: Double?
        var speedSampledAt: Date? = nil
        /// 需要留意时的第二行，例如「自检未通过，正在重新检测」。旧版本没有这个字段。
        var detail: String? = nil
    }

    /// 「断开」按钮的文字。
    var disconnectTitle: String
}

extension XDialConnectionAttributes.ContentState {
    /// Allow three sampling intervals before ActivityKit invalidates the last reading.
    static let speedLifetime: TimeInterval = 6

    var speedExpiresAt: Date? { speedSampledAt?.addingTimeInterval(Self.speedLifetime) }

    func displayed(isStale: Bool, at now: Date = Date()) -> Self {
        guard !isStale, let expiry = speedExpiresAt, expiry > now else {
            return clearingSpeed()
        }
        return self
    }

    func clearingSpeed() -> Self {
        var copy = self
        copy.downloadBytesPerSecond = nil
        copy.uploadBytesPerSecond = nil
        copy.speedSampledAt = nil
        return copy
    }

    /// 灵动岛收起时，一个方向的网速到这个数才值得占地方；再小只是零星的后台流量。
    static let compactSpeedThreshold: Double = 1_000

    /// 灵动岛收起时左侧要显示的下载速度；没连上、还没采样或没有像样的下载时为空，那一侧不占地方。
    var compactDownloadSpeed: Double? { compactSpeed(downloadBytesPerSecond) }

    /// 灵动岛收起时右侧要显示的上传速度，规则同下载，两侧各看各的。
    var compactUploadSpeed: Double? { compactSpeed(uploadBytesPerSecond) }

    private func compactSpeed(_ bytesPerSecond: Double?) -> Double? {
        guard connectedAt != nil, let bytesPerSecond,
              bytesPerSecond >= Self.compactSpeedThreshold else { return nil }
        return bytesPerSecond
    }
}

/// 网速的两种写法：灵动岛收起时地方小，用「1.4M」；其它地方用「1.4 MB/s」。
enum XDialSpeedFormat {
    /// 灵动岛收起时地方很窄，K 以上最多四个字符：「12K」「0.1M」「9.9M」「12M」「1.2G」。
    /// 100K 起就换成 M，免得出现「120K」「999K」这种更宽的写法。
    static func short(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value >= 0 else { return "—" }
        if value < 1_000 { return "\(Int(value))B" }
        let kilo = (value / 1_000).rounded()
        if kilo < 100 { return "\(Int(kilo))K" }
        if let mega = twoDigits(value / 1_000_000, unit: "M") { return mega }
        if let giga = twoDigits(value / 1_000_000_000, unit: "G") { return giga }
        return "\(Int((value / 1_000_000_000).rounded()))G"
    }

    /// `short` 可能写出的最宽样子，灵动岛按它定排法和字号。
    static let widestShort = "0.0M"

    /// 不到 10 保留一位小数，10 到 99 取整；到 100 就交给下一个单位。
    private static func twoDigits(_ amount: Double, unit: String) -> String? {
        let tenths = (amount * 10).rounded() / 10
        if tenths < 10 { return String(format: "%.1f%@", tenths, unit) }
        let whole = amount.rounded()
        if whole < 100 { return "\(Int(whole))\(unit)" }
        return nil
    }

    static func full(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value >= 0 else { return "—" }
        if value < 1_000 { return "\(Int(value)) B/s" }
        if value < 1_000_000 { return String(format: "%.0f KB/s", value / 1_000) }
        if value < 1_000_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        return String(format: "%.1f GB/s", value / 1_000_000_000)
    }
}
