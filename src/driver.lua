--[[
  Roku Streambar - combined Control4 driver over Roku ECP
  Final Touch AV

  One driver, three proxies:
    5001 receiver      "Roku Streambar"   power, volume, mute; room audio end-point;
                                           HDMI out to the TV
    5002 media_player  "Roku"             the Roku UI as a source; navigation/transport keys
    5003 avswitch      "Roku App Switcher" hidden; RF_MINI_APP inputs for universal
                                           app mini-drivers (Netflix, Hulu, ...)

  Internally the Roku and the app switcher feed the receiver through hidden,
  auto-bound connections, so the room sees: source -> Streambar -> TV.

  ECP: HTTP on port 8060, no auth. POST keypress/keydown/keyup/launch, GET query/*.
  The Streambar ignores keydown/keyup for volume, so hold-to-ramp is a timer that
  repeats keypress/VolumeUp|VolumeDown.
]]

DRIVER_VERSION = "0.2.1"

local RX = 5001  -- receiver proxy
local MP = 5002  -- media_player proxy
local SW = 5003  -- avswitch proxy (app mini-drivers)

local MINI_FIRST, MINI_LAST = 3101, 3125
local MINI_APP_VAR = "UM_ROKU"   -- variable name universal mini-drivers publish for Roku

local gDebug = false
local gRampTimer = nil
local gRampKey = nil
local gInFlight = false
local gLastPostFailed = false
local gAppTimer = nil
local gHoldTimer = nil      -- detects a held arrow key (no END_* within HOLD_DETECT_MS)
local gLastPowerOn = nil    -- tick of the last successful PowerOn
local HOLD_DETECT_MS = 500
local HOME_APP_ID = "562859" -- "Roku Dynamic Menu" = the Roku home screen
local refreshDeviceInfo -- forward declaration

---------------------------------------------------------------------------
-- Logging / helpers
---------------------------------------------------------------------------
local function dbg(msg)
  if gDebug then print("[Streambar] " .. tostring(msg)) end
end

local function setStatus(s)
  C4:UpdateProperty("Connection Status", s)
end

local function xmlTag(body, tag)
  local t = tag:gsub("%p", "%%%0")
  return body and body:match("<" .. t .. ">([^<]*)</" .. t .. ">")
end

local function xmlUnescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

---------------------------------------------------------------------------
-- ECP transport
---------------------------------------------------------------------------
local function baseUrl()
  local ip = Properties["IP Address"]
  if ip == nil or ip == "" then return nil end
  return "http://" .. ip .. ":8060"
end

-- POST an ECP path (e.g. "keypress/VolumeUp"); cb(ok, code) optional
local function ecpPost(path, cb)
  local base = baseUrl()
  if not base then
    setStatus("Not configured (set IP Address)")
    if cb then cb(false, 0) end
    return
  end
  local url = base .. "/" .. path
  dbg("POST " .. url)
  C4:url()
    :SetOptions({ timeout = 3, connect_timeout = 2, fail_on_error = false })
    :OnDone(function(transfer, responses, errCode, errMsg)
      local code = 0
      if responses and #responses > 0 then code = responses[#responses].code or 0 end
      local ok = (errCode == 0) and code == 200
      if ok then
        dbg("OK " .. path)
        if gLastPostFailed then
          gLastPostFailed = false
          refreshDeviceInfo()
        end
      else
        gLastPostFailed = true
        dbg("FAIL " .. path .. " code=" .. tostring(code) .. " err=" .. tostring(errCode) .. " " .. tostring(errMsg))
        if code == 401 or code == 403 then
          -- Roku OS 14.1+: keypress needs Settings > System > Advanced system settings >
          -- Control by mobile apps = Enabled
          setStatus("Refused (HTTP " .. code .. ") - on the Roku set Control by mobile apps = Enabled")
        elseif errCode ~= 0 then
          setStatus("Offline (" .. tostring(errMsg) .. ")")
        else
          setStatus("Error: HTTP " .. code)
        end
      end
      if cb then cb(ok, code) end
    end)
    :Post(url, "", {})
end

local function ecpGet(path, cb)
  local base = baseUrl()
  if not base then
    setStatus("Not configured (set IP Address)")
    if cb then cb(false, nil) end
    return
  end
  local url = base .. "/" .. path
  dbg("GET " .. url)
  C4:url()
    :SetOptions({ timeout = 3, connect_timeout = 2, fail_on_error = false })
    :OnDone(function(transfer, responses, errCode, errMsg)
      local r = responses and responses[#responses]
      if errCode == 0 and r and r.code == 200 then
        cb(true, r.body)
      else
        dbg("GET failed: " .. tostring(errMsg or (r and r.code)))
        cb(false, nil, errMsg)
      end
    end)
    :Get(url, {})
end

local function sendKey(key)
  gInFlight = true
  ecpPost("keypress/" .. key, function() gInFlight = false end)
end

---------------------------------------------------------------------------
-- Device info / current app
---------------------------------------------------------------------------
refreshDeviceInfo = function()
  ecpGet("query/device-info", function(ok, body, err)
    if not ok then
      setStatus("Offline (" .. tostring(err or "no response") .. ")")
      return
    end
    local model = xmlTag(body, "model-name") or "?"
    local name  = xmlTag(body, "friendly-device-name") or xmlTag(body, "user-device-name") or ""
    local sw    = xmlTag(body, "software-version") or "?"
    local power = xmlTag(body, "power-mode") or "?"
    local label = (name ~= "" and name ~= model) and (name .. " " .. model) or model
    C4:UpdateProperty("Device", string.format("%s (OS %s)", label, sw))
    setStatus("Online - power-mode " .. power)
  end)
end

local function refreshCurrentApp()
  ecpGet("query/active-app", function(ok, body)
    if not ok or not body then return end
    local id, name = body:match('<app id="([^"]*)"[^>]*>([^<]*)</app>')
    local label
    if not id or id == HOME_APP_ID then
      label = "Home"
    else
      label = xmlUnescape(name or "?") .. " (" .. id .. ")"
    end
    C4:UpdateProperty("Current App", label)
  end)
end

local function printApps()
  ecpGet("query/apps", function(ok, body)
    if not ok or not body then print("[Streambar] could not read query/apps") return end
    print("[Streambar] Installed apps (id  name):")
    for id, name in body:gmatch('<app id="([^"]*)"[^>]*>([^<]*)</app>') do
      print(string.format("  %-8s %s", id, xmlUnescape(name)))
    end
  end)
end

---------------------------------------------------------------------------
-- Volume ramp (receiver)
---------------------------------------------------------------------------
local function stopRamp(reason)
  if gRampTimer then
    gRampTimer:Cancel()
    gRampTimer = nil
    dbg("ramp stopped (" .. tostring(reason) .. ")")
  end
  gRampKey = nil
end

-- Repeat keypress/<key> until stopRamp(). No immediate keypress: the room has
-- already sent the first step (PULSE_VOL_* / the arrow press itself).
local function startRamp(key, intervalProp)
  stopRamp("restart")
  gRampKey = key
  local interval = tonumber(Properties[intervalProp or "Ramp Interval (ms)"]) or 150
  local maxMs = (tonumber(Properties["Max Ramp Time (s)"]) or 10) * 1000
  local elapsed = 0

  gRampTimer = C4:SetTimer(interval, function(timer)
    elapsed = elapsed + interval
    if elapsed >= maxMs then
      stopRamp("max ramp time - STOP never arrived?")
      return
    end
    -- Don't queue requests: skip the tick while the last keypress is unanswered,
    -- so the volume doesn't keep climbing after the button is released.
    if gInFlight then
      dbg("tick skipped (in flight)")
      return
    end
    if gRampKey then sendKey(gRampKey) end
  end, true)
  dbg("ramp started " .. key .. " @" .. interval .. "ms")
end

local RX_CMDS = {
  -- The room powers on the video and the audio path separately, so ON arrives
  -- several times per source selection; one PowerOn within 3 s is enough.
  ON  = function()
    local now = C4:GetTickCount()
    if gLastPowerOn and (now - gLastPowerOn) < 3000 then dbg("PowerOn skipped (sent <3 s ago)") return end
    gLastPowerOn = now
    ecpPost("keypress/PowerOn", function(ok) if not ok then gLastPowerOn = nil end end)
  end,
  OFF = function()
    stopRamp("power off")
    gLastPowerOn = nil
    ecpPost("keypress/PowerOff")
  end,

  PULSE_VOL_UP   = function() sendKey("VolumeUp") end,
  PULSE_VOL_DOWN = function() sendKey("VolumeDown") end,
  START_VOL_UP   = function() startRamp("VolumeUp") end,
  START_VOL_DOWN = function() startRamp("VolumeDown") end,
  STOP_VOL_UP    = function() stopRamp("STOP_VOL_UP") end,
  STOP_VOL_DOWN  = function() stopRamp("STOP_VOL_DOWN") end,

  -- ECP only has a mute toggle; discrete mute is mapped onto it.
  MUTE_TOGGLE = function() sendKey("VolumeMute") end,
  MUTE_ON     = function() dbg("MUTE_ON -> toggle"); sendKey("VolumeMute") end,
  MUTE_OFF    = function() dbg("MUTE_OFF -> toggle"); sendKey("VolumeMute") end,

  -- Input changes happen inside the Streambar on their own; nothing to send.
  SET_INPUT = function(p) dbg("SET_INPUT " .. tostring(p and p.INPUT) .. " (no-op)") end,

  END_VOL_UP        = function() end,
  END_VOL_DOWN      = function() end,
  CONNECT_OUTPUT    = function() end,
  DISCONNECT_OUTPUT = function() end,
  GET_IS_MUTED      = function() end, -- ECP can't report mute state
}

---------------------------------------------------------------------------
-- Navigation / transport (media player, and pass-through from app mini-drivers)
---------------------------------------------------------------------------
-- Roku keys for the buttons whose function is set by a property
local function buttonKey(prop)
  local v = Properties[prop]
  if v == nil or v == "Do Nothing" then return nil end
  return v
end

-- command -> ECP path (fixed keys)
local NAV = {
  UP = "keypress/Up", DOWN = "keypress/Down", LEFT = "keypress/Left", RIGHT = "keypress/Right",
  ENTER = "keypress/Select",

  PLAY = "keypress/Play", PAUSE = "keypress/Play", PLAYPAUSE = "keypress/Play", STOP = "keypress/Play",
  SCAN_FWD = "keypress/Fwd", SCAN_REV = "keypress/Rev",
  SKIP_FWD = "keypress/Fwd", SKIP_REV = "keypress/Rev",
  START_SCAN_FWD = "keydown/Fwd", START_SCAN_REV = "keydown/Rev",
  STOP_SCAN_FWD = "keyup/Fwd", STOP_SCAN_REV = "keyup/Rev",

  HOME = "keypress/Home", BACK = "keypress/Back",
  REPLAY = "keypress/InstantReplay", OPTIONS = "keypress/Info",
}
for i = 0, 9 do NAV["NUMBER_" .. i] = "keypress/Lit_" .. i end

-- buttons whose Roku key is chosen in Composer
local NAV_PROP = {
  MENU = "MENU Button", GUIDE = "GUIDE Button", INFO = "INFO Button",
  CANCEL = "CANCEL Button", RECALL = "RECALL Button",
}

-- arrow keys: pressed -> one keypress; still held after HOLD_DETECT_MS -> repeat
local ARROWS = { UP = "Up", DOWN = "Down", LEFT = "Left", RIGHT = "Right" }

-- commands the room sends that need no action (END_* handled generically below)
local NAV_IGNORE = {
  ON = true, OFF = true, -- power is handled by the receiver proxy
  CONNECT_OUTPUT = true, DISCONNECT_OUTPUT = true,
  SELECT_SOURCE = true, WATCH_BUTTON = true, LISTEN_BUTTON = true,
}

local function cancelHold()
  if gHoldTimer then gHoldTimer:Cancel(); gHoldTimer = nil end
end

local function handleArrow(cmd)
  local key = ARROWS[cmd]
  if key then
    cancelHold()
    stopRamp("new arrow")
    sendKey(key)
    gHoldTimer = C4:SetTimer(HOLD_DETECT_MS, function()
      gHoldTimer = nil
      startRamp(key, "Nav Repeat Interval (ms)")
    end)
    return true
  end
  local startKey = cmd:match("^START_(%u+)$")
  if startKey and ARROWS[startKey] then
    cancelHold()
    startRamp(ARROWS[startKey], "Nav Repeat Interval (ms)")
    return true
  end
  local endKey = cmd:match("^END_(%u+)$") or cmd:match("^STOP_(%u+)$")
  if endKey and ARROWS[endKey] then
    cancelHold()
    stopRamp(cmd)
    return true
  end
  return false
end

local function handleNav(cmd)
  if NAV_IGNORE[cmd] then return true end
  if handleArrow(cmd) then return true end
  if cmd:match("^END_") then return true end -- release of a non-arrow button
  local path = NAV[cmd]
  if not path and NAV_PROP[cmd] then
    local key = buttonKey(NAV_PROP[cmd])
    if not key then dbg(cmd .. " set to Do Nothing") return true end
    path = "keypress/" .. key
  end
  if not path then return false end
  ecpPost(path)
  if cmd == "HOME" or cmd == "BACK" then
    if gAppTimer then gAppTimer:Cancel() end
    gAppTimer = C4:SetTimer(2000, function() refreshCurrentApp() end)
  end
  return true
end

---------------------------------------------------------------------------
-- App mini-drivers (universal mini-drivers bound to the app switcher)
---------------------------------------------------------------------------
-- Look up the app ID that the mini-driver on switcher input `input` publishes.
local function miniDriverAppId(input)
  local switchProxyId = next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), SW) or {})
  if not switchProxyId then dbg("app switcher proxy not found") return nil end
  local miniProxyId = C4:GetBoundProviderDevice(switchProxyId, input)
  if not miniProxyId or miniProxyId == 0 then dbg("nothing bound to App input " .. input) return nil end
  local miniDeviceId = C4:GetBoundProviderDevice(miniProxyId, 5001)
  if not miniDeviceId or miniDeviceId == 0 then return nil end

  local vars = C4:GetDeviceVariables(miniDeviceId) or {}
  local fallback, name
  for _, v in pairs(vars) do
    if v.name == MINI_APP_VAR then return v.value, name end
    if v.name == "APP_ID" then fallback = v.value end
    if v.name == "APP_NAME" then name = v.value end
  end
  return fallback, name
end

local function launchApp(appId, label)
  if not appId or appId == "" then return end
  dbg("launch " .. tostring(label or "") .. " id=" .. appId)
  ecpPost("launch/" .. appId, function(ok)
    if ok then
      if gAppTimer then gAppTimer:Cancel() end
      gAppTimer = C4:SetTimer(3000, function() refreshCurrentApp() end)
    end
  end)
end

local function handleSwitch(cmd, p)
  if cmd == "SET_INPUT" then
    local input = tonumber(p and p.INPUT)
    if input and input >= MINI_FIRST and input <= MINI_LAST then
      local appId, name = miniDriverAppId(input)
      if appId then
        launchApp(appId, name)
      else
        dbg("no Roku app ID on the mini-driver at input " .. input)
      end
    end
    return
  end
  if cmd == "CONNECT_OUTPUT" or cmd == "DISCONNECT_OUTPUT" or cmd == "ON" or cmd == "OFF" then return end
  dbg("unhandled app switcher command " .. tostring(cmd))
end

---------------------------------------------------------------------------
-- Proxy dispatch
---------------------------------------------------------------------------
local function fmt(t)
  local s = ""
  for k, v in pairs(t or {}) do s = s .. k .. "=" .. tostring(v) .. " " end
  return s
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  dbg("RFP " .. tostring(idBinding) .. " " .. tostring(strCommand) .. " " .. fmt(tParams))

  -- Mini-drivers in pass-through mode forward remote keys wrapped in PASSTHROUGH
  if strCommand == "PASSTHROUGH" then
    local inner = tParams.PASSTHROUGH_COMMAND
    if not inner then return end
    -- No hold detection here: a mini-driver may never forward the release.
    if ARROWS[inner] then ecpPost("keypress/" .. ARROWS[inner]) return end
    if not handleNav(inner) and RX_CMDS[inner] then RX_CMDS[inner](tParams) end
    return
  end

  if idBinding == RX then
    local h = RX_CMDS[strCommand]
    if h then h(tParams)
    elseif not handleNav(strCommand) then dbg("unhandled receiver command " .. strCommand) end

  elseif idBinding == MP then
    if not handleNav(strCommand) then
      -- volume can arrive here too if the media player is ever the volume device
      local h = RX_CMDS[strCommand]
      if h and strCommand ~= "ON" and strCommand ~= "OFF" then h(tParams)
      else dbg("unhandled media player command " .. strCommand) end
    end

  elseif idBinding == SW then
    handleSwitch(strCommand, tParams)
  end
end

---------------------------------------------------------------------------
-- Hide the app switcher in all rooms (it is plumbing, not a source)
---------------------------------------------------------------------------
local function hideSwitcher()
  local id, name = next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), SW) or {})
  if not id then return end
  for roomId, _ in pairs(C4:GetDevicesByC4iName("roomdevice.c4i") or {}) do
    C4:SendToDevice(roomId, "SET_DEVICE_HIDDEN_STATE", { PROXY_GROUP = "ALL", DEVICE_ID = id, IS_HIDDEN = true })
  end
  dbg("app switcher hidden: " .. tostring(name))
end

---------------------------------------------------------------------------
-- Actions / properties / lifecycle
---------------------------------------------------------------------------
local ACTIONS = {
  TestConnection = function() refreshDeviceInfo(); refreshCurrentApp() end,
  TestVolUp      = function() sendKey("VolumeUp") end,
  TestVolDown    = function() sendKey("VolumeDown") end,
  TestHome       = function() handleNav("HOME") end,
  PrintApps      = printApps,
}

function ExecuteCommand(strCommand, tParams)
  if strCommand == "LUA_ACTION" and tParams and ACTIONS[tParams.ACTION] then
    ACTIONS[tParams.ACTION]()
  else
    dbg("ExecuteCommand " .. tostring(strCommand))
  end
end

function OnPropertyChanged(strProperty)
  local v = Properties[strProperty]
  if strProperty == "Debug Mode" then
    gDebug = (v == "On")
  elseif strProperty == "IP Address" then
    refreshDeviceInfo()
    refreshCurrentApp()
  end
end

function OnDriverLateInit()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
  gDebug = (Properties["Debug Mode"] == "On")
  hideSwitcher()
  refreshDeviceInfo()
  refreshCurrentApp()
end

function OnDriverDestroyed()
  stopRamp("driver destroyed")
  cancelHold()
  if gAppTimer then gAppTimer:Cancel() end
end
