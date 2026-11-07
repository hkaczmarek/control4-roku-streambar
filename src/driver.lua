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

DRIVER_VERSION = "0.3.0"

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
local gLastPowerOn = nil    -- tick of the last successful PowerOn
local HOME_APP_ID = "562859" -- "Roku Dynamic Menu" = the Roku home screen
local refreshDeviceInfo -- forward declarations
local sendSearch

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
---------------------------------------------------------------------------
-- Discovery (SSDP, search target roku:ecp)
--   Rokus answer an M-SEARCH with LOCATION http://<ip>:8060/ and
--   USN uuid:roku:ecp:<serial>. The chosen Roku is remembered by serial, so the
--   driver follows it if its IP changes (e.g. Ethernet adapter <-> Wi-Fi).
---------------------------------------------------------------------------
local SSDP_BINDING = 6100
local SSDP_ADDR = "239.255.255.250"
local SSDP_RESCAN_MS = 5 * 60 * 1000

PersistData = PersistData or {}
local gFound = {}          -- serial -> { ip = , name = , model = }
local gDiscoveredIP = nil  -- current IP of the selected serial
local gScanTimer = nil
local gPollTimer = nil
local gRoomSource = {}     -- roomId -> current source device id (room variable 1000)

local function staticIP()
  local ip = Properties["Roku IP"]
  if ip == nil or ip == "" then return nil end
  return ip
end

local function currentIP()
  return staticIP() or gDiscoveredIP
end

local function baseUrl()
  local ip = currentIP()
  if not ip then return nil end
  return "http://" .. ip .. ":8060"
end

-- POST an ECP path (e.g. "keypress/VolumeUp"); cb(ok, code) optional
local function ecpPost(path, cb)
  local base = baseUrl()
  if not base then
    setStatus("No Roku selected (pick one in Roku Player Selector, or set Roku IP)")
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
          if not staticIP() then sendSearch() end -- maybe the IP changed
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
    setStatus("No Roku selected (pick one in Roku Player Selector, or set Roku IP)")
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
-- Discovery functions
---------------------------------------------------------------------------
local function listLabel(serial, d)
  local name = (d.name and d.name ~= "") and d.name or (d.model or "Roku")
  return (name .. " [" .. serial .. "]"):gsub(",", " ") -- the list is comma-separated
end

local function updateSelectorList()
  local labels = {}
  for serial, d in pairs(gFound) do labels[#labels + 1] = listLabel(serial, d) end
  table.sort(labels)
  C4:UpdatePropertyList("Roku Player Selector", table.concat(labels, ","))
end

local function showSelected()
  if staticIP() then
    C4:UpdateProperty("Roku Player", "Selected by Roku IP (" .. staticIP() .. ")")
    return
  end
  local serial = PersistData.selectedSerial
  if not serial then
    C4:UpdateProperty("Roku Player", "None selected")
    return
  end
  local d = gFound[serial]
  if d then
    C4:UpdateProperty("Roku Player", listLabel(serial, d) .. " at " .. d.ip)
  else
    C4:UpdateProperty("Roku Player", "[" .. serial .. "] - searching...")
  end
end

local function selectSerial(serial)
  PersistData.selectedSerial = serial
  local d = gFound[serial]
  gDiscoveredIP = d and d.ip or nil
  showSelected()
  if not staticIP() and gDiscoveredIP then refreshDeviceInfo() end
end

-- Fetch name/model for a newly seen Roku
local function describe(serial, ip)
  C4:url()
    :SetOptions({ timeout = 3, connect_timeout = 2, fail_on_error = false })
    :OnDone(function(transfer, responses, errCode)
      local r = responses and responses[#responses]
      local d = gFound[serial]
      if not d then return end
      if errCode == 0 and r and r.code == 200 and r.body then
        d.name  = xmlTag(r.body, "user-device-name") or xmlTag(r.body, "friendly-device-name") or d.name
        d.model = xmlTag(r.body, "model-name") or d.model
      end
      updateSelectorList()
      -- First run: if nothing is selected and exactly one Streambar answers, take it
      if not PersistData.selectedSerial then
        local only, count = nil, 0
        for s, x in pairs(gFound) do
          if (x.model or ""):find("Streambar") then only, count = s, count + 1 end
        end
        if count == 1 then dbg("auto-selected Streambar " .. only); selectSerial(only) end
      end
      showSelected()
    end)
    :Get("http://" .. ip .. ":8060/query/device-info", {})
end

local function onSsdpResponse(data)
  if not data:find("roku:ecp", 1, true) then return end
  local ip = data:match("[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:%s*http://([%d%.]+):8060")
  local serial = data:match("[Uu][Ss][Nn]:%s*uuid:roku:ecp:([%w%-]+)")
  if not ip or not serial then return end

  local d = gFound[serial]
  local isNew = (d == nil)
  if isNew then
    d = {}
    gFound[serial] = d
  end
  local moved = d.ip and d.ip ~= ip
  d.ip = ip
  if isNew or moved then
    dbg("SSDP: Roku " .. serial .. " at " .. ip .. (moved and " (IP changed)" or ""))
    describe(serial, ip)
  end
  if serial == PersistData.selectedSerial and gDiscoveredIP ~= ip then
    gDiscoveredIP = ip
    showSelected()
    if not staticIP() then refreshDeviceInfo() end
  end
end

sendSearch = function()
  local msg = table.concat({
    "M-SEARCH * HTTP/1.1",
    "HOST: 239.255.255.250:1900",
    'MAN: "ssdp:discover"',
    "MX: 3",
    "ST: roku:ecp",
    "", "",
  }, "\r\n")
  dbg("SSDP: M-SEARCH roku:ecp")
  C4:SendToNetwork(SSDP_BINDING, 1900, msg)
end

local function startDiscovery()
  C4:NetDisconnect(SSDP_BINDING, 1900)
  C4:CreateNetworkConnection(SSDP_BINDING, SSDP_ADDR)
  C4:NetConnect(SSDP_BINDING, 1900, "UDP")
  if gScanTimer then gScanTimer:Cancel() end
  gScanTimer = C4:SetTimer(SSDP_RESCAN_MS, function() sendSearch() end, true)
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  if idBinding == SSDP_BINDING and strStatus == "ONLINE" then sendSearch() end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  if idBinding == SSDP_BINDING and strData then onSsdpResponse(strData) end
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

local function startPolling()
  if gPollTimer then gPollTimer:Cancel() end
  local secs = tonumber(Properties["Polling Time"]) or 15
  gPollTimer = C4:SetTimer(secs * 1000, function()
    if currentIP() then refreshCurrentApp() end
  end, true)
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
    ecpPost("keypress/PowerOn", function(ok)
      if not ok then gLastPowerOn = nil return end
      -- On Power On = Home: give the Roku a moment to wake, then go home
      if Properties["On Power On"] == "Home" then
        C4:SetTimer(2000, function() ecpPost("keypress/Home") end)
      end
    end)
  end,
  OFF = function()
    stopRamp("power off")
    gLastPowerOn = nil
    if Properties["On Power Off"] == "Home" then
      -- close the running app first, then standby
      ecpPost("keypress/Home", function()
        C4:SetTimer(500, function() ecpPost("keypress/PowerOff") end)
      end)
    else
      ecpPost("keypress/PowerOff")
    end
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
  -- held arrows: the room sends START_*/STOP_*; the Streambar repeats on keydown
  START_UP = "keydown/Up", START_DOWN = "keydown/Down",
  START_LEFT = "keydown/Left", START_RIGHT = "keydown/Right",
  STOP_UP = "keyup/Up", STOP_DOWN = "keyup/Down",
  STOP_LEFT = "keyup/Left", STOP_RIGHT = "keyup/Right",

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
  PVR = "PVR Button", STAR = "STAR Button", POUND = "POUND Button",
}

-- commands the room sends that need no action (END_* handled generically below)
local NAV_IGNORE = {
  ON = true, OFF = true, -- power is handled by the receiver proxy
  CONNECT_OUTPUT = true, DISCONNECT_OUTPUT = true,
  SELECT_SOURCE = true, WATCH_BUTTON = true, LISTEN_BUTTON = true,
}

local function handleNav(cmd)
  if NAV_IGNORE[cmd] then return true end
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
    if v.name == MINI_APP_VAR then return v.value, name, miniProxyId end
    if v.name == "APP_ID" then fallback = v.value end
    if v.name == "APP_NAME" then name = v.value end
  end
  return fallback, name, miniProxyId
end

-- Passthrough Mode = Off: once the app is launched, rooms that have the app's
-- mini-driver selected are switched to the Roku media player, so remote keys go
-- straight to the Roku proxy instead of through the mini-driver.
local function handBackToRoku(miniProxyId)
  if Properties["Passthrough Mode"] == "On" then return end
  local mpId = next(C4:GetBoundConsumerDevices(C4:GetDeviceID(), MP) or {})
  if not mpId or not miniProxyId then return end
  C4:SetTimer(500, function()
    for roomId, srcId in pairs(gRoomSource) do
      if srcId == miniProxyId then
        dbg("passthrough off: room " .. roomId .. " -> Roku media player")
        C4:SendToDevice(roomId, "SELECT_VIDEO_DEVICE", { deviceid = mpId })
      end
    end
  end)
end

local function watchRooms()
  for roomId, _ in pairs(C4:GetDevicesByC4iName("roomdevice.c4i") or {}) do
    gRoomSource[roomId] = tonumber(C4:GetDeviceVariable(roomId, 1000)) or 0
    C4:UnregisterVariableListener(roomId, 1000)
    C4:RegisterVariableListener(roomId, 1000)
  end
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if idVariable == 1000 then gRoomSource[tonumber(idDevice)] = tonumber(strValue) or 0 end
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
      local appId, name, miniProxyId = miniDriverAppId(input)
      if appId then
        launchApp(appId, name)
        handBackToRoku(miniProxyId)
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
  Rescan         = function() sendSearch() end,
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
  elseif strProperty == "Polling Time" then
    startPolling()
  elseif strProperty == "Roku IP" then
    showSelected()
    if currentIP() then refreshDeviceInfo(); refreshCurrentApp() end
  elseif strProperty == "Roku Player Selector" then
    local serial = v and v:match("%[([%w%-]+)%]$")
    if serial then selectSerial(serial); refreshCurrentApp() end
  end
end

function OnDriverLateInit()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
  gDebug = (Properties["Debug Mode"] == "On")
  hideSwitcher()
  watchRooms()
  showSelected()
  startDiscovery()
  startPolling()
  if currentIP() then refreshDeviceInfo(); refreshCurrentApp() end
end

function OnDriverDestroyed()
  stopRamp("driver destroyed")
  if gAppTimer then gAppTimer:Cancel() end
  if gScanTimer then gScanTimer:Cancel() end
  if gPollTimer then gPollTimer:Cancel() end
  C4:NetDisconnect(SSDP_BINDING, 1900)
end
