# Changelog

All versions were built and bench-tested on 2026-11-07 against a Roku Streambar
(model 9102R, Roku OS 15.3.4, serial YL000J474928) in Helmut Bedroom, controlled
from an SR-150 remote. Driver XML `<version>` is shown in brackets.

## v0.3.0 [30] — discovery and the stock driver's remaining properties
- **Roku Player / Roku Player Selector / Roku IP** (behavior modeled on the stock
  Roku driver's properties, own code):
  - SSDP M-SEARCH for `roku:ecp` on 239.255.255.250:1900 (UDP binding 6100) at
    startup, every 5 minutes, and whenever a command fails with a network error.
  - The chosen Roku is remembered by **serial number** (`PersistData.selectedSerial`),
    so the driver follows it when its IP changes (USB Ethernet adapter ↔ Wi-Fi).
  - If nothing is selected and exactly one Roku with "Streambar" in its model name
    answers, it is selected automatically.
  - **Roku IP** is an optional static override; it replaces the old `IP Address`
    property.
  - New action **Rescan for Rokus**.
- **Polling Time** (3–30 s, default 15): refreshes Current App.
- **On Power On / On Power Off** (Do Nothing | Home, default Home): Home 2 s after a
  successful PowerOn; Home, then PowerOff 500 ms later, on room off.
- **PVR / STAR / POUND Button** mappings (defaults Back / Do Nothing / Do Nothing).
- **Passthrough Mode** (default Off): with Off, after an app mini-driver launches its
  app, rooms that have that mini-driver selected are switched to the Roku media
  player (`SELECT_VIDEO_DEVICE`); room sources are tracked via room variable 1000.
- Verified on the controller: SSDP found the Streambar plus two Roku Ultras
  (`X02800XWL799`, `X0100006SX8C`) and auto-selected the Streambar.

## v0.2.2 [22] — held arrows back to keydown/keyup
- v0.2.1's timer-based arrow repeat was based on a wrong reading of a log that only
  contained taps. The SR-150 *does* send `START_<dir>`/`STOP_<dir>` when an arrow is
  held, and the Streambar *does* honor `keydown`/`keyup` for navigation, so the
  native Roku repeat is used again (as in v0.2.0).
- Kept from v0.2.1: PowerOn debounce, quiet no-ops, Home label.

## v0.2.1 [21] — (superseded by v0.2.2)
- Timer-based arrow repeat (removed in v0.2.2).
- PowerOn debounce: the room sends `ON` once per path (video and audio) and again on
  WATCH_BUTTON, producing up to 4 PowerOn posts; repeats within 3 s are skipped.
- `SELECT_SOURCE`, `WATCH_BUTTON`, `LISTEN_BUTTON` and all `END_*` handled silently.
- Current App shows **Home** for the Roku home screen (app id 562859,
  "Roku Dynamic Menu").

## v0.2.0 [20] — combined driver
- One driver with three proxies: `receiver` (Streambar), `media_player` (Roku UI),
  `avswitch` (hidden app switcher with App 1–25 `RF_MINI_APP` inputs for universal
  app mini-drivers). Internal routing via hidden auto-bound connections.
- Navigation/transport keys, configurable MENU/GUIDE/INFO/CANCEL/RECALL buttons,
  app launch through mini-drivers (`UM_ROKU` / `APP_ID` device variables),
  pass-through of keys from mini-drivers, **Current App** property,
  **Print Installed Apps** and **Send Home** actions.
- `tools/gen_xml.py` generates `driver.xml`; `tools/mock_test.py` runs the Lua
  against a mocked Control4 API.
- Packaged as `roku_streambar_combined.c4z` (a different file name from v0.1.x, so
  Composer does not treat it as an update of the receiver-only driver — see
  docs/INSTALL.md).

## v0.1.8 [9] — receiver-only driver, final
Last version of the single-proxy receiver driver that ran alongside the stock Roku
driver. Recoverable from git (`git checkout v0.1.8`).

## v0.1.7 [8]
- Connection Status shows *"Refused (HTTP 401/403) – on the Roku set Control by
  mobile apps = Enabled"* when the Roku rejects a keypress; status recovers on the
  next successful command.
- Tried reading `supports-tv-power-control` / `supports-audio-volume-control` — the
  Streambar does not report them (removed in v0.1.8).

## v0.1.6 [7]
- No extra volume step at ramp start: the room sends `PULSE_VOL_*` before
  `START_VOL_*`, so the ramp begins on the first timer tick.
- Silent no-ops for `END_VOL_*`, `CONNECT_OUTPUT`, `DISCONNECT_OUTPUT`, `GET_IS_MUTED`.

## v0.1.5 [6]
- **Removed `<combo>true</combo>`.** With combo set, `C4:GetProxyDevices()` returned
  the driver's own device id, no receiver proxy was created, and Composer showed no
  AV connections. This was the root cause of the missing connections.

## v0.1.4 [5]
- `proxybindingid="5001"` on the input and room connections; single room end-point
  with both `AUDIO_SELECTION` and `AUDIO_VOLUME` (per the DriverWorks XML guide).

## v0.1.3 [4]
- Receiver capability counts (`audio_consumer_count`, `audio_provider_count`, …),
  `primary="True"` on the proxy.

## v0.1.2 [3]
- Internal Roku input accepts STEREO / DIGITAL_COAX / DIGITAL_OPTICAL so the stock
  Roku driver's audio outputs could bind to it.

## v0.1.1 [2]
- Fixed device-info parsing: `-` is a Lua pattern quantifier, so `<model-name>`
  never matched; tag names are now escaped.

## v0.1.0 [1]
- Receiver proxy driver: volume up/down/mute via `keypress`, hold-to-ramp by
  repeating `keypress/VolumeUp|Down` (the Streambar ignores `keydown` for volume),
  PowerOn/PowerOff (TV follows via HDMI-CEC), IP as a property.
