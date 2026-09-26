-- Tests for shared.luau. Run from the plugin root: lua tests/shared_test.lua

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local env = setmetatable({}, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()

local failures = 0
local function check(name, cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. name)
    end
end

-- Shapes captured from mxctl.py status on an MX Master 3S over Bluetooth.
local dpi = {
    name = "dpi", label = "Sensitivity (DPI)", kind = "choice", value = 1000,
    choices = {},
}
for id = 200, 8000, 50 do
    dpi.choices[#dpi.choices + 1] = { id = id, name = tostring(id) }
end
local ratchet = {
    name = "scroll-ratchet", kind = "choice", value = 2,
    choices = { { id = 1, name = "Freespinning" }, { id = 2, name = "Ratcheted" } },
}
local smartShift = { name = "smart-shift", kind = "range", value = 10, min = 1, max = 50 }
local invert = { name = "hires-smooth-invert", kind = "toggle", value = false }
local host = {
    name = "change-host", kind = "choice", value = 1,
    choices = { { id = 0, name = "1:mac" }, { id = 1, name = "2:zbook" }, { id = 2, name = "3" } },
}
local divert = {
    name = "divert-keys", kind = "map_choice",
    keys = {
        { key = "82", label = "Middle Button", kind = "choice", value = 0,
          choices = { { id = 0, name = "Regular" }, { id = 1, name = "Diverted" } } },
        { key = "83", label = "Back Button", kind = "choice", value = 1,
          choices = { { id = 0, name = "Regular" }, { id = 1, name = "Diverted" } } },
    },
}
local eq = { name = "graphic-eq", kind = "multiple_range", display = "{...}" }

-- pickDevice
local status = { devices = {
    { id = "A", online = false },
    { id = "B", online = true },
} }
check("pickDevice prefers the requested id", shared.pickDevice(status, "A").id == "A")
check("pickDevice falls back to the first online device", shared.pickDevice(status, "missing").id == "B")
check("pickDevice without devices is nil", shared.pickDevice({ devices = {} }) == nil)
check("pickDevice without a status is nil", shared.pickDevice(nil) == nil)

-- controlFor
local c = shared.controlFor(invert)
check("toggle maps to a toggle", c.type == "toggle" and c.value == false)

c = shared.controlFor(smartShift)
check("range maps to a slider", c.type == "slider" and c.min == 1 and c.max == 50 and c.step == 1 and c.value == 10)

c = shared.controlFor(dpi)
check("an evenly spaced 157-step DPI list becomes a slider",
    c.type == "slider" and c.min == 200 and c.max == 8000 and c.step == 50 and c.value == 1000)

c = shared.controlFor(ratchet)
check("a short choice list stays a select",
    c.type == "select" and #c.options == 2 and c.options[2] == "Ratcheted" and c.index == 1)

check("change-host gets the host list, not a select", shared.controlFor(host).type == "hosts")

c = shared.controlFor(divert)
check("map_choice renders one control per key",
    c.type == "map" and #c.entries == 2 and c.entries[2].control.type == "select" and c.entries[2].control.index == 1)

c = shared.controlFor(eq)
check("unsupported kinds are read-only", c.type == "readonly" and c.text == "{...}")

-- commandValue returns (sent, shown). Choice values are sent as a name or a
-- digit string: the host encodes Luau numbers as doubles, and the helper's
-- choice matcher rejects 1000.0.
local sent, shown = shared.commandValue(shared.controlFor(invert), nil, "true")
check("toggle input becomes a boolean", sent == true and shown == true)

sent, shown = shared.commandValue(shared.controlFor(ratchet), ratchet.choices, "0")
check("a select sends the choice name", sent == "Freespinning")
check("a select shows the choice id", shown == 1)

sent, shown = shared.commandValue(shared.controlFor(dpi), dpi.choices, "1012")
check("DPI slider sends the snapped value as a digit string", sent == "1000")
check("DPI slider shows the snapped number", shown == 1000)
sent, shown = shared.commandValue(shared.controlFor(dpi), dpi.choices, "1030")
check("DPI slider snaps up to the step", sent == "1050" and shown == 1050)
sent = shared.commandValue(shared.controlFor(dpi), dpi.choices, "7999.9")
check("a sent choice string never looks like a float", sent == "8000" and not tostring(sent):find("%."))

sent, shown = shared.commandValue(shared.controlFor(smartShift), nil, "10.6")
check("range slider sends and shows an integer", sent == 11 and shown == 11)

check("an out-of-range select index is rejected", shared.commandValue(shared.controlFor(ratchet), ratchet.choices, "5") == nil)

local divertEntry = shared.controlFor(divert).entries[1]
check("a per-button select sends the choice name",
    shared.commandValue(divertEntry.control, divertEntry.choices, "1") == "Diverted")

check("a host switch sends the slot index as a digit string", shared.hostSwitchValue(1) == "1")

-- isFreshNonce: commands older than the window are not replayed after a reload.
check("a fresh nonce is accepted", shared.isFreshNonce("1000-1", 3000, 5000))
check("a nonce with a fractional timestamp is accepted", shared.isFreshNonce("1000.5-1", 3000, 5000))
check("an old nonce is dropped", not shared.isFreshNonce("1000-1", 7000, 5000))
check("a nonce slightly ahead of the clock is accepted", shared.isFreshNonce("9000-1", 7000, 5000))
check("a missing nonce is dropped", not shared.isFreshNonce(nil, 7000, 5000))
check("a malformed nonce is dropped", not shared.isFreshNonce("abc", 7000, 5000))

-- mergesByButton: only settings keyed by button control id share a group.
check("reprogrammable-keys merges into button groups", shared.mergesByButton("reprogrammable-keys"))
check("divert-keys merges into button groups", shared.mergesByButton("divert-keys"))
check("gesture settings keep their own block", not shared.mergesByButton("gesture2-gestures"))
check("per-key lighting keeps its own block", not shared.mergesByButton("per-key-lighting"))

-- evenScale edge cases
local unnamed, uneven, descending = {}, {}, {}
for i = 1, 20 do
    unnamed[i] = { id = nil, name = "x" .. i }
    uneven[i] = { id = i * i, name = tostring(i * i) }
    descending[i] = { id = 100 - i, name = tostring(100 - i) }
end
check("evenScale rejects choices without numeric ids", shared.evenScale(unnamed) == nil)
check("evenScale rejects uneven spacing", shared.evenScale(uneven) == nil)
check("evenScale rejects a descending list", shared.evenScale(descending) == nil)

-- runtimeDirFrom: the helper prints the directory it actually uses.
check("runtime-dir output is trimmed", shared.runtimeDirFrom("/run/user/1000/omarchy-mx\n", "/x") == "/run/user/1000/omarchy-mx")
check("empty runtime-dir output keeps the fallback", shared.runtimeDirFrom("", "/x") == "/x")
check("a relative runtime-dir output is ignored", shared.runtimeDirFrom("omarchy-mx\n", "/x") == "/x")

-- choiceIndex accepts the {id, name} form jsonable() emits for NamedInt values.
check("choiceIndex matches an {id,name} value", shared.choiceIndex(ratchet.choices, { id = 1, name = "Freespinning" }) == 0)
check("choiceIndex returns -1 when nothing matches", shared.choiceIndex(ratchet.choices, 9) == -1)

-- setCommand
local cmd = shared.setCommand("B7EBE049", "divert-keys", "82", 1)
check("setCommand builds a set op", cmd.op == "set" and cmd.device == "B7EBE049"
    and cmd.setting == "divert-keys" and cmd.key == "82" and cmd.value == 1)

-- spoolName: serve drains cmd-*.json in lexicographic order.
local a = shared.spoolName(1790338078123, 1)
local b = shared.spoolName(1790338078123, 2)
local later = shared.spoolName(1790338078124, 0)
check("spoolName matches serve's cmd-*.json glob", a:match("^cmd%-%d+%-noctalia%.json$") ~= nil)
check("spoolName orders by sequence within a millisecond", a < b)
check("spoolName orders by time", b < later)

-- stateCode
check("no status means the helper is starting", shared.stateCode(nil, 100) == "starting")
check("a snapshot older than the heartbeat window is stale", shared.stateCode({ ts = 100, devices = {} }, 1000) == "stale")
check("no devices is reported", shared.stateCode({ ts = 100, devices = {} }, 110) == "no_devices")
check("a permission error is reported",
    shared.stateCode({ ts = 100, devices = { { id = "A" } }, accessible = false, permissionError = "x" }, 110) == "no_access")
check("a healthy snapshot has no state code", shared.stateCode({ ts = 100, devices = { { id = "A" } }, accessible = true }, 110) == nil)
check("a stale snapshot wins over its old permission error",
    shared.stateCode({ ts = 100, devices = { { id = "A" } }, accessible = false, permissionError = "x" }, 1000) == "stale")

-- sectionFor
check("dpi is a pointer setting", shared.sectionFor("dpi") == "pointer")
check("smart-shift is a scroll setting", shared.sectionFor("smart-shift") == "scroll")
check("thumb settings get their own section", shared.sectionFor("thumb-scroll-mode") == "thumb")
check("key settings are buttons", shared.sectionFor("reprogrammable-keys") == "buttons")
check("change-host is the hosts section", shared.sectionFor("change-host") == "hosts")

-- tabFor
check("pointer settings live on the point tab", shared.tabFor("dpi") == "point")
check("scroll settings live on the point tab", shared.tabFor("scroll-ratchet") == "point")
check("thumb settings live on the point tab", shared.tabFor("thumb-scroll-invert") == "point")
check("unknown settings live on the point tab", shared.tabFor("backlight") == "point")
check("button settings live on the buttons tab", shared.tabFor("divert-keys") == "buttons")
check("change-host lives on the hosts tab", shared.tabFor("change-host") == "hosts")
check("the point tab lists its sections in order",
    table.concat(shared.sectionsFor("point"), ",") == "pointer,scroll,thumb,other")

-- captionKey: the per-button columns on the buttons tab
check("reprogrammable-keys is the action column", shared.captionKey("reprogrammable-keys") == "caption.action")
check("divert-keys is the mode column", shared.captionKey("divert-keys") == "caption.mode")
check("other key settings fall back to their own label", shared.captionKey("gesture2-gestures") == nil)

-- battery
check("low battery is an error", shared.levelRole(10) == "error")
check("healthy battery keeps the default colour", shared.levelRole(90) == nil)
check("batteryText prefers the level", shared.batteryText({ online = true, battery = { level = 90 } }) == "90%")
check("batteryText for an offline device", shared.batteryText({ online = false }) == "--")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("ok")
