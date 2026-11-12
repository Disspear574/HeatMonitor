import Foundation

func limiterTests() {
    let t = Date(timeIntervalSince1970: 10_000)
    func at(_ min: Double) -> Date { t.addingTimeInterval(min * 60) }
    let cfg = LimiterConfig(power: true, heat: true, heatC: 95, holdMin: 3, releaseMin: 3)

    // Engages only after the condition holds for holdMin.
    var e = LimiterEngine()
    check(e.step(short: true, cpuTemp: 60, now: at(0), cfg) == nil, "shortage starts: wait")
    check(e.step(short: true, cpuTemp: 60, now: at(2.9), cfg) == nil, "2.9 min: wait")
    check(e.step(short: true, cpuTemp: 60, now: at(3), cfg) == .engage(.power), "3 min: engage for power")
    check(e.engaged == .power, "engaged state")
    check(e.step(short: true, cpuTemp: 60, now: at(4), cfg) == nil, "no repeat event while engaged")

    // Releases only after the condition stays clear for releaseMin; a relapse resets the clock.
    check(e.step(short: false, cpuTemp: 60, now: at(5), cfg) == nil, "clear starts")
    check(e.step(short: true, cpuTemp: 60, now: at(6), cfg) == nil, "relapse keeps engaged")
    check(e.step(short: false, cpuTemp: 60, now: at(7), cfg) == nil, "clear again")
    check(e.step(short: false, cpuTemp: 60, now: at(9.9), cfg) == nil, "2.9 min clear: hold")
    check(e.step(short: false, cpuTemp: 60, now: at(10), cfg) == .release, "3 min clear: release")
    check(e.engaged == nil, "released state")

    // A gap in the condition restarts the hold.
    var g = LimiterEngine()
    _ = g.step(short: true, cpuTemp: nil, now: at(0), cfg)
    _ = g.step(short: false, cpuTemp: nil, now: at(2), cfg)
    check(g.step(short: true, cpuTemp: nil, now: at(4), cfg) == nil, "hold restarted after a gap")
    check(g.step(short: true, cpuTemp: nil, now: at(7), cfg) == .engage(.power), "engages 3 min after restart")

    // Heat at or above the threshold; power wins when both hold.
    var h = LimiterEngine()
    _ = h.step(short: false, cpuTemp: 95, now: at(0), cfg)
    check(h.step(short: false, cpuTemp: 97, now: at(3), cfg) == .engage(.heat), "heat engages")
    var b = LimiterEngine()
    _ = b.step(short: true, cpuTemp: 99, now: at(0), cfg)
    check(b.step(short: true, cpuTemp: 99, now: at(3), cfg) == .engage(.power), "power named first")

    // Disabled triggers are ignored; turning both off releases at once.
    let heatOnly = LimiterConfig(power: false, heat: true, heatC: 95, holdMin: 3, releaseMin: 3)
    var d = LimiterEngine()
    _ = d.step(short: true, cpuTemp: 50, now: at(0), heatOnly)
    check(d.step(short: true, cpuTemp: 50, now: at(5), heatOnly) == nil, "power trigger off")
    let off = LimiterConfig(power: false, heat: false, heatC: 95, holdMin: 3, releaseMin: 3)
    check(e.step(short: true, cpuTemp: 60, now: at(20), cfg) == nil && e.step(short: true, cpuTemp: 60, now: at(23), cfg) == .engage(.power), "re-engage")
    check(e.step(short: true, cpuTemp: 99, now: at(24), off) == .release, "all triggers off: release now")

    // Process list: case-insensitive substring of the command line, blank lines ignored.
    let list = limitPatterns("qemu-system\n  GradleDaemon \n\n")
    check(list == ["qemu-system", "GradleDaemon"], "patterns parsed: \(list)")
    check(limitMatches("/opt/emu/qemu-system-aarch64 -avd x", list), "qemu matches")
    check(limitMatches("java -Xmx4g org.gradle.launcher.daemon.bootstrap.gradledaemon 8.10", list), "case-insensitive")
    check(!limitMatches("/Applications/Safari.app/Contents/MacOS/Safari", list), "other app untouched")
    check(!limitMatches("anything", []), "empty list matches nothing")
}
