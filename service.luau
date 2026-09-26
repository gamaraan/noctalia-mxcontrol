--!nonstrict
-- Owns the mxctl.py helper: keeps `serve` running, publishes its status.json to
-- the shared state, and turns UI commands into spool files serve picks up. The
-- widget and panel never spawn processes or touch the runtime directory.

local shared = require("./shared.luau")

local TICK_MS = 1000
local SUPERVISE_EVERY_TICKS = 10
-- Shared state outlives a reload, so a stored command must not be written twice.
local COMMAND_MAX_AGE_MS = 5000

local helper = (noctalia.pluginDir() or ".") .. "/backend/mxctl.py"
-- Replaced by the path `runtime-dir` prints, which is what serve really uses.
-- mxctl.py keeps the Omarchy directory names; see UPSTREAM.md.
local runtimeDir = (noctalia.getenv("XDG_RUNTIME_DIR") or "") .. "/omarchy-mx"

local lastRaw = nil
local reading = false
local ticks = 0
local seq = 0
local stopping = false

local function statusPath()
	return runtimeDir .. "/status.json"
end

local function readStatus()
	if reading then
		return
	end
	reading = true
	local started = noctalia.readFileAsync(statusPath(), function(contents)
		reading = false
		if contents == nil then
			if lastRaw ~= nil then
				lastRaw = nil
				noctalia.state.set(shared.STATUS_KEY, nil)
			end
			return
		end
		if contents == lastRaw then
			return
		end
		lastRaw = contents
		local decoded = noctalia.json.decode(contents)
		if type(decoded) == "table" then
			noctalia.state.set(shared.STATUS_KEY, decoded)
		end
	end)
	-- A read that fails to start never calls back.
	if not started then
		reading = false
	end
end

local function startHelper()
	-- runtime-dir creates the 0700 directory and drops stale commands first.
	noctalia.runAsync({ "python3", helper, "runtime-dir" }, function(result)
		if result.exitCode ~= 0 then
			noctalia.log("mx-control: runtime-dir failed: " .. tostring(result.stderr))
			return
		end
		runtimeDir = shared.runtimeDirFrom(result.stdout, runtimeDir)
		-- Detached: serve outlives runAsync's 60 s cap. A second copy exits on
		-- the helper's lock, so an extra launch is harmless.
		noctalia.runAsync({ "python3", helper, "serve" })
	end, 10000)
end

-- Any serve holds the helper's single lock, whichever path started it, so
-- supervision and teardown match the script name rather than this copy's path.
local function supervise()
	if stopping then
		return
	end
	noctalia.processMatches(function(running)
		if not running and not stopping then
			startHelper()
		end
	end, "mxctl.py", "serve")
end

-- Written under a non-matching name and renamed, so serve never reads half a file.
local function queueCommand(cmd)
	local text = noctalia.json.encode(cmd)
	if text == nil then
		return
	end
	seq += 1
	local name = shared.spoolName(noctalia.nowMs(), seq)
	local tmp = runtimeDir .. "/.tmp-" .. name
	local ok, err = noctalia.writeFile(tmp, text .. "\n")
	if not ok then
		noctalia.log("mx-control: cannot queue command: " .. tostring(err))
		return
	end
	local moved, moveErr = noctalia.renameFile(tmp, runtimeDir .. "/" .. name)
	if not moved then
		noctalia.removeFile(tmp)
		noctalia.log("mx-control: cannot queue command: " .. tostring(moveErr))
	end
end

local ALLOWED_OPS = { set = true, refresh = true }

local function onCommand(message)
	if type(message) ~= "table" or type(message.cmd) ~= "table" then
		return
	end
	if not ALLOWED_OPS[message.cmd.op] then
		return
	end
	if not shared.isFreshNonce(message.nonce, noctalia.nowMs(), COMMAND_MAX_AGE_MS) then
		return
	end
	queueCommand(message.cmd)
end

noctalia.state.watch(shared.COMMAND_KEY, onCommand)

function onIpc(event, _payload)
	if event == "refresh" then
		queueCommand({ op = "refresh" })
	end
end

function onExit(_signal, reason)
	-- Keep serve across a plugin reload; stop it when the plugin or shell goes away.
	if reason == "reload" then
		return
	end
	stopping = true
	noctalia.runAsync({ "pkill", "-TERM", "-f", "mxctl\\.py serve" })
end

noctalia.setUpdateInterval(TICK_MS)
supervise()
readStatus()

function update()
	ticks += 1
	if ticks % SUPERVISE_EVERY_TICKS == 0 then
		supervise()
	end
	readStatus()
end

