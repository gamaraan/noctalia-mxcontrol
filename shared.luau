--!nonstrict
-- Pure helpers for the service, widget and panel. Plain-Lua syntax only, so
-- tests/shared_test.lua can load this file under `lua`.

local M = {}

M.STATUS_KEY = "mx_status"
M.COMMAND_KEY = "mx_command"

-- serve stamps ts on every publish and heartbeats every 60 s.
local STALE_SEC = 150

-- A choice list this long and evenly spaced is a numeric scale (DPI).
local SLIDER_MIN_CHOICES = 13

M.TABS = { "point", "buttons", "hosts" }

local TAB_SECTIONS = {
    point = { "pointer", "scroll", "thumb", "other" },
    buttons = { "buttons" },
    hosts = { "hosts" },
}

local SECTION_TAB = {}
for tab, sections in pairs(TAB_SECTIONS) do
    for _, section in ipairs(sections) do
        SECTION_TAB[section] = tab
    end
end

-- Column captions for the per-button groups; other key settings keep their label.
local CAPTION_KEYS = {
    ["reprogrammable-keys"] = "caption.action",
    ["divert-keys"] = "caption.mode",
}

function M.sectionsFor(tab)
    return TAB_SECTIONS[tab] or {}
end

function M.captionKey(settingName)
    return CAPTION_KEYS[settingName]
end

function M.sectionFor(name)
    name = tostring(name or "")
    if name == "change-host" then
        return "hosts"
    end
    if name == "dpi" or name:find("^dpi") or name:find("^pointer") then
        return "pointer"
    end
    if name:find("^thumb") then
        return "thumb"
    end
    if name:find("^hires") or name:find("^lowres") or name:find("^scroll") or name == "smart-shift" then
        return "scroll"
    end
    if name:find("key") or name:find("gesture") or name:find("button") then
        return "buttons"
    end
    return "other"
end

function M.tabFor(name)
    return SECTION_TAB[M.sectionFor(name)] or "point"
end

function M.pickDevice(status, preferred)
    if type(status) ~= "table" or type(status.devices) ~= "table" then
        return nil
    end
    local first, online
    for _, device in ipairs(status.devices) do
        if preferred and preferred ~= "" and device.id == preferred then
            return device
        end
        first = first or device
        if device.online and not online then
            online = device
        end
    end
    return online or first
end

-- jsonable() emits NamedInt values as {id, name}.
function M.valueId(value)
    if type(value) == "table" then
        if value.id ~= nil then
            return value.id
        end
        return value.name
    end
    return value
end

function M.choiceIndex(choices, value)
    local wanted = M.valueId(value)
    for i, choice in ipairs(choices or {}) do
        if choice.id == wanted or choice.name == wanted or tostring(choice.id) == tostring(wanted) then
            return i - 1
        end
    end
    return -1
end

function M.evenScale(choices)
    if type(choices) ~= "table" or #choices < SLIDER_MIN_CHOICES then
        return nil
    end
    local step = nil
    for i, choice in ipairs(choices) do
        if type(choice.id) ~= "number" then
            return nil
        end
        if i > 1 then
            local diff = choice.id - choices[i - 1].id
            if diff <= 0 or (step and diff ~= step) then
                return nil
            end
            step = diff
        end
    end
    return choices[1].id, choices[#choices].id, step
end

function M.displayText(value)
    if value == nil then
        return "--"
    end
    if type(value) == "table" then
        if value.name ~= nil then
            return tostring(value.name)
        end
        return "…"
    end
    return tostring(value)
end

local function names(choices)
    local out = {}
    for i, choice in ipairs(choices or {}) do
        out[i] = tostring(choice.name)
    end
    return out
end

function M.controlFor(setting)
    local kind = setting.kind
    if kind == "toggle" then
        return { type = "toggle", value = setting.value == true }
    end
    if kind == "range" and tonumber(setting.min) and tonumber(setting.max) then
        local lo = tonumber(setting.min)
        return {
            type = "slider", min = lo, max = tonumber(setting.max), step = 1,
            value = tonumber(M.valueId(setting.value)) or lo,
        }
    end
    if kind == "choice" then
        if setting.name == "change-host" then
            return { type = "hosts" }
        end
        local lo, hi, step = M.evenScale(setting.choices)
        if lo then
            return {
                type = "slider", min = lo, max = hi, step = step, snap = true,
                value = tonumber(M.valueId(setting.value)) or lo,
            }
        end
        return { type = "select", options = names(setting.choices), index = M.choiceIndex(setting.choices, setting.value) }
    end
    if kind == "map_choice" or kind == "map_range" or kind == "multiple_toggle" then
        local entries = {}
        for _, entry in ipairs(setting.keys or {}) do
            local control = M.controlFor({
                kind = entry.kind, value = entry.value, min = entry.min, max = entry.max, choices = entry.choices,
            })
            if control.type ~= "readonly" then
                entries[#entries + 1] = { key = entry.key, label = entry.label, control = control, choices = entry.choices }
            end
        end
        if #entries > 0 then
            return { type = "map", entries = entries }
        end
    end
    local shown = setting.display
    if shown == nil then
        shown = setting.value
    end
    return { type = "readonly", text = M.displayText(shown) }
end

-- Turns a control's raw callback string into (value to send, value to show).
-- Choices are sent as a name or a digit string: Luau numbers are doubles, and
-- the helper's choice matcher rejects an encoded 1000.0.
function M.commandValue(control, choices, raw)
    if control.type == "toggle" then
        local on = raw == "true" or raw == true
        return on, on
    end
    local n = tonumber(raw)
    if n == nil then
        return nil
    end
    if control.type == "slider" then
        local steps = math.floor((n - control.min) / control.step + 0.5)
        local value = control.min + steps * control.step
        if value < control.min then
            value = control.min
        elseif value > control.max then
            value = control.max
        end
        value = math.floor(value)
        if control.snap then
            return string.format("%d", value), value
        end
        return value, value
    end
    if control.type == "select" then
        local choice = (choices or {})[math.floor(n) + 1]
        if choice == nil then
            return nil
        end
        return tostring(choice.name), choice.id ~= nil and choice.id or choice.name
    end
    return nil
end

function M.hostSwitchValue(index)
    return string.format("%d", math.floor(tonumber(index) or 0))
end

-- Nonces start with the sender's nowMs; a stored command replayed after a
-- reload is older than the window and must not be written again.
function M.isFreshNonce(nonce, nowMs, maxAgeMs)
    local ms = tonumber(tostring(nonce or ""):match("^(%d+)[%.%d]*%-"))
    if ms == nil then
        return false
    end
    return math.abs(nowMs - ms) <= maxAgeMs
end

-- Only settings keyed by button control id can share a per-button group.
function M.mergesByButton(settingName)
    return CAPTION_KEYS[settingName] ~= nil
end

function M.runtimeDirFrom(stdout, fallback)
    local path = tostring(stdout or ""):match("^%s*(.-)%s*$")
    if path:sub(1, 1) == "/" then
        return path
    end
    return fallback
end

function M.setCommand(deviceId, settingName, key, value)
    return { op = "set", device = deviceId, setting = settingName, key = key, value = value }
end

-- serve drains cmd-*.json sorted by name, so the name carries the write order.
function M.spoolName(ms, seq)
    return string.format("cmd-%013d%07d-noctalia.json", math.floor(ms), math.floor(seq) % 10000000)
end

function M.stateCode(status, nowSec)
    if type(status) ~= "table" then
        return "starting"
    end
    if status.installed == false then
        return "no_solaar"
    end
    local ts = tonumber(status.ts)
    if ts and nowSec and nowSec - ts > STALE_SEC then
        return "stale"
    end
    if status.accessible == false and status.permissionError and status.permissionError ~= "" then
        return "no_access"
    end
    if type(status.devices) ~= "table" or #status.devices == 0 then
        return "no_devices"
    end
    return nil
end

function M.batteryLevel(device)
    if type(device) ~= "table" or type(device.battery) ~= "table" then
        return nil
    end
    return tonumber(device.battery.level)
end

function M.batteryText(device)
    if type(device) ~= "table" or not device.online then
        return "--"
    end
    local level = M.batteryLevel(device)
    if level then
        return tostring(math.floor(level)) .. "%"
    end
    if type(device.battery) == "table" and device.battery.text and device.battery.text ~= "" then
        return tostring(device.battery.text)
    end
    return "--"
end

function M.levelRole(level)
    level = tonumber(level)
    if level == nil then
        return nil
    end
    if level <= 15 then
        return "error"
    end
    if level <= 30 then
        return "secondary"
    end
    return nil
end

return M
