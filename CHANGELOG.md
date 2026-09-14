# Changelog

## Unreleased
- New generation, verified on a Vader 5 Pro by a contributor (issue #1): the heartbeat is the bare `5A A5 01 02 03` frame, sent as an HID output report whose id follows the pad's `0xFFA0` descriptor (none on the Vader 5 Pro, 3 on the Apex 5); Space Station's leading `06` gets no reply. The cable needs the Xbox 360 start handshake before interface 0 streams; Steam holds the device exclusively while it runs. Reply fields partly decoded. docs/adding-a-controller.md §4 has the details; `system_profiler SPUSBHostDataType` replaces the old data type on macOS 26.
- Device catalog: id 130 is the Vader 5 Pro (from its heartbeat reply); ids 85, 91 and 105 are the Vader 4 Pro (classic protocol, per SDL's Flydigi driver); Space Station's `fp4` ids stay marked as inferred.
- New generation, cross-checked with SDL's Flydigi HID driver: report id 3 on the Apex 5 and unnumbered on the Vader 5 Pro, the info reply's fields (device id, connection, battery nibbles, four firmware versions as BCD), the acquire / status / rumble / input-report commands and SDL's minimum firmware versions are now in docs/adding-a-controller.md §4.
- `flydigi-probe` 0.2.4 (issue #1): reads and writes interface 0 with `ReadPipe`/`WritePipe` (0.2.3's `ReadPipeTO` fails on interrupt pipes, so its "no input reports" on `0x37D7` pads was wrong) and lists read errors instead of hiding them; sends the Xbox 360 start handshake to `0x37D7` pads before recording, so a wired Vader 5 Pro streams; sends the bare `5A A5 01 02 03` heartbeat on interface 0's OUT endpoint and on the `0xFFA0` HID with the output report id its descriptor declares (0 when none), collects the reply from whichever interface it comes back on, and prints the device id and firmware from it; stops with a message instead of recording silence when another app (Steam) holds the controller exclusively.
- `flydigi-probe` 0.2.3: sends the new-generation heartbeat as a raw 32-byte packet on the pad's XInput-class interface (where Space Station's `06 5A A5` frames appear to go) and counts the input packets that follow; on the vendor HID it tries report ids 3, 6 and 5 in turn. First reports from an Apex 5 and a Vader 4 Pro are summarised in docs/adding-a-controller.md §4.

## 0.2.2 — 2026-09-13

The app no longer hangs when macOS refuses to start the privileged helper, and says why.

- Fix: when macOS refuses to start the privileged helper, XInput mode no longer hangs waiting for it. The app pings the helper with a 3 s timeout before talking to the controller, Settings › Privileged helper says when the helper is registered but not running, and a **Repair helper** button registers it again. DInput mode keeps working without the helper. In XInput, a missing, unapproved or silent helper is now named as the reason instead of "the controller did not answer in time", and Install helper opens Login Items directly when macOS is waiting for approval.

## 0.2.1 — 2026-09-05

Safety fix for owners of other Flydigi models, plus the read-only survey tool.

- Fix: the firmware **Update** button is now disabled for controllers outside the Apex 4 family — Flydigi's server offered an image for a Direwolf 3 and the app would have flashed it with a sequence verified only on the Apex 4. Device id 95 is named Direwolf 3 (was "Vader 3 Pro (FP3)?").
- `flydigi-probe`: read-only survey tool for owners of other Flydigi models (USB/HID descriptors, input-report capture, Apex 4 device info), shipped as a signed universal binary next to the release. v2 also reads XInput-class interfaces without a macOS driver (new-generation pads), sends the new-generation identity request, and lists Switch-mode (Nintendo VID) devices.

## 0.2.0 — 2026-09-04

First signed and notarized release. Everything Space Station 4 offers for the Apex 4, plus keyboard/mouse mapping, per-game profiles, GIPHY, share codes and firmware updates from the Mac.

- Share codes compatible with Space Station: profile menu › Share as code… uploads the profile (with lighting) and shows the code; Import from code… fetches one into the library and the editor. CLI: `apex4 config share-code [--upload]`, `apex4 config import-code`.
- App update check against GitHub releases (Settings › About and a sidebar badge), Settings › Closing the window (quit vs menu bar), Settings › Log (export the unified log, open Console), `spacestation://` URL scheme, helper exits when idle for 10 minutes.
- DMG with the usual drag-to-Applications window (background, app on the left, Applications on the right), built with create-dmg.
- Keyboard and mouse mapping, done on the Mac: Buttons › Special (key, left/right click, wheel up/down), Sticks › Mapping (keyboard 4/8 directions or mouse with sensitivity), Gyro › Mouse (axes and signs measured on the pad). The app posts the events (Accessibility permission, Settings › Keyboard & mouse); mappings are kept per controller and profile slot. Buttons need DInput mode — the controller hides keyboard-flagged buttons in XInput.
- Buttons: choosing Macro on a button that already had one relinks it; "Edit macro" opens that macro in the Macros tab.
- Verified on hardware: macros recorded on the pad (M1), edited in the app and played back by the controller; per-app game profiles switching with a real app in front.
- Firmware: `apex4 firmware flash` streams the main-chip OTA the way Space Station's flasher does (START / DATA / END over the DInput OTA interface), gated on `--yes`, cable, DInput, battery ≥ 40 % and a validated image. First real update done with it on 2026-09-04 (6.8.3.0 → 6.8.3.7, 11 s, profiles and lighting intact). Settings › Firmware Update now has the real **Update** button: confirmation, switch to DInput through the helper, OTA with progress, wait for the restart, switch back to XInput, re-check — verified end to end on hardware.
- Release pipeline: Developer ID signing, notarization and stapling of both the app (via zip) and the signed DMG; Gatekeeper reports "Notarized Developer ID".
- Profiles: "Apply to NS mode…" copies the profile (and lighting) into the controller's Switch-mode slot (config ids 4–7), like Space Station.
- Fix: the macro editor crashed when a step or the macro itself was removed while its rows were still on screen (stale index in a binding).
- Fix: on connect the app read the lighting before asking which slot the pad was on, which moved the pad's "current slot" cursor and then re-applied the wrong profile; a config read right after an LED read of the same slot also returned the previous profile (wrong name under profile 1). Both orderings fixed.
- Profiles: the slot selected on the pad itself (fast swap, screen menu) is respected — the app asks the pad which slot is current before reading them, on connect and on Refresh, and in DInput keeps following switches made on the pad.
- Fix: lighting is per profile slot on the pad (`A5 26/2A <cfgId>`) but the app always read and wrote slot 1's — colours looked shared between profiles. Now lighting follows the selected profile, reloads on slot switch, and "Restore default configuration" also resets it.
- Macros: local library (save from a profile, add to any profile on a free button, rename, duplicate, export/import `.fdgmacro`).
- Sticks: report-rate meter (DInput) and a circularity test with coverage and average error, like Space Station's advanced test page.
- Profiles: local library ("Saved profiles…" in the profile menu) — save the current profile, load into the editor, rename, duplicate, reorder, delete, export/import as `.fdgprofile` (the raw 790-byte blob). (Share codes compatible with Space Station came later in this cycle, see above.)
- Screen: "Factory animations" tab with the animation each Apex 4 edition ships with (yours is marked).
- Parity batch from the gap analysis: GIF frame interval is now really sent to the pad (start packet period); Common tab › Controller card gained Controller Sleep Time (1 min…3 h / never), Fast Swap Config (SELECT + A/B/X/Y) and the Turbo hardware shortcut switch; profile menu "Restore default configuration…"; Screen "Restore default animation"; device nickname (right-click the card); second gyro activation key.
- Sticks: sensitivity curve drawn like Space Station (280 × 280 grid, 0–100 axes, dead-zone and edge bands, 4-point curve with draggable nodes), always visible, with SS4's Default / Instant / Delay / Custom presets and a live dot for the current deflection.
- Triggers: Vibration (grip-sync) mode now really engages in the live preview (written through the profile, as Space Station does); the vibration test and the grip vibration test use the Xbox rumble packet games send, which the triggers follow.
- Triggers: per-mode defaults are now the Apex 4's own presets, read back from the pad after picking each mode in its screen menu (Race = light damping over the whole travel, Recoil, Sniper, Trigger lock levels 1–3, Vibration). "Controller preset" button restores them.
- Triggers: ForceAdapt modes now match Space Station for the Apex 4 — General, Racing, Recoil, Sniper, Trigger lock, Vibration (SS4's own labels and tooltips) — with SS4's parameters and ranges (0–255 raw, not 1–10), the vibration mode sent as the "sync with grip" command, and the same layout in the profile blob. Game-profile presets use the same editor.
- Receiver (charging dock): "waiting for controller" state while the pad is off, automatic reconnection when it comes back or when the receiver re-enumerates, battery read correctly over the receiver, no stale errors when it is unplugged.
- Welcome screen: Space Station's own "add device" silhouette when nothing is connected; special-edition card artwork (EVA-01, Assassin's Creed, Black Myth Wukong, Genshin, Honkai Star Rail).
- Sidebar: device card without the dropdown (refresh icon, short firmware-update button, mode switch on the Mode row), title on its own line.
- Screen: GIPHY search next to Flydigi's library (shared beta key, or your own in Settings) and an "On the controller" card showing the last animation sent from this Mac, or the factory animation for the connected variant (the pad cannot be read back).
- App renamed **Space Station for Mac** (repo `flydigi-space-station-mac`), Space Station's app icon.
- Fix: the Screen editor crashed when a shorter GIF/image replaced a longer one (filmstrip indexed stale frames).
- Lighting: mode list now matches Space Station's for the Apex 4 (Default, Steady, Breathing, Gradient, Off — no Flow/Feedback on this model), with per-mode colour limits (Steady 1, Gradient 2–5, Breathing up to 5). "Off" now blanks every LED unit like Space Station does (the pad kept playing the previous colours before). "Default" sends the factory loop and colours under mode 7 like Space Station.
- Welcome / device-center screen with the connected model's picture, connection and battery.
- Battery read through GameController when macOS provides it (no USB borrow), device-info byte otherwise.
- Screen editor: drag / pinch / scroll to frame the image in a 2:1 viewport, Fit / Fill, GIF trimming with
  filmstrip, frame interval, exact 160 × 80 preview; long GIFs are thinned evenly to 35 frames.
- Key capture in XInput borrows the pad for a few seconds so paddles and Fn work everywhere.
- Game profiles per app (Adaptive Trigger page): pick an app, a profile slot, trigger presets and lighting; applied when the app is in front, restored when it leaves. "Open at login" toggle.
- Stick / trigger calibration wizard (Joystick tab): timed, guided, with the controller's own "Calibrating" window.
- Credits, social links and Buy Me a Coffee in Settings → About, the welcome screen, the menu bar and the About panel.
- Firmware: automatic update check on connect, update badges (welcome screen, sidebar, Settings), Flydigi's
  note, how-to-update guidance, and a read-only dry run that downloads and validates the image (Telink CRC32)
  and finds the OTA interface (the flasher itself followed later in this cycle, see above).
- Settings reorganised (Controller → App → About), in-app language switch, pt-BR translation.
- App renamed internally (Space Station.app, `com.uiltonlopes.spacestation`, SpaceStationHelper).

## 0.1.0 — 2026-09-02 (pre-release)

First public build. Signed with a personal Apple Development certificate, not notarized: right-click →
Open on first launch (see `docs/install.md`).

**Controller support:** Flydigi Apex 4 (device id 84, firmware 6.8.3.x) over USB-C or the charging
base's 2.4 GHz receiver, in XInput (via privileged helper) and DInput (direct) modes.

**Features**
- Space Station 4-style interface: device card with battery, hero with the official wireframe and key
  layout, profile slots (rename / apply / revert), tabs Common · Button · Joystick · Gyro · Trigger · Macros.
- Lighting: mode, colours, brightness, cycle time, applied live and saved to flash.
- Buttons: click / turbo / macro per key, "press the button on the pad" capture (paddles included, in both modes).
- Joystick: curves (incl. custom two-point), dead zone, edge, live readout.
- Gyro: mapping, activation key/type, sensitivity, dead zone, use mode.
- Triggers: ForceAdapt modes with live preview, start/end, live readout.
- Macros: on-board macros with step editor, timeline and recording from the pad.
- Screen: GIF/PNG/JPEG upload (160×80, ≤35 frames) and Flydigi's official animation library.
- Adaptive Trigger: Flydigi's per-game preset list (read-only for now).
- Settings: helper install/remove, USB mode switch, firmware availability check.
- Live input: every key lights on the hero; in DInput the raw report is decoded (paddles, Fn, Home).

**Not yet**
- Firmware flashing, keyboard/mouse mapping, automatic per-game trigger switching, stick calibration wizard.
- Screen upload over the 2.4 GHz receiver (the receiver does not forward those commands).

**Known limits**
- In XInput mode Apple's driver hides paddles and Fn; the app borrows the pad for a few seconds when you
  ask it to capture a key.
