# Installing Space Station for Mac

**Requirements:** macOS 15 or newer, a Flydigi Apex 4 connected
over USB-C or through its charging base (2.4 GHz receiver).

## 1. Install the app

1. Open the `.dmg` and drag **Space Station.app** onto the Applications folder shown next to it.
2. First launch: builds from the Releases page are signed with a Developer ID and notarized by Apple, so
   the app opens like any other. (Only if you built it yourself with a personal certificate will macOS ask
   you to right-click → Open once, or to run `xattr -dr com.apple.quarantine "/Applications/Space Station.app"`.)

## 2. Install the helper (needed in XInput mode)

By default the controller is in **XInput** mode and Apple's own Xbox driver owns it. To talk to it the
app uses a small privileged helper that borrows the USB interface only while a command runs.

1. Open **Settings** (bottom of the sidebar) → **Install helper**.
2. macOS opens *Login Items & Extensions*; allow **SpaceStationHelper** and enter your password once.
3. Back in the app press the refresh icon. The sidebar should show your controller, firmware and battery.

If the app says macOS did not start the helper, press **Repair helper** in the same section. If that does not help,
macOS's background-items database holds a stale record: run `sfltool resetbtm`, restart the Mac, then install the
helper again. The reset clears the background-item approvals of every app. See the wiki's
[Troubleshooting](https://github.com/uiltonlopes/flydigi-space-station-mac/wiki/Troubleshooting-and-FAQ) page.

Without the helper the app still works fully in **DInput** mode (switch with the Mode row on the device
card or Settings → USB mode, or hold the controller's mode combination). The LCD upload always needs XInput + the cable.

If nothing is found while Steam is open, quit Steam: on some controllers it takes exclusive ownership of the USB
device (`UsbExclusiveOwner` in `ioreg`) and nothing else can open it.

## 3. Modes at a glance

| | XInput (default) | DInput |
|---|---|---|
| Games | see an Xbox controller | see a generic gamepad |
| Configuration | via helper | direct, no helper |
| Screen (GIF) upload | yes, cable only | no |
| Live view of paddles / Fn | only while capturing a key | always |

## Uninstall

Delete `Space Station.app`. To remove the helper first: Settings → **Remove helper**, or in Terminal
`sudo launchctl bootout system/com.uiltonlopes.spacestation.helper`.

## Safety

Everything the app writes (lighting, profiles, macros, screen) goes to the same flash areas Space
Station writes, using the same commands, verified on real hardware. The firmware update uses the same OTA
sequence as Space Station's flasher and only runs over the cable with the battery above 40 %; keep the cable
in until the controller restarts. If the screen ever gets stuck mid-upload, unplug and re-plug the controller.

## Support

Questions and bugs: open an issue on GitHub. If the app is useful to you, you can
[buy the author a coffee](https://buymeacoffee.com/uiltonlopes).
