import AppKit
import IOKit

/// Energy Mode on the adapter: reads `pmset`, switches it through the system admin prompt.
@MainActor
final class EnergyModeModel: ObservableObject {
    @Published private(set) var acMode: EnergyMode?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var adapterName: String?
    @Published private(set) var negotiatedW: Int?

    private let io = DispatchQueue(label: "energy-mode", qos: .utility)

    func refresh() {
        io.async {
            let mode = Self.run("/usr/bin/pmset", ["-g", "custom"]).map { acEnergyMode(pmsetCustom: $0.out) } ?? nil
            let adapter = Self.adapterDetails()
            DispatchQueue.main.async {
                self.acMode = mode
                self.adapterName = adapter.name
                self.negotiatedW = adapter.watts
            }
        }
    }

    // osascript shows the macOS password prompt; HeatMonitor never sees the password.
    func set(_ mode: EnergyMode) {
        guard !busy else { return }
        busy = true
        error = nil
        let prompt = tr("HeatMonitor меняет режим энергопотребления от адаптера.").replacingOccurrences(of: "\"", with: "")
        let script = "do shell script \"/usr/bin/pmset -c powermode \(mode.rawValue)\" with prompt \"\(prompt)\" with administrator privileges"
        io.async {
            let r = Self.run("/usr/bin/osascript", ["-e", script])
            let cancelled = r?.err.contains("-128") ?? false
            DispatchQueue.main.async {
                self.busy = false
                if r?.status != 0, !cancelled { self.error = tr("Не удалось сменить режим.") }
                self.refresh()
            }
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return nil }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    nonisolated private static func adapterDetails() -> (name: String?, watts: Int?) {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard s != 0 else { return (nil, nil) }
        defer { IOObjectRelease(s) }
        let d = IORegistryEntryCreateCFProperty(s, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return (d?["Name"] as? String, d?["Watts"] as? Int)
    }
}
