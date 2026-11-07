import sys, pathlib
out = pathlib.Path(sys.argv[1])

def conn(id_, name, typ, consumer, classes, proxy=None, hidden=False, idautobind=None, autobind=False, audiosource=False, videosource=False, linelevel=True):
    attr = f' proxybindingid="{proxy}"' if proxy else ''
    cl = "\n".join(
        f"        <class><classname>{c}</classname>{'<autobind>true</autobind>' if autobind else ''}</class>" for c in classes)
    extra = ""
    if idautobind is not None: extra += f"      <idautobind>{idautobind}</idautobind>\n"
    if hidden: extra += "      <hidden>True</hidden>\n"
    return f"""    <connection{attr}>
      <id>{id_}</id>
      <facing>6</facing>
      <connectionname>{name}</connectionname>
      <type>{typ}</type>
      <consumer>{consumer}</consumer>
      <audiosource>{audiosource}</audiosource>
      <videosource>{videosource}</videosource>
      <linelevel>{linelevel}</linelevel>
{extra}      <classes>
{cl}
      </classes>
    </connection>"""

AUD = ["STEREO", "DIGITAL_COAX", "DIGITAL_OPTICAL"]
VID = ["HDMI"]
RX, MP, SW = 5001, 5002, 5003
c = []
# proxy connections
c.append(conn(RX, "Receiver", 2, False, ["RECEIVER"], linelevel=False))
c.append(conn(MP, "MEDIA_PLAYER", 2, False, ["MEDIA_PLAYER"], linelevel=False))
c.append(conn(SW, "AVSWITCH", 2, False, ["AVSWITCH"], linelevel=False))
# --- media player (Roku UI) -> receiver, internal
c.append(conn(2010, "Roku Video Out", 5, False, VID, proxy=MP, hidden=True, idautobind=1, autobind=True))
c.append(conn(4010, "Roku Audio Out", 6, False, AUD, proxy=MP, hidden=True, idautobind=2, autobind=True))
# --- app switcher -> receiver, internal
c.append(conn(2110, "Roku Apps Video Out", 5, False, VID, proxy=SW, hidden=True, idautobind=10, autobind=True))
c.append(conn(4110, "Roku Apps Audio Out", 6, False, AUD, proxy=SW, hidden=True, idautobind=20, autobind=True))
# --- receiver inputs
c.append(conn(1000, "Roku (video)", 5, True, VID, proxy=RX, hidden=True, idautobind=1, autobind=True))
c.append(conn(1001, "Roku Apps (video)", 5, True, VID, proxy=RX, hidden=True, idautobind=10, autobind=True))
c.append(conn(3000, "Roku (audio)", 6, True, AUD, proxy=RX, hidden=True, idautobind=2, autobind=True))
c.append(conn(3003, "Roku Apps (audio)", 6, True, AUD, proxy=RX, hidden=True, idautobind=20, autobind=True))
c.append(conn(3001, "HDMI ARC (TV)", 6, True, ["HDMI"], proxy=RX))
c.append(conn(3002, "Optical In", 6, True, ["DIGITAL_OPTICAL"], proxy=RX))
# --- receiver outputs
c.append(conn(2000, "HDMI Out", 5, False, VID, proxy=RX, videosource=True))
c.append(conn(7000, "Audio End-Point", 7, False, ["AUDIO_SELECTION", "AUDIO_VOLUME"], proxy=RX, audiosource=True))
# --- app mini-driver inputs on the switcher
for i in range(1, 26):
    c.append(conn(3100 + i, f"App {i}", 5, True, ["RF_MINI_APP"], proxy=SW, linelevel=False))

def prop(name, typ, default="", readonly=False, items=None, mn=None, mx=None):
    s = f"      <property>\n        <name>{name}</name>\n        <type>{typ}</type>\n        <readonly>{'true' if readonly else 'false'}</readonly>\n"
    if items: s += "        <items>\n" + "".join(f"          <item>{i}</item>\n" for i in items) + "        </items>\n"
    if mn is not None: s += f"        <minimum>{mn}</minimum>\n        <maximum>{mx}</maximum>\n"
    s += f"        <default>{default}</default>\n      </property>"
    return s

KEYS = ["Home", "Back", "Info", "InstantReplay", "Do Nothing"]
props = "\n".join([
    prop("Driver Version", "STRING", readonly=True),
    prop("Connection Status", "STRING", "Not configured", readonly=True),
    prop("Device", "STRING", readonly=True),
    prop("Current App", "STRING", readonly=True),
    prop("Roku Player", "STRING", "None selected", readonly=True),
    prop("Roku Player Selector", "DYNAMIC_LIST"),
    prop("Roku IP", "STRING"),
    prop("Polling Time", "RANGED_INTEGER", 15, mn=3, mx=30),
    prop("On Power On", "LIST", "Home", items=["Do Nothing", "Home"]),
    prop("On Power Off", "LIST", "Home", items=["Do Nothing", "Home"]),
    prop("Passthrough Mode", "LIST", "Off", items=["Off", "On"]),
    prop("Ramp Interval (ms)", "RANGED_INTEGER", 150, mn=80, mx=1000),
    prop("Max Ramp Time (s)", "RANGED_INTEGER", 10, mn=2, mx=30),
    prop("MENU Button", "LIST", "Home", items=KEYS),
    prop("GUIDE Button", "LIST", "Home", items=KEYS),
    prop("INFO Button", "LIST", "Info", items=KEYS),
    prop("CANCEL Button", "LIST", "Back", items=KEYS),
    prop("RECALL Button", "LIST", "InstantReplay", items=KEYS),
    prop("PVR Button", "LIST", "Back", items=KEYS),
    prop("STAR Button", "LIST", "Do Nothing", items=KEYS),
    prop("POUND Button", "LIST", "Do Nothing", items=KEYS),
    prop("Debug Mode", "LIST", "Off", items=["Off", "On"]),
])

xml = f"""<devicedata>
  <copyright>Copyright 2026 Final Touch AV. All rights reserved.</copyright>
  <creator>Final Touch AV</creator>
  <manufacturer>Roku</manufacturer>
  <name>Roku Streambar</name>
  <model>Streambar (ECP)</model>
  <created>11/07/2026 12:00 PM</created>
  <modified>11/07/2026 12:00 PM</modified>
  <version>30</version>
  <control>lua_gen</control>
  <controlmethod>ip</controlmethod>
  <driver>DriverWorks</driver>
  <proxies qty="3">
    <proxy proxybindingid="{RX}" name="Roku Streambar" primary="True">receiver</proxy>
    <proxy proxybindingid="{MP}" name="Roku">media_player</proxy>
    <proxy proxybindingid="{SW}" name="Roku App Switcher">avswitch</proxy>
  </proxies>
  <capabilities>
    <audio_consumer_count>4</audio_consumer_count>
    <audio_provider_count>1</audio_provider_count>
    <video_consumer_count>2</video_consumer_count>
    <video_provider_count>1</video_provider_count>
    <can_switch>True</can_switch>
    <can_switch_separately>False</can_switch_separately>
    <can_upclass>False</can_upclass>
    <can_downclass>False</can_downclass>
    <has_discrete_volume_control>False</has_discrete_volume_control>
    <has_up_down_volume_control>True</has_up_down_volume_control>
    <has_discrete_mute_control>False</has_discrete_mute_control>
    <has_toggle_mute_control>True</has_toggle_mute_control>
    <has_discrete_input_select>False</has_discrete_input_select>
    <has_discrete_surround_mode_select>False</has_discrete_surround_mode_select>
    <transports>
      <supported>PLAY, PAUSE, SCAN_FWD, SCAN_REV, DPAD, PRG_BTNS</supported>
      <button_bar>
        <buttons>
          <button><id>HOME</id><name>Home</name><command>HOME</command><type>ROOM</type></button>
          <button><id>BACK</id><name>Back</name><command>BACK</command><type>ROOM</type></button>
          <button><id>INFO</id><name>Options</name><command>INFO</command><type>ROOM</type></button>
          <button><id>REPLAY</id><name>Instant Replay</name><command>REPLAY</command><type>ROOM</type></button>
        </buttons>
        <default_buttons>HOME, BACK, INFO, REPLAY</default_buttons>
      </button_bar>
    </transports>
  </capabilities>
  <connections>
{chr(10).join(c)}
  </connections>
  <config>
    <script file="driver.lua" jit="1"></script>
    <properties>
{props}
    </properties>
    <actions>
      <action><name>Test Connection</name><command>TestConnection</command></action>
      <action><name>Send Volume Up</name><command>TestVolUp</command></action>
      <action><name>Send Volume Down</name><command>TestVolDown</command></action>
      <action><name>Send Home</name><command>TestHome</command></action>
      <action><name>Print Installed Apps</name><command>PrintApps</command></action>
      <action><name>Rescan for Rokus</name><command>Rescan</command></action>
    </actions>
  </config>
</devicedata>
"""
out.write_text(xml)
print("ok", len(c), "connections")
