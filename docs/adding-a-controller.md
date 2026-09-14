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
that changed, and the device info (classic `05 EC` query on Apex 4-family pads, new-generation `5A A5 01`
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
"?"). Note the VID/PID in each USB mode (`system_profiler SPUSBHostDataType`; the older `SPUSBDataType` prints nothing on macOS 26): `045e:028e` + `04b4:2412` means
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

Pads that enumerate with VID `0x37D7` (Apex 5/6, Vader 5 Pro) use `5A A5 <cmd> <len> … crc` framing and
different command ids. That is a new `ProtocolVariant` with its own framing file, replies and tests. Nothing Apple
ships claims VID `0x37D7`, and the config channel is a plain HID interface that opens without root, so it should
not need the helper. (Space Station's tables also list the Vader 4 Pro here, but the hardware speaks the classic
protocol — see below.)

**Verified on a Vader 5 Pro** (`37d7:2401`, cable and dongle, macOS 26.5, by a contributor in
[issue #1](https://github.com/uiltonlopes/flydigi-space-station-mac/issues/1)):

- The heartbeat is the bare frame `5A A5 01 02 03` padded to 32 bytes. Sent as an output report on the `0xFFA0`
  vendor HID it is answered within ~10 ms by a 32-byte input report on the same HID, e.g. on the dongle
  `5a a5 01 01 00 82 01 00 00 00 00 05 45 01 00 72 21 04 83 36 05 00 00 00 00 00 00 10 43 27 00 9f`.
  Header `5A A5 <cmd> <total packets> <index>`; the last byte is the sum of bytes 2…30 mod 256.
- **The report id comes from the pad's `0xFFA0` descriptor.** The Vader 5 Pro declares none (report id 0, frame
  as-is); the Apex 5 declares output id **3** / input id **4** (31 bytes each), so there the frame goes out as
  report 3. Space Station's leading `06` (analysis §4.1) is **not** part of the frame the pad accepts:
  `06 5A A5 …` got no reply on the HID nor on interface 0's OUT endpoint. The bare frame on interface 0's OUT
  endpoint is also answered — on the `0xFFA0` HID, not on interface 0.
- Reply fields, partly decoded from the cable/dongle differences and the field order in Space Station's parser
  (device, connection, MAC, battery, chip, motion, firmware, dongle/switch/trigger/screen versions): byte 5 =
  device id (`0x82` = 130 = Vader 5 Pro), byte 6 = `01` on the dongle / `00` on the cable, byte 11 = battery
  (`05` = full; `25` on the cable, high nibble probably "charging"), bytes 17–18 = `04 83` only on the dongle
  (receiver version?). Firmware is probably around bytes 14–16; unconfirmed until matched against the version the
  pad displays.
- Interface 0 (`ff/5d/01`, no macOS driver) streams the standard 20-byte Xbox 360 report (`00 14 …`, buttons in
  bytes 2–3, triggers 4–5, four 16-bit stick axes 6–13). On the **cable** it stays silent until the Xbox 360 start
  handshake — the three vendor IN control requests Linux `xpad` sends (`C1 01 0100`, `C1 01 0000`, `C0 01 0000`);
  the dongle streams without it.
- Cable and dongle enumerate identically (same VID:PID, name and four interfaces); only the OTA HID's usage page
  differs: `0xFFEF` wired, `0xFFEE` on the dongle. The dongle does not enumerate while the pad is off.
- While Steam is running it holds the whole device (`UsbExclusiveOwner = … steam_osx` in `ioreg`) and interface 0
  cannot be opened. Quit Steam before probing.
- IOUSBLib: `ReadPipeTO`/`WritePipeTO` are bulk-only and return `kIOReturnBadArgument` (`0xe00002c2`) on these
  interrupt pipes; use `ReadPipe` + `AbortPipe` and `WritePipe`, as `USBTransport.swift` does. flydigi-probe ≤ 0.2.3
  used the TO variants and printed "no input reports" for interface 0 for that reason; its Apex 5 result below is
  invalid on that point.

**Apex 5** (`37d7:2501`, wired and on its dongle, macOS 27): interface 0 XInput-class with no driver, interface 1 a
keyboard/mouse HID, interface 2 the vendor HID with `0xFFA0` (output report id 3, input id 4, 31 bytes) plus the
OTA collection (`0xFFEF` wired, `0xFFEE` dongle). A heartbeat sent as report id 6 got no reply, which the Vader
result explains; report id 3 with the bare frame has not been tried on it yet.

**Vader 4 Pro** (firmware 6.9.5.5, wired) does **not** use the new VID: it enumerates as the classic `045e:028e`
(Apple's driver, 20-byte report) and the app read its firmware and M1/M2 over the classic protocol. Its device id is
not in the catalog yet.

Start from `docs/spacestation4-analysis.md` §4.1 and the notes in `protocol.md` §7.

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
