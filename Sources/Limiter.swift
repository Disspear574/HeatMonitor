import Foundation
import UserNotifications

/// Soft limiter: on a lasting power shortage or heat, listed processes of this user go to background priority.
@MainActor
final class Limiter {
    private let monitor: Monitor
    private var engine = LimiterEngine()
    private var timer: Timer?
    private var demoted: Set<Int32>
    private let io = DispatchQueue(label: "limiter", qos: .utility)
    private let defaults = UserDefaults.standard

    init(monitor: Monitor) {
        self.monitor = monitor
        demoted = Set((UserDefaults.standard.array(forKey: LimiterPref.demoted) as? [Int]).map { $0.map(Int32.init) } ?? [])
    }

    static var registeredDefaults: [String: Any] {
        [LimiterPref.enabled: false, LimiterPref.power: true, LimiterPref.heat: true,
         LimiterPref.heatC: 95.0, LimiterPref.holdMin: 3.0, LimiterPref.patterns: LimiterPref.defaultPatterns]
    }

    // Processes left demoted by a crash or quit get their priority back first.
    func sync() {
        if !demoted.isEmpty && engine.engaged == nil { restore() }
        if defaults.bool(forKey: LimiterPref.enabled) {
            guard timer == nil else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer?.tolerance = 5
        } else {
            timer?.invalidate()
            timer = nil
            if engine.engaged != nil { engine = LimiterEngine(); restore() }
        }
    }

    func stop() { restore() }

    private var config: LimiterConfig {
        let hold = max(defaults.double(forKey: LimiterPref.holdMin), 1)
        return LimiterConfig(power: defaults.bool(forKey: LimiterPref.power), heat: defaults.bool(forKey: LimiterPref.heat),
                             heatC: defaults.double(forKey: LimiterPref.heatC), holdMin: hold, releaseMin: hold)
    }

    private func tick() {
        monitor.limiterSample { [weak self] temp, battery in
            guard let self else { return }
            let short = battery.map { b in b.plugged && (b.batteryW.map { adapterShort(batteryW: $0, adapterInW: b.adapterInW, adapterMaxW: b.adapterMaxW) } ?? false) } ?? false
            switch self.engine.step(short: short, cpuTemp: temp, now: Date(), self.config) {
            case .engage(let reason): self.demote { self.notifyEngaged(reason, count: $0) }
            case .release: self.restore(); self.notify(tr("Ограничитель снят"), tr("Процессы из списка вернулись к обычному приоритету."))
            case nil: if self.engine.engaged != nil { self.demote(nil) }
            }
        }
    }

    // New matches are demoted on every tick while engaged; only this user's processes are listed.
    private func demote(_ done: ((Int) -> Void)?) {
        let patterns = limitPatterns(defaults.string(forKey: LimiterPref.patterns) ?? "")
        let known = demoted
        io.async {
            let pids = Self.matching(patterns).filter { !known.contains($0) }
            let ok = pids.filter { Self.taskpolicy("-b", $0) }
            Task { @MainActor in
                self.demoted.formUnion(ok)
                self.save()
                done?(self.demoted.count)
            }
        }
    }

    private func restore() {
        let pids = demoted
        demoted = []
        save()
        io.async { pids.forEach { _ = Self.taskpolicy("-B", $0) } }
    }

    private func save() { defaults.set(demoted.map { Int($0) }, forKey: LimiterPref.demoted) }

    private func notifyEngaged(_ reason: LimitReason, count: Int) {
        let title = reason == .power ? tr("Питания не хватает — ограничитель включён") : tr("Mac перегрет — ограничитель включён")
        var body = String(format: tr("Процессов в фоновом приоритете: %ld."), count)
        if reason == .power { body += " " + tr("Режим энергосбережения от адаптера включается в разделе «Питание».") }
        notify(title, body)
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "limiter", content: c, trigger: nil))
    }

    nonisolated private static func matching(_ patterns: [String]) -> [Int32] {
        guard !patterns.isEmpty else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-U", String(getuid()), "-o", "pid=,args="]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let me = getpid()
        return text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let space = t.firstIndex(of: " "), let pid = Int32(t[..<space]), pid != me,
                  limitMatches(String(t[space...]), patterns) else { return nil }
            return pid
        }
    }

    nonisolated private static func taskpolicy(_ flag: String, _ pid: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        p.arguments = [flag, "-p", String(pid)]
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
