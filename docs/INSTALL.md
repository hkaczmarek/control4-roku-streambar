# Installing the Roku Streambar driver (Composer Pro)

Tested with Composer Pro 2026.10.14 / OS Management Package 4.0.0.

## Prerequisites on the Roku
- **Settings > System > Advanced system settings > Control by mobile apps = Enabled.**
  Required since Roku OS 14.1 for `keypress`/`keydown`/`keyup`. Without it,
  `query/device-info` still answers but every command is refused; the driver shows
  *Refused (HTTP 401/403)* in Connection Status.
- HDMI-CEC enabled on the TV, so PowerOn/PowerOff on the Streambar switch the TV.
- A DHCP reservation is optional: the driver finds the Streambar by serial number
  via SSDP and follows IP changes. Note that the Streambar has two MACs; on the
  bench unit the USB Ethernet adapter is `8c:ae:4c:db:79:b8` and Wi-Fi is
  `84:ea:ed:7a:84:6c`, and the IP follows whichever interface is active.

## Fresh install
1. In System Design, select the room and **add** `release/roku_streambar_combined.c4z`
   as a new driver. Three devices appear: **Roku Streambar** (receiver), **Roku**
   (media player, the source), **Roku App Switcher** (hidden in rooms). Composer
   numbers them ("Roku 2", "Roku App Switcher 3") if those names already exist in
   the project; rename as you like.
2. Properties: leave **Roku IP** empty. Within a few seconds **Roku Player** shows
   `Roku Streambar [<serial>] at <ip>`. If several Streambars exist, pick one in
   **Roku Player Selector**. To use a fixed address instead, enter it in Roku IP.
3. Connections → Control/AV: **Roku Streambar → HDMI Out** to the TV's HDMI input.
4. Connections → Rooms: the room's **Audio End-Point**, **Video's Audio End-Point**,
   **Audio Volume** and **Video Volume** to **Roku Streambar → Audio End-Point**
   (Composer may do this automatically).
5. App mini-drivers (Netflix, Hulu, …): bind them to the **Roku App Switcher**'s
   App 1–25 inputs. Only apps installed on the Streambar can launch; use the
   **Print Installed Apps** action to see the Roku app IDs.
6. Programming: the source to select for "Watch" is the **Roku** media player
   proxy (not "Roku Streambar", not "Roku App Switcher").
7. Refresh Navigators.

## Migrating from the stock Roku driver + programming (what was done in Helmut Bedroom)
Do it one step at a time and keep the old drivers until the new one is proven.
1. **Remove programming that sends the same ECP commands**, or every press is sent
   twice (mute toggles twice and appears to do nothing):
   - room commands *Pulse Volume up / Pulse Volume down / Mute toggle* that post
     `/keypress/Volume…`
   - the *Send HTTP post …/keypress/PowerOff* line in *Room turned off*
     (keep the off-timer lines).
2. Rename the old devices (e.g. "Roku Streambar Old") so they can't be confused.
3. Add the combined driver as a **new** driver (see the warning below).
4. Move the TV's HDMI input from the old Roku driver to **Roku Streambar → HDMI Out**.
5. Move the four room end-points to the new Roku Streambar.
6. Re-point the *Watch Button* script: *Select the <new Roku> as the video source*.
7. Test Watch, navigation (tap and hold), volume (tap and hold), mute, room off.
8. Remove the old drivers from that room only (other rooms' Roku drivers stay).

## Warnings learned the hard way
- **Add, don't update, when the driver structure changes.** Composer creates a
  driver's proxies only when the driver is *added*. Updating a receiver-only
  instance with the combined driver leaves a broken hybrid. Recovery: update back
  to the previous version (`git checkout 3268f78 && python build.py` for v0.1.8), then add the
  combined driver fresh.
- **File names matter.** When a `.c4z` with a file name Composer already knows is
  loaded, Composer can apply it as an update to every instance of that driver. The
  combined driver therefore ships as `roku_streambar_combined.c4z`, not
  `roku_streambar.c4z`.
- **Never add `<combo>true</combo>` to driver.xml** — it suppresses the real proxies
  (no AV connections in Composer, proxy id == device id).
- Composer's local driver library is `Documents\Control4\Drivers` (here under
  OneDrive). Deleting files there does not affect drivers installed in a project.

## Debugging
- Set **Debug Mode = On**; the Lua tab shows `RFP <binding> <command> <params>`
  for every proxy command and `POST`/`GET` lines with `OK`/`FAIL`.
- `SSDP:` lines show discovery searches and which Rokus answered.
- Useful actions: **Test Connection**, **Send Volume Up/Down**, **Send Home**,
  **Print Installed Apps**, **Rescan for Rokus**.
