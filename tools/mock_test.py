import pathlib
import sys
from lupa import LuaRuntime
lua = LuaRuntime()
lua.execute(r'''
posts = {}
Properties = { ["Roku IP"]="", ["Ramp Interval (ms)"]="150", ["Max Ramp Time (s)"]="10",
  ["Debug Mode"]="On", ["MENU Button"]="Home", ["GUIDE Button"]="Do Nothing", ["INFO Button"]="Info",
  ["CANCEL Button"]="Back", ["RECALL Button"]="InstantReplay", ["Polling Time"]="15",
  ["On Power On"]="Home", ["On Power Off"]="Home", ["Passthrough Mode"]="Off", ["PVR Button"]="Back",
  ["STAR Button"]="Do Nothing", ["POUND Button"]="Do Nothing" }
tick_ms = 0
timers = {}
local function mkurl()
  local u = {}
  function u:SetOptions() return self end
  function u:OnDone(f) self.f = f return self end
  function u:Post(url) table.insert(posts, "POST "..url); self.f(self, {{code=200, body=""}}, 0, nil) return self end
  function u:Get(url)
    table.insert(posts, "GET "..url)
    local body = ""
    if url:match("192%.168%.15%.50.*device%-info") then body = "<device-info><model-name>Roku Ultra</model-name><user-device-name>Living Room</user-device-name></device-info>"
    elseif url:match("device%-info") then body = "<device-info><model-name>Roku Streambar</model-name><software-version>15.3.4</software-version><power-mode>PowerOn</power-mode></device-info>"
    elseif url:match("active%-app") then body = '<active-app><app id="562859" type="appl" version="1">Roku Dynamic Menu</app></active-app>'
    elseif url:match("query/apps") then body = '<apps><app id="12" type="appl" version="1">Netflix</app><app id="2285">Hulu</app></apps>' end
    self.f(self, {{code=200, body=body}}, 0, nil) return self end
  return u
end
props = {}
lists = {}
net = {}
C4 = {
  url = function() return mkurl() end,
  UpdateProperty = function(_, k, v) props[k] = v end,
  UpdatePropertyList = function(_, k, v) lists[k] = v end,
  CreateNetworkConnection = function(_, b, a) table.insert(net, "create "..b.." "..a) end,
  NetConnect = function(_, b, p, kind) table.insert(net, "connect "..b.." "..p.." "..kind) end,
  NetDisconnect = function() end,
  SendToNetwork = function(_, b, p, d) table.insert(net, "send "..b.." "..p.." "..d:gsub("\r\n", "|")) end,
  SetTimer = function(_, ms, f, rep) local t = {f=f, rep=rep, cancelled=false}; function t:Cancel() self.cancelled=true end; table.insert(timers, t); return t end,
  GetDeviceID = function() return 2761 end,
  GetTickCount = function() return tick_ms end,
  GetDeviceVariable = function(_, dev, v) return "3000" end,   -- room 1204 has the Netflix mini-driver (3000) selected
  RegisterVariableListener = function() end,
  UnregisterVariableListener = function() end,
  GetBoundConsumerDevices = function(_, dev, b) if b == 5003 then return {[2764]="Roku App Switcher"} end if b == 5002 then return {[2763]="Roku"} end return {} end,
  GetBoundProviderDevice = function(_, dev, b) if dev == 2764 and b == 3102 then return 3000 end if dev == 3000 and b == 5001 then return 2999 end return 0 end,
  GetDeviceVariables = function(_, dev) return { {name="APP_NAME", value="Netflix"}, {name="UM_ROKU", value="12"} } end,
  GetDevicesByC4iName = function() return {[1204]="Helmut Bedroom"} end,
  SendToDevice = function(_, id, cmd, p) table.insert(posts, "SEND "..id.." "..cmd) end,
}
''')
lua.execute(open(pathlib.Path(__file__).resolve().parent.parent / 'src' / 'driver.lua').read())
lua.execute(r'''
OnDriverLateInit()
OnConnectionStatusChanged(6100, 1900, "ONLINE")
ReceivedFromNetwork(6100, 1900, "HTTP/1.1 200 OK\r\nCache-Control: max-age=3600\r\nST: roku:ecp\r\nLOCATION: http://192.168.15.26:8060/\r\nUSN: uuid:roku:ecp:YL000J474928\r\n\r\n")
ReceivedFromNetwork(6100, 1900, "HTTP/1.1 200 OK\r\nST: roku:ecp\r\nLocation: http://192.168.15.50:8060/\r\nUSN: uuid:roku:ecp:X00000000001\r\n\r\n")
print("after discovery: Roku Player = " .. tostring(props["Roku Player"]) .. " | list = " .. tostring(lists["Roku Player Selector"]))
-- IP change of the selected Streambar (fell back to Wi-Fi)
ReceivedFromNetwork(6100, 1900, "HTTP/1.1 200 OK\r\nST: roku:ecp\r\nLOCATION: http://192.168.15.27:8060/\r\nUSN: uuid:roku:ecp:YL000J474928\r\n\r\n")
print("after IP change: Roku Player = " .. tostring(props["Roku Player"]))
-- pick the other Roku from the list, then back
Properties["Roku Player Selector"] = "Living Room [X00000000001]"; OnPropertyChanged("Roku Player Selector")
print("picked other: " .. tostring(props["Roku Player"]))
Properties["Roku Player Selector"] = "Roku Streambar [YL000J474928]"; OnPropertyChanged("Roku Player Selector")
print("picked streambar: " .. tostring(props["Roku Player"]))
local function tick(n) for i=1,n do
  local snapshot = {}; for _, t in ipairs(timers) do snapshot[#snapshot+1] = t end
  for _, t in ipairs(snapshot) do if not t.cancelled then if not t.rep then t.cancelled = true end; t.f(t) end end
end end
ReceivedFromProxy(5001, "ON", {})
ReceivedFromProxy(5001, "ON", {})        -- debounced
tick_ms = 5000
ReceivedFromProxy(5002, "SELECT_SOURCE", {}); ReceivedFromProxy(5002, "WATCH_BUTTON", {})
ReceivedFromProxy(5001, "PULSE_VOL_UP", {})
ReceivedFromProxy(5001, "START_VOL_UP", {})
tick(3)
ReceivedFromProxy(5001, "STOP_VOL_UP", {})
tick(2)
ReceivedFromProxy(5001, "MUTE_TOGGLE", {})
-- tap: hold timer cancelled by END_UP
ReceivedFromProxy(5002, "UP", {}); ReceivedFromProxy(5002, "END_UP", {}); tick(2)
-- hold: room sends DOWN, START_DOWN ... STOP_DOWN
ReceivedFromProxy(5002, "DOWN", {}); ReceivedFromProxy(5002, "START_DOWN", {}); ReceivedFromProxy(5002, "STOP_DOWN", {})
ReceivedFromProxy(5002, "END_MENU", {}); ReceivedFromProxy(5002, "END_CANCEL", {})
ReceivedFromProxy(5002, "ENTER", {}); ReceivedFromProxy(5002, "MENU", {}); ReceivedFromProxy(5002, "GUIDE", {})
ReceivedFromProxy(5002, "CANCEL", {}); ReceivedFromProxy(5002, "RECALL", {}); ReceivedFromProxy(5002, "PLAY", {})
ReceivedFromProxy(5003, "SET_INPUT", {INPUT="3102"}); tick(1)
ReceivedFromProxy(5002, "PVR", {})
ReceivedFromProxy(5003, "PASSTHROUGH", {PASSTHROUGH_COMMAND="DOWN"})
ReceivedFromProxy(5003, "PASSTHROUGH", {PASSTHROUGH_COMMAND="PULSE_VOL_DOWN"})
ExecuteCommand("LUA_ACTION", {ACTION="PrintApps"})
tick(1)
ReceivedFromProxy(5001, "OFF", {}); tick(1)
Properties["Roku IP"] = "10.0.0.9"; OnPropertyChanged("Roku IP")
print("static: " .. tostring(props["Roku Player"]))
ReceivedFromProxy(5001, "MUTE_TOGGLE", {})
''')
for p in lua.globals().net.values(): print("NET", p)
for p in lua.globals().posts.values(): print(p)
print(dict(lua.globals().props.items()))
