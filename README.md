# control4-roku-streambar

One Control4 driver for the Roku Streambar (soundbar + Roku player) over Roku ECP (HTTP, port 8060).
Replaces the stock Roku driver plus a separate volume driver. Own code; no Snap One code.

## Proxies
| Binding | Proxy | Role |
|---|---|---|
| 5001 | receiver "Roku Streambar" | Power (TV follows via HDMI-CEC), volume with hold-to-ramp, mute; room audio end-point; HDMI Out to the TV |
| 5002 | media_player "Roku" | The Roku UI as a source; navigation and transport keys |
| 5003 | avswitch "Roku App Switcher" | Hidden; App 1-25 inputs (RF_MINI_APP) for universal app mini-drivers |

Internally the Roku and the app switcher feed the receiver through hidden auto-bound connections.

## Composer hookup
- Streambar **HDMI Out** -> TV HDMI input
- Room Audio End-Point / Audio Volume (and video's audio/volume) -> Streambar
- App mini-drivers (Netflix, Hulu, ...) bind to the App Switcher's App 1-25 inputs
- Room source for "Watch": the **Roku** media player proxy

## Properties
| Property | Default | Notes |
|---|---|---|
| IP Address | — | Streambar IP (DHCP reservation on the active MAC) |
| Ramp Interval (ms) | 150 | Time between repeated volume keypresses while held |
| Max Ramp Time (s) | 10 | Safety stop if a STOP never arrives |
| Nav Repeat Interval (ms) | 200 | Arrow repeat rate when an arrow is held (repeat starts after 500 ms without release) |
| MENU / GUIDE / INFO / CANCEL / RECALL Button | Home / Home / Info / Back / InstantReplay | Roku key each Control4 button sends |
| Debug Mode | Off | Prints to Lua output |

Actions: Test Connection, Send Volume Up/Down, Send Home, Print Installed Apps (Roku app IDs).

## Build / test
    python build.py                          # -> build/roku_streambar_combined.c4z, copied to release/ (tracked)
    python tools/gen_xml.py src/driver.xml   # regenerate driver.xml (connections/properties)
    python tools/mock_test.py                # runs driver.lua against a mocked C4 API (pip install lupa)

## Notes
- Volume/power keys are documented by Roku for Roku TVs only; the Streambar (9102R, OS 15.3.4) accepts them.
- `keydown`/`keyup` are ignored for volume on the Streambar, hence the timer ramp.
- Roku OS 14.1+: keypress requires Settings > System > Advanced system settings > Control by mobile apps = Enabled. The driver shows a hint on HTTP 401/403.
- Remove any old room programming that posts the same ECP keys (Pulse Volume, Mute toggle, Room Off PowerOff), or presses get sent twice.
- Do not set `<combo>` in driver.xml: it stops Composer from creating the real proxies.

## Not yet
- Navigator app browsing (media_service), now-playing metadata
- Discrete mute and volume feedback (ECP has no volume/mute state)
- SSDP discovery by serial number
