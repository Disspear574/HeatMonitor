import Foundation

/// Settings keys of the limiter.
enum LimiterPref {
    static let enabled = "limiterEnabled"
    static let power = "limiterPower"
    static let heat = "limiterHeat"
    static let heatC = "limiterHeatC"
    static let holdMin = "limiterHoldMin"
    static let patterns = "limiterPatterns"
    static let demoted = "limiterDemoted"
    static let defaultPatterns = "qemu-system\nSimMetalHost\nlaunchd_sim\nGradleDaemon\nKotlinCompileDaemon\nswift-frontend\nxcodebuild"
}

/// What the limiter watches and how long a condition must last.
struct LimiterConfig: Equatable {
    var power: Bool
    var heat: Bool
    var heatC: Double
    var holdMin: Double
    var releaseMin: Double
}

enum LimitReason: Equatable { case power, heat }
enum LimiterEvent: Equatable { case engage(LimitReason), release }

/// Engages after a condition holds for `holdMin`, releases after it stays clear for `releaseMin`.
struct LimiterEngine {
    private(set) var engaged: LimitReason?
    private var since: Date?
    private var clearSince: Date?

    mutating func step(short: Bool, cpuTemp: Double?, now: Date, _ cfg: LimiterConfig) -> LimiterEvent? {
        if !cfg.power && !cfg.heat {
            since = nil; clearSince = nil
            guard engaged != nil else { return nil }
            engaged = nil
            return .release
        }
        let reason: LimitReason? = cfg.power && short ? .power
            : cfg.heat && (cpuTemp ?? 0) >= cfg.heatC ? .heat : nil
        if engaged == nil {
            guard let reason else { since = nil; return nil }
            let start = since ?? now
            since = start
            guard now.timeIntervalSince(start) >= cfg.holdMin * 60 else { return nil }
            engaged = reason; since = nil; clearSince = nil
            return .engage(reason)
        }
        if reason != nil { clearSince = nil; return nil }
        let start = clearSince ?? now
        clearSince = start
        guard now.timeIntervalSince(start) >= cfg.releaseMin * 60 else { return nil }
        engaged = nil; clearSince = nil
        return .release
    }
}

func limitPatterns(_ text: String) -> [String] {
    text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func limitMatches(_ args: String, _ patterns: [String]) -> Bool {
    patterns.contains { args.range(of: $0, options: .caseInsensitive) != nil }
}
