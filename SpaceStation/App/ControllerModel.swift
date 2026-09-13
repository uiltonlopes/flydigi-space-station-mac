// App-side model: what mode the pad is in, how we reach it (direct HID or via the helper), and the
// operations the views call. Everything blocking runs off the main actor.

import Foundation
import OSLog
import Observation
import IOKit
import FlydigiKit
import FlydigiHelperProtocol
import FlydigiTransport

@MainActor @Observable
final class ControllerModel {
    enum Connection: Equatable {
        case none
        case dinput                 // vendor HID interface, talked to directly
        case xinput                 // Apple's Xbox driver owns it; we go through the helper
    }

    var connection: Connection = .none
    var info: HelperDeviceInfo?
    var led: LEDConfig?
    var helperInstalled = false
    /// nil = not checked / not installed; false = registered but launchd does not start it.
    var helperResponding: Bool?
    var repairingHelper = false
    static let log = Logger(subsystem: "com.uiltonlopes.spacestation", category: "controller")
    var busy = false
    var lastError: String?
    var uploadProgress: Double?   // 0…1 while a screen upload runs
    var firmwareUpdate: FlydigiAPI.FirmwareChip?      // newer main-chip firmware Flydigi offers, nil = up to date / unknown
    /// Slot the pad reported as current at the last refresh, read before anything moved the cursor (nil = unknown).
    var padSlot: UInt8?
    /// USB link is up but the pad has not answered yet — the 2.4 GHz receiver with the pad off, typically.
    var awaitingPad: Bool { connection != .none && info == nil }
    /// USB product string of the matched device ("Flydigi VADER3" is the charging dock's receiver).
    var usbProductName: String?
    var looksLikeReceiver: Bool { usbProductName?.localizedCaseInsensitiveContains("vader") == true }
    private var padPoll: Task<Void, Never>?
    var firmwareChecked = false
    var firmwareReport: [String] = []                 // dry-run log shown in Settings
    private var firmwareCheckedFor: String?

    private var monitor: USBMonitor?
    /// Staged profile edits (four on-board slots). Created in `init` (needs `self`); it is @Observable itself.
    @ObservationIgnored private(set) var profiles: ProfileStore!
    /// Our own helper calls capture/release the pad, which re-enumerates it and fires USB notifications.
    /// Ignore notifications until this date so we never refresh in response to ourselves.
    private var suppressNotificationsUntil = Date.distantPast
    private var pendingNotification: Task<Void, Never>?

    init() {
        profiles = ProfileStore(controller: self)
        refreshHelperStatus()
        monitor = USBMonitor { [weak self] in Task { @MainActor in self?.usbChanged() } }
        startPresencePoll()
        Task { await checkHelperHealth(); await refresh() }
    }

    /// Debounced USB attach/detach handling: update `connection`; fetch details only when a pad appears.
    /// Notifications that arrive while we are busy with the device are not dropped: the check is re-run
    /// once the quiet period is over, so a pad that came back mid-request is still picked up.
    private func usbChanged() {
        pendingNotification?.cancel()
        pendingNotification = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            while !Task.isCancelled, Date() < suppressNotificationsUntil { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            await reconcileConnection()
        }
        if presencePoll == nil { startPresencePoll() }
    }

    /// Compares what USB shows now with what we believe and reacts to the difference.
    private func reconcileConnection() async {
        let now = USBMonitor.currentConnection()
        if now != connection {
            connection = now
            if now == .none { info = nil; led = nil; firmwareUpdate = nil; firmwareCheckedFor = nil; lastError = nil; padPoll?.cancel(); padPoll = nil }
            else { await refresh() }
        } else if now != .none, info == nil, !busy, padPoll == nil {
            await refresh()
        }
    }

    /// Safety net for missed IOKit notifications (seen after the receiver drops off the bus and comes back):
    /// while nothing is connected, look at the USB tree every few seconds.
    private var presencePoll: Task<Void, Never>?
    private func startPresencePoll() {
        presencePoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                if self.connection == .none, !self.busy, Date() >= self.suppressNotificationsUntil, USBMonitor.currentConnection() != .none {
                    await self.reconcileConnection()
                }
            }
        }
    }

    func refreshHelperStatus() {
        if #available(macOS 14.0, *) { helperInstalled = HelperClient.shared.status == .enabled }
        if !helperInstalled { helperResponding = nil }
    }

    // MARK: Discovery

    func refresh() async {
        connection = USBMonitor.currentConnection()
        usbProductName = USBMonitor.productName()
        refreshHelperStatus()
        guard connection != .none else { info = nil; led = nil; firmwareUpdate = nil; firmwareCheckedFor = nil; lastError = nil; padPoll?.cancel(); padPoll = nil; return }
        let conn = connection, installed = helperInstalled
        let remembered = UInt8(clamping: UserDefaults.standard.integer(forKey: "activeSlot"))
        await run {
            // Order matters: ask which slot is current *before* any blob read — reads move that cursor
            // (docs/protocol.md §10) — then read the lighting of that slot.
            switch conn {
            case .dinput:
                let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }
                let i = try s.deviceInfo()
                let cur = (try? s.currentConfigId()).flatMap { $0 < 4 ? $0 : nil }
                s.configId = cur ?? remembered
                let l = try s.readLED()
                return (HelperDeviceInfo(i), l, cur)
            case .xinput:
                guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }
                guard installed else { throw HelperClient.shared.status == .requiresApproval ? HelperError.awaitingApproval : HelperError.notInstalled }
                guard HelperClient.shared.isResponding() else { throw HelperError.notResponding }
                let i = try HelperClient.shared.deviceInfo()
                let cur = (try? HelperClient.shared.currentSlot()).flatMap { $0 < 4 ? $0 : nil }
                return (i, try HelperClient.shared.readLED(slot: cur ?? remembered), cur)
            case .none:
                throw HelperError.transport("no controller")
            }
        } onSuccess: { (i: HelperDeviceInfo, l: LEDConfig, cur: UInt8?) in
            self.info = i; self.led = l; self.padSlot = cur
            if let cur { UserDefaults.standard.set(Int(cur), forKey: "activeSlot") }
        }
        if let fw = info?.firmware, firmwareCheckedFor != fw { firmwareCheckedFor = fw; Task { await checkFirmware() } }
        if info == nil {
            padWentSilent()
        } else {
            padPoll?.cancel(); padPoll = nil
            // Over the receiver the first answer often carries battery 0 ("unknown") until the dongle has
            // asked the pad; Space Station re-sends its heartbeat after 1 s in that case — so do we.
            if info?.batteryRaw == 0, info?.wired == false { scheduleBatteryReread(attempt: 1) }
        }
    }

    /// The link is up but the pad stopped answering (turned off, out of range, still waking up): show the
    /// "waiting" state and keep asking every few seconds; it comes back by itself.
    func padWentSilent() {
        guard connection != .none else { return }
        batteryReread?.cancel(); batteryReread = nil
        info = nil; led = nil; firmwareUpdate = nil; firmwareCheckedFor = nil
        lastError = looksLikeReceiver
            ? String(localized: "Receiver connected. Turn the controller on (Home button) — it shows up by itself.")
            : String(localized: "The controller did not answer in time. Turn it on or reconnect the cable — it shows up by itself.")
        padPoll?.cancel()
        padPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.awaitingPad else { break }
                if !self.busy { await self.refresh() }
                if self.info != nil { break }
            }
            self?.padPoll = nil
        }
    }

    private var batteryReread: Task<Void, Never>?
    /// Space Station keeps re-sending its heartbeat every second until the battery is non-zero; the receiver
    /// can take a while after the pad powers on. We ask every 2 s for up to ~30 s, quietly (no busy state,
    /// no error banner — a missed answer over the dongle is normal).
    private func scheduleBatteryReread(attempt: Int) {
        batteryReread?.cancel()
        batteryReread = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.info != nil, !self.busy else { return }
            let conn = self.connection, installed = self.helperInstalled
            self.suppressNotificationsUntil = .distantFuture
            let r: Result<HelperDeviceInfo, Error> = await Task.detached {
                Result {
                    switch conn {
                    case .dinput:
                        let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }
                        return HelperDeviceInfo(try s.deviceInfo())
                    case .xinput:
                        guard installed, #available(macOS 14.0, *) else { throw HelperError.notInstalled }
                        return try HelperClient.shared.deviceInfo()
                    case .none: throw HelperError.transport("no controller")
                    }
                }
            }.value
            self.suppressNotificationsUntil = Date().addingTimeInterval(4)
            guard !Task.isCancelled, self.info != nil else { return }
            if case .success(let i) = r { self.info = i }
            if self.info?.batteryRaw == 0, attempt < 15 { self.scheduleBatteryReread(attempt: attempt + 1) }
        }
    }

    // MARK: Firmware check and dry run (docs/firmware-update.md)

    /// Asks Flydigi whether a newer main-chip firmware exists for the installed one. Network only.
    func checkFirmware() async {
        guard let fw = info?.firmware, let id = info?.deviceId else { return }
        let r: Result<[String: FlydigiAPI.FirmwareChip], Error> = await Task.detached { Result { try FlydigiAPI.firmwareUpdates(deviceId: Int(id), mainChip: fw) } }.value
        firmwareChecked = true
        if case .success(let chips) = r, let main = chips["main_chip"], FirmwareVersion.isNewer(main.version, than: fw) { firmwareUpdate = main } else { firmwareUpdate = nil }
    }

    /// Downloads the offered image, validates it (size field, CRC32, boot mark) and, in DInput mode, reads
    /// the version the OTA interface reports. Writes nothing to the controller.
    func firmwareDryRun() async {
        guard let update = firmwareUpdate else { return }
        firmwareReport = ["Downloading \(update.url.lastPathComponent)…"]
        let conn = connection
        let r: Result<[String], Error> = await Task.detached {
            Result {
                var log: [String] = []
                guard FlydigiAPI.isTrustedFirmwareHost(update.url) else { throw HelperError.transport("firmware URL is not on Flydigi's servers: \(update.url.host ?? "?")") }
                let data = try FlydigiAPI.download(update.url)
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Space Station/firmware", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(update.url.lastPathComponent)
                try data.write(to: file)
                log.append("Downloaded \(data.count) bytes → \(file.path)")
                let img = try FirmwareImage(data: data)
                log.append(String(format: "Header: payload %d bytes, version field 0x%08x, boot mark %@", img.payloadSize, img.versionField, img.hasBootMark ? "KNLT ✓" : "missing"))
                log.append(String(format: "CRC32: file %08x, computed %08x → %@", img.storedCRC, img.computedCRC, img.crcMatches ? "match ✓" : "MISMATCH"))
                try img.validate()
                log.append("Image valid · \(img.packetCount) OTA packets of 16 bytes")
                if conn == .dinput {
                    if OTALink.isPresent() {
                        let ota = try OTALink(); defer { ota.close() }
                        let sizes = ota.reportSizes
                        log.append("OTA interface found (usage page FFEF) · report sizes in \(sizes.input) / out \(sizes.output) — ready for the flasher")
                    } else {
                        log.append("OTA interface (usage page FFEF) not present in this enumeration")
                    }
                } else {
                    log.append("Switch to DInput mode to probe the OTA interface (read-only)")
                }
                return log
            }
        }.value
        switch r {
        case .success(let log): firmwareReport = log + ["Dry run complete — nothing was written."]
        case .failure(let e): firmwareReport.append("Failed: \(e)")
        }
    }

    // MARK: Firmware flashing (docs/firmware-update.md §6c — same sequence as the CLI, verified on hardware)

    var firmwareFlashing = false
    var firmwareProgress: Double = 0
    var firmwareStage = ""

    /// Why the Update button is disabled, or nil when flashing may start.
    var firmwareFlashBlocker: String? {
        guard firmwareUpdate != nil, let info else { return nil }
        // The OTA sequence was only ever exercised on the Apex 4 family. Flydigi's server answers for other device
        // ids too, but writing that image with this flow to an untested model is not something we let happen.
        if let d = DeviceCatalog.descriptor(for: info.deviceId), d.family != .apex4 { return String(localized: "Updates from this app are only enabled for the Apex 4 family. Use Flydigi Space Station (Windows) for \(d.name).") }
        if DeviceCatalog.descriptor(for: info.deviceId) == nil { return String(localized: "Updates from this app are only enabled for the Apex 4 family (unknown controller id \(info.deviceId)).") }
        if !info.wired { return String(localized: "Connect the USB cable — updates never run over the receiver.") }
        if min(5, Int(info.batteryRaw & 0xF)) * 20 < 40 { return String(localized: "Charge the controller to at least 40 % first.") }
        if connection == .xinput, !helperInstalled { return String(localized: "Install the helper (or switch to DInput) so the app can put the controller in update mode.") }
        return nil
    }

    /// Download → validate → (XInput: switch to DInput) → OTA → wait for the reboot → (switch back) → refresh.
    func flashFirmware() async {
        guard let update = firmwareUpdate, firmwareFlashBlocker == nil, !firmwareFlashing else { return }
        let wasXInput = connection == .xinput
        firmwareFlashing = true; busy = true; lastError = nil
        suppressNotificationsUntil = .distantFuture        // the pad re-enumerates twice; we drive it ourselves
        padPoll?.cancel(); padPoll = nil
        firmwareProgress = 0; firmwareReport = []
        func log(_ line: String) { firmwareReport.append(line) }
        do {
            firmwareStage = String(localized: "Downloading the firmware…")
            let img: FirmwareImage = try await Task.detached {
                guard FlydigiAPI.isTrustedFirmwareHost(update.url) else { throw HelperError.transport("firmware URL is not on Flydigi's servers") }
                let d = try FlydigiAPI.download(update.url); let i = try FirmwareImage(data: d); try i.validate(); return i
            }.value
            log(String(format: "%@: %d bytes, CRC32 %08x OK, %d packets", update.url.lastPathComponent, img.payloadSize, img.storedCRC, img.packetCount))

            if wasXInput {
                firmwareStage = String(localized: "Putting the controller in update mode (DInput)…")
                guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }
                try await Task.detached { try HelperClient.shared.switchMode() }.value
                _ = try await waitForDInput(seconds: 15)
                log(String(localized: "Controller in DInput mode"))
            }
            guard OTALink.isPresent() else { throw HelperError.transport(String(localized: "The controller's update interface did not appear.")) }

            firmwareStage = String(localized: "Writing the firmware — keep the cable connected…")
            let outcome = try await Task.detached { [weak self] in
                let ota = try OTALink(); defer { ota.close() }
                var last = -1
                return try ota.flash(img) { sent, total in
                    let pct = sent * 100 / total
                    if pct != last { last = pct; Task { @MainActor in self?.firmwareProgress = Double(sent) / Double(total) } }
                }
            }.value
            firmwareProgress = 1
            log(outcome == .confirmed ? String(localized: "The controller confirmed the image (result 0).") : String(localized: "Image sent; the controller restarted before reporting."))

            firmwareStage = String(localized: "Controller restarting…")
            try? await Task.sleep(for: .seconds(2))
            let back = try await waitForDInput(seconds: 30)
            log(String(localized: "Back on USB with firmware \(back.firmware)"))
            if back.firmware != update.version {
                throw HelperError.transport(String(localized: "The controller still reports \(back.firmware) — the update did not take. Try again with the cable firmly connected."))
            }

            if wasXInput {
                firmwareStage = String(localized: "Switching back to XInput…")
                try await Task.detached { let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; try s.switchMode() }.value
                try? await Task.sleep(for: .seconds(4))
            }
            firmwareStage = String(localized: "Update complete")
        } catch {
            lastError = "\(error)"; firmwareStage = String(localized: "Update failed"); log("Failed: \(error)")
        }
        firmwareFlashing = false; busy = false
        suppressNotificationsUntil = Date().addingTimeInterval(4)
        connection = USBMonitor.currentConnection()
        firmwareCheckedFor = nil                           // re-check against the new version
        await refresh()
        if info == nil { try? await Task.sleep(for: .seconds(2)); connection = USBMonitor.currentConnection(); await refresh() }
    }

    /// Polls the DInput config interface until the pad answers (after a mode switch or the OTA reboot).
    private func waitForDInput(seconds: Double) async throws -> DeviceInfo {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            let r: DeviceInfo? = try? await Task.detached {
                let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }
                guard s.channel == .dinput else { throw HelperError.transport("not DInput") }
                return try s.deviceInfo()
            }.value
            if let r { return r }
        }
        throw HelperError.transport(String(localized: "The controller did not come back within \(Int(seconds)) s. Unplug and replug the cable, then check its firmware version."))
    }

    // MARK: Actions

    /// Reads the lighting stored in a profile slot (each slot has its own 500-byte LED blob).
    func loadLED(slot: UInt8) async {
        let conn = connection, installed = helperInstalled
        guard conn != .none else { return }
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; s.configId = slot; return try s.readLED()
            case .xinput: guard installed, #available(macOS 14.0, *) else { throw HelperError.notInstalled }; return try HelperClient.shared.readLED(slot: slot)
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (l: LEDConfig) in self.led = l })
    }

    func apply(led newLED: LEDConfig, persist: Bool = true) async {
        let conn = connection, slot = profiles.shownSlot
        Self.log.info("LED write → slot \(slot) mode \(newLED.mode.rawValue) speed \(newLED.speed) brightness \(newLED.brightness) persist \(persist)")
        await run {
            // Write, then read back and compare; a lost parcel would otherwise leave a half-applied effect.
            for attempt in 0..<2 {
                switch conn {
                case .dinput:
                    let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }
                    s.configId = slot
                    try s.applyLED(newLED, persist: persist)
                    if try s.readLED().bytes == newLED.bytes { return newLED }
                case .xinput:
                    guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }
                    try HelperClient.shared.applyLED(newLED, slot: slot, persist: persist)
                    if try HelperClient.shared.readLED(slot: slot).bytes == newLED.bytes { return newLED }
                case .none: throw HelperError.transport("no controller")
                }
                if attempt == 1 { throw HelperError.transport(String(localized: "The lighting did not apply completely. Try again.")) }
            }
            return newLED
        } onSuccess: { (l: LEDConfig) in self.led = l }
    }

    /// Screen uploads need XInput + helper (see docs/protocol.md §6).
    func uploadScreen(url: URL) async {
        guard let frames = try? ImageLoader.frames(url: url) else { lastError = "Cannot decode \(url.lastPathComponent)"; return }
        await uploadScreen(frames: frames)
    }

    /// Sends already-encoded LVGL frames (from the screen editor).
    @discardableResult
    func uploadScreen(frames: [[UInt8]], intervalMs: Int = 200) async -> Bool {
        let period = UInt8(clamping: max(1, Int((Double(intervalMs) / 100).rounded())))
        uploadProgress = 0
        defer { uploadProgress = nil }
        let conn = connection
        var ok = false
        await run {
            guard conn == .xinput else { throw HelperError.transport("Screen upload needs the controller in XInput mode. Use “Switch mode” below.") }
            guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }
            try HelperClient.shared.uploadScreen(frames: frames, period: period) { done, total in
                Task { @MainActor in self.uploadProgress = Double(done) / Double(total) }
            }
            return ()
        } onSuccess: { (_: Void) in ok = true }
        return ok
    }

    // MARK: Controller settings (Settings › Controller)

    /// Auto-sleep minutes as the pad reports them (XInput only; nil = not read yet).
    var sleepMinutes: UInt8?
    func loadSleepTime() async {
        guard connection == .xinput, helperInstalled, #available(macOS 14.0, *) else { return }
        let r: Result<UInt8, Error> = await Task.detached { Result { try HelperClient.shared.readSleepTime() } }.value
        if case .success(let v) = r { sleepMinutes = v }
    }
    func setSleepTime(_ minutes: UInt8) async {
        let conn = connection
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; try s.setScreenSleepTime(minutes)
            case .xinput: guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }; try HelperClient.shared.setSleepTime(minutes)
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (_: Void) in self.sleepMinutes = minutes })
    }
    /// Write-only switches (the pad does not report them back): remembered locally per controller.
    func setQuickSwitch(_ on: Bool) async {
        let conn = connection
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; try s.setQuickSwitch(on)
            case .xinput: guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }; try HelperClient.shared.setQuickSwitch(on)
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (_: Void) in UserDefaults.standard.set(on, forKey: "quickSwitch.\(self.info?.mac ?? "")") })
    }
    func setTurboSwitch(_ on: Bool) async {
        let conn = connection
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; try s.setTurboSwitch(on)
            case .xinput: guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }; try HelperClient.shared.setTurboSwitch(on)
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (_: Void) in UserDefaults.standard.set(on, forKey: "turboSwitch.\(self.info?.mac ?? "")") })
    }
    var nickname: String {
        get { UserDefaults.standard.string(forKey: "nickname.\(info?.mac ?? "")") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nickname.\(info?.mac ?? "")") }
    }

    func switchMode() async {
        let conn = connection
        await run {
            switch conn {
            case .dinput:
                let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }
                try s.switchMode()
            case .xinput:
                guard #available(macOS 14.0, *) else { throw HelperError.notInstalled }
                try HelperClient.shared.switchMode()
            case .none: throw HelperError.transport("no controller")
            }
            return ()
        } onSuccess: { (_: Void) in }
        try? await Task.sleep(for: .seconds(4))          // re-enumeration + driver matching
        await refresh()
        if lastError != nil { try? await Task.sleep(for: .seconds(2)); await refresh() }
    }

    /// Borrow the pad for up to `seconds` and return the first key pressed (paddles included). In XInput the
    /// helper captures the USB interface, so games lose the pad for those seconds; in DInput it is read directly.
    func captureKey(seconds: Double = 5) async -> ControllerKey? {
        let conn = connection
        var result: ControllerKey? = nil
        await run({
            switch conn {
            case .none: return nil as UInt8?
            case .dinput:
                let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }
                return try s.captureKey(timeout: seconds)?.rawValue
            case .xinput:
                return try HelperClient.shared.captureKey(timeoutMs: Int(seconds * 1000))
            }
        }, onSuccess: { raw in result = raw.flatMap(ControllerKey.init(rawValue:)) })
        return result
    }

    // MARK: Calibration & joystick hardware switches

    var joystickSettings: JoystickSettings?

    func loadJoystickSettings() async {
        let conn = connection
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; return try s.readJoystickSettings()
            case .xinput: return try HelperClient.shared.readJoystickSettings()
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (j: JoystickSettings) in self.joystickSettings = j })
    }

    func setJoystickToggle(_ opt: DeviceSession.JoystickOption, enabled: Bool) async {
        let conn = connection
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; try s.setJoystickToggle(opt, enabled: enabled)
            case .xinput: try HelperClient.shared.setJoystickOption(opt, value: enabled ? 0 : 1)
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (_: Void) in })
        await loadJoystickSettings()
    }

    /// Opens / closes the calibration window on the pad. Only the wizard calls this.
    func calibration(start: Bool) async -> Bool {
        let conn = connection
        var ok = false
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; try s.calibration(start: start)
            case .xinput: try HelperClient.shared.calibration(start: start)
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (_: Void) in ok = true })
        return ok
    }

    // MARK: Game profiles (temporary changes that do not touch the user's remembered slot)

    func applySlot(_ slot: UInt8) async {
        let conn = connection
        await run({
            switch conn {
            case .dinput: let s = try DeviceSession.open(preferring: .dinput); defer { s.close() }; try s.applyConfig(slot: slot)
            case .xinput: try HelperClient.shared.applySlot(slot)
            case .none: throw HelperError.transport("no controller")
            }
        }, onSuccess: { (_: Void) in })
        profiles.showTemporary(slot: slot)
    }

    /// ForceAdapt on both triggers (XInput only — the DInput form of `A5 30 06` is not known).
    func setForceAdapt(left: [UInt8], right: [UInt8]) async {
        guard connection == .xinput else { return }
        await run({
            try HelperClient.shared.setForceTrigger(side: 1, params: left)
            try HelperClient.shared.setForceTrigger(side: 2, params: right)
        }, onSuccess: { (_: Void) in })
    }

    func installHelper() {
        guard #available(macOS 14.0, *) else { return }
        do { try HelperClient.shared.install() } catch { lastError = "\(error)" }
        refreshHelperStatus()
        if HelperClient.shared.status == .requiresApproval { HelperClient.shared.openLoginItemsSettings() }
    }

    /// A helper that is registered and approved can still be refused by macOS: on a development Mac the kernel
    /// rejected it on every spawn (launch-constraint violation), and requests then blocked forever. Ping it at
    /// launch with a timeout so Settings can say so. Re-registering did not clear that state, so it is not
    /// done automatically; Settings › Privileged helper › Repair helper still offers it.
    func checkHelperHealth() async {
        guard #available(macOS 14.0, *) else { return }
        refreshHelperStatus()
        guard helperInstalled else { helperResponding = nil; return }
        helperResponding = await Task.detached(operation: { HelperClient.shared.isResponding() }).value
        if helperResponding == false {
            Logger(subsystem: "com.uiltonlopes.spacestation", category: "helper").error("helper registered but not answering")
        }
    }

    /// Unregister + register the daemon (see `HelperClient.reinstall`), then ask for approval if macOS wants it.
    func repairHelper() async {
        guard #available(macOS 14.0, *), !repairingHelper else { return }
        repairingHelper = true; defer { repairingHelper = false }
        let r: Result<Void, Error> = await Task.detached { Result { try HelperClient.shared.reinstall() } }.value
        refreshHelperStatus()
        if case .failure(let e) = r { lastError = "\(e)"; helperResponding = false; return }
        if HelperClient.shared.status == .requiresApproval {
            helperResponding = nil
            lastError = String(localized: "Space Station registered its helper again. Approve it in System Settings › General › Login Items & Extensions, then come back.")
            HelperClient.shared.openLoginItemsSettings()
            return
        }
        helperResponding = await Task.detached(operation: { HelperClient.shared.isResponding() }).value
        if helperResponding == true { lastError = nil; if connection == .xinput { await refresh() } }
    }

    func uninstallHelper() {
        guard #available(macOS 14.0, *) else { return }
        do { try HelperClient.shared.uninstall() } catch { lastError = "\(error)" }
        refreshHelperStatus()
    }

    // MARK: Plumbing

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T, onSuccess: @MainActor (T) -> Void) async {
        busy = true; lastError = nil
        suppressNotificationsUntil = .distantFuture
        defer { busy = false; suppressNotificationsUntil = Date().addingTimeInterval(4) }   // release + re-match takes ~1–2 s
        var result: Result<T, Error> = await Task.detached { Result { try work() } }.value
        if case .failure(let e) = result, "\(e)".contains("no matching report") || "\(e)".contains("timeout") {
            // Right after a mode switch or re-enumeration the pad ignores the first request; try once more.
            try? await Task.sleep(for: .seconds(1.5))
            result = await Task.detached { Result { try work() } }.value
        }
        switch result {
        case .success(let v): onSuccess(v)
        case .failure(let e):
            let text = "\(e)"
            if text.contains("not found"), USBMonitor.currentConnection() == .none {
                // The receiver / cable went away while we were talking to it: not an error, just gone.
                connection = .none; info = nil; led = nil; firmwareUpdate = nil; firmwareCheckedFor = nil; lastError = nil
                padPoll?.cancel(); padPoll = nil
            } else if text.contains("no matching report") || text.contains("timeout") {
                lastError = String(localized: "The controller did not answer in time. Press refresh to try again.")
                if info != nil { padWentSilent() }       // it was there a moment ago: turned off / out of range
            } else {
                lastError = text
            }
        }
    }
}

/// Watches USB attach/detach for the pad (both VID/PIDs) and reports which mode is present.
final class USBMonitor: @unchecked Sendable {
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.global(qos: .utility))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for (vid, pid) in [(USBID.xinputVendor, USBID.xinputProduct), (USBID.dinputVendor, USBID.dinputProduct)] {
            for kind in [kIOMatchedNotification, kIOTerminatedNotification] {
                let match = IOServiceMatching("IOUSBHostDevice")! as NSMutableDictionary
                match["idVendor"] = Int(vid); match["idProduct"] = Int(pid)
                var it: io_iterator_t = 0
                let kr = IOServiceAddMatchingNotification(port, kind, match as CFDictionary, { ctx, iterator in
                    while case let s = IOIteratorNext(iterator), s != IO_OBJECT_NULL { IOObjectRelease(s) }   // drain (arms the notification)
                    Unmanaged<USBMonitor>.fromOpaque(ctx!).takeUnretainedValue().onChange()
                }, ctx, &it)
                if kr == kIOReturnSuccess {
                    while case let s = IOIteratorNext(it), s != IO_OBJECT_NULL { IOObjectRelease(s) }
                    iterators.append(it)
                }
            }
        }
    }

    static func currentConnection() -> ControllerModel.Connection {
        func present(_ vid: UInt16, _ pid: UInt16) -> Bool {
            let match = IOServiceMatching("IOUSBHostDevice")! as NSMutableDictionary
            match["idVendor"] = Int(vid); match["idProduct"] = Int(pid)
            let s = IOServiceGetMatchingService(kIOMainPortDefault, match as CFDictionary)
            if s != IO_OBJECT_NULL { IOObjectRelease(s); return true }
            return false
        }
        if present(USBID.dinputVendor, USBID.dinputProduct) { return .dinput }
        if present(USBID.xinputVendor, USBID.xinputProduct) { return .xinput }
        return .none
    }

    /// "USB Product Name" of whichever pad device is present (the receiver announces itself as "Flydigi VADER3").
    static func productName() -> String? {
        for (vid, pid) in [(USBID.dinputVendor, USBID.dinputProduct), (USBID.xinputVendor, USBID.xinputProduct)] {
            let match = IOServiceMatching("IOUSBHostDevice")! as NSMutableDictionary
            match["idVendor"] = Int(vid); match["idProduct"] = Int(pid)
            let s = IOServiceGetMatchingService(kIOMainPortDefault, match as CFDictionary)
            guard s != IO_OBJECT_NULL else { continue }
            defer { IOObjectRelease(s) }
            if let n = IORegistryEntryCreateCFProperty(s, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { return n }
        }
        return nil
    }

    deinit { iterators.forEach { IOObjectRelease($0) }; IONotificationPortDestroy(port) }
}
