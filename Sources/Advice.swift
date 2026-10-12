import AppKit
import CoreGraphics
import SwiftUI

/// One process from a `ps` snapshot.
struct ProcInfo {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let cpuTime: Double
    let elapsed: Double
    let rss: Double
    let args: String
    let path: String
    var cpu: Double = 0
    var name: String { (path.isEmpty ? args : path).components(separatedBy: "/").last ?? args }
}

enum ProcSnapshot {
    static func read() -> [ProcInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,ppid=,uid=,time=,etime=,rss=,args="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var buf = [CChar](repeating: 0, count: 4096)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard f.count == 7, let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]) else { return nil }
            let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
            return ProcInfo(pid: pid, ppid: ppid, uid: uid, cpuTime: seconds(f[3]), elapsed: seconds(f[4]),
                            rss: (Double(f[5]) ?? 0) * 1024, args: String(f[6]), path: path)
        }
    }

    // Parses ps durations: "[[dd-]hh:]mm:ss[.ss]".
    static func seconds(_ s: Substring) -> Double {
        let dayParts = s.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let clock = dayParts.last ?? ""
        return clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) } + days * 86400
    }
}

/// Live checks behind the Advice tab: WindowServer health, stuck services, leftover dev tools.
@MainActor
final class AdviceModel: ObservableObject {
    struct WindowServer { let cpu: Double; let uptime: Double; let shields: Int; let displays: Int }
    struct Service: Identifiable { let id: Int32; let name: String; let cpu: Double; let average: Double; let uptime: Double; let mine: Bool }
    struct DevGroup: Identifiable {
        let id: String
        let title: String
        let procs: [ProcInfo]
        let booted: Int
        var cpu: Double { procs.reduce(0) { $0 + $1.cpu } }
        var rss: Double { procs.reduce(0) { $0 + $1.rss } }
    }

    @Published var windowServer: WindowServer?
    @Published var services: [Service] = []
    @Published var dev: [DevGroup] = []
    @Published var message: String?

    private var previous: [Int32: Double] = [:]
    private var lastRead = Date()
    private var timer: Timer?
    private let io = DispatchQueue(label: "advice", qos: .utility)

    private static let devPatterns: [(id: String, title: String, match: (ProcInfo) -> Bool)] = [
        ("simulator", "Симуляторы iOS", { $0.path.contains("/CoreSimulator/Devices/") || $0.path.hasSuffix("/launchd_sim") }),
        ("emulator", "Эмуляторы Android", { $0.args.contains("qemu-system") }),
        ("gradle", "Демоны Gradle", { $0.args.contains("org.gradle.launcher.daemon") }),
        ("kotlin", "Демоны Kotlin", { $0.args.contains("KotlinCompileDaemon") }),
    ]

    // These render what is open right now (a tab, a video), so their load is real work, not a stuck loop.
    private static let contentServices = ["com.apple.WebKit.", "VTDecoderXPCService", "VTEncoderXPCService"]

    var stoppable: [String] {
        services.filter(\.mine).map(\.name) + dev.map { tr($0.title) }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 1
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        io.async { [weak self] in
            let procs = ProcSnapshot.read()
            let shieldsByOwner = Self.offscreenShields()
            let displays = Self.onlineDisplays()
            Task { @MainActor in self?.apply(procs, shieldsByOwner: shieldsByOwner, displays: displays) }
        }
    }

    private func apply(_ raw: [ProcInfo], shieldsByOwner: [Int32: Int], displays: Int) {
        let now = Date()
        let dt = now.timeIntervalSince(lastRead)
        lastRead = now
        let me = getuid()
        let procs = raw.map { p -> ProcInfo in
            var p = p
            // CPU since the previous snapshot; the first one has none, so it falls back to the lifetime average.
            if let before = previous[p.pid], dt > 0.5 { p.cpu = max(0, (p.cpuTime - before) / dt * 100) }
            else if p.elapsed > 0 { p.cpu = p.cpuTime / p.elapsed * 100 }
            return p
        }
        previous = Dictionary(procs.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { a, _ in a })

        let ws = procs.first(where: { $0.path.hasSuffix("/WindowServer") || $0.args.hasPrefix("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer") })
        let windowServerPid = ws?.pid
        if let ws {
            windowServer = WindowServer(cpu: ws.cpu, uptime: ws.elapsed, shields: shieldsByOwner[ws.pid] ?? 0, displays: displays)
        }

        var devPids = Set<Int32>()
        dev = Self.devPatterns.compactMap { pattern in
            let found = procs.filter { $0.uid == me && pattern.match($0) }
            guard !found.isEmpty else { return nil }
            devPids.formUnion(found.map(\.pid))
            let booted = found.filter { $0.path.hasSuffix("/launchd_sim") }.count
            if pattern.id == "simulator" && booted == 0 { return nil }
            return DevGroup(id: pattern.id, title: pattern.title, procs: found, booted: booted)
        }

        let skip: Set<Int32> = [getpid(), windowServerPid ?? 0]
        services = procs.filter { p in
            guard p.ppid == 1, !skip.contains(p.pid), !devPids.contains(p.pid), p.elapsed > 600,
                  !Self.contentServices.contains(where: p.name.hasPrefix) else { return false }
            let average = p.cpuTime / p.elapsed * 100
            guard p.cpu > 5, average > 10 else { return false }
            // Opened apps also have launchd as parent; only their helpers count as services.
            let path = p.path.isEmpty ? p.args : p.path
            return path.contains(".xpc/") || path.contains(".appex/") || !path.contains(".app/Contents/MacOS/")
        }
        .sorted { $0.cpu > $1.cpu }
        .map { Service(id: $0.pid, name: $0.name, cpu: $0.cpu, average: $0.cpuTime / $0.elapsed * 100, uptime: $0.elapsed, mine: $0.uid == me) }
    }

    // Shield windows cover a display while it is reconfigured; offscreen ones are left from displays that are gone.
    nonisolated private static func offscreenShields() -> [Int32: Int] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var counts: [Int32: Int] = [:]
        for w in list where (w[kCGWindowLayer as String] as? Int) == Int(Int32.max) - 1
            && (w[kCGWindowIsOnscreen as String] as? Bool) != true {
            if let owner = w[kCGWindowOwnerPID as String] as? Int32 { counts[owner, default: 0] += 1 }
        }
        return counts
    }

    nonisolated private static func onlineDisplays() -> Int {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        return Int(count)
    }

    func stop(_ service: Service) {
        if kill(service.id, SIGTERM) != 0 { message = String(format: tr("Не удалось завершить «%@»."), service.name) }
        refresh()
    }

    func stop(_ group: DevGroup) {
        if group.id == "simulator" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["simctl", "shutdown", "all"]
            p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.refresh() } }
            if (try? p.run()) == nil { message = tr("Не удалось выключить симуляторы: нет xcrun.") }
            return
        }
        let failed = group.procs.filter { kill($0.pid, SIGTERM) != 0 }
        if !failed.isEmpty { message = String(format: tr("Не удалось завершить «%@»."), tr(group.title)) }
        refresh()
    }

    func stopAll() {
        services.filter(\.mine).forEach { stop($0) }
        dev.forEach { stop($0) }
    }
}

// ps reports percent of one core; the process table shows a share of all cores, so the tab does the same.
func share(_ cpu: Double) -> Int { Int((cpu / Double(max(SystemInfo.cores, 1))).rounded()) }

func duration(_ s: Double) -> String {
    let m = Int(s) / 60
    if m >= 1440 { return String(format: tr("%ld д %ld ч"), m / 1440, m % 1440 / 60) }
    if m >= 60 { return String(format: tr("%ld ч %ld мин"), m / 60, m % 60) }
    return String(format: tr("%ld мин"), m)
}

struct AdviceView: View {
    @StateObject private var model = AdviceModel()
    @State private var confirmStopAll = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    windowServerCard
                    servicesCard
                    devCard
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text(model.message ?? tr("Проверки обновляются каждые 5 секунд, пока открыта эта вкладка."))
                    .foregroundStyle(model.message == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                Spacer()
                Button("Остановить всё найденное", role: .destructive) { confirmStopAll = true }
                    .disabled(model.stoppable.isEmpty)
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert("Остановить всё найденное?", isPresented: $confirmStopAll) {
            Button("Остановить", role: .destructive) { model.stopAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(model.stoppable.joined(separator: "\n"))
        }
    }

    private var windowServerCard: some View {
        let ws = model.windowServer
        let stale = ws.map { $0.shields > 100 || $0.uptime > 7 * 86400 } ?? false
        let busy = (ws?.cpu ?? 0) > 20
        let color: Color = !busy ? .green : stale ? .orange : .yellow
        return AdviceCard(color: color, title: tr("WindowServer — рисует весь экран")) {
            if let ws {
                Text(String(format: tr("CPU %ld%% · работает %@ · окон от отключённых дисплеев: %ld · дисплеев: %ld"),
                            share(ws.cpu), duration(ws.uptime), ws.shields, ws.displays))
                    .monospacedDigit()
            }
            Text(!busy ? tr("В норме.")
                 : stale ? tr("WindowServer давно не перезапускался и хранит окна дисплеев, которые уже отключены. Такой WindowServer тратит CPU сам по себе: прятать или закрывать приложения бесполезно. Выйдите из системы и войдите снова или перезагрузите Mac.")
                 : tr("WindowServer рисует то, что показывают приложения. Чаще всего его грузят видео, анимации и окна на Electron. Прячьте приложения по одному (⌘H) и смотрите, когда CPU упадёт."))
                .foregroundStyle(.secondary)
        }
    }

    private var servicesCard: some View {
        AdviceCard(color: model.services.isEmpty ? .green : .orange, title: tr("Зависшие фоновые службы")) {
            Text("Служба, которую macOS запускает по запросу, иногда зацикливается и часами грузит процессор. Её можно завершить: macOS запустит её снова, когда она понадобится.")
                .foregroundStyle(.secondary)
            if model.services.isEmpty { Text("Не найдено.") }
            ForEach(model.services) { s in
                HStack {
                    Text(s.name).lineLimit(1).truncationMode(.middle).help(s.name)
                    Text(String(format: tr("сейчас %ld%% · в среднем %ld%% за %@"), share(s.cpu), share(s.average), duration(s.uptime)))
                        .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    Spacer()
                    if s.mine {
                        Button("Завершить") { model.stop(s) }
                    } else {
                        Text("системная").foregroundStyle(.secondary)
                            .help(tr("Системную службу может завершить только администратор. Обычно она успокаивается сама: индексация и обновления заканчиваются."))
                    }
                }
            }
        }
    }

    private var devCard: some View {
        AdviceCard(color: model.dev.isEmpty ? .green : .orange, title: tr("Забытые процессы разработки")) {
            Text("Симуляторы, эмуляторы Android и демоны Gradle и Kotlin продолжают работать после сборки и держат память и процессор.")
                .foregroundStyle(.secondary)
            if model.dev.isEmpty { Text("Не найдено.") }
            ForEach(model.dev) { g in
                HStack {
                    Text(tr(g.title)).lineLimit(1)
                    Text(String(format: tr("процессов: %ld"), g.procs.count) + " · CPU \(share(g.cpu))% · " + String(format: tr("%@ ГБ"), gb(g.rss)))
                        .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    Spacer()
                    Button("Остановить") { model.stop(g) }
                }
            }
        }
    }
}

/// A titled advice block with a status dot.
struct AdviceCard<Content: View>: View {
    let color: Color
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.headline)
            }
        }
    }
}
