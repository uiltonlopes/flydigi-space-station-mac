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
(Nintendo VID `0x057E`) are listed too. The only things sent to the controller are those two identity requests and,
on `0x37D7` pads, the Xbox 360 start handshake (three read requests; a wired Vader 5 Pro sends no input without them);
nothing is written to its memory. Quit Steam first (⌘Q): while it runs it holds the pad, and the probe stops and says so. Send the file with the model, firmware version and connection type in an issue or a DM.
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

## 4. New protocol (`0x37D7`, "NewXInput"; SDL calls it V2)

Pads that enumerate with VID `0x37D7` (Apex 5/6, Vader 5 Pro) use `5A A5 <cmd> <len> …` framing and different
command ids. That is a new `ProtocolVariant` with its own framing file, replies and tests. Nothing Apple ships
claims VID `0x37D7`, and the config channel is a plain HID interface that opens without root, so it should not need
the helper. (Space Station's tables also list an `fp4` code here; the Vader 4 Pro hardware met so far speaks the
classic protocol — see below.)

Two independent sources agree on the wire format: a contributor's measurements on a **Vader 5 Pro** (`37d7:2401`,
firmware 7.2.2.1, cable and dongle, macOS 26.5, [issue #1](https://github.com/uiltonlopes/flydigi-space-station-mac/issues/1)) and SDL's Flydigi HID driver
([`SDL_hidapi_flydigi.c`](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_flydigi.c), zlib licence — used as a reference, no code copied).

**Transport.** Commands are 32-byte HID output reports on the `0xFFA0` interface; replies and the optional input
stream are 32-byte input reports on the same interface. **The report id follows the pad's descriptor:** the Apex 5
(`37d7:2501`) declares output id **3** / input id **4**, the Vader 5 Pro declares none, so there the frame goes out
as report 0 exactly as written (SDL hard-codes id 3 and zeroes it for product `0x2401`). Space Station's leading
`06` (analysis §4.1) is **not** accepted: `06 5A A5 …` got no reply on the HID nor on interface 0's OUT endpoint.
The bare frame written to interface 0's OUT endpoint is also answered — on the `0xFFA0` HID.

**Commands** (`5A A5 <cmd> <len> <payload…>`, `len` = payload bytes + 2; the info request is answered with `03` or
`00` as its last byte, so a checksum is at least not enforced there):

| cmd | name | frame | reply |
|---|---|---|---|
| `01` | get info | `5A A5 01 02 00` | `5A A5 01 <total> <index> …`, fields below |
| `10` | get status | `5A A5 10` | byte 9 = 1 → third-party takeover allowed |
| `11` | status changed (pad → host) | — | re-send get status |
| `12` | rumble | `5A A5 12 06 <low> <high> 00 00 00` | — |
| `1C` | acquire controller | `5A A5 1C 17 <1/0> "SDL" 00…` (the name is free text) | bytes 5–6; afterwards the pad streams `EF` |
| `EF` | input report (pad → host) | — | see below |

**Info reply** — `5a a5 01 01 00 82 01 00 00 00 00 05 45 01 00 72 21 04 83 36 05 00 00 00 00 00 00 10 43 27 00 9f`
on the dongle; last byte = sum of bytes 2…30 mod 256:

| bytes | field | notes |
|---|---|---|
| 5 | device id | `0x82` = 130 = Vader 5 Pro |
| 6 | connection | SDL reads 1 = wired, 2 = wireless; this pad sent `00` on the cable, `01` on the dongle |
| 11 | battery | high nibble 0 = on battery, 1 = charging, 2 = charged; low nibble = level × 20 %. `05` = 100 % on battery, `25` = charged |
| 15–16 | firmware | one nibble per digit: `72 21` = 7.2.2.1 (SDL: `LOAD16(data[16], data[15])`) |
| 17–18 | receiver firmware | `04 83` = 0.4.8.3; `00 00` on the cable |
| 19–20 | SI firmware | `36 05` = 3.6.0.5 |
| 27–28 | RF firmware | `10 43` = 1.0.4.3 |

SDL refuses firmware below 7.0.3.1 on the Apex 5 and 7.1.4.1 on the Vader 5 Pro. The contributor had to update
theirs on Windows before Space Station's edit mode would assign buttons at all, so expect older firmware to behave
differently.

**Input over HID.** After `acquire` (SDL re-sends it and the info request every 30 s) the pad emits `5A A5 EF …`
reports on `0xFFA0`: sticks as little-endian int16 at bytes 3–10 (Y axes inverted), buttons at 11 (d-pad in the low
nibble; A `10`, B `20`, Back `40`, X `80`), 12 (Y `01`, Start `02`, LB `04`, RB `08`, LS `40`, RS `80`), 13 (M1 `04`,
M2 `08`, M3 `10`, M4 `20`, C `01`, Z `02`, LM `40`, RM `80`), 14 (Guide `08`, circle `01`), triggers 15–16, gyro
17–22, accelerometer 23–28. It only works while **"Allow third-party apps to take over mappings"** is enabled in
Space Station (its `AcquireController`, see the analysis doc); otherwise `get status` answers 0. That is the path to
gamepad input on macOS without an XInput driver — not needed for configuration, but it shows what the channel does.

**Interface 0** (`ff/5d/01`, no macOS driver) streams the standard 20-byte Xbox 360 report (`00 14 …`, buttons in
bytes 2–3, triggers 4–5, four 16-bit stick axes 6–13). On the **cable** it stays silent until the Xbox 360 start
handshake — the three vendor IN control requests Linux `xpad` sends (`C1 01 0100`, `C1 01 0000`, `C0 01 0000`);
the dongle streams without it.

**Also observed.** Cable and dongle enumerate identically; only the OTA HID's usage page differs (`0xFFEF` wired,
`0xFFEE` dongle), and the dongle does not enumerate while the pad is off. While Steam is running it holds the whole
device (`UsbExclusiveOwner = … steam_osx` in `ioreg`) and interface 0 cannot be opened. IOUSBLib's
`ReadPipeTO`/`WritePipeTO` are bulk-only and return `kIOReturnBadArgument` (`0xe00002c2`) on these interrupt pipes;
use `ReadPipe` + `AbortPipe` and `WritePipe`, as `USBTransport.swift` does. flydigi-probe ≤ 0.2.3 used the TO variants
and printed "no input reports" for interface 0 for that reason.

**Device ids SDL knows from hardware:** 19 Apex 2; 24/26/29 Apex 3; 84 Apex 4; 20/21/23 Vader 2; 22 Vader 2 Pro;
28 Vader 3; 80/81 Vader 3 Pro; **85/91/105 Vader 4 Pro** (classic protocol); 128/129/133/134 Apex 5; 130 Vader 5 Pro.
The catalog follows that; Space Station's `fp4` ids (132, 146–148) stay listed as inferred.

**Apex 5** (`37d7:2501`, wired and on its dongle): interface 0 XInput-class with no driver, interface 1 a
keyboard/mouse HID, interface 2 the vendor HID with `0xFFA0` (output report id 3, input id 4, 31 bytes) plus the OTA
collection. A heartbeat sent as report id 6 got no reply, which the Vader result explains; report id 3 with the bare
frame — what SDL does — has not been tried on it yet.

**Vader 4 Pro** (firmware 6.9.5.5, wired) does **not** use the new VID: it enumerates as the classic `045e:028e`
(Apple's driver, 20-byte report) and the app read its firmware and M1/M2 over the classic protocol. SDL maps device
ids 85, 91 and 105 to it.

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
