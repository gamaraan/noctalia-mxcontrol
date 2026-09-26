--!nonstrict
-- Settings panel. Every setting the helper reports is rendered from its kind,
-- so Solaar settings this file has never heard of still get a control. Writes
-- go through the service's command channel.

local shared = require("./shared.luau")

-- A write shows at once and holds until the helper confirms it or this passes.
local PENDING_MS = 4000
-- Switching host sends the mouse to another machine, so it takes a second click.
local ARM_MS = 4000

local status = noctalia.state.get(shared.STATUS_KEY)
local selectedId = nil
local activeTab = "point"
local pending = {}
local dragging = {}
local armedHost = nil
local armedUntil = 0
local isOpen = false
local seq = 0
local render

local function tr(key)
	return noctalia.tr(key)
end

local function now()
	return noctalia.nowMs()
end

-- The service drops commands whose nonce timestamp is too old, so a stored one
-- is never replayed after a reload.
local function send(cmd)
	seq += 1
	noctalia.state.set(shared.COMMAND_KEY, { cmd = cmd, nonce = string.format("%d-%d", math.floor(now()), seq) })
end

local function controlKey(deviceId, settingName, key)
	return tostring(deviceId) .. "|" .. tostring(settingName) .. "|" .. tostring(key or "")
end

-- A held slider wins, then an unconfirmed write, then what the helper reported.
local function shownValue(k, reported)
	if dragging[k] ~= nil then
		return dragging[k]
	end
	local p = pending[k]
	if p then
		if now() > p.untilMs or tostring(shared.valueId(reported)) == tostring(p.value) then
			pending[k] = nil
		else
			return p.value
		end
	end
	return reported
end

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function withShownValues(setting, deviceId)
	local shown = copy(setting)
	shown.value = shownValue(controlKey(deviceId, setting.name, nil), setting.value)
	if type(setting.keys) == "table" then
		shown.keys = {}
		for i, entry in ipairs(setting.keys) do
			local e = copy(entry)
			e.value = shownValue(controlKey(deviceId, setting.name, entry.key), entry.value)
			shown.keys[i] = e
		end
	end
	return shown
end

local function commit(deviceId, settingName, key, control, choices, raw)
	local value, shown = shared.commandValue(control, choices, raw)
	if value == nil then
		return
	end
	pending[controlKey(deviceId, settingName, key)] = { value = shown, untilMs = now() + PENDING_MS }
	send(shared.setCommand(deviceId, settingName, key, value))
	render()
end

-- fill: the control grows into its column instead of taking a fixed width.
local function controlNode(deviceId, settingName, key, control, choices, enabled, fill)
	local k = controlKey(deviceId, settingName, key)
	if control.type == "toggle" then
		return ui.toggle({
			key = k, checked = control.value, enabled = enabled,
			onChange = function(v)
				commit(deviceId, settingName, key, control, choices, v)
			end,
		})
	elseif control.type == "select" then
		return ui.select({
			key = k, options = control.options, selectedIndex = control.index, enabled = enabled,
			width = not fill and 210 or nil, flexGrow = fill and 1 or nil,
			onChange = function(index, _text)
				commit(deviceId, settingName, key, control, choices, index)
			end,
		})
	elseif control.type == "slider" then
		return ui.slider({
			key = k, min = control.min, max = control.max, step = control.step, value = control.value,
			enabled = enabled, flexGrow = 1,
			onChange = function(v)
				local _, shown = shared.commandValue(control, choices, v)
				dragging[k] = shown
				render()
			end,
			onDragEnd = function()
				local v = dragging[k]
				dragging[k] = nil
				if v ~= nil then
					commit(deviceId, settingName, key, control, choices, tostring(v))
				end
			end,
		})
	end
	return ui.label({ text = control.text or "--", color = "on_surface_variant" })
end

local function firstParagraph(text)
	return (tostring(text):gsub("\n.*", ""))
end

local function settingRow(device, setting, enabled)
	local control = shared.controlFor(withShownValues(setting, device.id))
	local label = ui.label({ text = setting.label or setting.name, color = "on_surface", flexGrow = 1 })
	local caption = nil
	if setting.description and setting.description ~= "" then
		caption = ui.label({ text = firstParagraph(setting.description), fontSize = 11, color = "on_surface_variant", maxLines = 2 })
	end

	local children
	if control.type == "slider" then
		children = {
			ui.row({ gap = 8, align = "center" }, {
				label,
				ui.label({ text = tostring(control.value), color = "primary", fontWeight = "medium" }),
			}),
			controlNode(device.id, setting.name, nil, control, setting.choices, enabled),
		}
	elseif control.type == "map" then
		children = { label }
		for _, entry in ipairs(control.entries) do
			children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = entry.label, color = "on_surface_variant", flexGrow = 1 }),
				controlNode(device.id, setting.name, entry.key, entry.control, entry.choices, enabled),
			})
		end
	else
		children = {
			ui.row({ gap = 8, align = "center" }, {
				label,
				controlNode(device.id, setting.name, nil, control, setting.choices, enabled),
			}),
		}
	end
	if caption and control.type ~= "map" then
		children[#children + 1] = caption
	end
	if setting.readError and setting.readError ~= "" then
		children[#children + 1] = ui.label({ text = setting.readError, fontSize = 11, color = "error", maxLines = 2 })
	end
	return ui.column({ gap = 4 }, children)
end

local function section(title, rows)
	local children = { ui.label({ text = title, fontWeight = "semibold", color = "on_surface_variant" }) }
	for _, row in ipairs(rows) do
		children[#children + 1] = row
	end
	return ui.column({ gap = 10 }, children)
end

local function emptyNote(key)
	return ui.label({ text = tr(key), color = "on_surface_variant", maxLines = 3 })
end

local function settingsOn(device, tab)
	local out = {}
	for _, setting in ipairs(device.settings or {}) do
		if shared.tabFor(setting.name) == tab then
			out[#out + 1] = setting
		end
	end
	return out
end

local function pointTab(device, enabled)
	local grouped = {}
	for _, setting in ipairs(settingsOn(device, "point")) do
		local id = shared.sectionFor(setting.name)
		grouped[id] = grouped[id] or {}
		table.insert(grouped[id], settingRow(device, setting, enabled))
	end
	local body = {}
	for _, id in ipairs(shared.sectionsFor("point")) do
		if grouped[id] then
			body[#body + 1] = section(tr("section." .. id), grouped[id])
		end
	end
	if #body == 0 then
		body[1] = emptyNote("panel.empty_tab")
	end
	return body
end

-- One group per physical button, merging every per-key setting (action, mode).
local function buttonsTab(device, enabled)
	local order, groups, extra = {}, {}, {}
	for _, setting in ipairs(settingsOn(device, "buttons")) do
		local control = shared.controlFor(withShownValues(setting, device.id))
		if control.type == "map" and shared.mergesByButton(setting.name) then
			local captionKey = shared.captionKey(setting.name)
			local caption = captionKey and tr(captionKey) or (setting.label or setting.name)
			for _, entry in ipairs(control.entries) do
				local group = groups[entry.key]
				if group == nil then
					group = { label = entry.label, columns = {} }
					groups[entry.key] = group
					order[#order + 1] = entry.key
				end
				group.columns[#group.columns + 1] = ui.column({ gap = 2, flexGrow = 1 }, {
					ui.label({ text = caption, fontSize = 11, color = "on_surface_variant" }),
					controlNode(device.id, setting.name, entry.key, entry.control, entry.choices, enabled, true),
				})
			end
		else
			extra[#extra + 1] = settingRow(device, setting, enabled)
		end
	end

	local body = {}
	for _, key in ipairs(order) do
		local group = groups[key]
		body[#body + 1] = ui.column({ gap = 6 }, {
			ui.label({ text = group.label, fontWeight = "semibold", color = "on_surface" }),
			ui.row({ gap = 10 }, group.columns),
		})
	end
	for _, row in ipairs(extra) do
		body[#body + 1] = row
	end
	if #body == 0 then
		body[1] = emptyNote("panel.empty_tab")
	end
	return body
end

local function hostName(host)
	local name = tostring(host.name or "")
	if name == "" then
		return tr("panel.host") .. " " .. tostring((host.index or 0) + 1)
	end
	return name
end

local function hostsTab(device, enabled)
	local setting = nil
	for _, s in ipairs(settingsOn(device, "hosts")) do
		setting = s
	end
	if setting == nil or type(device.hosts) ~= "table" or #device.hosts == 0 then
		return { emptyNote("panel.no_hosts") }
	end

	local rows = { emptyNote("panel.hosts_hint") }
	for _, host in ipairs(device.hosts) do
		local right
		if host.current then
			right = ui.label({ text = tr("panel.this_computer"), color = "primary" })
		elseif host.paired then
			local armKey = tostring(device.id) .. "|" .. tostring(host.index)
			local armed = armedHost == armKey and now() < armedUntil
			right = ui.button({
				text = armed and tr("panel.confirm_switch") or tr("panel.switch"),
				variant = armed and "destructive" or "outline",
				controlSize = "sm",
				enabled = enabled,
				onClick = function()
					if armedHost == armKey and now() < armedUntil then
						armedHost = nil
						send(shared.setCommand(device.id, setting.name, nil, shared.hostSwitchValue(host.index)))
					else
						armedHost = armKey
						armedUntil = now() + ARM_MS
					end
					render()
				end,
			})
		else
			right = ui.label({ text = tr("panel.empty_slot"), color = "on_surface_variant" })
		end
		rows[#rows + 1] = ui.row({ gap = 10, align = "center" }, {
			ui.label({ text = tostring((host.index or 0) + 1), fontWeight = "semibold", color = "on_surface_variant", width = 14 }),
			ui.glyph({ name = "device-laptop", size = 18, color = host.current and "primary" or "on_surface_variant" }),
			ui.label({ text = hostName(host), flexGrow = 1 }),
			right,
		})
	end
	return rows
end

local function deviceCard(device)
	local level = shared.batteryLevel(device)
	local subtitle = tr("panel.offline")
	if device.online then
		subtitle = tostring(device.connection or "")
		if device.protocol and device.protocol ~= "" then
			subtitle = subtitle .. " · " .. device.protocol
		end
	end
	local children = {
		ui.row({ gap = 10, align = "center" }, {
			ui.glyph({ name = device.online and "mouse" or "mouse-off", size = 22, color = device.online and "primary" or "on_surface_variant" }),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = device.name or "MX", fontSize = 15, fontWeight = "semibold" }),
				ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant" }),
			}),
			ui.label({ text = shared.batteryText(device), fontWeight = "medium", color = shared.levelRole(level) or "on_surface" }),
		}),
	}
	if device.online and level then
		children[#children + 1] = ui.progress({ progress = level / 100, fill = shared.levelRole(level) or "primary" })
	end
	return ui.column({ gap = 8 }, children)
end

local function devicePicker(device)
	local devices = status.devices or {}
	if #devices < 2 then
		return nil
	end
	local options, index = {}, 0
	for i, d in ipairs(devices) do
		options[i] = tostring(d.name or d.id)
		if d.id == device.id then
			index = i - 1
		end
	end
	return ui.select({
		options = options, selectedIndex = index,
		onChange = function(i, _text)
			local picked = devices[(tonumber(i) or 0) + 1]
			selectedId = picked and picked.id or nil
			armedHost = nil
			render()
		end,
	})
end

local function tabBar()
	local buttons = {}
	for _, tab in ipairs(shared.TABS) do
		local active = activeTab == tab
		buttons[#buttons + 1] = ui.button({
			text = tr("tab." .. tab),
			selected = active,
			variant = active and "secondary" or "ghost",
			controlSize = "sm",
			flexGrow = 1,
			onClick = function()
				activeTab = tab
				render()
			end,
		})
	end
	return ui.row({ gap = 6 }, buttons)
end

local function tabContent(device, code)
	if not device.online then
		return { emptyNote("panel.offline_hint") }
	end
	local enabled = code == nil and not device.readonly
	if activeTab == "buttons" then
		return buttonsTab(device, enabled)
	elseif activeTab == "hosts" then
		return hostsTab(device, enabled)
	end
	return pointTab(device, enabled)
end

render = function()
	if not isOpen then
		return
	end
	local code = shared.stateCode(status, os.time())
	local device = shared.pickDevice(status, selectedId)

	local top = {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = "MX Control", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({
				glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh"),
				onClick = function()
					send({ op = "refresh", device = device and device.id or nil })
				end,
			}),
			ui.button({ glyph = "close", variant = "ghost", onClick = function()
				panel.close()
			end }),
		}),
	}
	if code then
		top[#top + 1] = ui.label({ text = tr("state." .. code), color = code == "no_devices" and "on_surface_variant" or "error" })
		if code == "no_solaar" or code == "no_access" then
			top[#top + 1] = ui.label({ text = tr("hint." .. code), fontSize = 11, color = "on_surface_variant", maxLines = 4 })
		end
	end

	local body = {}
	if device then
		local picker = devicePicker(device)
		if picker then
			top[#top + 1] = picker
		end
		top[#top + 1] = deviceCard(device)
		top[#top + 1] = tabBar()
		body = tabContent(device, code)
	end

	if type(status) == "table" then
		if status.lastError and status.lastError ~= "" then
			body[#body + 1] = ui.label({ text = status.lastError, color = "error", maxLines = 3 })
		end
		local progress = status.progress
		if type(progress) == "table" and progress.phase and progress.phase ~= "idle" then
			body[#body + 1] = ui.label({ text = tr("panel.reading"), color = "on_surface_variant" })
		end
	end

	top[#top + 1] = ui.scroll({ flexGrow = 1, gap = 18 }, body)
	panel.render(ui.column({ flexGrow = 1, gap = 14 }, top))
end

noctalia.state.watch(shared.STATUS_KEY, function(value)
	status = value
	render()
end)

function onOpen(_context)
	isOpen = true
	status = noctalia.state.get(shared.STATUS_KEY)
	render()
end

function onClose()
	isOpen = false
	dragging = {}
	armedHost = nil
end

function onKey(chord, pressed)
	if chord == "escape" and pressed then
		panel.close()
	end
end
