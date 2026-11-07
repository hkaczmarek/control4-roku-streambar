# Roku ECP on the Streambar — what we found

Device: Roku Streambar, model 9102R, Roku OS 15.3.4, serial YL000J474928,
on a USB Ethernet adapter. Reference: Roku's External Control Protocol docs
(https://developer.roku.com/dev/docs/external-control-api).

Other model: Roku Streambar SE (9104R) — not yet tested. Points to verify on an SE:
`model-name`, `PowerOn`, whether `keydown/Volume*` is also ignored, `keydown`
arrows, `network-type` with the USB Ethernet adaptor.

## Transport
- HTTP on port 8060, no authentication. Commands are `POST` with an empty body;
  queries are `GET`.
- Since Roku OS 14.1, `keypress`, `keydown`, `keyup` (and a few queries) require
  **Settings > System > Advanced system settings > Control by mobile apps =
  Enabled**. Control4's tech support blog documents the same fix for its stock
  driver.
- Roku's docs list no rate limits.

## Commands — what the Streambar does
| ECP | Documented for | Streambar result |
|---|---|---|
| `keypress/PowerOn` | not listed in Roku's docs | wakes the Streambar; TV turns on via CEC |
| `keypress/PowerOff` | Roku TVs | standby; TV turns off via CEC |
| `keypress/VolumeUp/Down/Mute` | Roku TVs ("some Roku devices") | works |
| `keydown/VolumeUp` + `keyup/VolumeUp` | Roku TVs | **ignored** — no ramp. Hence the driver's timer ramp |
| `keydown/<arrow>` + `keyup/<arrow>` | all | **works** — native Roku repeat while held |
| `keypress/Up/Down/Left/Right/Select/Home/Back/Info/InstantReplay/Play/Fwd/Rev` | all | works |
| `launch/<appId>` | all | launches the app |
| `InputHDMI1-4`, `InputAV1`, `InputTuner` | Roku TVs | not applicable — the Streambar can't be switched between its Roku and ARC/optical over ECP |

## Queries
- `query/device-info`: `model-name` = "Roku Streambar", `software-version`,
  `power-mode` (`PowerOn`, `DisplayOff`, `Ready`, …), `network-type` (`ethernet` /
  `wifi`), `ethernet-mac`, `wifi-mac`, `serial-number`, `friendly-device-name` /
  `user-device-name`.
  - `supports-ethernet` is `false` even on Ethernet: it describes the built-in
    port (the Streambar has none), not the active link. Use `network-type`.
  - The Roku OS 15 flags `supports-tv-power-control` and
    `supports-audio-volume-control` are **not** reported by the Streambar.
  - Reported `supports-*`: ethernet=false, becp=false, suspend, find-remote,
    audio-guide, rva, private-listening, audio-settings, ecs-textedit,
    ecs-microphone, wake-on-wlan, airplay, trc = true.
- `query/active-app`: the home screen is app id **562859** "Roku Dynamic Menu".
- `query/apps`: installed apps with ids, e.g. YouTube 837, Prime Video 13,
  The Roku Channel 151908, Roku Media Player 2213, HBO Max 61322,
  Disney Plus 291097, Paramount Plus 31440, Apple TV 551012,
  Plex 13535 (Netflix and Hulu were not installed on the bench unit).
- There is **no** query for volume level or mute state.

## SSDP
- Request: `M-SEARCH * HTTP/1.1`, `HOST: 239.255.255.250:1900`,
  `MAN: "ssdp:discover"`, `MX: 3`, `ST: roku:ecp`.
- Response headers used: `LOCATION: http://<ip>:8060/`,
  `USN: uuid:roku:ecp:<serial>` (header case varies).
- On the bench network: Roku Streambar [YL000J474928], Roku Ultra 2024
  [X02800XWL799], Roku Ultra [X0100006SX8C].

## Control4 room behavior observed (SR-150)
- Volume tap: `PULSE_VOL_*` then `END_VOL_*`. Hold: `PULSE_VOL_*`, `START_VOL_*`,
  … `STOP_VOL_*`.
- Arrow tap: `<DIR>` then `END_<DIR>`. Hold: `<DIR>`, `START_<DIR>`, … `STOP_<DIR>`.
- Selecting the Roku source sends `SELECT_SOURCE` and `ON` to the media player
  and `ON` to the receiver once per path type (video 1, audio 3); pressing Watch
  while on repeats the whole sequence.
- Room off: `DISCONNECT_OUTPUT`, `OFF` to the receiver and to the media player.
