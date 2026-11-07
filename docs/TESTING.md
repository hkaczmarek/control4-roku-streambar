# Testing

## Mock test (no controller needed)
    pip install lupa
    python tools/mock_test.py

Runs `src/driver.lua` inside a real Lua runtime against a mocked `C4` API (URL
transfers, timers, properties, bindings, network) and prints every ECP request.
It covers power + debounce + On Power On/Off, volume pulse/ramp/stop, mute,
arrow tap and hold, configurable buttons, app launch through a mini-driver,
Passthrough Off hand-back, pass-through keys, SSDP discovery, auto-selection,
IP change, manual selection, and the Roku IP override. Note: the mock fires every
live repeating timer on each `tick()`, so the 5-minute SSDP rescan and the poll
appear more often than they would on a controller.

## Bench tests on the controller (2026-11-07, Helmut Bedroom, SR-150)
| Version | Test | Result |
|---|---|---|
| 0.1.0 | Test Connection | Online, but device-info fields showed "?" (pattern bug) |
| 0.1.1 | Test Connection | Roku Streambar, OS 15.3.4, PowerOn |
| 0.1.0–0.1.4 | AV connections in Composer | none shown |
| 0.1.5 | without `<combo>` | receiver icon, inputs and room end-points shown; proxy id ≠ device id |
| 0.1.5 | Watch, volume tap/hold, room off | PowerOn/PowerOff OK; ramp works |
| 0.1.6 | Mute | appeared broken — old *Mute toggle* script also sent VolumeMute; works after removing it |
| 0.1.7 | Roku Capabilities | n/a (Streambar doesn't report the OS 15 flags) |
| 0.2.0 | combined driver added next to the old ones | three proxies created; Current App, Print Installed Apps OK |
| 0.2.0 | Watch → Roku, navigation, volume, mute, room off | all OK; held arrows scroll via keydown/keyup |
| 0.2.2 | Watch | one PowerOn, repeats skipped |
| 0.3.0 | discovery | Streambar auto-selected by serial with Roku IP empty; selector listed 3 Rokus |

## Before releasing a new version
1. `python tools/gen_xml.py src/driver.xml` if properties or connections changed
   (bump `<version>` in `tools/gen_xml.py`).
2. Bump `DRIVER_VERSION` in `src/driver.lua`.
3. `python tools/mock_test.py` — check the POST list.
4. `python build.py` — updates `release/roku_streambar_combined.c4z`.
5. If connections or proxies changed, test by **adding** the driver fresh, not by
   Update Driver.
6. Update CHANGELOG.md, commit, tag `vX.Y.Z`.
