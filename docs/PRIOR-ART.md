# Existing drivers (searched 2026-11-07)

Question: did Control4 / Snap One ever ship a Streambar-specific driver?

**Nothing found.** What exists:

- **Snap One "Roku Player" driver (v151)** — `media_service` + `media_player` +
  `avswitch` proxies, SSDP discovery, app mini-drivers. It has a Roku TV mode
  (capability `is_rokutv`) with TV inputs and channels. It handles
  `PULSE_VOL_*` and `MUTE_TOGGLE` with `keypress`, so a Streambar can step volume
  through it, but held volume uses `keydown/keyup`, which the Streambar ignores.
  It has no receiver proxy, so it can't be the room's audio/volume end-point the
  way a soundbar should be.
- **Control4 tech support blog** — "Roku Control4 Driver Stops Working After Roku
  Update to OS 14.1": enable *Control by mobile apps*. Applies to all control
  systems.
- **HTI Customs "Roku IP" / "Roku IP Channels"** (third party, ~2016–2017, sold via
  Houselogix/BlackWire) — general Roku players, not Streambar-specific.
- **RTI (not Control4)**: Intrinsic Dev "Roku Pro" lists Roku TV, **Streambar** and
  sticks, with volume, mute and power for Roku TV / Streambar. Custom Control
  Drivers "Roku Universal" ramps held volume with a 150 ms repeat — the same
  approach used here.

## Market note
Roku still sells the hardware: the **Roku Streambar SE (model 9104R)** is listed on
roku.com (https://www.roku.com/products/players/roku-streambar-se) as a 2-in-1
soundbar with built-in Roku 4K HDR streaming, HDMI 2.0a with ARC, one optical
input, and no built-in Ethernet (USB adaptor required). This driver is expected
to work with it but is untested on an SE.

Before selling this driver: Roku's ECP documentation states that ECP commands may
not be sent from third-party platforms (e.g. mobile applications). Control4's own
Roku driver uses ECP regardless; review before charging for the driver.

Not checked: Control4's dealer driver database (requires a dealer login). To be
sure, search Composer's online driver search for "Streambar" and "Roku".
