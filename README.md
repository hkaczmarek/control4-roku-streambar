# control4-roku-streambar

Control4 receiver-proxy driver for the Roku Streambar over Roku ECP (HTTP POST, port 8060).

- Volume up/down/mute as normal room volume
- Hold-to-ramp: repeating `keypress/VolumeUp|Down` (the Streambar ignores keydown/keyup)
- Power on/off → `keypress/PowerOn|PowerOff` (TV follows via HDMI-CEC)
- IP address as a property; "Test Connection" reads `query/device-info`

## Build
    python build.py      # -> build/roku_streambar.c4z, copied to release/ (tracked)

## Properties
| Property | Default | Notes |
|---|---|---|
| IP Address | — | Streambar IP |
| Ramp Interval (ms) | 150 | Time between repeated keypresses while held |
| Max Ramp Time (s) | 10 | Safety stop if a STOP never arrives |
| Debug Mode | Off | Prints to Lua output |

Ticks are skipped while a keypress is still in flight, so volume doesn't keep climbing after release.

## Composer hookup
- Room → Audio End-Point (7000) = Streambar; Streambar is the room volume device
- Roku player audio out → **Internal Roku** input; TV audio out → **HDMI ARC (TV)**

## Notes
- Volume/power keys are documented by Roku for Roku TVs only; the Streambar (9102R, OS 15.3.4) accepts them.
- `keydown`/`keyup` are ignored for volume on the Streambar, hence the timer ramp.
- Roku OS 14.1+: keypress requires Settings > System > Advanced system settings > Control by mobile apps = Enabled. The driver shows a hint on HTTP 401/403.
- Remove any old room programming that posts the same ECP keys (Pulse Volume, Mute toggle, Room Off PowerOff), or presses get sent twice.

## Not yet
- Input switching (SET_INPUT is logged only)
- Discrete mute (mapped to toggle) and volume feedback (ECP doesn't report volume)
