-- SmartThings Edge driver: AMH-9900UV (Tuya WiFi) 가습기, Tuya 로컬 프로토콜 3.4로 직접 제어.
-- 허브 ─TCP 6668─▶ 가습기. 클라우드·브리지 없음. 문서: ../../docs/

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local client_mod = require "client"
local amh = require "amh"

local okj, json = pcall(require, "st.json")
if not okj then json = require "dkjson" end

local DNI = "tuya-amh-9900uv-1"
local PROFILE = "amh-9900uv.v1"
local POWER_ON_DELAY = 1.5 -- 초. 전원을 켠 뒤 다음 명령까지

local clients = {} -- device.id -> client

math.randomseed(os.time())

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local function emit(device, comp_id, event)
  local comp = device.profile.components[comp_id]
  if comp then device:emit_component_event(comp, event) end
end

local function emit_supported_modes(device)
  local hidden = { visibility = { displayed = false } }
  local args_attr = capabilities.mode.supportedArguments -- 오래된 허브 라이브러리에는 없을 수 있음
  for comp, list in pairs({ mist = amh.MIST_MODES, humidityTarget = amh.TARGET_MODES }) do
    emit(device, comp, capabilities.mode.supportedModes(list, hidden))
    if args_attr then emit(device, comp, args_attr(list, hidden)) end
  end
end

local function send(device, dps)
  local c = clients[device.id]
  if not c then
    log.warn("no connection for " .. device.label)
    return
  end
  local ok, err = amh.is_safe(dps)
  if not ok then
    log.error("refusing command: " .. err)
    return
  end
  c:set(dps)
end

local function state_of(device)
  local c = clients[device.id]
  return c and c.state or {}
end

-- 가습기가 꺼져 있으면 먼저 켜고 잠시 뒤에 fn 실행 (앱은 꺼진 상태에서 다른 조작을 막는다)
local function with_power_on(device, fn)
  if state_of(device)["1"] == true then
    fn()
  else
    send(device, { ["1"] = true })
    device.thread:call_with_delay(POWER_ON_DELAY, fn)
  end
end

----------------------------------------------------------------------
-- 가습기 → SmartThings
----------------------------------------------------------------------
local function apply(device, changed, state)
  for _, u in ipairs(amh.updates(changed, state)) do
    if u.kind == "switch" then
      emit(device, u.component, u.value == "on" and capabilities.switch.switch.on() or capabilities.switch.switch.off())
    elseif u.kind == "mode" then
      emit(device, u.component, capabilities.mode.mode(u.value))
    elseif u.kind == "humidity" then
      emit(device, "main", capabilities.relativeHumidityMeasurement.humidity(u.value))
    end
  end
end

----------------------------------------------------------------------
-- 연결
----------------------------------------------------------------------
local function stop_client(device)
  local c = clients[device.id]
  if c then
    c:stop()
    clients[device.id] = nil
  end
end

local function start_client(device)
  stop_client(device)
  local ip, dev_id, key = amh.check_prefs(device.preferences or {})
  if not ip then
    log.warn("settings incomplete (" .. tostring(dev_id) .. "): open the device settings in the SmartThings app")
    device:offline()
    return
  end
  log.info(string.format("humidifier %s, device id %s", ip, dev_id)) -- 키는 기록하지 않는다
  local c = client_mod.new({
    ip = ip, dev_id = dev_id, key = key, json = json,
    log = { info = log.info, warn = log.warn, debug = log.debug },
    on_dps = function(changed, state) apply(device, changed, state) end,
    on_connect = function() device:online() end,
    on_disconnect = function(reason)
      log.warn("humidifier disconnected: " .. tostring(reason))
      device:offline()
    end,
  })
  clients[device.id] = c
  c:start()
end

----------------------------------------------------------------------
-- capability handlers
----------------------------------------------------------------------
local function switch_handler(value)
  return function(_, device, command)
    local dp = amh.SWITCH_DPS[command.component]
    if not dp then return end
    if command.component == "main" then
      send(device, { [dp] = value })
    elseif value == false and state_of(device)["1"] ~= true then
      -- 꺼진 상태에서 끄기: 끄려고 전원을 켜지 않는다. 화면은 현재 값으로 되돌린다.
      log.info("humidifier is off; ignoring " .. command.component .. " off")
      local cur = state_of(device)[dp]
      if type(cur) == "boolean" then
        emit(device, command.component, cur and capabilities.switch.switch.on() or capabilities.switch.switch.off())
      end
    else
      with_power_on(device, function() send(device, { [dp] = value }) end)
    end
  end
end

local function set_mode(_, device, command)
  local mode = command.args.mode
  if command.component == "mist" then
    with_power_on(device, function()
      local dps = amh.mist_command(mode, state_of(device))
      if dps then send(device, dps) else log.warn("ignoring unsupported mist mode: " .. tostring(mode)) end
    end)
  elseif command.component == "humidityTarget" then
    local dps = amh.target_command(mode)
    if not dps then
      log.warn("ignoring unsupported target humidity: " .. tostring(mode))
      return
    end
    with_power_on(device, function() send(device, dps) end)
  end
end

local function refresh(_, device)
  local c = clients[device.id]
  if c then c:query() end
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------
local function device_init(_, device)
  log.info("init " .. device.label)
  emit_supported_modes(device)
  device:offline() -- 연결되면 online
  start_client(device)
end

local function device_info_changed(_, device, _, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}
  if old.ipAddress ~= new.ipAddress or old.deviceId ~= new.deviceId or old.localKey ~= new.localKey then
    log.info("settings changed; reconnecting")
    start_client(device)
  end
end

local function device_removed(_, device)
  stop_client(device)
end

local function discovery(driver, _, _)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == DNI then
      log.info("discovery: device already exists")
      return
    end
  end
  log.info("discovery: creating AMH-9900UV device")
  driver:try_create_device({
    type = "LAN",
    device_network_id = DNI,
    label = "AMH-9900UV 가습기",
    profile = PROFILE,
    manufacturer = "Tuya",
    model = "AMH-9900UV",
    vendor_provided_label = "AMH-9900UV",
  })
end

local driver = Driver("tuya-humidifier-local", {
  discovery = discovery,
  lifecycle_handlers = {
    init = device_init,
    infoChanged = device_info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_handler(true),
      [capabilities.switch.commands.off.NAME] = switch_handler(false),
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = set_mode,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
  },
})

driver:run()
