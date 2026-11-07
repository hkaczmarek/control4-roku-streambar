import pathlib
import sys
from lupa import LuaRuntime
lua = LuaRuntime()
lua.execute(r'''
posts = {}
Properties = { ["IP Address"]="192.168.15.26", ["Ramp Interval (ms)"]="150", ["Max Ramp Time (s)"]="10",
  ["Debug Mode"]="On", ["MENU Button"]="Home", ["GUIDE Button"]="Do Nothing", ["INFO Button"]="Info",
  ["CANCEL Button"]="Back", ["RECALL Button"]="InstantReplay", ["Nav Repeat Interval (ms)"]="200" }
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
    if url:match("device%-info") then body = "<device-info><model-name>Roku Streambar</model-name><software-version>15.3.4</software-version><power-mode>PowerOn</power-mode></device-info>"
    elseif url:match("active%-app") then body = '<active-app><app id="562859" type="appl" version="1">Roku Dynamic Menu</app></active-app>'
    elseif url:match("query/apps") then body = '<apps><app id="12" type="appl" version="1">Netflix</app><app id="2285">Hulu</app></apps>' end
    self.f(self, {{code=200, body=body}}, 0, nil) return self end
  return u
end
props = {}
C4 = {
  url = function() return mkurl() end,
  UpdateProperty = function(_, k, v) props[k] = v end,
  SetTimer = function(_, ms, f, rep) local t = {f=f, rep=rep, cancelled=false}; function t:Cancel() self.cancelled=true end; table.insert(timers, t); return t end,
  GetDeviceID = function() return 2761 end,
  GetTickCount = function() return tick_ms end,
  GetBoundConsumerDevices = function(_, dev, b) if b == 5003 then return {[2764]="Roku App Switcher"} end return {} end,
  GetBoundProviderDevice = function(_, dev, b) if dev == 2764 and b == 3102 then return 3000 end if dev == 3000 and b == 5001 then return 2999 end return 0 end,
  GetDeviceVariables = function(_, dev) return { {name="APP_NAME", value="Netflix"}, {name="UM_ROKU", value="12"} } end,
  GetDevicesByC4iName = function() return {[1204]="Helmut Bedroom"} end,
  SendToDevice = function(_, id, cmd, p) table.insert(posts, "SEND "..id.." "..cmd) end,
}
''')
lua.execute(open(pathlib.Path(__file__).resolve().parent.parent / 'src' / 'driver.lua').read())
lua.execute(r'''
OnDriverLateInit()
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
ReceivedFromProxy(5003, "SET_INPUT", {INPUT="3102"})
ReceivedFromProxy(5003, "PASSTHROUGH", {PASSTHROUGH_COMMAND="DOWN"})
ReceivedFromProxy(5003, "PASSTHROUGH", {PASSTHROUGH_COMMAND="PULSE_VOL_DOWN"})
ExecuteCommand("LUA_ACTION", {ACTION="PrintApps"})
tick(1)
ReceivedFromProxy(5001, "OFF", {})
''')
for p in lua.globals().posts.values(): print(p)
print(dict(lua.globals().props.items()))
