# Adding another Flydigi controller

The app is built around the **Apex 4** because that is the pad the maintainers own, but nothing in the
architecture is Apex-only: transports, framing, blobs and the UI read everything model-specific from a
**`DeviceDescriptor`** in `FlydigiKit/Sources/FlydigiKit/DeviceCatalog.swift`. If you own another Flydigi
pad and want it supported, this is the path. Expect a few evenings for a same-generation pad (Apex 3,
Vader 3/3 Pro) and a real project for the new-protocol ones (Apex 5, Vader 4 Pro/5).

## 0. Ground rules

- Everything in this repo is written from scratch (MIT). **Do not commit** Flydigi binaries, decompiled
  sources, their images/GIFs or copy. Document *what the bytes mean*, not their code.
- Every claim in `docs/protocol.md` is either verified on hardware or marked *(unverified)*. Keep it so.
- Never leave a pad in a worse state than you found it: dump its configs first
  (`apex4 config dump ./backup`), restore afterwards.

## 0.5 Owners who are not developers: run the probe

You do not need Xcode to help. Download `flydigi-probe-<version>-macos.zip` from the
[Releases](https://github.com/uiltonlopes/flydigi-space-station-mac/releases) page, connect the controller with its
cable (or dongle), and in Terminal:

```bash
cd ~/Downloads && unzip -o flydigi-probe-*-macos.zip && ./flydigi-probe
```

For 15 seconds press every button once, move both sticks in a circle, pull both triggers. The tool writes
`flydigi-probe-<date>.txt` on your Desktop: USB and HID interfaces with their report descriptors, the input reports
that changed, and the device info (classic `05 EC` query on Apex 4-family pads, new-generation `06 5A A5 01`
heartbeat on `0x37D7` pads). Interfaces that macOS has no driver for (the XInput-class interface 0 of the new
generation) are read directly over USB, so the pad does not need to appear as a game controller. Switch-mode pads
(Nintendo VID `0x057E`) are listed too. The only things sent to the controller are those two identity requests; nothing
is written to its memory. Send the file with the model, firmware version and connection type in an issue or a DM.
Run it once per controller and once per USB mode if the pad has a mode switch.

## 1. Identify the pad

```bash
cd FlydigiKit && swift build
.build/debug/apex4 info                      # DInput mode: no root
sudo .build/debug/apex4 info --channel xinput
```
`device id` is Flydigi's `DeviceType`; the catalogue already knows most ids (names inferred where marked
"?"). Note the VID/PID in each USB mode (`system_profiler SPUSBDataType`): `045e:028e` + `04b4:2412` means
the classic protocol; VID `0x37D7` means the new one (see §4).

## 2. Same protocol family (classic `A5`/`05`)

1. Add or update the descriptor: id, `code` (the `device_code` Flydigi's web API uses — look at what the
   Windows app requests, e.g. `k1`), name, family, capabilities (LED groups, screen size/max frames or
   `nil`, config slots, ForceAdapt, gyro, grip motors). Set `support: .untested`.
2. Capture fixtures with the CLI and drop them in `FlydigiKit/Tests/FlydigiKitTests/Fixtures/` (the Apex 4 ones are flat; use a `<code>/` subfolder for a new pad):
   `config dump`, LED blob, and one screen frame if the pad has a screen.
3. Verify, in this order, each with a note in `protocol.md`:
   - device info, module versions (`apex4 dev xinput-probe`)
   - LED read → write brightness → save → power-cycle → read (persistence)
   - config read for every slot (`apex4 dev slots`), then the round-trip write test on a non-active slot
     (`apex4 dev slot-write-test`) — **check the blob length**: Apex 4 uses 790 B / 79 parcels; other pads
     may report 840 B (v3.1) or 770 B (v2.0) — the reader must honour the parcel count in the header.
   - screen (if any): frame size and max frames differ per model (Apex 3 uses a different upload protocol:
     `05 F0/F1`, 20-byte packets — see `spacestation4-analysis.md`).
4. Add `ConfigBlob` tests for the new fixture (decode expectations + byte-exact round trip).
5. Flip `support` to `.supported`, add yourself to the README's supported-hardware table with firmware
   version and date.

## 3. LED / screen differences

`LEDConfig` is the 500-byte "V2.0" layout (16 groups × 10 units). Pads with more zones use "V3.0"
(`grip_sync`, variable groups) — add a second struct rather than bending the first. Screens: keep
`Screen.width/height/maxFrames` per descriptor, and extend `ScreenUploadPlan` only if the command set
differs.

## 4. New protocol (`0x37D7`, "NewXInput")

Pads that enumerate with VID `0x37D7` (Apex 5/6, Vader 5, and per Space Station's tables the Vader 4 Pro) use
`5A A5 <cmd> <len> … crc` framing and different command ids. Space Station builds 32-byte frames that start with
`06`, and the replies come back as bare `5A A5 …`. That is a new `ProtocolVariant` with its own framing file,
replies and tests. Nothing Apple ships claims VID `0x37D7`, so it may not even need the helper.

What owners' probe reports show so far (macOS 27, 2026-09-06):

- **Apex 5**, wired and on its dongle: `37d7:2501`. Interface 0 is XInput-class (`ff/5d/01`) with no macOS
  driver, so games on the Mac do not see the pad. Interface 1 is a keyboard/mouse HID. Interface 2 is the vendor
  HID: usage page `0xFFA0` with output report id **3** and input report id **4**, 31 bytes each, plus the OTA
  collection (`0xFFEF` wired, `0xFFEE` on the dongle). A heartbeat sent as HID report id 6 got no reply, and
  interface 0 sent nothing during 15 s of button presses. So the leading `06` is most likely the first byte of a
  raw packet on interface 0's OUT endpoint, not a HID report id. Probe 0.2.3 tests that, and report ids 3/6/5 on
  the vendor HID.
- **Vader 4 Pro**, firmware 6.9.5.5, wired: it does **not** use the new VID. It enumerates as the classic
  `045e:028e` (Apple's driver, standard 20-byte report), and the app read its firmware and M1/M2 over the classic
  protocol. Its device id is not in the catalog yet. Start from
`docs/spacestation4-analysis.md` §4.1 and the official WebHID tool notes in `protocol.md` §7.

## 5. UI

The UI should read `DeviceDescriptor.capabilities`; today it is Apex 4-only — fixed `Screen` constants,
artwork looked up by device id — so a new family also means gating the Screen page and preview sizes on the
descriptor. Button hotspot positions for the hero render are per family (today `SpaceStation/App/Stage/Apex4Render.swift`
plus `KeyShapes.swift`) — a new family needs its own render (your own artwork, not Flydigi's)
and hotspot table.

## 6. Send it

PR checklist: descriptor + fixtures + tests green (`swift test` with Xcode installed) + `protocol.md`
updated with what you verified (and what you did not) + README table row. Open an issue first if you
hit a firmware behaviour that contradicts the docs — those are the interesting bits.
