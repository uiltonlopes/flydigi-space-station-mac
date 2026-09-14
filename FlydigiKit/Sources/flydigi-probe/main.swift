// flydigi-probe — read-only survey of a Flydigi controller for people who own models we cannot test.
//
// It lists the controller's USB and HID interfaces (descriptors included), records a few seconds of input
// reports while the owner presses buttons and moves the sticks, reads the XInput-class interface directly when
// no system driver owns it (the new-generation pads under Flydigi's own vendor id, after the Xbox 360 start
// handshake), and asks the pad who it is with the identification command of its generation. It never writes
// configuration, never changes modes, never flashes. The report is a text file on the Desktop meant to be sent to
// the maintainers (docs/adding-a-controller.md).

import Foundation
import IOKit
import IOKit.hid
import IOKit.usb
import FlydigiKit

let version = "0.2.4"
let seconds: Double = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 15
let vendors: [Int] = [0x04B4, 0x37D7, 0x045E, 0x057E]   // classic DInput (Cypress), Flydigi's own VID, Xbox identity, Nintendo identity (Switch mode)
nonisolated(unsafe) var report: [String] = []
setvbuf(stdout, nil, _IOLBF, 0)
func out(_ s: String) { print(s); report.append(s) }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
func looksFlydigi(_ s: String?) -> Bool {
    guard let s = s?.lowercased() else { return false }
    return ["flydigi", "apex", "vader", "direwolf", "dunefox", "feizhi", "pro controller"].contains { s.contains($0) }
}
func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
/// Report ids a HID report descriptor uses for Output items inside the top-level collection whose usage page is
/// `page`; `[0]` when that collection declares none (the Vader 5 Pro's 0xFFA0), `[]` when there is no such
/// collection. Other collections on the same interface are skipped on purpose: the Apex 5 keeps its 0xFFEF
/// firmware-update collection (output report 8) in the same descriptor as 0xFFA0, and the heartbeat must not go there.
func outputReportIDs(_ d: [UInt8], usagePage page: Int) -> [UInt8] {
    var ids = Set<UInt8>(), reportID: UInt8 = 0, currentPage = 0, depth = 0, inWanted = false, sawWanted = false, i = 0
    while i < d.count {
        let prefix = d[i]
        if prefix == 0xFE { i += 3 + (i + 1 < d.count ? Int(d[i + 1]) : 0); continue }   // long item
        let size = [0, 1, 2, 4][Int(prefix & 3)]
        var data = 0
        for k in 0..<size where i + 1 + k < d.count { data |= Int(d[i + 1 + k]) << (8 * k) }
        switch prefix & 0xFC {
        case 0x04: currentPage = data                                                                 // Usage Page (global)
        case 0x84: reportID = UInt8(truncatingIfNeeded: data)                                         // Report ID (global)
        case 0xA0: if depth == 0 { inWanted = currentPage == page; sawWanted = sawWanted || inWanted }; depth += 1   // Collection
        case 0xC0: depth -= 1                                                                          // End Collection
        case 0x90: if inWanted { ids.insert(reportID) }                                                // Output
        default: break
        }
        i += 1 + size
    }
    guard sawWanted else { return [] }
    return ids.isEmpty ? [0] : ids.sorted()
}
/// New-generation heartbeat reply fields, checked on a Vader 5 Pro against the versions Flydigi's app shows
/// (issue #1): device id at byte 5, firmware at 15–16 with one digit per nibble. A leading report id is skipped.
func heartbeatInfo(_ r: [UInt8]) -> String? {
    let b = r.first == 0x5A ? r : Array(r.dropFirst())
    guard b.count >= 17, b[0] == 0x5A, b[1] == 0xA5, b[2] == 0x01 else { return nil }
    let firmware = [b[15] >> 4, b[15] & 0xF, b[16] >> 4, b[16] & 0xF].map(String.init).joined(separator: ".")
    return "device id \(b[5]) (\(DeviceCatalog.descriptor(for: b[5])?.name ?? "not in the catalog")) · firmware \(firmware)"
}

out("flydigi-probe \(version) · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(ISO8601DateFormatter().string(from: Date()))")
out("Read-only: only identity requests and the Xbox 360 start handshake are sent; nothing is written to the controller's memory.")
out("")

// MARK: - 1. USB registry (what macOS sees before any driver)

struct USBDev { let service: io_service_t; let vid: Int; let pid: Int; let name: String; var xinputClassInterface: Int? }
var usbDevices: [USBDev] = []
var exclusiveOwners: [String] = []
out("== USB devices")
var usbIter: io_iterator_t = 0
if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &usbIter) == kIOReturnSuccess {
    var dev = IOIteratorNext(usbIter)
    while dev != 0 {
        let vid = int(property(dev, "idVendor")) ?? 0, pid = int(property(dev, "idProduct")) ?? 0
        let product = property(dev, "USB Product Name") as? String, vendor = property(dev, "USB Vendor Name") as? String
        guard vendors.contains(vid) || looksFlydigi(product) || looksFlydigi(vendor) else { IOObjectRelease(dev); dev = IOIteratorNext(usbIter); continue }
        var entry = USBDev(service: dev, vid: vid, pid: pid, name: product ?? "?", xinputClassInterface: nil)
        out(String(format: "  %04x:%04x  \"%@\" by \"%@\"  bcdDevice %@  serial %@", vid, pid, product ?? "?", vendor ?? "?",
                   int(property(dev, "bcdDevice")).map { String(format: "%04x", $0) } ?? "?", (property(dev, "USB Serial Number") as? String) ?? "-"))
        // Steam takes Xbox-style pads for itself while it runs; nothing else can open interface 0 then.
        if let owner = property(dev, "UsbExclusiveOwner") as? String { out("      held exclusively by \(owner)"); exclusiveOwners.append(owner) }
        var ifIter: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(dev, kIOServicePlane, &ifIter) == kIOReturnSuccess {
            var intf = IOIteratorNext(ifIter)
            while intf != 0 {
                var cls = [CChar](repeating: 0, count: 128); IOObjectGetClass(intf, &cls)
                if String(cString: cls).contains("Interface") {
                    let num = int(property(intf, "bInterfaceNumber")) ?? -1
                    let c = int(property(intf, "bInterfaceClass")) ?? 0, sc = int(property(intf, "bInterfaceSubClass")) ?? 0, pr = int(property(intf, "bInterfaceProtocol")) ?? 0
                    // Which kernel driver (if any) took the interface — tells us whether we can read it ourselves.
                    var drv: io_iterator_t = 0; var driver = "no driver"
                    if IORegistryEntryGetChildIterator(intf, kIOServicePlane, &drv) == kIOReturnSuccess {
                        let child = IOIteratorNext(drv)
                        if child != 0 { var dc = [CChar](repeating: 0, count: 128); IOObjectGetClass(child, &dc); driver = String(cString: dc); IOObjectRelease(child) }
                        IOObjectRelease(drv)
                    }
                    out(String(format: "      interface %d: class %02x/%02x/%02x  endpoints %@  → %@", num, c, sc, pr, int(property(intf, "bNumEndpoints")).map(String.init) ?? "?", driver))
                    if c == 0xFF && sc == 0x5D && driver == "no driver" { entry.xinputClassInterface = num }
                }
                IOObjectRelease(intf); intf = IOIteratorNext(ifIter)
            }
            IOObjectRelease(ifIter)
        }
        usbDevices.append(entry)              // keeps `dev` retained for the raw read below
        dev = IOIteratorNext(usbIter)
    }
    IOObjectRelease(usbIter)
}
if usbDevices.isEmpty { out("  (no Flydigi-looking USB device — is the controller connected with a cable or its dongle?)") }
out("")
if let owner = exclusiveOwners.first {
    // A report taken now would say the pad sends nothing, which is how a Vader 5 Pro was first misread (issue #1).
    let process = owner.components(separatedBy: ", ").last ?? owner
    let app = process.lowercased().hasPrefix("steam") ? "Steam" : process
    print("Another app holds the controller exclusively (\(owner)). Quit \(app) completely (⌘Q; closing its window is not enough) and run the probe again.")
    exit(2)
}

// MARK: - 2. HID interfaces (descriptors are the most useful part for a new model)

out("== HID interfaces")
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
let all = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
func hidProp(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
func isGameController(_ d: IOHIDDevice) -> Bool { int(hidProp(d, kIOHIDPrimaryUsagePageKey)) == 1 && [4, 5, 8].contains(int(hidProp(d, kIOHIDPrimaryUsageKey)) ?? 0) }
let flydigiHID = all.filter { d in
    let vid = int(hidProp(d, kIOHIDVendorIDKey)) ?? 0
    return vendors.contains(vid) || looksFlydigi(hidProp(d, kIOHIDProductKey) as? String) || looksFlydigi(hidProp(d, kIOHIDManufacturerKey) as? String)
}.sorted { (int(hidProp($0, kIOHIDLocationIDKey)) ?? 0, int(hidProp($0, kIOHIDPrimaryUsagePageKey)) ?? 0) < (int(hidProp($1, kIOHIDLocationIDKey)) ?? 0, int(hidProp($1, kIOHIDPrimaryUsagePageKey)) ?? 0) }
for (i, d) in flydigiHID.enumerated() {
    out(String(format: "  #%d  %04x:%04x  \"%@\"  usage %04x/%04x  transport %@  reports in %d / out %d / feature %d  version %@",
               i, int(hidProp(d, kIOHIDVendorIDKey)) ?? 0, int(hidProp(d, kIOHIDProductIDKey)) ?? 0, (hidProp(d, kIOHIDProductKey) as? String) ?? "?",
               int(hidProp(d, kIOHIDPrimaryUsagePageKey)) ?? 0, int(hidProp(d, kIOHIDPrimaryUsageKey)) ?? 0, (hidProp(d, kIOHIDTransportKey) as? String) ?? "?",
               int(hidProp(d, kIOHIDMaxInputReportSizeKey)) ?? 0, int(hidProp(d, kIOHIDMaxOutputReportSizeKey)) ?? 0, int(hidProp(d, kIOHIDMaxFeatureReportSizeKey)) ?? 0,
               int(hidProp(d, kIOHIDVersionNumberKey)).map { String(format: "%04x", $0) } ?? "?"))
    if let desc = hidProp(d, kIOHIDReportDescriptorKey) as? Data { out("      report descriptor (\(desc.count) B): " + hex([UInt8](desc))) }
}
if flydigiHID.isEmpty { out("  (none)") }
let otherPads = all.filter { isGameController($0) && !flydigiHID.contains($0) }
if !otherPads.isEmpty {
    out("  other game controllers visible to macOS right now:")
    for d in otherPads { out(String(format: "    %04x:%04x  \"%@\" by \"%@\"", int(hidProp(d, kIOHIDVendorIDKey)) ?? 0, int(hidProp(d, kIOHIDProductIDKey)) ?? 0, (hidProp(d, kIOHIDProductKey) as? String) ?? "?", (hidProp(d, kIOHIDManufacturerKey) as? String) ?? "?")) }
}
out("")

// MARK: - 3. Capture: HID input reports + raw XInput-class interfaces nobody drives

/// Every reply-looking packet from every capture, in arrival order: the answer to a write on one interface can come
/// back on another (a Vader 5 Pro answers a heartbeat on interface 0's OUT endpoint through its 0xFFA0 HID).
final class ReplyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(source: String, bytes: [UInt8])] = []
    func add(_ source: String, _ r: [UInt8]) { lock.lock(); if entries.count < 256 { entries.append((source, r)) }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    func since(_ n: Int) -> [(source: String, bytes: [UInt8])] { lock.lock(); defer { lock.unlock() }; return Array(entries.dropFirst(n)) }
}

final class Capture: @unchecked Sendable {
    static let log = ReplyLog()
    let label: String
    init(label: String) { self.label = label }
    let lock = NSLock()
    var perId: [UInt8: (count: Int, first: [UInt8], last: [UInt8], changed: Set<Int>)] = [:]
    var replies: [[UInt8]] = []                          // command replies kept apart from the status stream
    var errors: [IOReturn: Int] = [:]                    // failed reads, reported rather than hidden
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    static let callback: IOHIDReportCallback = { ctx, _, _, _, _, ptr, len in
        Unmanaged<Capture>.fromOpaque(ctx!).takeUnretainedValue().add(Array(UnsafeBufferPointer(start: ptr, count: Int(len))))
    }
    func add(_ r: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let isReply = r.count > 3 && ((r[0] == 4 && r[1] == 0xFF) || (r[0] == 0x5A && r[1] == 0xA5) || (r[1] == 0x5A && r[2] == 0xA5))
        if isReply, replies.count < 32 { replies.append(r); Capture.log.add(label, r); return }
        let id = r.first ?? 0
        if var e = perId[id] {
            e.count += 1
            for i in 0..<min(e.last.count, r.count) where e.last[i] != r[i] { e.changed.insert(i) }
            e.last = r; perId[id] = e
        } else { perId[id] = (1, r, r, []) }
    }
    func failed(_ kr: IOReturn) { lock.lock(); errors[kr, default: 0] += 1; lock.unlock() }
    func summary(indent: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let errorLine = errors.isEmpty ? [] : [indent + "read errors: " + errors.sorted(by: { $0.key < $1.key }).map { String(format: "0x%08x ×%d", UInt32(bitPattern: $0.key), $0.value) }.joined(separator: ", ")]
        if perId.isEmpty { return ["\(indent)no input reports"] + errorLine }
        return perId.sorted(by: { $0.key < $1.key }).flatMap { id, e in
            [String(format: "%@report id %02x: %d reports (%d B)  changing bytes: %@", indent, id, e.count, e.first.count, e.changed.sorted().map(String.init).joined(separator: ",")),
             "\(indent)  first: " + hex(e.first), "\(indent)  last:  " + hex(e.last)]
        } + errorLine
    }
}

// 3a. HID
var captures: [(IOHIDDevice, Capture, String)] = []
let queue = DispatchQueue(label: "probe.hid")
for d in flydigiHID {
    let vid = int(hidProp(d, kIOHIDVendorIDKey)) ?? 0
    let label = String(format: "%04x:%04x usage %04x", vid, int(hidProp(d, kIOHIDProductIDKey)) ?? 0, int(hidProp(d, kIOHIDPrimaryUsagePageKey)) ?? 0)
    guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { out("  \(label): cannot open (owned by a system driver)"); continue }
    let cap = Capture(label: label)
    IOHIDDeviceSetDispatchQueue(d, queue)
    IOHIDDeviceRegisterInputReportCallback(d, cap.buffer, 1024, Capture.callback, Unmanaged.passUnretained(cap).toOpaque())
    IOHIDDeviceActivate(d)
    captures.append((d, cap, label))
}

// 3b. Raw USB read of XInput-class interfaces that no driver claimed (new-generation pads on macOS)
enum UUIDs {
    static var cfPlugIn: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F) }
    static var deviceUserClient: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61) }
    static var interfaceUserClient: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xD4, 0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61) }
    static var deviceInterface650: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0x4A, 0xAC, 0x1B, 0x2E, 0x24, 0xC2, 0x47, 0x6A, 0x96, 0x4D, 0x91, 0x33, 0x35, 0x34, 0xF2, 0xCC) }
    static var interfaceInterface800: CFUUID { CFUUIDGetConstantUUIDWithBytes(nil, 0x33, 0xA8, 0x5D, 0xB0, 0x0C, 0x3B, 0x43, 0x28, 0x8F, 0x02, 0xFD, 0xA8, 0x1B, 0x11, 0x7F, 0x4C) }
}
typealias DevicePtr = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface650>?>
typealias InterfacePtr = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface800>?>
struct ProbeError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

final class RawUSB: @unchecked Sendable {
    let cap: Capture
    let label: String
    var device: DevicePtr?
    var intf: InterfacePtr?
    let vid: Int, pid: Int, interfaceNumber: Int
    var pipe: UInt8 = 0
    var outPipe: UInt8 = 0
    var maxPacket: UInt16 = 64
    var thread: Thread?
    nonisolated(unsafe) var stop = false
    var error: String?
    var note: String?
    var deviceOpened = false
    init(_ d: USBDev, interfaceNumber: Int) {
        vid = d.vid; pid = d.pid; self.interfaceNumber = interfaceNumber
        label = String(format: "%04x:%04x interface %d (XInput-class, raw USB)", d.vid, d.pid, interfaceNumber)
        cap = Capture(label: label)
        do {
            var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?; var score: Int32 = 0
            var kr = IOCreatePlugInInterfaceForService(d.service, UUIDs.deviceUserClient, UUIDs.cfPlugIn, &plugIn, &score)
            guard kr == kIOReturnSuccess, let plugIn else { throw ProbeError(String(format: "device plug-in 0x%08x", UInt32(bitPattern: kr))) }
            var raw: LPVOID?
            guard plugIn.pointee!.pointee.QueryInterface(plugIn, CFUUIDGetUUIDBytes(UUIDs.deviceInterface650), &raw) == S_OK, let raw else { throw ProbeError("QueryInterface(device)") }
            _ = plugIn.pointee!.pointee.Release(plugIn)
            let dev = DevicePtr(OpaquePointer(raw)); device = dev
            // Device-level open is optional: a kernel driver on another interface (the keyboard/mouse HID one)
            // makes it fail, but the unclaimed interface can still be opened on its own.
            kr = dev.pointee!.pointee.USBDeviceOpen(dev)
            deviceOpened = kr == kIOReturnSuccess
            if !deviceOpened { note = String(format: "device open 0x%08x, opening the interface alone", UInt32(bitPattern: kr)) }
            var request = IOUSBFindInterfaceRequest(bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare), bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare), bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare), bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))
            var it: io_iterator_t = 0
            guard dev.pointee!.pointee.CreateInterfaceIterator(dev, &request, &it) == kIOReturnSuccess else { throw ProbeError("CreateInterfaceIterator") }
            var svc: io_service_t = 0
            while case let s = IOIteratorNext(it), s != 0 { if int(property(s, "bInterfaceNumber")) == interfaceNumber { svc = s; break }; IOObjectRelease(s) }
            IOObjectRelease(it)
            guard svc != 0 else { throw ProbeError("interface not found") }
            var iplug: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            kr = IOCreatePlugInInterfaceForService(svc, UUIDs.interfaceUserClient, UUIDs.cfPlugIn, &iplug, &score); IOObjectRelease(svc)
            guard kr == kIOReturnSuccess, let iplug else { throw ProbeError(String(format: "interface plug-in 0x%08x", UInt32(bitPattern: kr))) }
            var iraw: LPVOID?
            guard iplug.pointee!.pointee.QueryInterface(iplug, CFUUIDGetUUIDBytes(UUIDs.interfaceInterface800), &iraw) == S_OK, let iraw else { throw ProbeError("QueryInterface(interface)") }
            _ = iplug.pointee!.pointee.Release(iplug)
            let i = InterfacePtr(OpaquePointer(iraw)); intf = i
            kr = i.pointee!.pointee.USBInterfaceOpen(i)
            guard kr == kIOReturnSuccess else { throw ProbeError(String(format: "USBInterfaceOpen 0x%08x", UInt32(bitPattern: kr))) }
            var n: UInt8 = 0; _ = i.pointee!.pointee.GetNumEndpoints(i, &n)
            for p in 1...max(1, n) {
                var dir: UInt8 = 0, num: UInt8 = 0, type: UInt8 = 0, interval: UInt8 = 0, mp: UInt16 = 0
                guard i.pointee!.pointee.GetPipeProperties(i, p, &dir, &num, &type, &mp, &interval) == kIOReturnSuccess else { continue }
                if dir == UInt8(kUSBIn) && type == UInt8(kUSBInterrupt) { pipe = p; maxPacket = mp }
                if dir == UInt8(kUSBOut) && type == UInt8(kUSBInterrupt) { outPipe = p }
            }
            guard pipe != 0 else { throw ProbeError("no interrupt IN pipe") }
        } catch { self.error = "\(error)" }
    }
    /// The Xbox 360 start handshake Linux xpad sends (`xpad_start_xbox_360`): three vendor IN requests, nothing
    /// written. A wired Vader 5 Pro sends one idle report and then stays silent until it gets them; on its dongle
    /// it streams without them and answers them all the same (issue #1).
    func handshake() -> [String] {
        guard error == nil, let i = intf else { return [] }
        return [(UInt8(0xC1), UInt16(0x0100), UInt16(20)), (0xC1, 0x0000, 8), (0xC0, 0x0000, 4)].map { type, value, length in
            var buf = [UInt8](repeating: 0, count: Int(length))
            var done: UInt32 = 0
            let kr: IOReturn = buf.withUnsafeMutableBytes { p in
                var rq = IOUSBDevRequestTO(bmRequestType: type, bRequest: 1, wValue: value, wIndex: 0, wLength: length, pData: p.baseAddress, wLenDone: 0, noDataTimeout: 1000, completionTimeout: 1000)
                let kr = deviceOpened ? device!.pointee!.pointee.DeviceRequestTO(device, &rq) : i.pointee!.pointee.ControlRequestTO(i, 0, &rq)
                done = rq.wLenDone
                return kr
            }
            return String(format: "  %@: start handshake %02x 01 %04x → %@", label, type, value, kr == kIOReturnSuccess ? "ok, \(done) B: " + hex(Array(buf.prefix(Int(done)))) : String(format: "0x%08x", UInt32(bitPattern: kr)))
        }
    }
    func start() {
        guard error == nil, let i = intf else { return }
        let pipe = self.pipe, maxPacket = self.maxPacket, cap = self.cap
        thread = Thread { [self] in
            while !self.stop {
                // Plain ReadPipe: the …TO variants only accept bulk pipes and answer kIOReturnBadArgument on this
                // interrupt pipe (issue #1). It blocks until a packet arrives or finish() aborts the pipe.
                var size = UInt32(maxPacket); var buf = [UInt8](repeating: 0, count: Int(maxPacket))
                let kr = buf.withUnsafeMutableBytes { i.pointee!.pointee.ReadPipe(i, pipe, $0.baseAddress, &size) }
                if kr == kIOReturnSuccess { if size > 0 { cap.add(Array(buf.prefix(Int(size)))) } }
                else if !self.stop { cap.failed(kr); _ = i.pointee!.pointee.ClearPipeStallBothEnds(i, pipe); Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        thread?.start()
    }
    /// One packet on the interrupt OUT pipe: a raw endpoint write, no HID report id. Plain WritePipe for the same
    /// reason as the read.
    func write(_ bytes: [UInt8]) -> IOReturn {
        guard error == nil, let i = intf, outPipe != 0 else { return kIOReturnNotOpen }
        var b = bytes
        return b.withUnsafeMutableBytes { i.pointee!.pointee.WritePipe(i, outPipe, $0.baseAddress, UInt32($0.count)) }
    }
    func finish() {
        stop = true
        if let i = intf { _ = i.pointee!.pointee.AbortPipe(i, pipe) }      // unblocks the reader thread
        Thread.sleep(forTimeInterval: 0.3)
        if let i = intf { _ = i.pointee!.pointee.USBInterfaceClose(i); _ = i.pointee!.pointee.Release(UnsafeMutableRawPointer(i)) }
        if let d = device { if deviceOpened { _ = d.pointee!.pointee.USBDeviceClose(d) }; _ = d.pointee!.pointee.Release(UnsafeMutableRawPointer(d)) }
    }
}
var rawReaders: [RawUSB] = []
for d in usbDevices { if let n = d.xinputClassInterface { rawReaders.append(RawUSB(d, interfaceNumber: n)) } }
for r in rawReaders {
    if let e = r.error { out("  \(r.label): cannot read (\(e))") }
    else {
        if let n = r.note { out("  \(r.label): \(n)") }
        if r.vid == 0x37D7 { r.handshake().forEach(out) }
        out("  \(r.label): reading pipe \(r.pipe), max packet \(r.maxPacket)"); r.start()
    }
}

if !captures.isEmpty || rawReaders.contains(where: { $0.error == nil }) {
    print("\n>>> Recording for \(Int(seconds)) s: press EVERY button once (including paddles and the extra keys), move both sticks in a full circle, pull both triggers, and shake the controller a little.")
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds { Thread.sleep(forTimeInterval: 0.5); let left = Int(seconds - Date().timeIntervalSince(t0)); if left % 5 == 0 { print("    \(left) s…") } }

    // Identification queries, before the interfaces are cancelled. Both are what Space Station sends on connect.
    var infoLines: [String] = []
    func writeReport(_ d: IOHIDDevice, _ bytes: [UInt8]) -> IOReturn { bytes.withUnsafeBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(bytes[0]), $0.baseAddress!, $0.count) } }
    // New generation: the bare heartbeat `5A A5 01 02 03` (cmd 01, len 2, crc = sum from cmd on). Space Station's
    // code starts these frames with 06, but a Vader 5 Pro ignores `06 5A A5 …` and answers the bare frame, whether it
    // goes out on interface 0's OUT endpoint or on the 0xFFA0 HID, and the reply comes back on the HID (issue #1).
    let heartbeat: [UInt8] = [0x5A, 0xA5, 0x01, 0x02, 0x03]
    func padded(_ b: [UInt8], _ n: Int) -> [UInt8] { b + [UInt8](repeating: 0, count: max(0, n - b.count)) }
    func listReplies(_ replies: [(source: String, bytes: [UInt8])]) {
        for (source, bytes) in replies {
            infoLines.append("    \(source): " + hex(bytes))
            if let info = heartbeatInfo(bytes) { infoLines.append("      → " + info) }
        }
    }
    for r in rawReaders where r.error == nil && r.vid == 0x37D7 {
        infoLines.append(String(format: "== New-generation heartbeat (5A A5 01) on %04x:%04x interface %d OUT endpoint (raw USB)", r.vid, r.pid, r.interfaceNumber))
        guard r.outPipe != 0 else { infoLines.append("  no interrupt OUT pipe on this interface"); continue }
        let before = Capture.log.count
        let kr = r.write(padded(heartbeat, 32))
        guard kr == kIOReturnSuccess else { infoLines.append(String(format: "  write on OUT pipe %d failed 0x%08x", r.outPipe, UInt32(bitPattern: kr))); continue }
        Thread.sleep(forTimeInterval: 1.5)
        let replies = Capture.log.since(before)
        infoLines.append("  sent 32 B on OUT pipe \(r.outPipe); \(replies.count) reply packet(s) on any interface within 1.5 s")
        listReplies(replies)
    }
    for (d, cap, _) in captures {
        let vid = int(hidProp(d, kIOHIDVendorIDKey)) ?? 0, pid = int(hidProp(d, kIOHIDProductIDKey)) ?? 0, page = int(hidProp(d, kIOHIDPrimaryUsagePageKey)) ?? 0
        guard page == 0xFFA0 else { continue }
        if vid == 0x04B4 && pid == 0x2412 {
            // Apex 4 family, classic DInput: `05 EC`.
            let r = writeReport(d, DInput.command(DInput.Cmd.deviceInfo))
            infoLines.append("== Classic device info (05 EC on 04b4:2412)")
            if r == kIOReturnSuccess {
                Thread.sleep(forTimeInterval: 1.0)
                cap.lock.lock(); let replies = cap.replies; cap.lock.unlock()
                if let reply = replies.first(where: { DInputReply.deviceInfo($0) != nil }), let info = DInputReply.deviceInfo(reply) {
                    infoLines.append("  device id \(info.deviceId) (\(info.modelName)) · firmware \(info.firmware) · \(info.isWired ? "wired" : "wireless") · reply: \(hex(reply))")
                } else { infoLines.append("  no device-info reply (\(replies.count) other replies)") }
            } else { infoLines.append(String(format: "  write failed 0x%08x", r)) }
        } else if vid == 0x37D7 {
            // Same heartbeat on the vendor HID, with the report id its descriptor declares for output: none on the
            // Vader 5 Pro (report 0, frame as-is), 3 on the Apex 5. Probe 0.2.3 tried 3, 6 and 5, never 0.
            let descriptor = (hidProp(d, kIOHIDReportDescriptorKey) as? Data).map { [UInt8]($0) } ?? []
            let size = int(hidProp(d, kIOHIDMaxOutputReportSizeKey)) ?? 32
            infoLines.append(String(format: "== New-generation heartbeat (5A A5 01) on %04x:%04x vendor HID (usage ffa0)", vid, pid))
            for id in outputReportIDs(descriptor, usagePage: 0xFFA0) {
                let report = id == 0 ? padded(heartbeat, size) : [id] + padded(heartbeat, size - 1)
                let before = Capture.log.count
                let r = report.withUnsafeBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(id), $0.baseAddress!, $0.count) }
                guard r == kIOReturnSuccess else { infoLines.append(String(format: "  report id %02x: write failed 0x%08x", id, UInt32(bitPattern: r))); continue }
                Thread.sleep(forTimeInterval: 1.5)
                let replies = Capture.log.since(before)
                infoLines.append(String(format: "  report id %02x (%d B): %d reply packet(s) within 1.5 s", id, report.count, replies.count))
                listReplies(replies)
            }
        }
    }

    out("== Input reports (\(Int(seconds)) s)")
    for (d, cap, label) in captures { IOHIDDeviceCancel(d); out("  \(label)"); cap.summary(indent: "      ").forEach(out) }
    for r in rawReaders where r.error == nil {
        r.finish(); out("  \(r.label)"); r.cap.summary(indent: "      ").forEach(out)
        r.cap.lock.lock(); for rep in r.cap.replies { out("      reply-like packet: " + hex(rep)) }; r.cap.lock.unlock()
    }
    out("")
    infoLines.forEach(out); if !infoLines.isEmpty { out("") }
    for (d, _, _) in captures { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
}
for d in usbDevices { IOObjectRelease(d.service) }

// MARK: - 4. Save

let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
let file = desktop.appendingPathComponent("flydigi-probe-\(stamp).txt")
do {
    try report.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    print("\nSaved \(file.path)\nPlease send this file with the controller model, its firmware version and whether it was on the cable or the dongle.")
} catch { print("could not save the report: \(error)") }
