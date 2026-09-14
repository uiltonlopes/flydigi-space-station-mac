# Flydigi Space Station 4.x — analysis and comparison with 3.4.4.3

Scope: what Flydigi's current Windows app (Space Station 4, "SS4") does for the **Apex 4 (`k2`,
deviceId 84)**, how its protocol differs from the 3.4.4.3 code base we reverse-engineered in
[`protocol.md`](protocol.md), and what that means for this project's [roadmap](roadmap.md).

Legend used throughout: **[verified]** = read directly in decompiled/unminified code or observed in
a live HTTP response; **[inferred]** = deduced from names, strings or assets, not exercised.
The 2026-09-01 analysis was done without running anything on hardware and without executing any Flydigi binary; later verifications are dated inline (§9).

## 1. Source

| Item | Value |
|---|---|
| Download page | `https://shops.flydigi.com/pages/game-center` (section "Flydigi Space Station 4 — Support APEX 4/5, Vader 3/4/5, Direwolf 3/4, BS2, BS2Pro") |
| Installer analysed (primary) | `https://tencent-android.cdn.flydigi.com/PC/SpaceStation4.0/Flydigi%20Space%20Station_setup_4.2.0.9.exe` — 240 229 328 B, `Last-Modified: 21 May 2026`, sha256 `736070b1…dfc373a`, Inno Setup **6.7.0** |
| Newest build (from the update API, not linked on the site) | `…/Flydigi%20Space%20Station_setup_4.2.2.3.exe` — 243 135 488 B, sha256 `cee0ffe9…0172e9f`, Inno Setup **7.0.0.3**. Diffed against 4.2.0.9 (§3.6) |
| Older build (for the support timeline) | `https://andriod-1300023079.cos.ap-shanghai.myqcloud.com/PC/SpaceStation4.0/Flydigi%20Space%20Station_setup_4.1.0.31.exe` — 152 902 520 B, 18 Jul 2025, Inno 6.4.0.1 |
| 3.4.4.3 (reference) | `…/PC/Space%20Station3.0/FlydigiSpaceStation_setup_3.4.4.3_Release.exe` (still offered on the same page for "Vader 4/3, APEX 4/3, Direwolf 3, BS1") |

Tooling: `innoextract` built from PR dscharrer/innoextract#210 (Inno 6.4.2–7.0.2 support; stock
1.10-dev stops at 6.4), a small Python extractor for the .NET single-file bundle and for
Electron's `app.asar`, `ilspycmd` 11.0 for the .NET assemblies, `grep` on the Vite/React bundles,
`curl` against Flydigi's public API.

## 2. Stack — a complete rewrite

3.4.4.3 was a single .NET Framework/WPF process. SS4 is two processes **[verified]**:

| Layer | 3.4.4.3 | SS4 (4.2.x) |
|---|---|---|
| UI | WPF (`LibCommon.dll`, ViewModels) | **Electron 36.9.5** (Chrome 136) + **React 18 / Redux / antd**, built with **electron-forge + Vite**; `package.json` name `flydigi_space_station`, `main: .vite/build/main.js`. UI text in `locales/*/translation.json` (13 languages incl. `pt`) |
| Device I/O | in-process (`GameController.ServiceHandler.dll` service) | **`SpaceStationService.exe`** — a **.NET 8 single-file** Windows Service ("Flydigi Space Station Service", `sc create … start=auto`), assemblies `Flydigi.ControllerSdk`, `Flydigi.Hid` (HidApi.Net → `hidapi.dll`), `Flydigi.Basic`, `Flydigi.SharedResources` (protobuf), `Flydigi.{Charger,Cooler,Keyboard}Sdk`, `AdapterTriggerService`, `IntelligentCoolingService` (LibreHardwareMonitor + PawnIO.sys) |
| UI ↔ service | in-process | **Named pipe `\\?\pipe\fcs.sock`**, 4-byte LE length prefix + **protobuf** `IpcCommand` / `IpcResult` (`Flydigi.SharedResources.Data.Protobuf`, `IpcCommandEnum` — full list in Appendix A) |
| XInput vendor channel (045e:028e) | filter driver | kernel filter driver **`Xbox360Filter64.sys`** + `XboxComm64.dll` (`InitXboxMonitorRes`, `WriteData2Usb`, `IsCurrentUsbCanWrite`) — *absent in 4.1.0.31, added with k2 support in 4.2* |
| DInput vendor channel (04b4:2412) | hidapi | hidapi, interface 2 / usage page `0xFFA0` (`ControllerHidManager.FindSpecialHidDevice`) |
| Image → LVGL `.bin` | `lvImage2bin_x64.dll` | **JS port of LVGL's image converter in the renderer** (`index-D5oDoA4y.js`: `ICF_TRUE_COLOR_ARGB8565_RBSWAP`, `CF_TRUE_COLOR`, `outputFormat BIN`) — no native DLL |
| Firmware flashing | esptool + vendor loaders | `firmware/FirmwareConsole.exe` CLI + vendor tools (WCH `CH375`/`WCH55xISPDLL`/`CH343PT`, JieLi `jl_firmware_upgrade_x64.dll`, Megahunt `mhtool/hid_boot_command.exe`, HiSilicon `hsh_tool/BurnTool.exe` for NearLink bs21/ws63) |
| Other drivers | `FeizVKB64.sys` / `FeizVMO64.sys` (virtual keyboard/mouse), `hidvirtualdriver.sys`, `flydigimapclient.dll` | same set, plus `PawnIO.sys` (hardware monitor for coolers) |
| Telemetry | — | `crash-reporter.flydigi.com/upload`, `data.flydigi.com/api/space_station`, NPS survey `api/nps/report` |

The installer also ships a developer's `Logs/service_log_2026MMDD.txt` (4.2.0.9: 28 Apr 2026;
4.2.2.3: 20 May 2026) which confirms the runtime class names used below **[verified]**.

## 3. Device support

`Flydigi.ControllerSDK.data.model.DeviceType` (4.2.0.9 = 4.2.2.3) **[verified]**:

| Family (`DeviceCode`) | IDs | Notes |
|---|---|---|
| **`k2` — Apex 4** | **84** `K2` "APEX 4", 86 `K2Eva` "APEX 4 EVA", 87 `K2Stn` "APEX 4 STN", 92 `K2Acc` "APEX 4 Assassin's Creed", 93 `K2Rus` "ARDOR GAMING APEX 4", **102 `K2_HSH`** "Apex 4 Black Myth WuKong" (NearLink RF, no LED), **103 `K2GS`** "Yae Miko", **104 `K2SRS`** "Honkai: Star Rail Firefly" | Same 8 IDs as 3.4.4.3; **no new k2 IDs**. `Configs/Controller/k2/default/default_mapping_<id>.dat` + `default_screen_image_<id>.bin` shipped for all 8 |
| `k5` — Apex 5 | 128, 129, 133, 134, 135, 136 | NewXInput protocol, 160×80 screen, up to **150 frames** (`default_screen_image_128.bin` = 137 frames) |
| `k6` — Apex 6 / 6 Pro | 149, 150 | NewXInput; new `K6Trigger*` commands (waveform/realtime haptic triggers) |
| `f3`/`f3p` Vader 3, `f4` Vader 4 (85, 91, 105), `f5` Vader 5 (130, 144, 145), `fp3` Direwolf 3, `fp4` Direwolf 4 (132, 146–148, +151 in 4.2.2.3), `k1` Apex 3 | | |
| Chargers `cd2`, coolers `bs2/bs2pro/bs3/bs3pro`, keyboard `e10` | | new product categories |

Support timeline **[verified]**: 4.1.0.31 (Jul 2025) has **no k2 code paths, no `k2` configs and no
Xbox360 filter driver** (`DeviceType` lacks K2 variants beyond the enum; `Configs/Controller` only
has `k5`, `f4`); 4.2.0.9 adds the full k2 set, the driver and `UploadPicCommandK2Factory`. The
download page now advertises SS4 for "APEX 4/5".

`FlydigiControllerFactory.GenerateControllerApex4` **[verified]**: `IsSupportLed`, `IsSupportScreen`,
`IsSupportForceTrigger`, `IsSupportMotion`, `IsSupportVibration`, `IsSupportNs`; keys = A B X Y,
d-pad, LT/LB/RT/RB, Select/Start/Home/Menu, **M1–M4**, sticks; **no trigger vibration** (that is
Vader). Firmware modules: `ChipMain`=Telink, `ChipScreen`=**`ChipType.Freq`**, `ChipSi`=Krly,
`ChipTrigger`=Wch, `ChipDongle`=Telink (`K2_HSH`: RF+dongle = NearLink, LED off).
Note: our `protocol.md` says the LCD is driven by an ESP32; SS4 labels the k2 screen chip `Freq`
(the enum also has `Esp`). Worth re-checking before any LCD-firmware work **[inferred]**.

### 3.1 How SS4 treats the Apex 4's two USB modes — important

`ControllerHidManager.CreateDeviceFromHid` **[verified]**:
`ManufacturerString == "Microsoft"` → `ControllerType.XInput`; `VendorId == 0x37D7` →
`NewXInput`; anything else → `DInput`. So the Apex 4 is **`XInput` at 045e:028e and `DInput` at
04b4:2412**, exactly as in 3.4.4.3.

But the renderer treats VID `0x04B4` (1204) as **"firmware update mode"**: on
`receiveDeviceDetail` with `vendorId===1204` it shows *"Your controller is currently in firmware
update mode and cannot perform remapping or other editing operations. Please switch back to
standard mode"* (`dinput_mode_not_supported`) **[verified]**. Firmware flashing of the main chip
and dongle is done in DInput: `SwitchToFirmwareUpgradeMode(ChipMain, Telink)` sends `A5 17`
(= switch to DInput) and `FirmwareConsole.exe` is invoked with `--vendor_id 04b4 --product_id 2412`
**[verified]**. The UI prompt says *"press and hold FN + A to switch to DInput mode and update the
controller firmware"*.

**Consequence:** in SS4 all Apex 4 configuration (mapping, LED, screen, settings) goes through the
**XInput** channel via the kernel filter driver; the DInput command variants still exist in the SDK
(and are used for other DInput-only pads) but are not exercised for the k2 in normal use.
Our project's unprivileged DInput path therefore does something SS4 no longer offers.

## 4. Protocol differences vs 3.4.4.3

### 4.1 Framing — three transports, k2 unchanged

`AbstractCommand.CreateSimpleCommand` + `AbstractControllerCommand.TakeEndpointByDevice` **[verified]**:

| `ControllerType` | byte 0 | frame | used by |
|---|---|---|---|
| `XInput` | `0xA5` | **15 B** `A5 <cmd> <args…>` (CRC only on the screen commands), replies at `usb[14..]` (`A5`/`5A` marker, cmd at `usb[15]`) | Apex 4 (045e:028e), Vader 3/4, Direwolf 3, Apex 3 |
| `DInput` | report id **`0x05`** | `05 <cmd> <args…>`, 15 B; reply = report id 4 stripped, so SS4's `data[n]` = our `r[n+1]` | same pads at their DInput VID/PID |
| `NewXInput` | report id **`0x06`** | **32 B** (`maxPacketCount`) `06 5A A5 <cmd> <len> <payload…> <crc>` where `len` = payload+2 and `crc = sum(bytes[3 .. 3+len))`; replies `5A A5 <cmd> …`, input report `5A A5 EF …` (`0xF7` = raw data) | **VID `0x37D7`** products only: k5, k6, f5, fp4 |

So: **the Apex 4 still speaks the 3.4.4.3 framing** (`A5 …` / `05 …`), and the `5A A5 <cmd> <len> … crc`
family we saw on `hid2.flydigi.com` is the "NewXInput" protocol of the newer pads (note it is
report id 6, not 5, on USB). There is no k2 code path on the new framing, and the k2 firmware server
still serves a Telink `6.8.x` image (§6), so a k2 migration to `5A A5` is not in evidence.
`Controller.IsOldProtocol()` is literally `VendorId != 0x37D7` **[verified]**.

**Hardware note (2026-09-14):** a Vader 5 Pro ignores `06 5A A5 …` and answers the bare `5A A5 …` frame sent as
HID report 0 on `0xFFA0` (its descriptor declares no report ids; the Apex 5 declares out 3 / in 4). So the `06` in
`TakeEndpointByDevice` is a Windows-side or device-specific artefact, not part of the wire frame — see
`adding-a-controller.md` §4.

### 4.2 k2 command inventory in SS4 (XInput / DInput variants)

From `Flydigi.ControllerSDK.data.command.*` **[verified]**. `=` marks commands identical to
`protocol.md`; `≠` marks differences worth re-testing; `+` marks commands we had not documented.

| Function | XInput (`A5 …`) | DInput (`05 …`) | vs protocol.md |
|---|---|---|---|
| Heartbeat / device info | `A5 10 <random>` → `r[15]=10`, id `r[16]`, MAC `r[17..20]`, fw `r[21..22]`, batt `r[23]`, chip `r[24]`, conn `r[25]`, motion `r[26]`, **current cfg id `r[27]`** | `05 EC` → id `[2]`, **cfg id `[3]`**, MAC `[4..7]`, fw `[8..9]`, batt `[10]`, chip `[11]`, conn `[12]`, motion `[13]` | `=` (+ random pad byte, + cfg-id field) |
| Dongle info | `A5 11` → `0.<r16>.<r17>` | `05 11` | `=` |
| Extra versions (trigger/screen/switch/adc/nearlink) | `A5 30 01` → `r[17..26]` | `05 F5 01` → reply `FF F0 F5 01 …` | `+` |
| UID (13 B) | `A5 A0` → `r[16..28]` | `05 FA A0 <crc>` → `[4..16]` | `+` |
| Usage counters | `A5 A1` | `05 FA A1` | `+` |
| Current config id | `A5 20` → cfg `r[16]`, if `r[17]==A0` NS-cfg `r[18]` | `05 EB A0` → ack `[2]=AA [3]=AC`, cfg `[4]` | `+` |
| Read mapping config | `A5 21 <cfg>` → cmd 34 parcels of 10 B at `r[17..26]`; **count from header: v3.0 → 79, v3.1 → 84, else `r[19]`** | `05 EB <cfg>` → `[14]=EB`, idx `[2]`, data `[4..13]` | `=` + 840 B variant |
| Write mapping (all) | start `A5 25 <N> A0 <cfg>` (37), data `A5 24 <10 B> A0 <idx>` (36) | start `05 EF <start> <N> A0 <cfg>` (239) ack `[14]=EA`, data `05 22 <10 B> A0 <idx>` | XInput `=`; DInput start is **`EF` with start index**, we documented `EA` (`≠`, re-test) |
| Write mapping (partial, changed parcels only) | start **`A5 23 <start> <N> A0 <cfg>`** (35) | same `EF` | `+` (`MappingConfigParser.ParseConfigToArray(new, old)` diffs the two blobs and sends runs) |
| Read LED config | `A5 26 <cfg>` → cmd 39, 10 B parcels | `05 E5 <cfg>` | `=` |
| Write LED (all) | start `A5 2A <N> A0 <cfg>` (42), data `A5 29 <10 B> A0 <idx>` (41) | start **`05 E6 <cfg> <start> <N>`** (230) ack `[14]=E7`, data `05 33 <10 B> A0 <idx>` | XInput `=`; DInput start `E6` vs our `E7` (`≠`, re-test) |
| Write LED (partial) | start **`A5 28 <start> <N> A0 <cfg>`** (40) | same `E6` | `+` |
| Config random id (per slot) | `A5 50 02 <cfg>` → `r[17]` low, `r[18]` high | `05 50 02 <cfg>` | `=` (SS4 reads it **little-endian**; we read BE — value is opaque, but keep one convention) |
| All 4 random ids | `A5 50 04` | `05 50 02` (ack sub 4) | `+` |
| **Save to flash** | `A5 50 03 <verLo> <verHi>` (10 s timeout) | `05 50 03 <verLo> <verHi>` | `=` (byte order LE in SS4 — ours writes BE) |
| Apply onboard config | `A5 50 05 <cfg>` | `05 50 05 <cfg>` | `=` (now confirmed in code for both) |
| Read HW function status | `A5 50 07` | `05 F2 03` | `+` |
| Sleep time | set `A5 30 05 <t>`, read `A5 30 04` | set `05 F2 02 <t>`, read `05 F2 03` | `=` |
| Screen status bar always-on | `A5 30 03 <0=on/1=off>`; read `A5 30 02` (`r[17]==0` → on) | `05 F2 03 <0/1>`; read `05 F2 02` | `+` (was "unverified") |
| Xbox Home button | `A5 30 0A` on / `A5 30 09` off | — | `+` (usable only on f4/fp3/fp4/K2_HSH) |
| Motion debounce | `A5 30 0D <0/1>` | `05 F5 06 <0/1>` | `+` (same gating) |
| Joystick debounce / auto-cal / rebound | `A5 50 08|09|0E <1=off,0=on>` | same | `+` (gated: not for plain k2) |
| Hardware macro / mapping switch | `A5 50 06 <…>` | `05 50 05|06` | `+` |
| Report rate / stick precision / stick sensitivity | `A5 50 0A|0B|0D <v>` | same | `+` (enums: `ReportRate 1000/500/250/125 = 1/2/4/8`, `JoystickPrecision None,8,10,12,9,11,14,16 bit`, `JoystickSensitivity 14…20`) |
| Quick-switch config / audio | `A5 A2 <0/1>` | `05 FA A2 <0/1>` | `+` |
| Dock smart stop / write device type | `A5 50 10 <0/1>` / `A5 50 0F <type>` | same / `05 F5 05 <type>` | `+` |
| Mapping enable | `A5 18 <1=off,2=on>` | `05 EE <0/1>` | `+` |
| Disable macro mapping | `A5 19` | `05 E9` | `+` |
| Vibration (test / call) | `A5 12 <L> <R>` (k2 has no trigger vibration) | `05 0F <L> <R>` | `=` (motor test confirmed) |
| Force-trigger (ForceAdapt) config | `A5 30 06 <apply=1/preview=0> <cfg…>`; sync-with-grip `A5 30 08 <cfg…>`, `A5 51 01 type flag min max filter timeLimit vibrLimit levelLimit` | `05 A0 01 <apply> <cfg…>` / `05 A0 04 <cfg…>` | `+` (payload builder in `SetForceTriggerCommandFactory`) |
| Tests | LED `A5 13 R G B`, indicator `A5 15 id freq times`, screen `A5 30 08`, force trigger `A5 F2 04 <1/0>`, joystick `A5 F6 06 <1/2>`, ADC calibration `A5 14 <1=start/2=stop>`, sleep `A5 16`, RF loss `A5 41 <1/2>` | `05 E0`, `05 E3`, `05 A0 03`, `05 F2 04`, `05 F6 06`, `05 E2`, `05 E4` | `+` |
| Mode switch | `A5 17` → DInput | `05 ED` → XInput | `=` |
| Firmware-upgrade mode | main/dongle (Telink): `A5 17`; screen: `A5 30 0B`; trigger: `A5 30 0C` | `05 F5 03` (WCH582) / `05 F5 04` (WCH547) / `05 F6 01` (WCH571) | `+` |
| Device mask (DInput only) | — | `05 10 <ctrl> <media> <gyro>` | `+` |

### 4.3 Config blob (790 B, "3.0") and the 840 B "3.1" variant

`MappingConfigParser` **[verified]** — offsets into the 790-byte blob (protoVersion 2 B LE at 0,
`PackageCount` at 2):

| Offset | Field |
|---|---|
| 3..13 | LED reference (10 B) |
| 13..109 | **key table**: 32 × 3 B (`KeyConfigBean`: map type Key/Continuous(turbo)/Macro/MultiFunction/Keyboard) |
| 109..123 | joystick (dead zones, curve/sensitivity, circularity) |
| 123..137 | trigger (zero/end, `TriggerType` Normal/AdapterTrigger/VibrationTrigger) |
| 137..145 | motion (map type Off/LeftJoystick/RightJoystick/Mouse, dead zone, enable type, sensitivity, use mode FPS/Racer) |
| 145..154 | vibration (grip) |
| 154..183 | trigger motor / 185..225 auto-trigger ("adapter trigger" presets Normal/Race/Sniper/Recoil/Lock/Vibration) |
| 225..226 | **DataVersion** (the random id, LE) |
| 230..768 | macros (`MAX_HONG_NUMS 5`, 532 B, ≤64 steps each) |
| 770..790 | **title, UTF-16LE, 20 B** |
| 790..815 / 820..830 / 830..840 | v3.1 only: joystick extras (circularity type + edge per stick), macro extras, motion curve |

`m_fdg_mapping_config_struct_t` is the firmware-side struct (same fields, `cfg_name[16]`,
`joy_extra`, `macro_cycle`, `motion_curve`). `ReadMappingConfigCommandXInput` decides 79 vs 84
parcels from header bytes `r[18]==3 && r[17]==0|1` — an Apex 4 on newer firmware may report the
840-byte layout; our reader should honour the count in the first parcel rather than hard-code 79
**[inferred]**.

### 4.4 LED blob

`LedConfigParser` **[verified]** has two layouts selected by `data[1]`:
- **V2.0** (what our Apex 4 returns, `00 02`): 20-byte header `version(2) click_feedback loop_start loop_end loop_time brightness rgb_num led_mode reserve(11)` + **16 groups × 10 units × RGB** = 500 B — identical to `protocol.md` §5 (our "type/speed/mode" = `click_feedback/loop_time/rgb_type`).
- **V3.0**: header adds `grip_sync` at offset 9 (reserve shrinks to 10) and the body is `rgb_num × 3` bytes per group, variable length. Not seen on k2.
`LedType` enum: `Flow, Breath, Gradient, Feedback, On, Close, Default` (our modes 1–5, 0).
No change to the 500 B format for the Apex 4.

### 4.5 Screen upload (k2)

`UploadPicCommandK2Factory` / `UploadPic2K2{Start,Data,End,Finish}Command` **[verified]**:
- Frame = **25 604 B** (`4 + 160×80×2`), `FileStreamExtension.IsValidImageData` checks the header
  `04 80 02 0A`; the renderer converts with the LVGL JS converter using `cf = CF_TRUE_COLOR`,
  `binaryFormat = "bin_565_swap"` (`ICF_TRUE_COLOR_ARGB8565_RBSWAP` → high byte first) and **no
  dithering** (`options.dith` never set) — matches our encoder.
- Chunk size = **26 B in XInput** (`32 − 6`), 58 B in DInput (`64 − 6`, packet 64 B).
- Start (XInput, 15 B): `A5 D0 09 <picId=1> <picType 0=still/1=gif> <count> <idx> <period> <sizeHi=0x64> <sizeLo=0x04> <crc=sum(1..9)>` — **byte 7 is the frame period in 100 ms units** (`frameInterval/100`); our doc had a constant `02` there. Ack `usb[16]==D0 && usb[18]==0`.
- Data: `A5 D1 <offHi> <offLo> <26 B> <crc=sum(1..29)>`, ack requires `usb[19..20]` == offset, timeout 1 s ×3.
- End: `A5 D2 07 01 <idx> 64 04 00 <crc=sum(1..7)>`, **timeout 30 s** (flash write). Finish: `A5 D3 07 01 <count> 64 04 00 <crc>`.
- DInput variants exist with slightly different fields (`picType+1`, `picIdx+1`, no period byte) — consistent with our observation that the DInput path is not what Flydigi uses; on k2 SS4 only uploads in XInput (§3.1).
- Max frames: renderer sets **35 for k2**, 150 for k5, 17 for k1 (`deviceCode=="k2"?Ut(35)`), the user picks a frame range if the GIF is longer.
- **Apex 5 differs**: upload goes through `FirmwareConsole.exe --upgrade_type 2 --pic_type --pic_num --frame_rate` after `IpcCommandEnum_SwitchUsb` (a USB bootloader/serial path), not the HID protocol. "Restore default animation" (`is_restore_default`) uses the same tool.
- Upload is `IpcCommandEnum_UploadPic {uid, frameInterval, imageData}` over the pipe; progress via `UploadProgressChanged`.

### 4.6 Changes 4.2.0.9 → 4.2.2.3 **[verified]**

No new device IDs. New NewXInput-only commands: `ProbeConfigProtocolVersion` (`0x07`),
`SwitchMode(BluetoothMode None/Switch/Xbox/Flashplay/DInput)` (`0x1B`); `Controller.IsNewArchitecture`
flag; `ControllerHidManager` PID filter tweak; 10 new UI strings (default profile names "General /
Shooter / Fighting / Racing Game Profile", Direwolf 4 Phantom Blade 151, BS3 Pro EVA). Nothing
k2-specific. The `/Update/software` changelog for 4.2.2.3 announces a **web-based "Space Station
5.0"** for the Vader 5 Pro (desktop support "later") — the WebHID direction we saw at
`hid2.flydigi.com` **[inferred: from changelog text]**.

## 5. Feature inventory

Pages (`react-router` paths in the renderer): `/home/index`, `/deviceCenter`, `/equipementList`,
`/connectDevices`, `/screenPage`, `/handleTestPage`, `/adaptTrigger`, `/settingsModalPage`,
`/keyboard/index`, `/cooler/index`, `/charging/index`, `/chargerDiyPage`, `/memberCenter`,
`/creditMall` **[verified]**. Feature list from `IpcCommandEnum`, the SDK API and `en/translation.json`.

| Feature | SS 3.4.4.3 | SS4 4.2.x | Applies to Apex 4 | Our roadmap |
|---|---|---|---|---|
| Device info, battery, per-module firmware versions (main/screen/switch/trigger/dongle) | yes | yes (`ExtraInfo`, `FirmwareInfo` list) | yes | M0 ✅ info; add sub-versions |
| 4 onboard config slots, apply/switch slot, quick-switch (Select+A/B/X/Y) | yes | yes (`ApplyOnboardConfig`, `EnableQuickSwitchConfig`; k2 uses **SELECT** as modifier) | yes | M2 🔬 |
| **Local ("inactive") configs** stored on PC, sort/rename/delete, create new | partial | yes — protobuf `.dat` under `Configs/Controller/<code>/local`, `index.dat`; default `.dat` per device id shipped | yes | M2 (import/export) |
| **Config sharing by code** | no | yes — `ShareOnboardConfig/ShareLocalConfig` → `POST /pc/config_share/upload`, `DownloadSharedLocalConfig` ← `/pc/config_share/download` | yes | M3 "community presets" — could interoperate |
| Button mapping (key / turbo "Continuous" / macro / multi-function / keyboard+mouse) | yes | yes; macros also editable as **local macro library** (`GetLocalMacroConfigList`, record, share) | yes (keyboard/mouse output needs Windows drivers) | M2 🔬 |
| Joystick: dead zones, curve/sensitivity presets, circularity (Rectangle/Circular), edge, polling rate, precision, centre sensitivity, rebound/debounce/auto-cal | yes (subset) | yes; for plain k2 the advanced switches (rebound, auto-cal, debounce, Xbox Home) are **hidden** (`ReadHardwareFunctionStatus` gates them to f4/fp3/fp4/K2_HSH) | partially | M2 🔬 |
| Triggers: ForceAdapt modes (General / Racing / Recoil / Sniper / Trigger lock / Vibration-shield), stroke, dead zones, ADC calibration | yes | yes (`SetForceTrigger`, `CalibrationAdc`, `trigger_mode_K2_*` strings) | yes | M2 🔬 |
| Gyro/motion: off / L-stick / R-stick / mouse, FPS/Racer mode, dead-zone compensation, curve | yes | yes (+ motion curve in v3.1 blob) | yes | M2 🔬 |
| Vibration: grip intensity, test | yes | yes | yes | M2 🔬 |
| LED: 5 modes, per-group colours, brightness, speed | yes | yes; UI presets + colour picker | yes | M1 ✅ (CLI) |
| **Screen**: upload GIF/PNG/JPG, crop/scale editor, frame range (≤35), frame interval, preview | yes | yes, plus **online library** ("Library / Official selection / Player upload", `GET /pc/screen_pic/list`) and "restore default animation" | yes | M1 (library = new) |
| Screen settings: status bar always-on, animation on/off (`OffScreen`) | status bar | status bar for k2; `OffScreen` is NewXInput-only | status bar yes | M1 🔬 |
| Sleep/auto-standby time | yes | yes | yes | M1 🔬 |
| Live input test page (`/handleTestPage`): buttons, sticks, **circularity error test**, polling-rate test, raw data | yes | yes (`EnableRawData`, `RollingRateReport`) | yes | M2 (GameController) |
| **Adaptive-trigger game profiles** ("Adapt Trigger"): per-game force/vibration presets, Steam/Epic/Xbox/Ubisoft game discovery (`GameFinder`), optional game **mods** downloaded and launched, UDP telemetry 7878/8787, "DS mode" (PS5 DualSense emulation via `PS5Driver`) | yes (`GameTriggerModService`) | yes, rewritten (`AdapterTriggerService`, `GET /pc/adapter_trigger/list` — 94 games for k2) | yes on Windows; game-mod/DS parts are Windows-only | M3 (frontmost-app profiles) — reuse the API's per-game trigger params |
| Third-party takeover (Steam Input / reWASD) | no | yes (`AcquireController`) — NewXInput / k5 fw ≥ 7.0.3.0 only | no | 🚫 |
| Firmware update (check, download, flash, rollback) | yes | yes — `POST /pc/Update/firmware`, `FirmwareConsole.exe`; k2 main+dongle flashed in DInput mode | yes | Later ❓ |
| App self-update | yes | yes — `POST /pc/Update/software` | — | — |
| Charger (CD2) LED/DIY, coolers (BS2/BS3) fans/RGB/temps, keyboard (E10) | no | yes | no | 🚫 |
| Member centre / credit mall / SMS login (edge.flydigi.com, China only) | no | yes | no | 🚫 |
| Themes (dark/light/system), 13 languages, GPU-acceleration toggle, log export, NPS survey | partial | yes | — | — |

## 6. Firmware

- `DeviceType.K2` firmware modules and chips: see §3. Version format everywhere is 4 nibbles
  `H2.H1.L2.L1` from two bytes, as in `protocol.md`.
- **Live update server** (`POST https://api.flydigi.com/pc/Update/firmware`, header
  `appversion: <app>`; body `{device_code:"k2", device_id:84, app_version:"4.2.0.9", main_chip:"6.8.3.0"}`)
  **[verified 2026-09-01]**:
  `{"code":0,"data":{"device_code":"k2","chip_list":{"main_chip":{"version":"6.8.3.7","url":"https://tencent-android.cdn.flydigi.com/firmware/K2/K2_Telink87_Gamepad_6837_0714.bin","info":"更新点：\n1.优化连接体验","min_app_version":"4.1.2.0","is_push":0}}}}`
  — i.e. the newest Apex 4 main firmware is **6.8.3.7** (our unit runs 6.8.3.0); the file name
  confirms a **Telink TLSR87xx** MCU. Only chips whose current version is sent are answered;
  with `screen_chip/si_chip/trigger_chip/dongle_chip` set to dummy versions no update was
  returned for those modules. Same answer for id 86 (EVA).
- Minimum firmware: SS4 has **no** k2 firmware gate. Version gates in code are for other pads
  (`k5 ≥ 7.0.2.8/7.0.2.9/7.0.3.0`, `f5 ≥ 7.1.4.1`) and games carry `minFirmwareVersion`
  (e.g. `6.4.4.5` for EA WRC on k2). `min_app_version` in the firmware answer is 4.1.2.0 — the
  server expects SS4 ≥ 4.1.2 to offer 6.8.3.7 **[verified]**.
- Flashing CLI (`main.js` → `firmware/FirmwareConsole.exe`): `--device_id <code> --chip_module <n>
  --chip_type <n> --url <bin> --vendor_id 04b4 --product_id 2412 [--pic_type --pic_num --frame_rate
  --upgrade_type 2 --is_restore_default 0|1]`; progress parsed from stdout `Progress: NN%`,
  `success`/`failed`. Not run.

## 7. Web APIs (all plain HTTPS, no auth except the member centre) **[verified live unless noted]**

Base `https://api.flydigi.com/pc` (axios, `withCredentials`, header `appversion`).

| Endpoint | Request | Response (shape) |
|---|---|---|
| `GET /screen_pic/list?device_code=k2` | — | `{code:0, data:[{id, type:"gif"\|"jpg", imagePath:<cdn url>, title, freq, cate:"0"\|"1"\|"2", status, create_time, update_time, isRecomment, device_code}]}` — **38 items for k2** (23 GIF, 15 JPG), 48 for k5. `freq` (0/10/15/20) is the official frame interval the UI locks ("official GIF frame interval unmodifiable") — units to confirm **[inferred]** |
| `POST /Update/firmware` | `{device_code, device_id, app_version, main_chip?, screen_chip?, si_chip?, trigger_chip?, dongle_chip?, rf_chip?}` | `{code, message, data:{device_code, chip_list:{<chip>:{version, url, info, min_app_version, is_push}}}}` (`chip_list` is `[]` when nothing to offer) |
| `POST /Update/software` | `{app_version}` | `{status:0, data:{version:"4.2.2.3", url, info, force:false}}` |
| `GET /adapter_trigger/list?device_code=k2` | — | `{status:0, data:[{id, gid, gameName, enGameName, platforms:["steam","epic","xbox","ubisoft","standalone"], processGameNames, imagePath, isMod, isNeedDownMod, modDownLoadUrl, modStartType, isPS5, isRacingTelemetry, isVibration, vibType, vibParams:"0,1,1,15,0", vibParamsRight, vibFilter, pwmScal, minFirmwareVersion, minVersion, profilePackages, scenes, …}]}` — 94 games |
| `GET /activity_banner/list?device_code=k2` | — | `{data:{version, list:[{image_url, title, language, url}]}}` (empty for k2) |
| `GET /product/list` | — | device catalogue with connect guides/videos — **k2 not listed** (only K5, FP4, F5, CD2, BS2/3) |
| `POST /config_share/upload`, `GET /config_share/download` | share code ↔ protobuf `ControllerMappingConfigBean` | not exercised **[inferred]** |
| `GET /nss/index?device_code=&lang=&device_type=` | survey page (browser) | — |
| `https://data.flydigi.com/api/space_station`, `/api/nps/report`, `/api/web/link?u=…` | telemetry / NPS / help links | — |
| `https://edge.flydigi.com/space-api/*` (`auth/sms`, `auth/login`, `member/me`, `member/device`, `mall/*`, `feature-flags`) | member centre (China) | — |
| `https://crash-reporter.flydigi.com/upload` | Electron crash reporter | — |

## 8. Recommendations for our roadmap

> Status 2026-09-04: everything below is done (see `roadmap.md`) except the optional 30 s `D2` timeout and `.dat` import.

1. **Keep the k2 protocol as documented; no migration needed.** SS4 confirms every XInput
   command we use and adds none on a new framing. Add the confirmed commands to `protocol.md`
   (§4.2 table): current-config-id `A5 20`, config random ids `A5 50 02/04`, extra versions
   `A5 30 01`, UID `A5 A0`, status bar `A5 30 02/03`, sleep `A5 30 04/05`, force-trigger
   `A5 30 06`, tests `A5 13/14/15/16`, partial writes `A5 23`/`A5 28`.
2. **Re-test three DInput details** against SS4's variants: mapping write start `05 EF <start> <N>
   A0 <cfg>` (vs our `05 EA`), LED write start `05 E6 <cfg> <start> <N>` (vs `05 E7`), and the
   `05 F2 02` read/write asymmetry. Also decide one byte order for the save-to-flash version
   (SS4: little-endian) and honour the parcel count in the first config parcel (79 vs 84).
3. **Screen**: encode the frame period into start byte 7 (`interval_ms / 100`) instead of a fixed
   `02`; use a 30 s timeout on `D2`; keep no-dither RGB565-swap (matches SS4). Offer the frame-range
   picker (≤35) like SS4.
4. **Online GIF library** is trivial to add: `GET https://api.flydigi.com/pc/screen_pic/list?device_code=k2`
   returns CDN GIF/JPG URLs; convert locally with our encoder. Respect `freq` as the default
   interval for official items.
5. **Milestone 2 decoding** is now mostly done on paper: the 790 B layout offsets and the protobuf
   model (`ControllerMappingConfigBean`: key/joystick/trigger/motion/vibration/LED/macro beans,
   enums in Appendix B) give us a ready-made data model; the shipped
   `Configs/Controller/k2/default/default_mapping_84.dat` (protobuf) is a factory-default reference
   we can parse in tests (do not copy Flydigi's file into the repo; regenerate our own defaults).
6. **Config sharing**: SS4's share codes wrap the same protobuf bean; supporting `.dat` import and,
   later, the `config_share` endpoints would make our profiles interchangeable with SS4 users.
7. **Firmware**: the update server is a simple JSON POST and answers `6.8.3.7` for k2 today. A
   read-only "update available" notice (link to Flydigi's Windows tool) is low-risk; flashing itself
   (Telink over the DInput/04b4 endpoint) followed once the protocol was read — see `firmware-update.md`.
8. **Per-game trigger profiles** (M3): the `adapter_trigger/list` payload already contains per-game
   force/vibration parameters (`vibParams`, `pwmScal`, presets) and process names; a macOS
   frontmost-app matcher could reuse the presets for the same titles (mods/DS-mode excluded).
9. **Positioning**: SS4 refuses to configure an Apex 4 in DInput mode and needs a kernel filter
   driver for XInput; our unprivileged DInput path (config/LED without root) is a genuine
   advantage worth stating in the README. Note also that on the Apex 4, SS4 hides the advanced
   stick switches (rebound/auto-cal/debounce/Xbox-Home) — they are firmware features of newer pads.

## 9. Share codes (verified 2026-09-04)

- **Payload** = `BitConverter.ToString(ControllerMappingConfigBean.ToByteArray())`: the protobuf bytes of the profile
  bean, upper-case hex separated by dashes. The bean is produced from the 790-byte blob by `MappingConfigParserV30`
  (ported in `FlydigiKit/Sources/FlydigiKit/SS4Profile.swift`, integer arithmetic included — the proto 3.0 stick
  points lose a few units on the way, in Space Station too) and carries the LED bean when the service has one.
- **Upload**: `POST https://api.flydigi.com/pc/config_share/upload` JSON `{configName, controllerType: "k2",
  configContent: JSON.stringify(hex)}` (header `appversion`), no login. Reply `data.uniqueId` = `"分享码：<32 hex>"`;
  the code users exchange is the 32-hex part.
- **Download**: `GET …/config_share/download?uniqueId=<code>&configType=1&controllerType=k2` (camelCase only;
  snake_case → HTTP 400 "参数不完整"). Reply `data.{config_name, controller_type, config_content}`; the renderer
  rejects `config_type != 0` when present.
- Field numbers of every message are in `SS4Profile.swift`; enums are sequential in declaration order
  (`KeyMapType` Key/Continuous/Macro/MultiFunction/Keyboard, `JoystickMapType` Joystick/Keyboard/Mouse/DPad,
  `MotionMapType` Off/LeftJoystick/RightJoystick/Mouse, `MacroEnableType` None/Once/Press/Click, …).

## Appendix A — `IpcCommandEnum` (controller subset)

`Init 1, UploadLog 2, OperatorChanged 10, EnableXinput 11, EnableRawData 12, RollingRateReport 13,
SwitchUsb 15, EnableControlByThirdPartyApp 16, AcquireController 17, CheckThirdPartyAcquiredController 18,
GetConnectedDevices 4097, DeviceConnectionChanged 4098, GetDeviceDetailInfo 4099, GetCurrentAppliedConfigId 4100,
GetConfig 4112, UpdateConfig 4113, SaveConfig 4114, ApplyOnboardConfig 4115, SaveOnboardConfigToLocal 4116,
ApplyLocalConfig 4117, UpdateLocalConfigSort 4118, UpdateLocalConfigName 4119, DeleteLocalConfig 4120,
CreateNewLocalConfig 4121, ShareOnboardConfig 4122, ShareLocalConfig 4123, DownloadSharedLocalConfig 4124,
ResetMappingConfig 4127, GetLocalMacroConfigList 4128 … GetLocalMacroConfigDetail 4138,
GetScreenStatus 4144, EnableScreenStatusBarAlwaysOn 4145, OffScreen 4146, UploadPic 4147, UploadProgressChanged 4148,
GetAdapterTriggerGames 4160 … SetAdapterTriggerGameFavorite 4168, CallVibration 4176, CallGripVibration 4177,
CallTriggerVibration 4178, UpdateReportRate 4179, UpdateSleepTime 4180, UpdateJoystickSensitivity 4181,
UpdateJoystickPrecision 4182, EnableJoyStickDebounce 4183, EnableJoystickAutoCalibration 4184,
EnableJoystickRebound 4185, EnableQuickSwitchConfig 4186, EnableMotionDebounce 4187, ReadHardwareFunction 4188,
UpdateNickname 4189, EnableMappingSwitch 4190, EnableDockSmartStop 4191` (charger 24577+, cooler 28673+).

## Appendix B — protobuf enums (`Flydigi.SharedResources.Data.Protobuf`)

`KeyMapType: Key, Continuous, Macro, MultiFunction, Keyboard` · `MacroEnableType: None, Once, Press, Click` ·
`JoystickMapType: Joystick, Keyboard, Mouse, Dpad` · `JoystickSensitivityType: Default, Quick, Slow, Custom` ·
`JoystickCircularityType: Rectangle, Circular` · `MotionMapType: Off, LeftJoystick, RightJoystick, Mouse` ·
`MotionUseMode: Fps, Racer` · `TriggerType: Normal, AdapterTrigger, VibrationTrigger` ·
`AdapterTriggerType: Normal, Race, Sniper, Recoil, Lock, Vibration` · `LedType: Unknown, Flow, Breath, Gradient, Feedback, On, Close, Default` ·
`ChipModule: Main 0, Rf 1, Si 2, Screen 4, Trigger 5, Dongle 6, Adc 7, Led 8` ·
`ChipType: Unknown, Wch, Telink, Krly, NearLink, Megahunt, Puya, Esp, Freq, Jieli` · `ConnectType: Unknown, Wired, Dongle, Bluetooth` ·
`ControllerKey: Up 0, Right 1, Down 2, Left 3, A 4, B 5, Select 6, X 7, Y 8, Start 9, Lb 10, Rb 11, Lt 12, Rt 13, Thl 14, Thr 15, C 16, Z 17, M1–M6 18–23, Menu 24, Turbo 25, Home 27, Back 28, Macro 32, JsLeft 240, JsRight 241, JsWheel 242`.

## Appendix C — files examined

Decompiled from `SpaceStationService.exe` (4.2.0.9 and 4.2.2.3): `Flydigi.ControllerSdk`
(`data.command.*`, `data.protocol.{dinput,xinput}`, `data.parser`, `data.model.config`, `factory`,
`hardware`), `Flydigi.Hid`, `Flydigi.Basic`, `Flydigi.SharedResources`, `SpaceStationService`
(`FlydigiWorker`, `CommunicationProtocolHandler`, `ControllerBusinessService`, `MappingConfigManager`),
`AdapterTriggerService`. Renderer: `app.asar/.vite/renderer/main_window/assets/*.js`,
`locales/en/translation.json`; main process `.vite/build/main.js`. Installer payload:
`Configs/`, `driver/`, `firmware/`, `Logs/`. Work directory (not committed):
`scratchpad/ss4/` — `ext41/ ext42/ ext43/` (installer payloads), `bundle4x/`, `src4x/`,
`asar4x/`, `api/*.json`.
