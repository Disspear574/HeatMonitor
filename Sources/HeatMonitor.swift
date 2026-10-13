import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import Darwin

// MARK: - Temperature sensors (IOKit HID, no root needed on Apple Silicon)

final class TempReader {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatch = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProp = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double

    // The client owns the services; releasing it invalidates them.
    private var client: AnyObject?
    private var services: [(name: String, service: AnyObject)] = []
    private let copyEvent: CopyEvent?
    private let floatValue: FloatValue?

    init() {
        let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self)
        floatValue = sym("IOHIDEventGetFloatValue", FloatValue.self)
        guard let create = sym("IOHIDEventSystemClientCreate", Create.self),
              let setMatch = sym("IOHIDEventSystemClientSetMatching", SetMatch.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProp = sym("IOHIDServiceClientCopyProperty", CopyProp.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = setMatch(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        let list = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        // Sensor names never change, so they are resolved once.
        services = list.compactMap { s in
            (copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String).map { ($0, s) }
        }
    }

    func read() -> [String: Double] {
        guard let copyEvent, let floatValue else { return [:] }
        var out: [String: Double] = [:]
        for (name, s) in services {
            guard let event = copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = floatValue(event, 15 << 16)
            guard v > 0, v < 150 else { continue }
            out[name] = max(out[name] ?? 0, v)
        }
        return out
    }
}

// MARK: - SMC: fans and palm rest (missing keys simply read as nil)

final class SMCReader {
    struct Fan { let rpm: Double; let max: Double; let manual: Bool }
    private var conn: io_connect_t = 0
    private var sizes: [String: Int] = [:]

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        if IOServiceOpen(svc, mach_task_self_, 0, &conn) != kIOReturnSuccess { conn = 0 }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    func fans() -> [Fan] {
        guard let n = bytes("FNum")?.first, n > 0 else { return [] }
        return (0..<Int(min(n, 4))).compactMap { i in
            guard let rpm = float("F\(i)Ac") else { return nil }
            return Fan(rpm: rpm, max: float("F\(i)Mx") ?? 0, manual: bytes("F\(i)Md")?.first == 1)
        }
    }

    func palmRest() -> [Double] {
        ["Ts0P", "Ts1P"].compactMap { float($0) }.filter { $0 > 10 && $0 < 80 }
    }

    // Walks all ~2000 SMC keys: call once, off the main thread.
    func temperatureKeys() -> [String] {
        guard let count = bytes("#KEY"), count.count == 4 else { return [] }
        let n = count.reduce(0) { $0 << 8 | Int($1) }
        var keys: [String] = []
        for i in 0..<n {
            var input = [UInt8](repeating: 0, count: 80)
            input[42] = 8
            withUnsafeBytes(of: UInt32(i)) { for j in 0..<4 { input[44 + j] = $0[j] } }
            guard let out = call(input) else { continue }
            let name = String(bytes: out[0..<4].reversed(), encoding: .ascii) ?? ""
            guard name.hasPrefix("T") else { continue }
            var info = [UInt8](repeating: 0, count: 80)
            for j in 0..<4 { info[j] = out[j] }
            info[42] = 9
            guard let meta = call(info), meta[28] == 4,
                  String(bytes: meta[32...35].reversed(), encoding: .ascii) == "flt " else { continue }
            if let v = float(name), v > -20, v < 130 { keys.append(name) }
        }
        return keys
    }

    // PSTR is the whole system, PDTR the adapter input.
    func power() -> (system: Double?, adapter: Double?) {
        (float("PSTR").flatMap { $0 > 0 ? $0 : nil }, float("PDTR").flatMap { $0 >= 0 ? $0 : nil })
    }

    func temperatures(_ keys: [String]) -> [(key: String, value: Double)] {
        keys.compactMap { k in float(k).map { (k, $0) } }
    }

    private func float(_ key: String) -> Double? {
        guard let b = bytes(key), b.count == 4 else { return nil }
        return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }

    // SMCKeyData_t is 80 bytes: key @0, dataSize @28, result @40, command @42, payload @48.
    private func bytes(_ key: String) -> [UInt8]? {
        guard conn != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        withUnsafeBytes(of: code) { for i in 0..<4 { input[i] = $0[i] } }
        let size: Int
        if let cached = sizes[key] {
            size = cached
        } else {
            input[42] = 9
            guard let info = call(input) else { sizes[key] = 0; return nil }
            size = Int(info[28...31].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            sizes[key] = size
        }
        guard size > 0, size <= 32 else { return nil }
        withUnsafeBytes(of: UInt32(size)) { for i in 0..<4 { input[28 + i] = $0[i] } }
        input[42] = 5
        guard let value = call(input) else { return nil }
        return Array(value[48..<48 + size])
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var inp = input
        var out = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let r = IOConnectCallStructMethod(conn, 2, &inp, 80, &out, &outSize)
        return r == kIOReturnSuccess && out[40] == 0 ? out : nil
    }
}

// MARK: - GPU time per process (AGX driver user clients; no root needed)

final class GPUByProcess {
    private var last: [Int32: UInt64] = [:]
    private var lastTime: UInt64 = 0

    func read() -> [Int32: Double] {
        var accels: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accels) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(accels) }
        var now: [Int32: UInt64] = [:]
        // User clients are children of the accelerator; they cannot be found by service matching.
        while case let accel = IOIteratorNext(accels), accel != 0 {
            defer { IOObjectRelease(accel) }
            var it: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            collect(it, into: &now)
        }
        let t = DispatchTime.now().uptimeNanoseconds
        defer { last = now; lastTime = t }
        guard lastTime > 0, t > lastTime else { return [:] }
        let dt = Double(t - lastTime)
        var out: [Int32: Double] = [:]
        for (pid, v) in now {
            if let p = last[pid], v > p { out[pid] = min(Double(v - p) / dt * 100, 100) }
        }
        return out
    }

    private func collect(_ it: io_iterator_t, into now: inout [Int32: UInt64]) {
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard let creator = IORegistryEntryCreateCFProperty(s, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let pid = Int32(creator.dropFirst(4).prefix { $0 != "," }),
                  let usage = IORegistryEntryCreateCFProperty(s, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] else { continue }
            now[pid, default: 0] += usage.reduce(0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
        }
    }
}

// MARK: - GPU power (IOReport energy counters)

/// GPU watts from IOReport energy counters, the source powermetrics reads; no root needed.
final class GPUPower {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetInt = @convention(c) (CFDictionary, Int32) -> Int64

    private var sub: AnyObject?
    private var channels: CFMutableDictionary?
    private var samples: CreateSamples?
    private var delta: CreateDelta?
    private var name: GetString?
    private var unit: GetString?
    private var value: GetInt?
    private var last: (sample: CFDictionary, time: UInt64)?

    init() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannels.self),
              let create = sym("IOReportCreateSubscription", CreateSub.self),
              let all = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let chans = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, all) else { return }
        var subbed: Unmanaged<CFMutableDictionary>?
        sub = create(nil, chans, &subbed, 0, nil)?.takeUnretainedValue()
        channels = chans
        samples = sym("IOReportCreateSamples", CreateSamples.self)
        delta = sym("IOReportCreateSamplesDelta", CreateDelta.self)
        name = sym("IOReportChannelGetChannelName", GetString.self)
        unit = sym("IOReportChannelGetUnitLabel", GetString.self)
        value = sym("IOReportSimpleGetIntegerValue", GetInt.self)
    }

    // Nil on the first call and after a pause longer than 5 s.
    func watts() -> Double? {
        guard let sub, let channels, let samples, let delta, let name, let unit, let value,
              let now = samples(sub, channels, nil)?.takeRetainedValue() else { return nil }
        let time = DispatchTime.now().uptimeNanoseconds
        defer { last = (now, time) }
        guard let prev = last, case let seconds = Double(time - prev.time) / 1e9, seconds > 0.2, seconds < 5,
              let d = delta(prev.sample, now, nil)?.takeRetainedValue(),
              let items = (d as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        var joules = 0.0
        for item in items {
            let ch = item as CFDictionary
            let n = name(ch)?.takeUnretainedValue() as String?
            let u = (unit(ch)?.takeUnretainedValue() as String?)?.trimmingCharacters(in: .whitespaces)
            guard n == "GPU Energy" else { continue }
            let scale: Double = switch u { case "mJ": 1e-3; case "uJ": 1e-6; case "nJ": 1e-9; default: 0 }
            joules += Double(value(ch, 0)) * scale
        }
        return joules / seconds
    }
}

// MARK: - System totals

enum SystemInfo {
    /// Watts are positive into the battery (charging), negative out of it (discharging).
    struct Battery {
        let percent: Int?
        let plugged: Bool
        let charging: Bool
        let batteryW: Double?
        let systemW: Double?
        let adapterInW: Double?
        let adapterMaxW: Int?
        let minutesLeft: Int?
        let cycles: Int?
        let healthPercent: Int?
    }

    static let totalRAM = Double(ProcessInfo.processInfo.physicalMemory)
    static let cores = ProcessInfo.processInfo.activeProcessorCount

    // Same formula as Activity Monitor "Memory Used": app + wired + compressed.
    static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let app = max(Int64(stats.internal_page_count) - Int64(stats.purgeable_count), 0)
        let pages = app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return Double(pages) * Double(vm_kernel_page_size)
    }

    static func swap() -> (used: Double, total: Double) {
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(x.xsu_used), Double(x.xsu_total))
    }

    static func disk() -> (free: Double, total: Double)? {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage, let total = v?.volumeTotalCapacity else { return nil }
        return (Double(free), Double(total))
    }

    static func gpuUtilization() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = stats["Device Utilization %"] as? Int {
                best = max(best ?? 0, Double(u))
            }
        }
        return best
    }

    // Live SMC watts win: the battery driver's PowerTelemetryData updates only every tens of seconds.
    static func battery(systemW liveSystem: Double? = nil, adapterW liveAdapter: Double? = nil) -> Battery? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        let telemetry = prop("PowerTelemetryData") as? [String: Any] ?? [:]
        func watts(_ mW: Any?) -> Double? { (mW as? Int).map { Double($0) / 1000 } }

        // IOPS updates at once; the battery driver's ExternalConnected lags after unplugging.
        let ps = PowerSource.read()
        let plugged = ps?.onAC ?? (prop("ExternalConnected") as? Bool ?? false)

        var batteryW: Double?
        if let v = prop("Voltage") as? Int, let a = (prop("InstantAmperage") ?? prop("Amperage")) as? Int {
            batteryW = Double(v) * Double(a) / 1_000_000
            // A stale charging current right after unplugging is not shown.
            if !plugged, let b = batteryW, b > 0 { batteryW = nil }
        }
        let adapterIn = plugged ? (liveAdapter ?? watts(telemetry["SystemPowerIn"])) : nil
        var systemW = liveSystem ?? watts(telemetry["SystemLoad"]).flatMap { $0 > 0 ? $0 : nil }
        if systemW == nil, let b = batteryW { systemW = (adapterIn ?? 0) - b }
        let left = ps?.minutesToEmpty ?? prop("TimeRemaining") as? Int
        // Capacity keys sit in BatteryData on some models and at the top level on others.
        let data = prop("BatteryData") as? [String: Any] ?? [:]
        func capacity(_ k: String) -> Int? { ((data[k] ?? prop(k)) as? Int).flatMap { $0 > 0 ? $0 : nil } }
        var health: Int?
        if let design = capacity("DesignCapacity"),
           let full = capacity("NominalChargeCapacity") ?? capacity("AppleRawMaxCapacity") {
            // Truncated like System Information's "Maximum Capacity".
            health = min(Int(Double(full) / Double(design) * 100), 100)
        }
        return Battery(percent: ps?.percent ?? prop("CurrentCapacity") as? Int,
                       plugged: plugged,
                       charging: ps?.charging ?? prop("IsCharging") as? Bool ?? false,
                       batteryW: batteryW,
                       systemW: systemW,
                       adapterInW: adapterIn,
                       adapterMaxW: plugged ? (ps?.adapterWatts ?? (prop("AdapterDetails") as? [String: Any])?["Watts"] as? Int) : nil,
                       minutesLeft: left.flatMap { $0 > 0 && $0 < 65535 ? $0 : nil },
                       cycles: prop("CycleCount") as? Int,
                       healthPercent: health)
    }
}

/// CPU busy share from per-core tick counters, for the label while `top` is not running.
final class CPULoad: @unchecked Sendable {
    private var last: [UInt32]?

    // Nil on the first call: a share needs two snapshots.
    func sample() -> Double? {
        var cpus: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
        defer { last = ticks }
        guard let last, last.count == ticks.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(cpus) {
            let o = c * Int(CPU_STATE_MAX)
            let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(ticks[o + $0] &- last[o + $0]) }
            busy += d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            total += d.reduce(0, +)
        }
        return total > 0 ? Double(busy) / Double(total) * 100 : nil
    }
}

/// The system power source: the same data the menu bar battery icon shows.
struct PowerSource {
    let onAC: Bool
    let charging: Bool?
    let percent: Int?
    let minutesToEmpty: Int?
    let adapterWatts: Int?

    static func read() -> PowerSource? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let battery = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return PowerSource(onAC: type == kIOPMACPowerKey,
                           charging: battery?[kIOPSIsChargingKey] as? Bool,
                           percent: battery?[kIOPSCurrentCapacityKey] as? Int,
                           minutesToEmpty: battery?[kIOPSTimeToEmptyKey] as? Int,
                           adapterWatts: adapter?[kIOPSPowerAdapterWattsKey] as? Int)
    }
}

// MARK: - Processes (one long-running `top`, the only unprivileged way to see every process)

struct TopSample {
    struct Proc { let pid: Int32; let command: String; let cpu: Double; let memMB: Double }
    var procs: [Proc] = []
    var cpuUsage: Double = 0
}

final class TopStream {
    private let process = Process()
    private var buffer = ""
    private var blocks = 0

    func start(interval: Int, onSample: @escaping (TopSample) -> Void) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "0", "-s", "\(interval)", "-n", "120", "-o", "cpu", "-stats", "pid,cpu,mem,command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { h.readabilityHandler = nil; return }
            // Lenient decoding: top truncates names mid-character, which breaks strict UTF-8.
            self.buffer += String(decoding: data, as: UTF8.self)
            while let first = self.buffer.range(of: "Processes:"),
                  let next = self.buffer.range(of: "Processes:", range: first.upperBound..<self.buffer.endIndex) {
                let block = String(self.buffer[first.lowerBound..<next.lowerBound])
                self.buffer.removeSubrange(..<next.lowerBound)
                self.blocks += 1
                // The first sample has no CPU deltas.
                if self.blocks > 1 { onSample(Self.parse(block)) }
            }
        }
        try? process.run()
    }

    func stop() { if process.isRunning { process.terminate() } }

    static func parse(_ block: String) -> TopSample {
        var s = TopSample()
        var inTable = false
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("CPU usage:"), let r = line.range(of: #"([\d.]+)% idle"#, options: .regularExpression) {
                s.cpuUsage = 100 - (Double(line[r].dropLast(6)) ?? 100)
            } else if line.hasPrefix("PID") {
                inTable = true
            } else if inTable {
                let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard f.count == 4, let pid = Int32(f[0]) else { continue }
                s.procs.append(.init(pid: pid, command: String(f[3]).trimmingCharacters(in: .whitespaces),
                                     cpu: Double(f[1]) ?? 0, memMB: memMB(String(f[2]))))
            }
        }
        return s
    }

    static func memMB(_ raw: String) -> Double {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = t.last, let n = Double(t.dropLast()) else { return 0 }
        switch unit {
        case "G": return n * 1024
        case "M": return n
        case "K": return n / 1024
        case "B": return n / 1_048_576
        default: return Double(t).map { $0 / 1_048_576 } ?? 0
        }
    }
}

// MARK: - Grouping into apps

struct Row: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let appPath: String?
    var cpu: Double
    var gpu: Double
    var memMB: Double
    var pids: [Int32]
    // Share of all cores, like Windows Task Manager.
    var cpuShare: Double { cpu / Double(max(SystemInfo.cores, 1)) }
    var heat: Double { cpuShare + gpu }
    var count: Int { pids.count }
}

enum Identity {
    private static var cache: [Int32: (key: String, name: String, appPath: String?)] = [:]
    private static var icons: [String: NSImage] = [:]
    private static let generic = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()

    // Loading icons from disk on every refresh was the app's main CPU cost.
    static func icon(_ appPath: String?) -> NSImage {
        guard let appPath else { return generic }
        if let i = icons[appPath] { return i }
        // Pre-rendered at 32 px so table redraws copy a bitmap instead of resampling a 1024 px icon.
        let source = NSWorkspace.shared.icon(forFile: appPath)
        let i = NSImage(size: NSSize(width: 16, height: 16))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = NSSize(width: 16, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
            i.addRepresentation(rep)
        }
        icons[appPath] = i
        return i
    }

    static func of(_ p: TopSample.Proc) -> (key: String, name: String, appPath: String?) {
        if let c = cache[p.pid] { return c }
        var buf = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(p.pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        var result: (String, String, String?)
        // Outermost .app in the path: Chrome/Safari/Electron helpers count toward their app.
        if let r = path.range(of: ".app/") {
            let appPath = String(path[..<r.lowerBound]) + ".app"
            let bundle = Bundle(path: appPath)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            result = (appPath, name, appPath)
        } else {
            let name = path.isEmpty ? p.command : (path as NSString).lastPathComponent
            result = ("pid:\(p.pid)", name, nil)
        }
        if cache.count > 5000 { cache.removeAll() }
        cache[p.pid] = result
        return result
    }

    static func rows(_ procs: [TopSample.Proc], gpu: [Int32: Double], grouped: Bool) -> [Row] {
        var byKey: [String: Row] = [:]
        var order: [String] = []
        for p in procs {
            let id = of(p)
            let key = grouped ? id.key : "pid:\(p.pid)"
            let g = gpu[p.pid] ?? 0
            if var r = byKey[key] {
                r.cpu += p.cpu; r.gpu += g; r.memMB += p.memMB; r.pids.append(p.pid)
                byKey[key] = r
            } else {
                let name = grouped ? id.name : (id.appPath != nil ? p.command : id.name)
                byKey[key] = Row(id: key, name: name, icon: icon(id.appPath), appPath: id.appPath,
                                 cpu: p.cpu, gpu: g, memMB: p.memMB, pids: [p.pid])
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

// MARK: - Model

@MainActor
final class Monitor: ObservableObject {
    @Published var rows: [Row] = []
    @Published var hottest: Set<String> = []
    @Published var sensors: [String: Double] = [:]
    @Published var history: [Double] = []
    @Published var cpuUsage: Double = 0
    @Published var gpu: Double?
    @Published var gpuWatts: Double?
    @Published var memUsed: Double = 0
    @Published var swap: (used: Double, total: Double) = (0, 0)
    @Published var disk: (free: Double, total: Double)?
    @Published var battery: SystemInfo.Battery?
    @Published var fans: [SMCReader.Fan] = []
    @Published var palmRest: [Double] = []
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var message: String?
    @Published var fanBusy = false
    @Published var fanTarget: Bool?
    @Published var grouped = true { didSet { rebuild() } }
    @Published var sortOrder = [KeyPathComparator(\Row.heat, order: .reverse)] { didSet { rebuild() } }

    private var lastProcs: [TopSample.Proc] = []
    private var gpuByPid: [Int32: Double] = [:]
    private let temps = TempReader()
    private let smc = SMCReader()
    private let gpuReader = GPUByProcess()
    private let gpuPower = GPUPower()
    private var top: TopStream?
    private var timer: Timer?
    private var ticks = 0
    // IOKit sensor reads block for up to ~40 ms, so they run here, never on the main thread.
    private let io = DispatchQueue(label: "sensors", qos: .utility)

    /// SMC core sensor keys, found once on the io queue: Tp* performance and Te* efficiency cores, Tg* GPU.
    private final class CoreKeys { var cpu: [String]?; var gpu: [String] = []; var perCore: [String] = [] }
    private let coreKeys = CoreKeys()

    // One SMC key per core, found by recording a 12-core M3 Pro under load; other chips average every core key.
    nonisolated private static let perCoreKeys: [String: [String]] = [
        "Apple M3 Pro": ["Tp05", "Tp0D", "Tp0L", "Tp0S", "Tp17", "Tp1F", "Te04", "Te05", "Te0H", "Te0P", "Te0S", "Te0U"],
    ]

    nonisolated private static func chipName() -> String {
        var name = [CChar](repeating: 0, count: 64)
        var size = name.count
        return sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0) == 0 ? String(cString: name) : ""
    }

    private struct Snapshot {
        let sensors: [String: Double]
        let cpuCores: [Double]
        let perCore: [Double]
        let gpuCores: [Double]
        let gpu: Double?
        let gpuWatts: Double?
        let memUsed: Double
        let swap: (used: Double, total: Double)
        let battery: SystemInfo.Battery?
        let fans: [SMCReader.Fan]
        let palmRest: [Double]
        let disk: (free: Double, total: Double)?
    }

    // M2 and later name CPU die sensors "PMU tdie*"; M1 uses "*ACC MTR Temp Sensor*".
    @Published var cpuCores: [Double] = []
    @Published var perCore: [Double] = []
    @Published var gpuCores: [Double] = []

    // SMC core sensors are the real hot spots: under load they read ~110° where HID "PMU tdie" reads ~65°.
    var cpuSensors: [Double] {
        if !cpuCores.isEmpty { return cpuCores }
        let tdie = values { $0.hasPrefix("PMU tdie") }
        if !tdie.isEmpty { return tdie }
        let acc = values { $0.contains("ACC MTR") }
        return acc.isEmpty ? chipSensors : acc
    }
    var chipSensors: [Double] { values { !$0.hasPrefix("gas gauge") && !$0.hasPrefix("NAND") && !$0.contains("Battery") } }
    var cpuMax: Double? { cpuSensors.max() }
    var cpuAvg: Double? {
        let v = perCore.isEmpty ? cpuSensors : perCore
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    var gpuTemp: Double? { gpuCores.max() }

    // Core sensors jump 20°+ within a second on short bursts, so the header shows a 5-second mean.
    @Published var cpuHot: Double?
    @Published var cpuPeak: Double?
    @Published var cpuMean: Double?
    @Published var gpuHot: Double?
    private var window: [String: [Double]] = [:]

    private func smooth(_ key: String, _ v: Double?) -> Double? {
        guard let v else { window[key] = nil; return nil }
        let w = Array((window[key, default: []] + [v]).suffix(5))
        window[key] = w
        return w.reduce(0, +) / Double(w.count)
    }

    var ssd: Double? { values { $0.hasPrefix("NAND") }.max() }
    var batteryTemp: Double? { values { $0.hasPrefix("gas gauge") || $0.contains("Battery") }.max() }

    private func values(_ match: (String) -> Bool) -> [Double] {
        sensors.filter { match($0.key) }.map(\.value)
    }

    // Idempotent: called on launch and whenever the window becomes visible.
    func start() {
        guard top == nil else { return }
        refreshSystem()
        let t = TopStream()
        let gpuReader = self.gpuReader
        t.start(interval: 2) { [weak self] sample in
            let gpu = gpuReader.read()
            Task { @MainActor in self?.apply(sample, gpu: gpu) }
        }
        top = t
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystem() }
        }
        timer?.tolerance = 0.2
    }

    private var powerSource: CFRunLoopSource?

    func watchPowerSource() {
        guard powerSource == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<Monitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { m.refreshNow() }
        }, ctx)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }

    func refreshNow() { refreshSystem() }

    @Published var readings = Readings()
    private var lightTimer: Timer?
    private let cpuLoad = CPULoad()

    func startLight() {
        guard lightTimer == nil else { return }
        sampleLight()
        lightTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLight() }
        }
        lightTimer?.tolerance = 1
    }

    func stopLight() { lightTimer?.invalidate(); lightTimer = nil }

    // Only what the label shows: SMC keys and tick counters, no top, IOReport or disk.
    private func sampleLight() {
        io.async { [smc, temps, coreKeys, cpuLoad, weak self] in
            Self.findCoreKeys(smc, coreKeys)
            let cores = smc.temperatures(coreKeys.cpu ?? []).map(\.value)
            let r = Readings(cpuTemp: cores.max() ?? hidCPU(temps.read()),
                             gpuTemp: smc.temperatures(coreKeys.gpu).map(\.value).max(),
                             fanRPM: smc.fans().map(\.rpm).max(),
                             systemW: smc.power().system,
                             cpuLoad: cpuLoad.sample())
            Task { @MainActor in self?.readings = r }
        }
    }

    // While it exists, the root watcher from "max" keeps fans at max; deleting it hands them back with no password.
    private let fanFlag = FileManager.default.temporaryDirectory.appendingPathComponent("heatmonitor-fans-max").path

    func setFans(max: Bool) {
        guard !fanBusy else { return }
        fanBusy = true
        fanTarget = max
        guard !max, FileManager.default.fileExists(atPath: fanFlag) else { return runFanTool(max: max) }
        try? FileManager.default.removeItem(atPath: fanFlag)
        io.async { [smc, weak self] in
            var tries = 0, manual = true
            while manual && tries < 30 { usleep(100_000); tries += 1; manual = smc.fans().contains { $0.manual } }
            Task { @MainActor in
                if manual { self?.runFanTool(max: false) } else { self?.fanDone() }
            }
        }
    }

    // SMC writes need root; the "max" watcher returns fans to macOS when this app exits, even after a crash.
    private func runFanTool(max: Bool) {
        guard let tool = Bundle.main.path(forAuxiliaryExecutable: "heatmonitor-fan") else { return fanDone(ok: false) }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // The bracket keeps the pattern from matching osascript, whose arguments contain this very command.
        let stop = "pkill -f 'heatmonitor-fa[n] watch'; "
        if max { FileManager.default.createFile(atPath: fanFlag, contents: nil) }
        let shell = max
            ? stop + "\(q(tool)) max && (\(q(tool)) watch \(getpid()) \(q(fanFlag)) >/dev/null 2>&1 &)"
            : stop + "\(q(tool)) auto"
        let script = "do shell script \"" + shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        p.terminationHandler = { [weak self] p in
            let ok = p.terminationStatus == 0
            let why = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                if max && !ok, let flag = self?.fanFlag { try? FileManager.default.removeItem(atPath: flag) }
                self?.fanDone(ok: ok)
                self?.message = ok ? nil : why.contains("-128") ? tr("Вентиляторы не переключены: пароль не введён.")
                    : String(format: tr("Вентиляторы не переключены: %@"),
                             why.isEmpty ? "osascript \(p.terminationStatus)" : why.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        do { try p.run() } catch { fanDone(ok: false) }
    }

    // On success the switch keeps showing the target until a snapshot confirms it, so it does not flicker back.
    private func fanDone(ok: Bool = true) {
        fanBusy = false
        if !ok { fanTarget = nil }
        refreshSystem()
    }

    func stop() {
        top?.stop()
        top = nil
        timer?.invalidate()
        timer = nil
        window = [:]
        history = []
    }

    nonisolated private static func findCoreKeys(_ smc: SMCReader, _ k: CoreKeys) {
        guard k.cpu == nil else { return }
        let all = smc.temperatureKeys()
        k.cpu = all.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
        k.gpu = all.filter { $0.hasPrefix("Tg") }
        let table = perCoreKeys[chipName()] ?? []
        if table.count == ProcessInfo.processInfo.processorCount, table.allSatisfy(all.contains) { k.perCore = table }
    }

    private func refreshSystem() {
        let readDisk = ticks % 10 == 0
        ticks += 1
        io.async { [temps, smc, coreKeys, gpuPower, weak self] in
            Self.findCoreKeys(smc, coreKeys)
            let power = smc.power()
            let snap = Snapshot(sensors: temps.read(),
                                cpuCores: smc.temperatures(coreKeys.cpu ?? []).map(\.value),
                                perCore: smc.temperatures(coreKeys.perCore).map(\.value),
                                gpuCores: smc.temperatures(coreKeys.gpu).map(\.value),
                                gpu: SystemInfo.gpuUtilization(), gpuWatts: gpuPower.watts(), memUsed: SystemInfo.memoryUsed(),
                                swap: SystemInfo.swap(), battery: SystemInfo.battery(systemW: power.system, adapterW: power.adapter),
                                fans: smc.fans(), palmRest: smc.palmRest(), disk: readDisk ? SystemInfo.disk() : nil)
            Task { @MainActor in self?.publish(snap) }
        }
    }

    private func publish(_ s: Snapshot) {
        sensors = s.sensors
        cpuCores = s.cpuCores
        perCore = s.perCore
        gpuCores = s.gpuCores
        cpuHot = smooth("max", cpuMax)
        if let t = cpuHot {
            history.append(t)
            if history.count > Sparkline.capacity { history.removeFirst(history.count - Sparkline.capacity) }
        }
        cpuPeak = window["max"]?.max()
        cpuMean = smooth("avg", cpuAvg)
        gpuHot = smooth("gpu", gpuTemp)
        gpu = s.gpu
        gpuWatts = s.gpuWatts
        memUsed = s.memUsed
        swap = s.swap
        battery = s.battery
        fans = s.fans
        if !fanBusy, fanTarget == s.fans.contains(where: \.manual) { fanTarget = nil }
        palmRest = s.palmRest
        if let d = s.disk { disk = d }
        thermal = ProcessInfo.processInfo.thermalState
        readings = Readings(cpuTemp: cpuHot, gpuTemp: gpuHot, fanRPM: s.fans.map(\.rpm).max(),
                            systemW: s.battery?.systemW, cpuLoad: cpuUsage)
    }

    private func apply(_ s: TopSample, gpu: [Int32: Double]) {
        cpuUsage = s.cpuUsage
        lastProcs = s.procs
        gpuByPid = gpu
        rebuild()
    }

    private func rebuild() {
        let r = Identity.rows(lastProcs, gpu: gpuByPid, grouped: grouped).sorted(using: sortOrder)
        // Animated row moves on every refresh cost more CPU than the rest of the app.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { rows = Array(r.prefix(40)) }
        hottest = Set(r.filter { $0.heat >= 5 }.sorted { $0.heat > $1.heat }.prefix(3).map(\.id))
    }

    func search(_ row: Row) {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(row.name) " + tr("процесс macOS что это и почему грузит систему"))]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    func terminate(_ row: Row) {
        let failed = row.pids.filter { kill($0, SIGTERM) != 0 }
        message = failed.count == row.pids.count
            ? String(format: tr("«%@» — системный процесс, завершить его можно только с правами администратора."), row.name)
            : nil
    }

    var heatReason: String {
        var parts: [String] = []
        if let top = rows.max(by: { $0.heat < $1.heat }), top.heat >= 3 {
            var s = "\(top.name) — CPU \(Int(top.cpuShare.rounded()))%"
            if top.gpu >= 3 { s += ", GPU \(Int(top.gpu.rounded()))%" }
            parts.append(s)
        }
        if let g = gpu, g >= 40 { parts.append(String(format: tr("графика загружена на %ld%%"), Int(g))) }
        if cpuUsage >= 60 { parts.append(String(format: tr("процессор загружен на %ld%%"), Int(cpuUsage))) }
        if let w = battery?.batteryW, w > 15 { parts.append(String(format: tr("быстрая зарядка +%.0f Вт"), w)) }
        if thermal == .serious || thermal == .critical { parts.append(tr("macOS уже снижает частоты")) }
        return parts.isEmpty ? tr("Нагрузка маленькая — сейчас ничего не греет") : String(format: tr("Греет: %@"), parts.joined(separator: " · "))
    }
}

// MARK: - UI

func tempColor(_ t: Double) -> Color {
    // Apple Silicon cores run at 100–110° under full load before throttling.
    switch t {
    case ..<70: return .green
    case ..<85: return .yellow
    case ..<100: return .orange
    default: return .red
    }
}

func caseColor(_ t: Double) -> Color { t < 35 ? .secondary : t < 41 ? .yellow : .orange }

func fmt(_ t: Double?) -> String { t.map { String(format: "%.0f°", $0) } ?? "—" }
func gb(_ bytes: Double) -> String { String(format: bytes >= 100e9 ? "%.0f" : "%.1f", bytes / 1_073_741_824) }
// Totals are whole gigabytes.
func gbTotal(_ bytes: Double) -> String { String(format: "%.0f", bytes / 1_073_741_824) }
extension String { func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self } }
func w(_ v: Double?) -> String { v.map { String(format: tr("%.1f Вт"), $0) } ?? "—" }
func tr(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func ofGB(_ used: Double, _ total: Double) -> String { String(format: tr("%@ из %@ ГБ"), gb(used), gbTotal(total)) }

func thermalText(_ s: ProcessInfo.ThermalState) -> (String, Color) {
    switch s {
    case .nominal: return (tr("Частоты не снижены"), .secondary)
    case .fair: return (tr("Слегка горячо"), .yellow)
    case .serious: return (tr("Горячо — частоты снижаются"), .orange)
    case .critical: return (tr("Критично"), .red)
    @unknown default: return ("?", .secondary)
    }
}

/// Digits slide up when the value changes; no blur, so it stays cheap. Static under Reduce Motion.
struct RollingText: View {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(value.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .id(ch)
                    .transition(.push(from: .bottom))
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
    }
}

struct Sparkline: NSViewRepresentable {
    let values: [Double]
    static let capacity = 180

    func makeNSView(context: Context) -> SparkView { SparkView() }
    func updateNSView(_ view: SparkView, context: Context) {
        view.update(values, color: NSColor(tempColor(values.last ?? 0)),
                    animate: !context.environment.accessibilityReduceMotion)
    }
}

/// History line on a shape layer; Core Animation runs the scroll outside the app process.
final class SparkView: NSView {
    private let line = CAShapeLayer()
    private var values: [Double] = []
    private var scale = (mid: 0.0, span: 20.0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        line.fillColor = nil
        line.lineWidth = 2
        line.lineCap = .round
        line.lineJoin = .round
        layer?.addSublayer(line)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        line.frame = bounds
        redraw(animate: false)
    }

    override func viewDidChangeBackingProperties() {
        line.contentsScale = window?.backingScaleFactor ?? 2
    }

    func update(_ new: [Double], color: NSColor, animate: Bool) {
        line.strokeColor = color.cgColor
        guard new != values else { return }
        let scrolls = !values.isEmpty
        values = new
        redraw(animate: animate && scrolls)
    }

    private func redraw(animate: Bool) {
        // At least a 20° span, so a 1° wobble near the top does not look like a cliff.
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let next = (mid: (lo + hi) / 2, span: max(hi - lo + 4, 20))
        let from = path(scale)
        scale = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.path = path(next)
        CATransaction.commit()
        guard animate else { return }
        // Drawn one step to the right, where the old line was, then slid into place.
        let scroll = CABasicAnimation(keyPath: "transform.translation.x")
        scroll.fromValue = bounds.width / CGFloat(Sparkline.capacity - 1)
        scroll.toValue = 0
        scroll.duration = 1
        line.add(scroll, forKey: "scroll")
        let rescale = CABasicAnimation(keyPath: "path")
        rescale.fromValue = from
        rescale.duration = 1
        rescale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        line.add(rescale, forKey: "rescale")
    }

    private func path(_ s: (mid: Double, span: Double)) -> CGPath {
        let slots = CGFloat(Sparkline.capacity - 1)
        let first = Sparkline.capacity - values.count
        let points = values.enumerated().map { i, v in
            CGPoint(x: bounds.width * CGFloat(first + i) / slots,
                    y: bounds.height * CGFloat((v - s.mid) / s.span + 0.5))
        }
        let path = CGMutablePath()
        guard let start = points.first else { return path }
        path.move(to: start)
        for (a, b) in zip(points, points.dropFirst()) {
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }
}

struct Stat: View {
    let title: LocalizedStringKey
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            // Plain text: rolling digits here re-rendered the window every second.
            Text(value).font(.system(.body, design: .rounded).weight(.medium).monospacedDigit())
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Header: View {
    @ObservedObject var m: Monitor
    var body: some View {
        let (stateText, stateColor) = thermalText(m.thermal)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Температура CPU").font(.caption).foregroundStyle(.secondary)
                    RollingText(value: fmt(m.cpuHot))
                        .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tempColor(m.cpuHot ?? 0))
                        .help("Самое горячее ядро, среднее за 5 секунд")
                    Text("пик за 5 с: \(fmt(m.cpuPeak))").font(.caption).foregroundStyle(.secondary)
                    Label(stateText, systemImage: "thermometer.medium").foregroundStyle(stateColor).font(.callout)
                        .help("Оценка macOS: снижает ли система частоты из-за нагрева")
                    Sparkline(values: m.history)
                        .frame(width: 160, height: 32)
                        .padding(.top, 6)
                        .help("Температура CPU за последние 3 минуты")
                }
                .frame(width: 170, alignment: .leading)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        SectionTitle("Тепло")
                        Stat(title: "CPU средн.", value: fmt(m.cpuMean), color: tempColor(m.cpuMean ?? 0))
                        Stat(title: "GPU", value: fmt(m.gpuHot), color: tempColor(m.gpuHot ?? 0))
                        Stat(title: "SSD", value: fmt(m.ssd))
                        Stat(title: "Батарея", value: fmt(m.batteryTemp))
                        Stat(title: "Трекпад",
                             value: m.palmRest.isEmpty ? "—" : m.palmRest.map(fmt).joined(separator: " · "),
                             color: caseColor(m.palmRest.max() ?? 0))
                            .help("Датчики трекпада: поверхность и привод отклика")
                        Stat(title: m.fans.count > 1 ? "Вентиляторы" : "Вентилятор", value: fansText)
                    }
                    GridRow {
                        SectionTitle("Нагрузка")
                        Stat(title: "CPU · \(SystemInfo.cores) ядер", value: String(format: "%.0f%%", m.cpuUsage))
                        Stat(title: "GPU", value: gpuText)
                            .help("Доля времени, когда GPU занят. На низкой частоте лёгкая работа даёт десятки процентов; реальную нагрузку показывают ватты")
                        Stat(title: "Память", value: ofGB(m.memUsed, SystemInfo.totalRAM))
                        Stat(title: "Swap", value: m.swap.total > 0 ? ofGB(m.swap.used, m.swap.total) : tr("нет"))
                        Stat(title: "Диск свободно", value: m.disk.map { ofGB($0.free, $0.total) } ?? "—")
                            .gridCellColumns(m.fans.isEmpty ? 2 : 1)
                        if !m.fans.isEmpty { FanSwitch(m: m) }
                    }
                    if let b = m.battery {
                        PowerRow(b: b)
                    }
                }
            }
            if let b = m.battery {
                let s = adapterStatus(b)
                Label(s.1, systemImage: s.0)
                    .font(.callout).foregroundStyle(s.2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(m.heatReason, systemImage: "flame")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
    }

    private var fansText: String {
        if m.fans.isEmpty { return tr("нет") }
        let rpm = m.fans.map(\.rpm).max() ?? 0
        return rpm < 1 ? tr("стоят") : String(format: tr("%.0f об/мин"), rpm)
    }

    private var gpuText: String {
        guard let busy = m.gpu else { return "—" }
        let pct = String(format: "%.0f%%", busy)
        return m.gpuWatts.map { pct + " · " + w($0) } ?? pct
    }
}

/// Auto or maximum fans; the state comes from the SMC, so another fan app's manual mode shows too.
struct FanSwitch: View {
    @ObservedObject var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Режим").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Picker("Режим вентиляторов", selection: Binding(
                get: { m.fanTarget ?? m.fans.contains { $0.manual } },
                set: { m.setFans(max: $0) })) {
                Text("Авто").tag(false)
                Text("Макс").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            .help("Макс спрашивает пароль администратора. При выходе из приложения вентиляторы вернутся в Авто.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .frame(width: 70, alignment: .leading)
    }
}

struct PowerRow: View {
    let b: SystemInfo.Battery

    // The status line below explains charging; the tile keeps only what fits: percent and time left.
    private var timeLeft: String? {
        guard !b.plugged, let m = b.minutesLeft else { return nil }
        return String(format: "%ld:%02ld", m / 60, m % 60)
    }

    private var flow: (String, Color) {
        guard let v = b.batteryW else { return ("—", .primary) }
        if v > 0.3 { return (String(format: tr("+%.1f Вт"), v), .green) }
        if v < -0.3 { return (String(format: tr("−%.1f Вт"), -v), b.plugged ? .orange : .primary) }
        return (tr("0 Вт"), .primary)
    }

    var body: some View {
        GridRow {
            SectionTitle("Питание")
            Stat(title: "Заряд", value: [b.percent.map { "\($0)%" }, timeLeft].compactMap { $0 }.joined(separator: " · "))
            Stat(title: "Батарея сейчас", value: flow.0, color: flow.1)
            Stat(title: "Потребляет", value: w(b.systemW))
            Stat(title: "Адаптер", value: !b.plugged ? tr("не подключён")
                 : b.adapterInW.flatMap { inW in b.adapterMaxW.map { String(format: tr("%.0f из %ld Вт"), inW, $0) } } ?? w(b.adapterInW))
                .help("Сколько ватт идёт от адаптера и сколько доступно. Доступное Mac согласует с блоком питания: разъём может дать меньше, чем написано на блоке.")
            Stat(title: "Здоровье", value: [b.healthPercent.map { "\($0)%" }, b.cycles.map { String(format: tr("%ld цикл."), $0) }]
                    .compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
                .gridCellColumns(2)
        }
    }
}

func adapterStatus(_ b: SystemInfo.Battery) -> (String, String, Color) {
    guard b.plugged else {
        return ("battery.50percent", String(format: tr("Работает от батареи: Mac берёт %@."), w(b.systemW)), .secondary)
    }
    let rated = b.adapterMaxW.map { String(format: tr("%ld Вт"), $0) } ?? "?"
    if let v = b.batteryW, v < -0.5 {
        return ("exclamationmark.triangle.fill",
                String(format: tr("Блока питания не хватает: Mac берёт %@, от адаптера приходит %@ из %@ доступных, "), w(b.systemW), w(b.adapterInW), rated)
                + String(format: tr("ещё %.1f Вт идёт из батареи."), -v), .orange)
    }
    if let inW = b.adapterInW, let max = b.adapterMaxW, inW >= Double(max) * 0.9 {
        // The battery takes the surplus, and macOS slows charging before the Mac itself runs short.
        if let v = b.batteryW, v > 5 {
            return ("bolt.fill", String(format: tr("Быстрая зарядка: от адаптера %@ из %@ доступных, в батарею идёт +%.0f Вт."), w(inW), rated, v), .green)
        }
        return ("exclamationmark.circle", String(format: tr("Блок питания на пределе: %@ из %@ доступных."), w(inW), rated), .yellow)
    }
    var spare = ""
    if let max = b.adapterMaxW, let inW = b.adapterInW { spare = String(format: tr(", запас %.0f Вт"), Double(max) - inW) }
    if let v = b.batteryW, v > 0.3 {
        return ("bolt.fill", String(format: tr("Блока питания хватает: батарея заряжается на +%.1f Вт"), v) + spare + ".", .green)
    }
    if !b.charging, let p = b.percent, p < 95 {
        return ("pause.circle", tr("Подключено, но не заряжается: оптимизированная зарядка или лимит заряда в настройках."), .secondary)
    }
    return ("checkmark.circle", String(format: tr("Блока питания хватает: доступно %@"), rated) + spare + ".", .green)
}

struct HeatBar: View {
    let value: Double
    let share: Double
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                Capsule().fill(share > 0.6 ? Color.red : share > 0.25 ? .orange : .yellow)
                    .frame(width: 50 * min(max(share, 0), 1))
            }
            .frame(width: 50, height: 6)
            Text(String(format: "%.1f", value)).monospacedDigit()
        }
    }
}

struct ProcessTable: View {
    @ObservedObject var m: Monitor
    @Binding var selection: Set<Row.ID>
    @Binding var columns: TableColumnCustomization<Row>

    var body: some View {
        let maxHeat = max(m.rows.map(\.heat).max() ?? 0, 1)
        Table(m.rows, selection: $selection, sortOrder: $m.sortOrder, columnCustomization: $columns) {
            TableColumn("Процесс", value: \.name) { row in
                HStack(spacing: 6) {
                    // Fixed slot keeps icons aligned whether or not the flame is shown.
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                        .opacity(m.hottest.contains(row.id) ? 1 : 0)
                        .frame(width: 12)
                        .help("Один из главных источников нагрева")
                    Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                    Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
                    if row.count > 1 { Text("×\(row.count)").foregroundStyle(.secondary) }
                }
            }
            .width(min: 180, ideal: 280, max: 340)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Нагрев", value: \.heat) { row in
                HeatBar(value: row.heat, share: row.heat / maxHeat)
            }
            .width(110)
            .customizationID("heat")
            TableColumn(String(format: "CPU %.0f%%", m.cpuUsage), value: \.cpuShare) { row in
                Text(String(format: "%.1f%%", row.cpuShare)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            .customizationID("cpu")
            TableColumn(m.gpu.map { String(format: "GPU %.0f%%", $0) } ?? "GPU", value: \.gpu) { row in
                Text(row.gpu < 0.05 ? "—" : String(format: "%.1f%%", row.gpu)).monospacedDigit()
                    .foregroundStyle(row.gpu < 0.05 ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            .customizationID("gpu")
            TableColumn("Память \(gb(m.memUsed)) ГБ", value: \.memMB) { row in
                Text(row.memMB >= 1024 ? String(format: tr("%.1f ГБ"), row.memMB / 1024) : String(format: tr("%.0f МБ"), row.memMB))
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(110)
            .customizationID("mem")
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = m.rows.first(where: { $0.id == id }) {
                Button("Найти в интернете, что это") { m.search(row) }
                Divider()
                Button("Завершить «\(row.name)»") { m.terminate(row) }
                if let path = row.appPath {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
        }
    }
}

struct ActionBar: View {
    @ObservedObject var m: Monitor
    let selected: Row?
    var body: some View {
        HStack(spacing: 10) {
            if let row = selected {
                Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Text(row.count > 1 ? String(format: tr("процессов: %ld"), row.count) : "PID \(row.pids[0])")
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Найти в интернете") { m.search(row) }
                if let path = row.appPath {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Button("Завершить", role: .destructive) { m.terminate(row) }
                    .keyboardShortcut(.delete, modifiers: [])
            } else {
                Text(m.message ?? tr("Выберите процесс в списке, чтобы завершить его. Клик по заголовку столбца меняет сортировку."))
                    .foregroundStyle(m.message == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// Show/hide table columns; the choice survives relaunches.
struct ColumnsMenu: View {
    @Binding var columns: TableColumnCustomization<Row>
    private let items = [("heat", "Нагрев"), ("cpu", "CPU"), ("gpu", "GPU"), ("mem", "Память")]
    var body: some View {
        Menu("Столбцы") {
            ForEach(items, id: \.0) { id, title in
                Toggle(tr(title), isOn: Binding(
                    get: { columns[visibility: id] != .hidden },
                    set: { columns[visibility: id] = $0 ? .visible : .hidden }))
            }
        }
        .fixedSize()
    }
}

/// Raw dump of every temperature sensor, for finding the right keys on another Mac model.
@MainActor
final class SensorsModel: ObservableObject {
    struct Item: Identifiable { let id: String; let label: String; let value: Double }
    @Published var chip: [Item] = []
    @Published var smc: [Item] = []
    @Published var loading = true

    private let temps = TempReader()
    private let smcReader = SMCReader()
    private var keys: [String] = []
    private var timer: Timer?
    private let io = DispatchQueue(label: "sensors-dump", qos: .utility)

    static let known: [String: String] = [
        "Ts0P": "трекпад", "Ts1P": "привод трекпада",
        "TB0T": "батарея", "TB1T": "батарея 1", "TB2T": "батарея 2",
        "TaLP": "поток воздуха слева", "TaRF": "поток воздуха справа",
        "TW0P": "Wi‑Fi", "TH0x": "SSD", "TH0a": "SSD", "TH0b": "SSD",
    ]

    static func label(_ name: String) -> String {
        if let k = known[name] { return tr(k) }
        if name.hasPrefix("PMU tdie") { return tr("ядро CPU") }
        if name.hasPrefix("PMU tdev") { return tr("чип") }
        if name.hasPrefix("NAND") { return "SSD" }
        if name.hasPrefix("gas gauge") { return tr("батарея") }
        return ""
    }

    func start() {
        guard timer == nil else { return }
        io.async { [smcReader, temps, weak self] in
            let keys = smcReader.temperatureKeys()
            let chip = temps.read()
            let smc = smcReader.temperatures(keys)
            Task { @MainActor in
                self?.keys = keys
                self?.publish(chip, smc)
                self?.loading = false
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        let keys = self.keys
        io.async { [smcReader, temps, weak self] in
            let chip = temps.read()
            let smc = smcReader.temperatures(keys)
            Task { @MainActor in self?.publish(chip, smc) }
        }
    }

    private func publish(_ chip: [String: Double], _ smc: [(key: String, value: Double)]) {
        self.chip = chip.map { Item(id: $0.key, label: Self.label($0.key), value: $0.value) }.sorted { $0.id < $1.id }
        self.smc = smc.map { Item(id: $0.key, label: Self.label($0.key), value: $0.value) }
    }

    var report: String {
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        var lines = ["\(String(cString: model)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     String(format: tr("Тепловое состояние: %@"), thermalText(ProcessInfo.processInfo.thermalState).0), "", tr("Чип:")]
        lines += chip.map { "\($0.id)\t\(String(format: "%.1f", $0.value))\t\($0.label)" }
        lines += ["", "SMC:"]
        lines += smc.map { "\($0.id)\t\(String(format: "%.1f", $0.value))\t\($0.label)" }
        return lines.joined(separator: "\n")
    }
}

struct SensorsView: View {
    @StateObject private var model = SensorsModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Все датчики температуры").font(.headline)
                Spacer()
                Button("Скопировать всё") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.report, forType: .string)
                }
                .disabled(model.loading)
            }
            .padding(12)
            Text("Нагрейте Mac, нажмите «Скопировать всё» и пришлите текст — по нему видно, какие датчики есть у этой модели.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
            List {
                Section("Чип (IOHID)") { ForEach(model.chip) { row($0) } }
                Section("SMC") { ForEach(model.smc) { row($0) } }
            }
            .overlay { if model.loading { ProgressView("Читаю датчики…").controlSize(.small) } }
        }
        .frame(minWidth: 420, minHeight: 500)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func row(_ item: SensorsModel.Item) -> some View {
        HStack {
            Text(item.id).monospaced().lineLimit(1)
            Text(item.label).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(String(format: "%.1f°", item.value)).monospacedDigit().foregroundStyle(tempColor(item.value))
        }
    }
}

struct SensorsButton: View {
    var body: some View {
        Button("Все датчики…") { Windows.shared.showSensors() }
    }
}

struct ContentView: View {
    @ObservedObject var m: Monitor
    @State private var selection = Set<Row.ID>()
    @AppStorage("columns") private var storedColumns = Data()
    @State private var columns: TableColumnCustomization<Row> = {
        var c = TableColumnCustomization<Row>()
        c[visibility: "gpu"] = .hidden
        return c
    }()

    var body: some View {
        let selected = selection.first.flatMap { id in m.rows.first { $0.id == id } }
        VStack(spacing: 0) {
            Header(m: m)
            Divider()
            TabView {
                processes(selected).tabItem { Text("Что греет Mac") }
                AdviceView().tabItem { Text("Советы") }
            }
            .padding(.top, 8)
        }
        .frame(minWidth: 880, minHeight: 640)
        .onChange(of: selection) { _, _ in m.message = nil }
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: storedColumns) { columns = saved }
        }
        .onChange(of: columns) { _, c in storedColumns = (try? JSONEncoder().encode(c)) ?? Data() }
    }

    private func processes(_ selected: Row?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Что греет Mac").font(.headline)
                Text("нагрев = CPU + GPU процесса; на Mac это один чип").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Группировать по приложениям", isOn: $m.grouped).toggleStyle(.checkbox)
                ColumnsMenu(columns: $columns)
                SensorsButton()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ProcessTable(m: m, selection: $selection, columns: $columns)
                .overlay {
                    if m.rows.isEmpty {
                        ProgressView("Собираю список процессов…").controlSize(.small)
                    }
                }
            Divider()
            ActionBar(m: m, selected: selected)
        }
    }
}

/// Main and sensors windows built in AppKit: on macOS 14 SwiftUI opens the first window scene at launch.
@MainActor
final class Windows {
    static let shared = Windows()
    var onMainVisible: ((Bool) -> Void)?
    private var main: NSWindow?
    private var sensors: NSWindow?
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    func showMain(_ m: Monitor) {
        if main == nil {
            let w = window(ContentView(m: m), title: tr("Диспетчер тепла"), size: NSSize(width: 960, height: 760), autosave: "main") { [weak self] in
                self?.main = nil
                self?.onMainVisible?(false)
            }
            observe(w, NSWindow.didChangeOcclusionStateNotification) { [weak self] w in
                self?.onMainVisible?(w.isVisible && w.occlusionState.contains(.visible))
            }
            // Occlusion can misreport with Stage Manager or several displays; a key window is on screen.
            observe(w, NSWindow.didBecomeKeyNotification) { [weak self] _ in self?.onMainVisible?(true) }
            main = w
        }
        present(main!)
    }

    func showSensors() {
        if sensors == nil {
            sensors = window(SensorsView(), title: tr("Все датчики"), size: NSSize(width: 480, height: 640), autosave: "sensors") { [weak self] in
                self?.sensors = nil
            }
        }
        present(sensors!)
    }

    private func observe(_ w: NSWindow, _ name: Notification.Name, _ body: @escaping @MainActor (NSWindow) -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak w] _ in
            MainActor.assumeIsolated { if let w { body(w) } }
        }
        observers[ObjectIdentifier(w), default: []].append(token)
    }

    private func window<V: View>(_ view: V, title: String, size: NSSize, autosave: String, onClose: @escaping @MainActor () -> Void) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.minSize]
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(size)
        w.setFrameAutosaveName(autosave)
        observe(w, NSWindow.willCloseNotification) { [weak self] w in
            onClose()
            // A closed window stays allocated; dropping its view runs onDisappear, which stops the tab timers.
            w.contentViewController = nil
            self?.observers.removeValue(forKey: ObjectIdentifier(w))?.forEach(NotificationCenter.default.removeObserver)
        }
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    private var demand = Demand()
    private var stopTimer: Timer?
    private var status: StatusController?

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: Pref.defaults)
        applyDockPolicy()
        monitor.watchPowerSource()
        Windows.shared.onMainVisible = { [weak self] visible in self?.update { $0.set(window: visible, now: $1) } }
        status = StatusController(monitor: monitor) { [weak self] open in self?.update { $0.set(panel: open, now: $1) } }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update { _, _ in } }
        }
        update { _, _ in }
    }

    // Finder or the Dock icon shows the window; turning the Dock icon on also sends a reopen, with Settings visible.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Windows.shared.showMain(monitor) }
        return false
    }

    func applicationWillTerminate(_ n: Notification) { monitor.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // Full polling while the panel or window is open and 60 s after; the light label timer only when it is off.
    func update(_ change: (inout Demand, Date) -> Void) {
        let now = Date()
        change(&demand, now)
        stopTimer?.invalidate()
        stopTimer = nil
        if demand.wantsFull(at: now) {
            monitor.stopLight()
            monitor.start()
            if let at = demand.stopAt {
                stopTimer = Timer.scheduledTimer(withTimeInterval: max(0, at.timeIntervalSince(now)), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update { _, _ in } }
                }
            }
        } else {
            monitor.stop()
            if UserDefaults.standard.bool(forKey: Pref.liveLabel) { monitor.startLight() } else { monitor.stopLight() }
        }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: Pref.showInDock) ? .regular : .accessory)
    }
}

@main
struct HeatMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsView(dockChanged: { delegate.applyDockPolicy() }) }
    }
}
