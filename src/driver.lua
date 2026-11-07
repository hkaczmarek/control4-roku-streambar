--[[
  Roku Streambar - Control4 receiver driver over Roku ECP
  Final Touch AV

  ECP: HTTP POST http://<ip>:8060/keypress/<Key>, empty body, no auth.
  The Streambar ignores keydown/keyup, so hold-to-ramp is done here with a
  repeating timer that sends keypress/VolumeUp|VolumeDown.
]]

DRIVER_VERSION = "0.1.7"

local PROXY_BINDING = 5001

local gDebug = false
local gRampTimer = nil
local gRampKey = nil
local gInFlight = false
local gLastPostFailed = false
local refreshDeviceInfo -- forward declaration

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------
local function dbg(msg)
  if gDebug then print("[Streambar] " .. tostring(msg)) end
end

local function setStatus(s)
  C4:UpdateProperty("Connection Status", s)
end

---------------------------------------------------------------------------
-- ECP transport
---------------------------------------------------------------------------
local function baseUrl()
  local ip = Properties["IP Address"]
  if ip == nil or ip == "" then return nil end
  return "http://" .. ip .. ":8060"
end

-- POST an ECP path (e.g. "keypress/VolumeUp"); cb(ok, code, err) optional
local function ecpPost(path, cb)
  local base = baseUrl()
  if not base then
    setStatus("Not configured (set IP Address)")
    if cb then cb(false, 0, "no ip") end
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
      if cb then cb(ok, code, errMsg) end
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
        dbg("GET failed: " .. tostring(errMsg))
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
-- Device info / connection test
---------------------------------------------------------------------------
local function xmlTag(body, tag)
  -- escape Lua pattern magic chars ("-" in "model-name" is a quantifier)
  local t = tag:gsub("%p", "%%%0")
  return body and body:match("<" .. t .. ">([^<]*)</" .. t .. ">")
end

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
    local tvPower = xmlTag(body, "supports-tv-power-control") or "n/a"
    local volCtl  = xmlTag(body, "supports-audio-volume-control") or "n/a"
    C4:UpdateProperty("Roku Capabilities", "TV power control: " .. tvPower .. ", volume control: " .. volCtl)
    setStatus("Online - power-mode " .. power)
  end)
end

---------------------------------------------------------------------------
-- Volume ramp
---------------------------------------------------------------------------
local function stopRamp(reason)
  if gRampTimer then
    gRampTimer:Cancel()
    gRampTimer = nil
    dbg("ramp stopped (" .. tostring(reason) .. ")")
  end
  gRampKey = nil
end

local function startRamp(key)
  stopRamp("restart")
  gRampKey = key
  -- No immediate keypress: the room sends PULSE_VOL_* before START_VOL_*,
  -- so the first step has already gone out. Ramp starts on the first tick.

  local interval = tonumber(Properties["Ramp Interval (ms)"]) or 150
  local maxMs = (tonumber(Properties["Max Ramp Time (s)"]) or 10) * 1000
  local elapsed = 0

  gRampTimer = C4:SetTimer(interval, function(timer)
    elapsed = elapsed + interval
    if elapsed >= maxMs then
      stopRamp("max ramp time - STOP never arrived?")
      return
    end
    -- Don't queue requests: if the last keypress hasn't answered, skip this tick
    -- so the volume doesn't keep climbing after the button is released.
    if gInFlight then
      dbg("tick skipped (in flight)")
      return
    end
    if gRampKey then sendKey(gRampKey) end
  end, true)
  dbg("ramp started " .. key .. " @" .. interval .. "ms")
end

---------------------------------------------------------------------------
-- Proxy commands
---------------------------------------------------------------------------
local PROXY_CMDS = {
  ON  = function() ecpPost("keypress/PowerOn") end,
  OFF = function() stopRamp("power off"); ecpPost("keypress/PowerOff") end,

  PULSE_VOL_UP   = function() sendKey("VolumeUp") end,
  PULSE_VOL_DOWN = function() sendKey("VolumeDown") end,
  START_VOL_UP   = function() startRamp("VolumeUp") end,
  START_VOL_DOWN = function() startRamp("VolumeDown") end,
  STOP_VOL_UP    = function() stopRamp("STOP_VOL_UP") end,
  STOP_VOL_DOWN  = function() stopRamp("STOP_VOL_DOWN") end,

  -- ECP only has a mute toggle; discrete mute is mapped onto it for now.
  MUTE_TOGGLE = function() sendKey("VolumeMute") end,
  MUTE_ON     = function() dbg("MUTE_ON -> toggle"); sendKey("VolumeMute") end,
  MUTE_OFF    = function() dbg("MUTE_OFF -> toggle"); sendKey("VolumeMute") end,

  SET_INPUT = function(p) dbg("SET_INPUT " .. tostring(p and p.INPUT) .. " (no-op)") end,

  -- Sent by the room; nothing to do on the Streambar
  END_VOL_UP        = function() end,
  END_VOL_DOWN      = function() end,
  CONNECT_OUTPUT    = function() end,
  DISCONNECT_OUTPUT = function() end,
  GET_IS_MUTED      = function() end, -- ECP can't report mute state
}

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if gDebug then
    local s = ""
    for k, v in pairs(tParams or {}) do s = s .. k .. "=" .. tostring(v) .. " " end
    dbg("RFP " .. tostring(idBinding) .. " " .. strCommand .. " " .. s)
  end
  local h = PROXY_CMDS[strCommand]
  if h then h(tParams) else dbg("unhandled proxy command " .. strCommand) end
end

---------------------------------------------------------------------------
-- Actions / properties / lifecycle
---------------------------------------------------------------------------
local ACTIONS = {
  TestConnection = refreshDeviceInfo,
  TestVolUp      = function() sendKey("VolumeUp") end,
  TestVolDown    = function() sendKey("VolumeDown") end,
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
  end
end

function OnDriverLateInit()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
  gDebug = (Properties["Debug Mode"] == "On")
  refreshDeviceInfo()
end

function OnDriverDestroyed()
  stopRamp("driver destroyed")
end
