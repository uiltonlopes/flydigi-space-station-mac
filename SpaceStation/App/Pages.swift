// Sidebar routes: Screen (upload + official library), Adaptive Trigger (game presets), Settings.

import SwiftUI
import OSLog
import ServiceManagement
import UniformTypeIdentifiers
import FlydigiKit
import FlydigiTransport
import FlydigiHelperProtocol
@preconcurrency import Translation

// MARK: - Screen

struct ScreenPage: View {
    let back: () -> Void
    @Environment(ControllerModel.self) private var model
    @State private var editor = ScreenEditorState()
    @State private var importing = false
    @State private var library: [FlydigiAPI.ScreenPic] = []
    @State private var libraryError: String?
    @State private var downloading: String?
    @State private var source: Source = .flydigi
    @State private var giphyQuery = ""
    @State private var giphy: [Giphy.Gif] = []
    @State private var giphyError: String?
    @State private var giphyLoading = false
    @State private var current: ScreenStore.Current?
    @State private var origin = ScreenOrigin(name: "", kind: .file, url: nil)
    enum Source: Hashable { case flydigi, factory, giphy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Screen", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Screen Settings").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    onController
                    DarkCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 14) {
                                Text("Custom\nAnimation").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                                PrimaryButton(title: editor.isEmpty ? "Upload" : "Choose another…", enabled: !model.busy) { importing = true }
                                Text("GIF, PNG or JPEG · drop a file here · the screen is 160 × 80, up to \(Screen.maxFrames) frames").font(.system(size: 12)).foregroundStyle(SS.n300)
                                Spacer()
                                if let u = editor.url { Text(u.lastPathComponent).font(.system(size: 12)).foregroundStyle(SS.n400).lineLimit(1) }
                                GhostButton(title: "Restore default animation", icon: "arrow.counterclockwise", enabled: !model.busy) {
                                    let id = model.info.map { Int($0.deviceId) } ?? 84
                                    if let u = Bundle.main.url(forResource: "factory-k2-\(id)", withExtension: "gif") ?? Bundle.main.url(forResource: "factory-k2-84", withExtension: "gif") {
                                        load(u, ScreenOrigin(name: String(localized: "Factory animation"), kind: .file, url: nil))
                                    }
                                }
                            }
                            if !editor.isEmpty {
                                ScreenEditorView(state: editor)
                                HStack(spacing: 12) {
                                    if let p = model.uploadProgress {
                                        ProgressView(value: p).tint(SS.brand500).frame(width: 260)
                                        Text("Sending… \(Int(p * 100)) % — about \(Int((1 - p) * Double(max(1, editor.outputCount)) * 3.5)) s left").font(.system(size: 12)).foregroundStyle(SS.n300)
                                    } else {
                                        PrimaryButton(title: "Send to controller", icon: "arrow.up.circle", enabled: !model.busy && model.connection == .xinput && model.info?.wired != false) { send() }
                                        if model.connection != .xinput { Text("Needs XInput mode.").font(.system(size: 12)).foregroundStyle(SS.yellow) }
                                        else if model.info?.wired == false { Text("Needs the USB cable (the receiver does not forward screen data).").font(.system(size: 12)).foregroundStyle(SS.yellow) }
                                        else { Text("About \(Int(Double(editor.outputCount) * 3.5)) s for \(editor.outputCount) frames.").font(.system(size: 12)).foregroundStyle(SS.n400) }
                                    }
                                }
                            }
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in if let u = urls.first { load(u, ScreenOrigin(name: u.lastPathComponent, kind: .file, url: nil)) }; return true }

                    HStack(spacing: 14) {
                        PillSegmented(selection: $source, options: [(.flydigi, "Official selection"), (.factory, "Factory animations"), (.giphy, "GIPHY")])
                            .padding(2).background(SS.n700, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        if source == .giphy {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").foregroundStyle(SS.n400)
                                TextField("Search GIPHY", text: $giphyQuery).textFieldStyle(.plain).foregroundStyle(.white)
                                if giphyLoading { ProgressView().controlSize(.small) }
                                else if !giphyQuery.isEmpty { Button { giphyQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(SS.n400) }.buttonStyle(.plain) }
                            }
                            .padding(.horizontal, 10).frame(width: 300, height: 30)
                            .background(SS.n700, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SS.n500))
                        }
                        Spacer()
                        if source == .giphy { Text("Powered by GIPHY").font(.system(size: 11, weight: .semibold)).foregroundStyle(SS.n400) }
                        else if let e = libraryError { Text(e).font(.system(size: 12)).foregroundStyle(SS.n400) }
                    }
                    .padding(.top, 8)

                    if source == .factory {
                        Text("The animation each Apex 4 edition ships with on its screen. Yours is marked; the others are the special editions'.").font(.system(size: 12)).foregroundStyle(SS.n400)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 14)], spacing: 14) {
                            ForEach(ScreenPage.factoryIds, id: \.self) { id in factoryCell(id) }
                        }
                    } else if source == .flydigi {
                        if library.isEmpty && libraryError == nil {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading Flydigi's library…").font(.system(size: 12)).foregroundStyle(SS.n300) }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 14)], spacing: 14) {
                                ForEach(library) { pic in libraryCell(pic) }
                            }
                        }
                    } else {
                        if let e = giphyError, giphy.isEmpty { Text(e).font(.system(size: 12)).foregroundStyle(SS.n400) }
                        else if giphy.isEmpty { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading GIPHY…").font(.system(size: 12)).foregroundStyle(SS.n300) } }
                        else {
                            Text(giphyQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "Trending now" : "Results").font(.system(size: 12)).foregroundStyle(SS.n400)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 14)], spacing: 14) {
                                ForEach(giphy) { g in giphyCell(g) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gif, .png, .jpeg]) { if case let .success(u) = $0 { load(u, ScreenOrigin(name: u.lastPathComponent, kind: .file, url: nil)) } }
        .task { await loadLibrary() }
        .task(id: "\(source)|\(giphyQuery)") {
            guard source == .giphy else { return }
            if !giphyQuery.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }      // debounce typing
            guard !Task.isCancelled else { return }
            await searchGiphy()
        }
        .onChange(of: NavHints.shared.screenSource, initial: true) { _, s in applyHints() }
            .onAppear { current = ScreenStore.current(deviceId: model.info?.deviceId) }
        .onChange(of: model.info?.deviceId) { _, _ in current = ScreenStore.current(deviceId: model.info?.deviceId) }
    }

    /// What the LCD shows right now, as far as this Mac knows (no read-back command exists).
    private var onController: some View {
        DarkCard {
            HStack(spacing: 16) {
                ZStack {
                    Color.black
                    if let c = current { AnimatedGIF(url: c.gif, token: c.token) }
                }
                .frame(width: 240, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SS.n500))
                VStack(alignment: .leading, spacing: 6) {
                    Text("On the controller").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    if let r = current?.record {
                        Text(r.name).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
                        Text("Sent from this Mac on \(r.date.formatted(date: .abbreviated, time: .shortened)) · \(r.frames) frames · \(r.sourceLabel)")
                            .font(.system(size: 12)).foregroundStyle(SS.n300)
                    } else {
                        Text("Factory animation").font(.system(size: 13)).foregroundStyle(.white)
                        Text("Nothing has been sent from this Mac yet.").font(.system(size: 12)).foregroundStyle(SS.n300)
                    }
                    Text("The controller cannot be read back; this is what was last sent from here.").font(.system(size: 11)).foregroundStyle(SS.n400)
                }
                Spacer()
            }
        }
    }

    private func send() {
        let vp = ScreenEditorView.viewportSize
        let frames = editor.encode(viewport: vp)
        let images = editor.selectedImages(), crop = editor.crop(viewport: vp), interval = editor.intervalMs, o = origin
        Task {
            guard await model.uploadScreen(frames: frames, intervalMs: interval) else { return }
            let rec = ScreenRecord(name: o.name.isEmpty ? (editor.url?.lastPathComponent ?? "Animation") : o.name, source: o.kind.rawValue, url: o.url, date: Date(), frames: frames.count, intervalMs: interval)
            do { try ScreenStore.save(images: images, crop: crop, intervalMs: interval, record: rec) } catch { model.lastError = "\(error)" }
            current = ScreenStore.current(deviceId: model.info?.deviceId)
        }
    }

    private func libraryCell(_ pic: FlydigiAPI.ScreenPic) -> some View {
        Button { Task { await pick(pic) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RemoteThumb(url: pic.imagePath, aspect: 2)
                        .frame(height: 88).clipped()
                    if downloading == "flydigi-\(pic.id)" { ProgressView().controlSize(.small) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack {
                    Text(displayTitle(pic)).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text(pic.isGIF ? "GIF" : "JPG").font(.system(size: 10, weight: .semibold)).foregroundStyle(SS.n300)
                        .padding(.horizontal, 5).frame(height: 16).background(SS.n500, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(8)
            .background(SS.n700, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Load this animation into the preview")
    }

    static let factoryIds: [UInt8] = [84, 86, 87, 92, 93, 102, 103, 104]

    private func factoryCell(_ id: UInt8) -> some View {
        let url = Bundle.main.url(forResource: "factory-k2-\(id)", withExtension: "gif")
        let name = DeviceCatalog.descriptor(for: id)?.name.replacingOccurrences(of: "Flydigi ", with: "") ?? "Apex 4 (\(id))"
        let mine = model.info?.deviceId == id
        return Button {
            if let url { load(url, ScreenOrigin(name: String(localized: "Factory animation") + " · " + name, kind: .file, url: nil)) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.black
                    if let url { AnimatedGIF(url: url, token: url.lastPathComponent) }
                }
                .frame(height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack {
                    Text(name).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    if mine { Text("Yours").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 5).frame(height: 16).background(SS.brand, in: RoundedRectangle(cornerRadius: 4)) }
                    else { Text("GIF").font(.system(size: 10, weight: .semibold)).foregroundStyle(SS.n300).padding(.horizontal, 5).frame(height: 16).background(SS.n500, in: RoundedRectangle(cornerRadius: 4)) }
                }
            }
            .padding(8)
            .background(SS.n700, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(mine ? SS.brand500.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Load this animation into the preview")
    }

    private func giphyCell(_ g: Giphy.Gif) -> some View {
        Button { Task { await pick(g) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RemoteThumb(url: g.still, aspect: 2)
                        .frame(height: 88).clipped()
                    if downloading == "giphy-\(g.id)" { ProgressView().controlSize(.small) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack {
                    Text(g.title).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text("GIF").font(.system(size: 10, weight: .semibold)).foregroundStyle(SS.n300)
                        .padding(.horizontal, 5).frame(height: 16).background(SS.n500, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(8)
            .background(SS.n700, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Load this animation into the preview")
    }

    /// Flydigi names them "精选动画N" (featured) / "第三方无版权N" (third-party, royalty-free).
    private func displayTitle(_ pic: FlydigiAPI.ScreenPic) -> String {
        let t = pic.title
        if t.hasPrefix("精选动画") { return "Featured \(t.dropFirst(4))" }
        if t.hasPrefix("第三方无版权") { return "Community \(t.dropFirst(6))" }
        return t.isEmpty ? "#\(pic.id)" : t
    }

    private func loadLibrary() async {
        let r: Result<[FlydigiAPI.ScreenPic], Error> = await Task.detached { Result { try FlydigiAPI.screenPictures() } }.value
        switch r {
        case .success(let l): library = l.sorted { ($0.isRecomment, $0.id) > ($1.isRecomment, $1.id) }
        case .failure: libraryError = "Library unavailable offline."
        }
    }

    private func applyHints() {
        let h = NavHints.shared
        Logger(subsystem: "com.uiltonlopes.spacestation", category: "url").notice("screen applyHints source=\(h.screenSource ?? "-", privacy: .public) q=\(h.giphyQuery ?? "-", privacy: .public)")
        if let s = h.screenSource { source = s == "giphy" ? .giphy : (s == "factory" ? .factory : .flydigi); h.screenSource = nil }
        if let q = h.giphyQuery { giphyQuery = q; h.giphyQuery = nil; Task { await searchGiphy() } }
    }
    private func searchGiphy() async {
        giphyLoading = true
        defer { giphyLoading = false }
        do {
            let r = try await Giphy.search(giphyQuery)
            guard !Task.isCancelled else { return }
            giphy = r
            giphyError = r.isEmpty ? String(localized: "No results.") : nil
        } catch is CancellationError {
        } catch {
            giphy = []
            giphyError = error.localizedDescription
        }
    }

    private func pick(_ pic: FlydigiAPI.ScreenPic) async {
        downloading = "flydigi-\(pic.id)"
        defer { downloading = nil }
        let url = pic.imagePath
        let r: Result<URL, Error> = await Task.detached {
            Result {
                let data = try FlydigiAPI.download(url)
                let dst = FileManager.default.temporaryDirectory.appendingPathComponent("flydigi-\(pic.id).\(pic.isGIF ? "gif" : "jpg")")
                try data.write(to: dst)
                return dst
            }
        }.value
        if case .success(let u) = r { load(u, ScreenOrigin(name: displayTitle(pic), kind: .flydigi, url: url.absoluteString)) }
    }

    private func pick(_ g: Giphy.Gif) async {
        downloading = "giphy-\(g.id)"
        defer { downloading = nil }
        do { load(try await Giphy.download(g), ScreenOrigin(name: g.title, kind: .giphy, url: g.download.absoluteString)) }
        catch { model.lastError = error.localizedDescription }
    }

    private func load(_ url: URL, _ o: ScreenOrigin) { editor.load(url); origin = o }
}

// MARK: - Adaptive Trigger (game presets from Flydigi's list)

struct AdaptiveTriggerPage: View {
    let back: () -> Void
    @Environment(GameProfileStore.self) private var store
    @State private var games: [FlydigiAPI.GamePreset] = []
    @State private var error: String?
    @State private var query = ""
    @State private var baseRule: GameRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Adaptive Trigger", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GameRulesSection()
                    HDivider().padding(.vertical, 6)
                    SectionTitle("Flydigi's game list", icon: "list.star")
                    Text("Space Station's per-game presets. On Windows most of them rely on a mod injected into the game (not possible on macOS); here they are a starting point: press “Use as base” to create your own profile with that name.")
                        .font(.system(size: 12)).foregroundStyle(SS.n300)
                    TextField("Search games", text: $query).textFieldStyle(.roundedBorder).frame(width: 280)
                    if games.isEmpty && error == nil {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").font(.system(size: 12)).foregroundStyle(SS.n300) }
                    } else if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(SS.n400)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                            ForEach(filtered) { g in card(g) }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .task {
            let r: Result<[FlydigiAPI.GamePreset], Error> = await Task.detached { Result { try FlydigiAPI.gamePresets() } }.value
            switch r { case .success(let g): games = g; case .failure: error = "Game list unavailable offline." }
        }
    }

    private var filtered: [FlydigiAPI.GamePreset] {
        guard !query.isEmpty else { return games }
        return games.filter { $0.enGameName.localizedCaseInsensitiveContains(query) || $0.gameName.localizedCaseInsensitiveContains(query) }
    }

    private func card(_ g: FlydigiAPI.GamePreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteThumb(url: g.imagePath)
                .frame(height: 100).clipped().clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(g.enGameName.isEmpty ? g.gameName : g.enGameName).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            HStack(spacing: 4) {
                ForEach(g.platforms.prefix(3), id: \.self) { p in
                    Text(p.capitalized).font(.system(size: 10)).foregroundStyle(SS.n300)
                        .padding(.horizontal, 5).frame(height: 16).background(SS.n500, in: RoundedRectangle(cornerRadius: 4))
                }
                if g.isMod == 1 { Text("mod").font(.system(size: 10)).foregroundStyle(SS.yellow).padding(.horizontal, 5).frame(height: 16).background(SS.n500, in: RoundedRectangle(cornerRadius: 4)).help("Uses a Windows-only game mod in Space Station") }
                Spacer()
                Button("Use as base") {
                    var r = GameRule(name: g.enGameName.isEmpty ? g.gameName : g.enGameName)
                    r.flydigiId = g.id
                    r.processName = (g.enGameName.isEmpty ? g.gameName : g.enGameName).components(separatedBy: CharacterSet(charactersIn: "™®:")).first?.trimmingCharacters(in: .whitespaces)
                    if g.isVibration == 1 { r.left.mode = .vibration; r.right.mode = .vibration }
                    baseRule = r
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(SS.brand500)
            }
        }
        .padding(10)
        .background(SS.n700, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(item: $baseRule) { r in GameRuleEditor(rule: r) { store.rules.append($0) } }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    let back: () -> Void
    @Environment(ControllerModel.self) private var model
    @State private var checking = false
    @State private var dryRunning = false
    @State private var confirmFlash = false
    @State private var language = AppLanguage.current
    @State private var giphyKey = UserDefaults.standard.string(forKey: Giphy.keyDefaultsKey) ?? ""
    @State private var needsRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings", back: back)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    navGroup("Controller Settings", ["Firmware Update", "USB mode"])
                    navGroup("App Settings", ["Language", "GIPHY", "Keyboard & mouse", "Open at login", "Closing the window", "Log", "Privileged helper"])
                    navGroup("About", [])
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Space Station for Mac \(appVersion)").font(.system(size: 11)).foregroundStyle(SS.n400)
                        if let i = model.info { Text("Device firmware: \(i.firmware)").font(.system(size: 11)).foregroundStyle(SS.n400) }
                    }
                }
                .padding(16).frame(width: 220)
                .background(SS.n700, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.leading, 20).padding(.vertical, 20)

                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Controller Settings").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).id("Controller Settings")
                        section("Firmware Update") { firmware }
                        section("USB mode") {
                            Text(model.connection == .none ? "Not connected." : (model.connection == .xinput ? "XInput — what games expect; the screen and trigger previews need it." : "DInput — the app talks to the pad directly, no helper needed."))
                                .font(.system(size: 13)).foregroundStyle(.white)
                            GhostButton(title: model.connection == .xinput ? "Switch to DInput" : "Switch to XInput", icon: "arrow.left.arrow.right", enabled: model.connection != .none && !model.busy) { Task { await model.switchMode() } }
                        }
                        Text("App Settings").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).padding(.top, 8).id("App Settings")
                        section("Language") {
                            Text("Choose a language").font(.system(size: 13)).foregroundStyle(SS.n300)
                            DarkSelect(selection: $language, options: AppLanguage.allCases.map { ($0, $0.title) }, width: 260)
                                .onChange(of: language) { _, l in l.apply(); needsRestart = true }
                            if needsRestart {
                                HStack(spacing: 10) {
                                    Text("Takes effect after restarting the app").font(.system(size: 12)).foregroundStyle(SS.yellow)
                                    GhostButton(title: "Restart now", icon: "arrow.clockwise") { AppLanguage.relaunch() }
                                }
                            }
                        }
                        section("GIPHY") {
                            Text("API key for the GIF search on the Screen page").font(.system(size: 13)).foregroundStyle(SS.n300)
                            TextField("Leave empty to use the app's shared key", text: $giphyKey)
                                .textFieldStyle(.roundedBorder).frame(width: 360)
                                .onChange(of: giphyKey) { _, k in UserDefaults.standard.set(k, forKey: Giphy.keyDefaultsKey) }
                            Text("Saved as you type. The shared key is a GIPHY beta key, limited to about 100 searches per hour for everyone using this app; a free key of your own gives you a private limit.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                            HStack(spacing: 10) {
                                Link(destination: URL(string: "https://developers.giphy.com/dashboard/")!) { Label("Create a key at developers.giphy.com", systemImage: "link") }
                            }
                            .font(.system(size: 12)).tint(SS.brand500)
                        }
                        section("Keyboard & mouse") {
                            Text(KeyboardMouseEngine.isTrusted ? "Accessibility permission granted — mappings to the keyboard and mouse are active while the app runs." : "Accessibility permission not granted — mappings to the keyboard and mouse do nothing yet.")
                                .font(.system(size: 13)).foregroundStyle(.white)
                            Text("Buttons set to Special, sticks mapped to keyboard or mouse and the gyro mapped to the mouse are turned into key and mouse events by this app, per controller and profile. Buttons need DInput mode; the controller hides keyboard-mapped buttons in XInput.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                            KeyboardMouseStatus()
                        }
                        section("Open at login") {
                            SwitchRow(title: "Start Space Station when I log in", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { model.lastError = "\(error)" }
                            }))
                            .frame(maxWidth: 420)
                            Text("Needed for anything that has to happen while you are not looking at the app — per-game trigger presets, the menu bar status. You can close the window; the app keeps running in the menu bar.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                        }
                        section("Closing the window") {
                            SwitchRow(title: "Quit Space Station when the window closes", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "quitOnClose") }, set: { UserDefaults.standard.set($0, forKey: "quitOnClose") }))
                                .frame(maxWidth: 420)
                            Text("Off: the window closes and the app keeps running in the menu bar, so per-game profiles, keyboard/mouse mappings and the status icon stay active. On: closing the window quits the app.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                        }
                        section("Log") {
                            Text("The app logs to the unified system log (Console.app, subsystem com.uiltonlopes.spacestation). Export the last hours to a text file to attach to a bug report.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                            HStack(spacing: 8) {
                                GhostButton(title: "Export log…", icon: "square.and.arrow.up") { exportLog() }
                                GhostButton(title: "Open Console", icon: "terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")) }
                            }
                        }
                        section("Privileged helper") {
                            if !model.helperInstalled {
                                Text("Not installed.").font(.system(size: 13)).foregroundStyle(.white)
                            } else if model.helperResponding == false {
                                Text("Registered, but macOS does not start it. DInput mode works without the helper; Repair registers it again.").font(.system(size: 13)).foregroundStyle(SS.yellow)
                            } else {
                                Text("Installed and registered with launchd.").font(.system(size: 13)).foregroundStyle(.white)
                            }
                            Text("Runs as root only while talking to the controller in XInput mode, because Apple's Xbox driver owns the USB interface. Required for screen uploads, trigger previews and key capture in XInput.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                            HStack(spacing: 8) {
                                PrimaryButton(title: "Install helper", enabled: !model.helperInstalled) { model.installHelper() }
                                GhostButton(title: model.repairingHelper ? "Repairing…" : "Repair helper", icon: "wrench.and.screwdriver", enabled: model.helperInstalled && !model.repairingHelper) { Task { await model.repairHelper() } }
                                GhostButton(title: "Remove helper", enabled: model.helperInstalled, destructive: true) { model.uninstallHelper() }
                            }
                        }
                        Text("About").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).padding(.top, 8).id("About")
                        section("Space Station for Mac") {
                            Text("Version \(appVersion) — open-source (MIT), unofficial. Ported to macOS by Uilton Lopes.")
                                .font(.system(size: 13)).foregroundStyle(.white)
                            HStack(spacing: 10) {
                                if let r = updates.latest {
                                    Text("Version \(r.version) is available").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 8).frame(height: 22).background(SS.brand500, in: Capsule())
                                    PrimaryButton(title: "Download", icon: "arrow.down.circle") { updates.download() }
                                    Link("Release notes", destination: r.page).font(.system(size: 12)).tint(SS.brand500)
                                } else if updates.checked, updates.lastError == nil {
                                    Text("Up to date").font(.system(size: 12)).foregroundStyle(SS.green)
                                } else if let e = updates.lastError {
                                    Text("Could not check: \(e)").font(.system(size: 12)).foregroundStyle(SS.yellow).lineLimit(1)
                                }
                                GhostButton(title: updates.checking ? "Checking…" : "Check for app updates", icon: "arrow.triangle.2.circlepath", enabled: !updates.checking) { Task { await updates.check() } }
                            }
                            HStack(spacing: 10) {
                                Link(destination: URL(string: "https://github.com/uiltonlopes/flydigi-space-station-mac")!) { Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                                Link(destination: URL(string: "https://github.com/uiltonlopes")!) { Label("@uiltonlopes", systemImage: "person.crop.circle") }
                                Link(destination: URL(string: "https://www.linkedin.com/in/uiltonlopes")!) { Label("LinkedIn", systemImage: "link") }
                            }
                            .font(.system(size: 12)).tint(SS.brand500)
                            Text("Not affiliated with Flydigi. Controller artwork and app icon © Flydigi, used for interoperability (see NOTICE.md in the app bundle).")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                        }
                        section("Support the project") {
                            Text("Space Station for Mac is free and open source, built in my spare time by reverse-engineering the controller. If it saved you a Windows install, you can buy me a coffee.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                            Link(destination: URL(string: "https://buymeacoffee.com/uiltonlopes")!) {
                                HStack(spacing: 8) {
                                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 13))
                                    Text("Buy me a coffee").font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.black).padding(.horizontal, 14).frame(height: 32)
                                .background(Color(hex: 0xFFDD00), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            HStack(spacing: 6) {
                                Text("Made by").font(.system(size: 12)).foregroundStyle(SS.n300)
                                Link("Uilton Lopes", destination: URL(string: "https://github.com/uiltonlopes")!).font(.system(size: 12, weight: .semibold)).tint(SS.brand500)
                                Text("· Issues and pull requests are welcome on GitHub.").font(.system(size: 12)).foregroundStyle(SS.n300)
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: scrollTarget) { _, t in if let t { withAnimation { proxy.scrollTo(t, anchor: .top) }; scrollTarget = nil } }
                }
            }
        }
    }

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    @Environment(AppUpdateChecker.self) private var updates

    /// Pulls this process's entries from the unified log (last 12 h) into a text file the user picks.
    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SpaceStation-\(appVersion)-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-12 * 3600))
            let df = ISO8601DateFormatter(); df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var lines = ["Space Station for Mac \(appVersion) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(df.string(from: Date()))",
                         "Controller: \(model.info.map { "\($0.deviceId) fw \($0.firmware) \($0.wired ? "wired" : "wireless")" } ?? "none") · connection \(model.connection) · helper \(model.helperInstalled ? "installed" : "not installed")", ""]
            for e in try store.getEntries(at: since) {
                guard let l = e as? OSLogEntryLog, l.subsystem == "com.uiltonlopes.spacestation" else { continue }
                lines.append("\(df.string(from: l.date)) [\(l.category)] \(l.level.rawValue) \(l.composedMessage)")
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch { model.lastError = "\(error)" }
    }

    @ViewBuilder private var firmware: some View {
        if let i = model.info {
            HStack(spacing: 14) {
                Text("Device Firmware").font(.system(size: 13)).foregroundStyle(SS.n300)
                Text(i.firmware).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if let u = model.firmwareUpdate {
                    Text("Update available: \(u.version)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 22).background(SS.brand500, in: Capsule())
                } else if model.firmwareChecked {
                    Text("Up to date").font(.system(size: 12)).foregroundStyle(SS.green)
                }
            }
            if let u = model.firmwareUpdate {
                DarkCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("New firmware available, please update the firmware").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        if !u.info.isEmpty { ReleaseNote(text: u.info) }
                        if model.firmwareFlashing {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.firmwareStage).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) }
                                ProgressView(value: model.firmwareProgress).tint(SS.brand500)
                                Text("Do not unplug the cable or turn the controller off. It restarts by itself at the end (about 20 seconds in total).").font(.system(size: 11)).foregroundStyle(SS.n400)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("The update runs from this Mac the same way Space Station does it: the controller is put in update mode, the image is written over USB, and it restarts with the new firmware. Profiles, lighting and the screen animation are kept.")
                                .font(.system(size: 12)).foregroundStyle(SS.n300)
                            if let why = model.firmwareFlashBlocker { Text(why).font(.system(size: 12)).foregroundStyle(SS.yellow) }
                            HStack(spacing: 8) {
                                PrimaryButton(title: String(localized: "Update to \(u.version)"), icon: "arrow.up.circle", enabled: model.firmwareFlashBlocker == nil && !model.busy) { confirmFlash = true }
                                GhostButton(title: dryRunning ? "Verifying…" : "Download and verify only", icon: "checkmark.shield", enabled: !dryRunning && !model.busy) {
                                    dryRunning = true
                                    Task { await model.firmwareDryRun(); dryRunning = false }
                                }
                            }
                            .alert(String(localized: "Update the firmware to \(u.version)?"), isPresented: $confirmFlash) {
                                Button(String(localized: "Update")) { Task { await model.flashFirmware() } }
                                Button(String(localized: "Cancel"), role: .cancel) {}
                            } message: {
                                Text("Keep the USB cable connected the whole time. The controller switches to update mode, receives the image and restarts on its own; games lose it for about 20 seconds. There is no way back to the previous version afterwards.")
                            }
                        }
                        if !model.firmwareReport.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(model.firmwareReport.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(SS.n300).textSelection(.enabled)
                                }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(SS.n800, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                GhostButton(title: checking ? "Checking…" : "Check for updates", icon: "arrow.down.circle", enabled: !checking) {
                    checking = true; Task { await model.checkFirmware(); checking = false }
                }
                Text("Checked automatically when the controller connects.").font(.system(size: 12)).foregroundStyle(SS.n400)
            }
        } else {
            Text("Connect the controller to see its firmware.").font(.system(size: 13)).foregroundStyle(SS.n300)
        }
    }

    @State private var scrollTarget: String?
    private func navGroup(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { scrollTarget = title } label: {
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ForEach(items, id: \.self) { item in
                Button { scrollTarget = item } label: {
                    Text(LocalizedStringKey(item)).font(.system(size: 12)).foregroundStyle(SS.n300).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    /// One settings block: a dark card with a title, anchored for the left navigation.
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        DarkCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                content()
            }
        }
        .id(title)
    }
}

/// Flydigi's release note: original (Chinese) plus an on-device translation into the app's language
/// (Apple's Translation framework; macOS asks once to download the language pair).
struct ReleaseNote: View {
    let text: String
    @State private var translated: String?
    @State private var config: TranslationSession.Configuration?

    private var targetIsChinese: Bool { Locale.current.language.languageCode?.identifier == "zh" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Flydigi's release note").font(.system(size: 12)).foregroundStyle(SS.n300)
            if let translated, !targetIsChinese {
                Text(verbatim: translated).font(.system(size: 12)).foregroundStyle(.white)
                Text(verbatim: text).font(.system(size: 11)).foregroundStyle(SS.n400)
            } else {
                Text(verbatim: text).font(.system(size: 12)).foregroundStyle(.white)
                if !targetIsChinese { Text("Translating…").font(.system(size: 11)).foregroundStyle(SS.n400) }
            }
        }
        .onAppear { if !targetIsChinese { config = TranslationSession.Configuration(source: Locale.Language(identifier: "zh-Hans"), target: Locale.current.language) } }
        .translationTask(config) { session in
            nonisolated(unsafe) let s = session
            let out: String? = await Task.detached { (try? await s.translate(text))?.targetText }.value
            translated = out
        }
    }
}

/// In-app language override (SS4 has the same setting). Stored in `AppleLanguages`; needs a relaunch.
enum AppLanguage: String, CaseIterable, Hashable {
    case system, en, ptBR = "pt-BR"                 // zh-Hans would need a translation first
    var title: String {
        switch self { case .system: "System"; case .en: "English"; case .ptBR: "Português (Brasil)" }
    }
    static var current: AppLanguage {
        guard let first = UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String, UserDefaults.standard.bool(forKey: "LanguageOverride") else { return .system }
        return AppLanguage(rawValue: first) ?? (first.hasPrefix("pt") ? .ptBR : first.hasPrefix("en") ? .en : .system)
    }
    func apply() {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages"); UserDefaults.standard.set(false, forKey: "LanguageOverride") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages"); UserDefaults.standard.set(true, forKey: "LanguageOverride") }
    }
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
    }
}

// MARK: - Settings scene (⌘,) and menu bar extra

struct SettingsView: View {
    @Environment(ControllerModel.self) private var model
    var body: some View {
        Form {
            Section("Privileged helper") {
                LabeledContent("Status", value: model.helperInstalled ? "Installed" : "Not installed")
                HStack {
                    Button("Install helper") { model.installHelper() }.disabled(model.helperInstalled)
                    Button("Repair helper") { Task { await model.repairHelper() } }.disabled(!model.helperInstalled || model.repairingHelper)
                    Button("Remove helper", role: .destructive) { model.uninstallHelper() }.disabled(!model.helperInstalled)
                }
            }
            Section("About") {
                Text("Open-source, MIT. Not affiliated with Flydigi.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 440, height: 240)
    }
}

struct MenuBarView: View {
    @Environment(ControllerModel.self) private var model
    @Environment(ProfileStore.self) private var profiles
    @Environment(LiveInput.self) private var live
    @Environment(GameProfileStore.self) private var games
    @Environment(\.openWindow) private var openWindow

    private var connected: Bool { model.connection != .none }
    private var name: String { model.info.flatMap { DeviceCatalog.descriptor(for: $0.deviceId)?.name } ?? "Flydigi controller" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let img = Apex4Render.productImage(deviceId: model.info?.deviceId), connected {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 48, height: 34)
                } else {
                    Image(systemName: "gamecontroller").font(.system(size: 26)).foregroundStyle(.secondary).frame(width: 56, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(connected ? name : "No controller").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if connected, let i = model.info {
                    let b = Battery(raw: i.batteryRaw, system: live.battery)
                    HStack(spacing: 4) {
                        Image(systemName: b.symbol).foregroundStyle(b.charging ? .green : .secondary)
                        Text(b.description).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if let u = model.firmwareUpdate {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text("Firmware \(u.version) available").font(.caption.weight(.medium))
                    Spacer()
                    Button("Details") { openWindow(id: "main"); NSApp.activate() }.controlSize(.mini)
                }
                .foregroundStyle(SS.brand500).padding(.horizontal, 8).frame(height: 24)
                .background(SS.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if connected, let i = model.info {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Mode").foregroundStyle(.secondary); Text(model.connection == .xinput ? "XInput (Xbox)" : "DInput") }
                    GridRow { Text("Link").foregroundStyle(.secondary); Text(i.wired ? "USB cable" : "2.4 GHz receiver") }
                    GridRow { Text("Firmware").foregroundStyle(.secondary); Text(verbatim: i.firmware) }
                    if let l = model.led { GridRow { Text("Lighting").foregroundStyle(.secondary); Text(verbatim: "\(NSLocalizedString(lightingName(l.mode), comment: "")) · \(l.brightness) %") } }
                    GridRow { Text("Helper").foregroundStyle(.secondary); Text(model.helperInstalled ? "Installed" : "Not installed") }
                    if let r = games.activeRule { GridRow { Text("Game profile").foregroundStyle(.secondary); Text(verbatim: r.name).foregroundStyle(.green) } }
                }
                .font(.caption)
            }
            if !profiles.slots.isEmpty {
                Picker("Profile", selection: Binding(get: { profiles.activeSlot }, set: { profiles.select(slot: $0) })) {
                    ForEach(profiles.slots) { s in Text("\(s.index + 1) · \(s.config.title.isEmpty ? "Unnamed" : s.config.title)").tag(s.index) }
                }
                .disabled(profiles.isDirty)
                if profiles.isDirty { Text("Unsaved changes in the app — apply or revert there first.").font(.caption).foregroundStyle(.orange) }
            }
            Divider()
            HStack(spacing: 8) {
                Button("Open") { openWindow(id: "main"); NSApp.activate() }
                Button(model.connection == .xinput ? "Switch to DInput" : "Switch to XInput") { Task { await model.switchMode() } }.disabled(!connected || model.busy)
                Button { Task { await model.refresh(); await profiles.loadAll() } } label: { Image(systemName: "arrow.trianglehead.2.clockwise") }.disabled(model.busy)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Text("Space Station for Mac · by Uilton Lopes").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Link("Buy me a coffee", destination: URL(string: "https://buymeacoffee.com/uiltonlopes")!).font(.caption2)
            }
        }
        .padding(12).frame(width: 340)
    }

    private var subtitle: String {
        guard connected else { return "Plug in over USB-C or power on with the receiver" }
        var parts: [String] = []
        if let d = profiles.draft { parts.append("Slot \(profiles.activeSlot + 1)\(d.title.isEmpty ? "" : " · \(d.title)")") }
        if model.busy { parts.append("working…") }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
    }
    private func lightingName(_ m: LEDConfig.Mode) -> String {
        switch m { case .off: "Off"; case .streamlined: "Streamlined"; case .breathing: "Breathing"; case .gradient: "Gradient"; case .feedback: "Feedback"; case .steady: "Steady"; case .factoryDefault: "Default"; case .unknown: "Unknown" }
    }
}
