# Flydigi Apex 4 — USB protocol (reverse-engineered)

Everything here was verified against a real Apex 4 (`deviceId 84`, firmware 6.8.3.0, later 6.8.3.7) on macOS 26,
using Python prototypes (since replaced by the `FlydigiKit` package and the `apex4` CLI). Where a fact comes only from reading
Flydigi's Windows software and was **not** exercised on hardware, it is marked *(unverified)*.

The Apex 4 is Flydigi's internal model **`k2`** (Apex 3 = `k1`). Device IDs in the k2 family:
`84` (Apex 4), `86` (EVA), `87` (STN), `92` (Assassin's Creed), `93`, `102`, `103`, `104`.
It has **4 LED groups** and a **160×80** LCD driven by a separate screen MCU (Space Station calls it `Freq`, not an ESP32) running LVGL v8.

## 1. USB modes

The controller has a hardware/software mode switch. Two modes expose a vendor channel over USB:

| Mode | VID:PID | What macOS sees | Vendor channel | Root needed on macOS |
|---|---|---|---|---|
| **XInput** | `045e:028e` (Xbox 360 pad emulation) | Apple's `com.apple.gamecontroller.driver.XboxGamepad` dext claims interface 0 | same interface 0: interrupt **OUT ep5**, **IN ep1** (64 B) | **yes** — the device must be *captured* from Apple's dext (IOUSBHost device capture / libusb `detach_kernel_driver`) |
| **DInput** | `04b4:2412` | 4 HID interfaces; generic HID drivers, nothing exclusive | HID **interface 2** (usage page `0xFFA0`): OUTPUT report id **5** (63 B), INPUT report id **4** (31 B) | **no** — plain `IOHIDManager`/hidapi |

Interface 3 in DInput (usage page `0xFFEF`, report id 5, 63 B in/out/feature) is unused by Flydigi's software.

Software mode switch:
- DInput → XInput: write `05 ED` (report 5, cmd 237) — verified 2026-09-04 (app, CLI `mode`, helper, firmware flow)
- XInput → DInput: `A5 17 … crc` (cmd 23) — verified 2026-09-04; it is also Space Station's "enter update mode"

Both cause a USB re-enumeration.

## 2. Framing

### XInput channel (raw interrupt transfers on interface 0)
- Command packets are **15 bytes**: `A5 <cmd> <args…> <crc>` where `crc` = byte-sum of bytes `[0..13]` (mod 256). Zero-padded.
- Replies arrive inside the 64-byte gamepad input report; the vendor payload starts at **offset 14**:
  - `r[14]==0xA5` → command reply, `r[15]` = cmd, `r[16..]` = payload.
  - `r[14]==0x5A && r[15]==0xA5` → **screen** reply, `r[16]` = cmd (`D0..D3`), `r[18]` = ret, `r[19..20]` = size/offset (BE).

### DInput channel (HID interface 2)
- Output = report id `5`: `05 <cmd> <args…>`, **zero-padded to 12 bytes** (14 B for write parcels); a
  5-byte report is silently ignored. With IOKit/hidapi on macOS the buffer passed to `SetReport` must
  **include the report-id byte** (`05 …`) — passing only the payload gets no reply.
- Input = report id `4`: `04 xx xx <payload…>` — payload starts at **offset 3**. For bulk reads the parcel index is at `r[3]`, data at `r[5..14]`, and the command id at `r[15]`.

## 3. Commands

| Function | XInput | DInput | Reply |
|---|---|---|---|
| Device info | `A5 10` | `05 EC` (236) | XInput: `r[15]=0x10`, deviceId `r[16]`, MAC `r[17..20]`, fw `r[21..22]` (nibbles → `H2.H1.L2.L1`), battery `r[23]`, cpu `r[24]`, conn `r[25]`, motion `r[26]`. DInput: `r[15]=236`, deviceId `r[3]`, MAC `r[5..8]`, fw `r[9..10]`, battery `r[11]`, cpu `r[12]`, conn `r[13]` (1 = wired), motion `r[14]` |
| Dongle info | `A5 11` | `05 11` | fw bytes; all-zero = wired |
| Read config (790 B) | `A5 21 <cfgId>` (33) → replies cmd `34`, idx `r[16]`, 10 B at `r[17..26]`, 79 parcels | `05 EB <cfgId>` (235) → `r[15]=235`, idx `r[3]`, 10 B at `r[5..14]` | |
| Read LED config (500 B) | `A5 26 <cfgId>` (38) → replies cmd `39`, 50 parcels | `05 E5 <cfgId>` (229) → `r[15]=229` | |
| Write config | start `A5 25 <N> A0 <cfgId>` (37) → ack cmd 35/37; data `A5 24 <10 B> A0 <idx> 00 crc` (36) → ack cmd 36 | start `05 EA <N> A0 <cfgId>` (234); data `05 22 <10 B> A0 <idx>` (34); acks `r[15]∈{234,231,51}` with idx at `r[3]` | |
| Write LED config | start `A5 2A <cfgId> <N>` (42) → ack 42; data `A5 29 <10 B> A0 <idx> 00 crc` (41) → ack 41 with idx at `r[16]` | start `05 E7 <cfgId> <N>` (231); data `05 33 <10 B> A0 <idx>` (51); ack `r[15]=231`, idx `r[3]` | see §5 |
| Read config random id | `A5 50 02 <cfgId>` → `r[15]=0x50,r[16]=2`, id `r[17..18]` BE, cfg `r[19]` | `05 50 02 <cfgId> crc` → payload `[80,2,hi,lo,cfg]` at `r[3..]` | |
| **Save to flash** | `A5 50 03 <hi> <lo>` (id = random+1) → `r[17]==1` on success | `05 50 03 <hi> <lo> crc` → `r[5]==1` | **required** for a written config/LED to survive power-cycle |
| Screen info / sleep time | — | `05 F2 03` / `05 F2 02 <sleep>` (242) | `r[3]=242,r[4]=3/4`; set verified 2026-09-02 (General › Controller › Sleep time) |
| Current config slot | `A5 20` → `r[15]=20`, slot `r[16]` (verified: 0) | `05 EB A0` → `r[1]=EB r[2]=A0 r[3]=slot` *(reply layout assumed from SS4's SDK; app falls back to the remembered slot on timeout)* | trusted only before any slot read (cursor) |
| Switch active config | `A5 50 05 <slot>` → ack `r[15]=50 r[16]=05` (verified: 0→1→0) | `05 50 05 <slot>` | |
| Motor test | `A5 12 <L> <R>` (verified; send `A5 12 00 00` to stop) | `05 0F <L> <R>` | |
| Module versions | `A5 30 01` → `r[17..26]`: trigger `0.r17.r18hi.r18lo`, screen `0.r19.r20hi.r20lo`, switch `r21hi.r21lo.r22hi.r22lo`, adc `0.r23.r24hi.r24lo`, nearlink `r25…r26` (observed: trigger 0.3.0.9, screen 0.1.1.3, switch 0.4.0.1, adc 0.128.8.0) | `05 F5 01` → same at `r[4..13]` | verified |
| Screen status bar | read `A5 30 02` → `r[17]==0` on (observed off); set `A5 30 03 <0=on,1=off>` | `05 F2 02/03` | |
| Screen sleep time | read `A5 30 04` → `r[17]` (observed 15); set `A5 30 05 <t>` | `05 F2 03/02` | |
| Mapping enable | `A5 18 <1=off,2=on>` | `05 EE <0/1>` | *(unverified)* |
| **ForceAdapt** (trigger resistance) | `A5 30 06 <1=apply,0=preview> <side 1=L,2=R,3=both> <mode> <params…>` — Normal `[side,0]`; Race `[side,1,stroke,resistance≥1,match]`; Sniper `[side,2,stroke,pressure,strength,freq,match]`; Recoil `[side,3,stroke,recoilStroke,strength,0,match]`; Lock `[side,4,stroke,strength,match]`; Vibration `[side,5,stroke,pressure,strength,freq,match]`; sync-with-grip `A5 30 08 <side,bindType,filter,scale,stroke,pressure,strength,freq>` | `05 A0 01 …` / `05 A0 04 …` | sent & acked (Race/Sniper/Normal); live effect only, profiles persist it in the blob (offsets 185..224) |

`N` = number of 10-byte parcels (config: 79, LED: 50). Config id 0 was used throughout; the
controller has several config slots.

> **Cross-check with Space Station 4.2 (2026-09-01):** see [`spacestation4-analysis.md` §4.2](spacestation4-analysis.md)
> for the full k2 command inventory taken from SS4's `Flydigi.ControllerSdk`. The k2 wire protocol is
> unchanged; SS4 adds partial writes (`A5 23`/`A5 28`), module versions (`A5 30 01`), status bar
> (`A5 30 02/03`), sleep (`A5 30 04/05`), ForceAdapt (`A5 30 06`), apply config (`A5 50 05`), and more.
> **Re-tested on hardware (fw 6.8.3.0, DInput):** config start `EA` and `EF` both work (79/79 acks, same
> `EA` ack tag); LED start `E7` works (50/50), `E6` does **not** accept our parcels — we keep `EA`/`E7`.
> DInput acks carry the parcel index **1-based** in `r[3]` (`0xFF` for the header ack). Save-to-flash
> byte order is a host-side convention only (the firmware echoes the two bytes back); we use big-endian.
> Config blobs of 840 B (v3.1) not seen on this firmware — still read the parcel count from the header.

### Firmware quirk — LED writes in XInput
In XInput mode a standalone LED write is **acknowledged but ignored**. Flydigi's software always
writes the full config first (`37/36`), waits ~500 ms, then writes the LED config (`42/41`).
Replaying that sequence makes the LED write take effect. In DInput mode a standalone LED write
takes effect immediately.

## 4. Config blob (790 B) — decoded

Implemented in `FlydigiKit/Sources/FlydigiKit/GamepadConfig.swift` (layout from Space Station 4's `MappingConfigParserV30`,
verified on the Apex 4's factory profile: title "常规游戏配置", C/Z mapped to the stick clicks).

```
offset   size  field
0..1     2     protoVersion, LE (0x0300 = "3.0")
2        1     packageCount (77 in the header even though 79 parcels are transferred)
3..12    10    legacy LED reference
13..108  96    key table: 32 × (target, turboEnable, turboFreq), index = ControllerKey id 0…31
                 target 0xFF or own id = identity · 0x20 = macro · 0xFE = keyboard/mouse · else remap
                 turboFreq > 0 → turbo ("Continuous") with enable 0 close / 1 press / 2 click
109..122 14    sticks L,R: curve(0 default,1 quick,2 slow,3 custom), deadZone(0…127), p1x,p1y,p2x,p2y, end
123..136 14    triggers L,R: kind(0 normal,1 ForceAdapt,2 vibration), zero, p1x,p1y,p2x,p2y, end
137..144 8     motion: mapType(0 off,1 L-stick,2 R-stick,3 mouse), enableKey, enableType, deadZone, sens, sens, useMode(0 FPS,1 racer), enableKey2
145..153 9     vibration: enabled(0=on), L(enabled,min,max,scale), R(enabled,min,max,scale)
154..182 29    trigger vibration motors (linear/micro presets per side)
183..184 2     "lunpan" (wheel)
185..224 40    ForceAdapt per trigger: type(0 Normal,1 Race,2 Sniper,3 Recoil,4 Lock,5 Vibration), bind type/filter/scale, 5 bind params, mixed border, 10 params
```

**ForceAdapt modes as Space Station 4 shows them for the Apex 4** (its enum names differ from its labels —
type 2 `Sniper` is labelled "Machine gun", type 3 `Recoil` is labelled "Sniper"). Ranges are the renderer's:

| type | SS4 label | live params after side | blob params[10..14] | UI ranges |
|---|---|---|---|---|
| 0 | Normal | `0` | start, end | — |
| 1 | Racing | `1 start damping out` (SS4: out=1, forced 0 when start=0) | start, damping, 0, 0, 0 | start 0–192, damping 1–255 |
| 2 | Recoil (机枪) | `2 start startForce strength freq out` | start, startForce, strength, freq, out | start 0–192, others 1–255 |
| 3 | Sniper | `3 start stroke resistance 0 out` | start, stroke, resistance, 0, out | start 0–192, others 1–255 |
| 4 | Trigger lock | `4 pos 255 1` | pos, 255, 1, 0, 0 | pos 20–200 |
| 5 | Vibration (sync with grip) | **`A5 30 08 side 2 block scale stroke freq 1 90`** (no apply byte) | stroke, freq, 1, 90, 0; bind type 2, filter = block, scale, bind params `stroke 1 1 freq 0` | scale 0–200, block 1–255, stroke 1–200, freq 1–255 |

"out" = "output data starting from the start position" (MatchStart / matchStroke): **the trigger reports a full
press as soon as it reaches the start position**; the travel before it is the whole 0–100 % range and the effect
zone is "past the floor". Proof: SS4's `ForceTriggerConfigCommon` zeroes the flag for Racing when start = 0
(it would read 100 % all the time). Racing has it on and hidden in SS4; Recoil/Sniper expose it (default off);
lock always sends 1. Flydigi's own per-game presets (`/game/list`, `vibType 2`) are all "sync with grip":
`[side, 2, filter, scale=10, stroke, 1, strength, frequency]`, e.g. Need for Speed `stroke 0, strength 255,
frequency 70, filter 20`.
**The pad's own "Trig mode" screen menu writes its preset into the active profile's adapter block** (read it
back with `apex4 config dump`; nothing shows in the input report or in the `A5 10` / `A5 30 xx` replies).
Values observed on fw 6.8.3.0, 2026-09-02 — these are the app's per-mode defaults:

| menu | adapter block bytes 0..19 | meaning |
|---|---|---|
| Normal | `00 00 0a 32 64 01 ff 46 00 ff 00 00 00 00 00 ff…` | params all 0 |
| Race | `01 00 0a 32 64 01 ff 46 00 ff 00 1e 00 00 00 ff…` | start 0, damping 30, match 0 |
| Recoil | `02 00 0a 32 64 01 ff 46 00 ff 00 01 32 0f 01 ff…` | start 0, start force 1, strength 50, freq 15, match 1 |
| Sniper | `03 00 0a 0a 64 01 ff 46 00 ff 32 1e 01 00 01 00…` | start 50, stroke 30, resistance 1, match 1 |
| Trig Lock 1/2/3 | `04 00 0a 0a 64 01 ff 46 00 ff 28|50|78 fa 01 00 00 00…` | position 40 / 80 / 120, 250, 1 |
| Vibration | `05 02 0a 32 01 01 01 5a 00 ff 01 01 01 5a 00 ff…` | bind 2, block 10, scale 50, stroke 1, freq 90 |

The bind block the firmware keeps for the non-vibration modes is `filter 10, scale 50 (left) / 10 (right),
params 100 1 255 70 0, mixed border 255`. The trigger "kind" byte (blob 123/130) stays 0 — the firmware
does not need it set to 1 for the adapter block to be active.

**Vibration (grip-sync) mode only engages through the profile.** Verified 2026-09-02: `A5 30 06 … 05 …` followed
by `A5 30 08 …` leaves the trigger in its previous mode; writing the adapter block (type 5, bind type 2) into
the active profile (`config restore` / write blob, even without save-to-flash) makes the triggers follow the
grip. They follow the **Xbox 360 rumble output packet** `00 08 00 <L> <R> 00 00 00` written on OUT ep5 (the
pad's only OUT endpoint in XInput, wired or via the receiver) — i.e. game rumble; the padded 15/32-byte and
receiver-format variants were accepted too. Space Station reaches mode 5 the same way (profile write).

The Apex 4 has no trigger motors of its own (`IsSupportTriggerVibration` is false for k2), so SS4's
"vibration test" for the Vibration mode is simply a full grip rumble (`A5 12 FF FF`) for 5 s — the trigger
follows the grip. SS4 has no per-mode defaults: a newly picked mode starts from whatever the profile held.
```
225..226 2     dataVersion — the random id (`A5 50 02` returns the same two bytes)
230..767 538   macros: [count][offsets… (maxMacros+1 header)] then per macro: key, actionCount LE16, enable(0 none,1 once,2 press,3 click), N × (t LE16 ×10 ms cumulative, key, event 0 release/1 press) — verified: 4-action macro on M1 round-trips
770..789 20    title, UTF-16LE
```
Unmodelled bytes are preserved on write (the encoder only re-serialises groups that changed).
**Profiles (verified 2026-09-01):** the pad holds 4 slots (factory titles 常规/枪战/格斗/赛车 = general/shooter/
fighting/racing). Read with `A5 21 <slot>`, write with `A5 25 <N> A0 <slot>` + parcels, then save-to-flash;
`A5 50 05 <slot>` activates a slot. **Reading a slot with `A5 21 <slot>` also makes `A5 20` report that slot as current** — re-apply the user's slot after enumerating profiles. Saving rewrites the blob's `dataVersion` bytes (225..226), so a
byte-exact restore is impossible — compare everything else. A full edit cycle (remap A→B, retitle, save,
read back, activate, restore) was exercised on slot 3.
Round-tripping the blob unchanged is safe (verified: 80/80 acks, re-read identical).

## 5. LED blob (500 B)

```
offset  size  field
0       2     version (observed 00 02)
2       1     type
3       1     loop_start
4       1     loop_end
5       1     speed        0–100
6       1     brightness   0–100
7       1     rgb_num      number of LED groups in use (Apex 4: 4)
8       1     mode         1 flow · 2 breathing · 3 gradient · 4 feedback · 5 steady (On) · 6 off (Close) · 7 default — see §12
9       11    reserved (FF)
20      480   16 groups × 10 units × (R,G,B); each channel is 0–100 (%), not 0–255
```
Factory default observed: mode 3 (gradient), speed 50, brightness 50, 4 groups each with units
`(0,0,100) (100,0,0) (0,100,0)` → blue→red→green cycle.

**Config ids 4…7 are the Nintendo Switch-mode profiles** (verified 2026-09-02, `apex4 dev slots --count 8`:
factory titles 常规/枪战/格斗/赛车游戏配置 with 6 remapped keys — the NS button layout). Space Station's
"Apply to NS mode" on slot *n* (old protocol = the Apex 4) is just `write config` + `write LED` to id *n+4*
with keyboard/mouse mappings reverted to identity, and no save command.

**The LED blob is per profile slot**: `A5 26 <cfgId>` / `A5 2A … <cfgId>` (DInput `05 E5 <cfgId>` / `05 E7 <cfgId> <N>` …; `E6` does not accept our parcels, see §3). Reading or writing with cfgId 0 while slot 2 is active makes the colours look shared between profiles (bug fixed 2026-09-02). The pad's own "Config Switch" menu is the same four slots.

## 6. Screen (LCD) — image format and upload

There is no command to read the current animation back; the app remembers what it sent (`ScreenStore`) and
ships Space Station's factory animations (`default_screen_image_<id>.bin`, same LVGL frame format, 30–35 frames)
as the fallback preview.

### Image binary (one per frame)
LVGL v8 `lv_img_dsc_t`-style file, produced on Windows by `lvImage2bin_x64.dll`:
```
4-byte header, little-endian uint32:  cf | (w << 10) | (h << 21)
   cf = 4  (LV_IMG_CF_TRUE_COLOR),  w = 160,  h = 80   → 04 80 02 0A
pixels: 160*80 × RGB565, **big-endian** (byte-swapped: `rol 8`), row-major
```
Per-channel quantisation used by Flydigi: `R5 = min(31, floor(R/8 + 0.5))`, `G6 = min(63, floor(G/4 + 0.5))`,
`B5 = min(31, floor(B/8 + 0.5))`. Frame size = 4 + 25600 = **25 604 B**. GIF: max **35 frames** for k2,
frames are resized to 160×80; frame delay is taken from the GIF (`duration/10` = centiseconds).

### Upload sequence (XInput only — see §1)
For each frame `num = 1..N` (`gifType=1`, size = frame length):
```
start   A5 D0 09 01 <gifType> <N> <num> <period> <sizeHi> <sizeLo> <crc = sum(bytes 1..9)> 00 00 00 00
        (period = frame interval in 100 ms units per SS4; Space Station 3.4 hard-codes 02, which is what we send)
        → reply 5A A5 D0 … ret@18
data    A5 D1 <offHi> <offLo> <26 data bytes, FF-padded> <crc = sum(bytes 1..29)>   (31 B)
        → reply 5A A5 D1 … ret@18 (0 = ok, 1 = resend), next offset @19..20
end     A5 D2 07 01 <num> <sentHi> <sentLo> 00 <crc = sum(bytes 1..7)> 00…      (15 B)
        → reply 5A A5 D2 … ret@18
```
After the last frame: `A5 D3 07 01 <N> 00 00 00 <crc> …` (EndAll) — the firmware acknowledges it with a **`D2`** reply, not `D3`. Throughput ≈ 4.5 s per frame
(985 × 26-byte packets, each acknowledged).

The DInput start command (`05 A5 D0 09 01 <gifType> <N> <num> <freq*10/50> <hi> <lo> <crc(2..10)>`)
**is** acknowledged (`5A A5 D0 03 00`) and puts the controller in upload mode ("1/N" on the LCD), but
the firmware then NAKs every HID OUT transfer on interfaces 2 and 3 — there is no working DInput data
path. Recovery: unplug and power-cycle the controller.

## 7. Newer Flydigi devices (for reference)
Flydigi's official WebHID tool (`hid2.flydigi.com`, a "device ID correction" utility) talks to
devices with Flydigi's own vendor id **`0x37D7`** using report id 5 and a different framing:
`5A A5 <cmd> <len+2> <payload…> <crc>`. The Apex 4 (fw 6.8.x) does not enumerate with that VID, but the
`5A A5` family is the same one the Apex 4 uses for screen replies — expect newer firmware/products to
converge on it. Space Station's code starts these frames with `06`, but a Vader 5 Pro ignores `06 5A A5 …` and answers the bare
`5A A5 …` frame sent as an HID output report whose id follows the pad's `0xFFA0` descriptor (none on the Vader 5
Pro, 3 on the Apex 5). Frame, reply layout and the cable handshake: `adding-a-controller.md` §4.

## 8. Legacy / other
- Apex 3 (`k1`, deviceId 24) uses a different screen protocol (`05 F0/F1`, 20-byte packets, w/h in
  the start command). Not targeted by this project.
- Bluetooth: Flydigi's BLE configuration service does not cover the Apex 4.
- **2.4 GHz dongle (charging base): works.** The dongle enumerates as `045e:028e` "Flydigi VADER3"
  (4 interfaces, Xbox-360-receiver style); interface 0 has the same OUT ep5 / IN ep1 and speaks the
  same XInput protocol — **LED/config read/write verified** through it. **Screen upload does not**: the
  `A5 D0` start command gets no `5A A5` ack over the dongle (the receiver firmware does not forward the
  screen commands, or they are wired-only). Root is needed exactly as in wired XInput.
  Observed behaviour of the receiver (2026-09-02, fw 6.8.3.0): it announces itself as "Flydigi VADER3" in
  the USB product string (the wired pad does not); it stays enumerated for a while after the pad turns
  off and then **drops off the bus by itself**, re-enumerating when the pad comes back; roughly every
  other request times out (retry once); and right after the pad powers on the device-info battery byte
  reads 0 for several seconds — Space Station keeps re-sending `A5 10` every second until it is non-zero,
  the app polls every 2 s for up to 30 s. macOS's GameController battery object for the receiver is
  state "unknown" / level 0 and must be ignored.

## 9. Live input in DInput mode (report id 4)

The vendor interface streams a 32-byte status report (`04 FE …`) continuously; the layout is Space
Station's `OperatorDataParser` (classic branch) shifted by one because IOHIDManager keeps the report id
in byte 0. Verified on an Apex 4 on 2026-09-01 (`apex4 dev hid-diff`):

| Byte | Bits |
|---|---|
| 7 | b0 C, b1 Z, b2 M1, b3 M2, b4 M3, b5 M4, b6 M5, b7 M6 |
| 8 | b0 Fn/Menu, b1 Turbo, b3 Home, b4 Back |
| 9 | b0 Up, b1 Right, b2 Down, b3 Left, b4 A, b5 B, b6 Select, b7 X |
| 10 | b0 Y, b1 Start, b2 LB, b3 RB, b4 LT, b5 RT, b6 L-stick click, b7 R-stick click |
| 17 / 19 | left stick X / Y (0…255, centre 0x7F, Y grows downwards) |
| 21 / 22 | right stick X / Y |
| 23 / 24 | LT / RT (0…255) |
| 4–6, 11–15, 18, 20, 26, 29 | motion sensor (changes when the pad moves; not decoded) |

A key whose table entry is `0xFE` (keyboard/mouse) **is still reported here** but is **removed from the XInput/Xbox
report** (verified 2026-09-04 with a one-off `apex4 dev km-probe`, since removed): the firmware suppresses it for games, so keyboard mappings
can only be driven from the DInput vendor report. **Motion (verified 2026-09-04 with one-off probes, `apex4 dev gyro-watch` remains):** the pad streams the sensor **only while the active profile's
motion map type is not Off** (byte 137); the report rate stays ~500 Hz. Bytes 4–6 pack two signed 12-bit rates like
Space Station's classic parser: `X = b4 | (b6 & 0xF0) << 4` = **yaw** (negative turning left, ≈ ±120 for a slow
turn), `Y = b5 | (b6 & 0x0F) << 8` = **pitch** (negative when the front rises; far more sensitive, saturates at
±2047). Bytes 29–30 (s16 LE) carry the **roll** rate (positive lifting the left grip); 11–12 / 13–14 / 15–16 are the
accelerometer X / Y / Z (Z ≈ 800 flat). Byte 18 wraps like a counter; 20, 26–27 are small. The Xbox report carries
the same three bytes at 14–16.

This is how the app lights up paddles, Fn and Home, which Apple's Xbox driver never reports in XInput
mode (`FlydigiKit/Sources/FlydigiKit/InputReport.swift`). Reply frames on the same interface use
`04 FF …` and are ignored by the parser.

**XInput carries the same state.** The interrupt report Apple's driver reads is 32 bytes, not the Xbox
360's 20: bytes 0…13 are the standard report (`00 14`, buttons, triggers, 16-bit sticks) and bytes
14…26 are Flydigi's appended state with the *same bit layout as above* at 17 (dpad/A/B/Select/X),
18 (Y/Start/LB/RB/LT/RT/thumbs), 19 (C/Z/M1…M6), 20 (Fn/Turbo/Home/Back), sticks 21…24 (centre 0x80),
triggers 25/26 (verified 2026-09-02 with `apex4 dev xinput-raw`; no enable command needed). Reading it
requires capturing interface 0, so the app only does that for a few seconds while the user is asked to
press a key ("borrow the pad"), then hands the pad back to the system driver.

## 10. Two traps found on 2026-09-02 (both channels)

- **Stale parcels.** After a blob read completes, the pad may still deliver one or two trailing parcels
  (the last index again). If the next read command is sent without draining the input queue, the
  assembler of the *next* blob accepts them — you get a config whose title is half from another slot
  (`"Padra置"`) or, in the worst case, a whole slot mis-attributed (id 0 showing slot 3). Drain the queue
  before every read and again ~30 ms after the last parcel (`Link.discardPending()`).
- **A config read right after an LED read of the same id returns the previous config.** Probe 2026-09-02
  (one-off `apex4 dev slot-probe`, since removed): apply 2 → read cfg 0 "Padrao" → read cfg 1 "Safari" → read LED cfg 0 → read
  **cfg 0 → "Safari"** (wrong) → read cfg 2 (right) → read LED cfg 2 → cfg 0 "Padrao" (right again). Slot ids
  are otherwise absolute in XInput (verified with the pad applied to 0, 1 and 2). Mitigation: query `A5 20`
  before any blob read on connect, read the LED of that slot, and burn one config read of that slot before
  enumerating the four profiles.
- **The cursor is not the active slot.** `A5 20` (XInput "current config id") reports the id of the last
  slot *read*, so reading slots 0…3 and then "re-applying the current slot" activates slot 3. The app now
  remembers which slot the user chose and re-applies it with `A5 50 05 <slot>` (XInput) / `05 50 05 <slot>`
  (DInput) after any multi-slot read. In DInput, `05 EB <id>` with id 0…3 reads the slot directly
  (id 4 returns a blank "常规游戏配置" template).

## 11. Calibration and joystick hardware switches (from Space Station's SDK, 2026-09-02)

- **ADC calibration window**: XInput `A5 14 01` opens, `A5 14 02` closes; DInput `05 E2 01` / `05 E2 02`.
  No acknowledgement. The pad learns centre and limits from whatever it sees in between, so the app only
  sends `02` after every axis has been swept (guided wizard in the Joystick tab). **Verified 2026-09-02:**
  after `A5 14 01` the LCD shows "Calibrating" and the pad stops reporting stick/trigger movement (both
  through Apple's driver and the raw report) until `A5 14 02` closes the window, so the wizard is timed
  (24 s sticks + 10 s triggers) rather than driven by live coverage.
- **Hardware function switches** (`A5 50 07` read, `A5 50 08/09/0B/0D/0E <v>` set = joystick debounce,
  auto-calibration, precision, sensitivity, rebounce; DInput read `05 F2 03`): the Apex 4 (fw 6.8.3.0)
  **does not answer** `A5 50 07` in XInput, and in DInput `05 F2 03` returns `f2 03 0f ff` — usable bits
  0…3 only, none of the joystick functions — so these settings are for newer models. The code stays in
  `DeviceSession` for other controllers; the app does not show them for the Apex 4.

## 12. LED blob per mode (from Space Station's `ConvertLedConfigToBean`, verified 2026-09-02)

Header bytes: `[0..1]` version (0x0200 for the Apex 4), `[2]` ClickFeedback (1 only in Feedback mode),
`[3]` loopStart (0), `[4]` **loopEnd**, `[5]` loop time, `[6]` brightness, `[7]` LED groups (4), `[8]` mode,
`[9..19]` FF. Mode values are Space Station's `LedType`: 1 Flow (streamlined), 2 Breath, 3 Gradient,
4 Feedback, **5 On (steady), 6 Close (off)**, 7 Default. The firmware cycles units `loopStart…loopEnd` of
each group, so `loopEnd` must follow the mode: On → every unit = the colour, loopEnd 0 (leaving a stale
loopEnd from a gradient makes a "steady" colour pulse); Gradient → units 0…n−1, loopEnd n−1; Breath →
colours on even units with black in between, loopEnd 2n−1; Feedback → units 0…n−1, loopEnd n,
ClickFeedback 1; Flow → colours untouched, loopEnd = groups.

Space Station's own mode list for the Apex 4 (`GetDefaultLedConfigsByDevice`) is **Default, Breath, Gradient,
On, Close** — Flow is excluded for `k2` and Feedback exists only for the Vader 4 (`f4`). On hardware the k2
indeed plays Flow like Breath. Colour counts in its UI: Gradient 2–5, Breath 1–5, On 1, Default/Close none.
Two modes need more than the mode byte: **Close** also blanks every unit (loop 0…0), and **Default** copies
the factory profile's loop and colours (k2 `default_mapping_*.dat`: loop 0…2, units blue/red/green, 4 groups)
under mode 7 — with black units mode 7 stays dark.
