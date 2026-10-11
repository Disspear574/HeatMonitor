import Foundation
import IOKit

// Root-only fan switch for Heat Monitor (max | auto | watch <pid> <flag>); it never sets fans below macOS.

var conn: io_connect_t = 0

func call(_ input: [UInt8]) -> [UInt8]? {
    var inp = input
    var out = [UInt8](repeating: 0, count: 80)
    var size = 80
    let r = IOConnectCallStructMethod(conn, 2, &inp, 80, &out, &size)
    return r == kIOReturnSuccess && out[40] == 0 ? out : nil
}

// SMCKeyData_t is 80 bytes: key @0, dataSize @28, dataType @32, result @40, command @42, payload @48.
func info(_ key: String) -> [UInt8]? {
    var input = [UInt8](repeating: 0, count: 80)
    let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    withUnsafeBytes(of: code) { for i in 0..<4 { input[i] = $0[i] } }
    input[42] = 9
    guard let out = call(input) else { return nil }
    input[28..<36] = out[28..<36]
    return input
}

func read(_ key: String) -> [UInt8]? {
    guard var input = info(key) else { return nil }
    let size = Int(input[28])
    input[42] = 5
    return call(input).map { Array($0[48..<48 + size]) }
}

func write(_ key: String, _ bytes: [UInt8]) -> Bool {
    guard var input = info(key), Int(input[28]) == bytes.count else { return false }
    for (i, b) in bytes.enumerated() { input[48 + i] = b }
    input[42] = 6
    return call(input) != nil
}

func fanCount() -> Int { Int(read("FNum")?.first ?? 0) }

// Returns nil on success, or which step the SMC refused.
func setMax() -> String? {
    let n = fanCount()
    guard n > 0 else { return "no fans" }
    // Apple Silicon: Ftst lets a manual mode stick; thermalmonitord may need several seconds to let go.
    guard write("Ftst", [1]) else { return "Ftst write refused" }
    for f in 0..<n {
        var manual = false
        for _ in 0..<100 {
            if write("F\(f)Md", [1]), read("F\(f)Md")?.first == 1 { manual = true; break }
            usleep(100_000)
        }
        guard manual else { return "fan \(f): mode stayed \(read("F\(f)Md")?.first.map(String.init) ?? "?") after 10 s" }
        guard let top = read("F\(f)Mx"), top.count == 4 else { return "fan \(f): no F\(f)Mx" }
        guard write("F\(f)Tg", top) else { return "fan \(f): target write refused" }
    }
    return nil
}

func setAuto() -> Bool {
    var ok = true
    for f in 0..<fanCount() { ok = write("F\(f)Md", [0]) && ok }
    return write("Ftst", [0]) && ok
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard geteuid() == 0 else { fail("heatmonitor-fan must run as root") }
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard svc != 0, IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { fail("SMC is not available") }

switch args.dropFirst().first {
case "max":
    if let error = setMax() { _ = setAuto(); fail(error) }
case "auto":
    if !setAuto() { fail("the SMC did not accept auto fan mode") }
case "watch":
    guard args.count > 3, let pid = Int32(args[2]) else { fail("usage: heatmonitor-fan watch <pid> <flag>") }
    // The flag only ever leads back to auto, so a user-owned file is a safe trigger for a root process.
    let fd = open(args[3], O_EVTONLY)
    let flag = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename], queue: .main)
    let app = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    for source in [flag, app] as [DispatchSourceProtocol] {
        source.setEventHandler { _ = setAuto(); exit(0) }
        source.resume()
    }
    if fd < 0 || (kill(pid, 0) != 0 && errno != EPERM) { _ = setAuto(); exit(0) }
    dispatchMain()
default:
    fail("usage: heatmonitor-fan max | auto | watch <pid> <flag>")
}
