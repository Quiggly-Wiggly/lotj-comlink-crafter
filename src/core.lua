-- LotJComlink 1.5.1, adapted from Ruusm's MUSHclient v1.3.
-- Edit WEAR_LOCATION / COMLINK_KEYWORD below to customize item targeting.
if LotJComlink and LotJComlink.shutdown then LotJComlink.shutdown() end
LotJComlink = {version="1.5.1"}
local M = LotJComlink
local handlers = {}

-- ===================== Editable constants =====================

local WEAR_LOCATION     = "hold"      -- used for both makecomlink and makecontainer
local COMLINK_KEYWORD   = "comlink"   -- keyword used to target the most-recently-made comlink

-- Filler words skipped when auto-picking a keyword out of a container's name.
-- This is only a best-effort default - mclcontainer lets you override it explicitly.
local MCL_STOPWORDS = {
	["a"]=true, ["an"]=true, ["the"]=true, ["of"]=true, ["and"]=true, ["or"]=true,
	["for"]=true, ["to"]=true, ["in"]=true, ["on"]=true, ["with"]=true, ["your"]=true,
	["you"]=true, ["some"]=true, ["this"]=true, ["that"]=true, ["these"]=true, ["those"]=true,
	["is"]=true, ["are"]=true, ["it"]=true, ["its"]=true,
}

-- ===================== State =====================

local mclQueue             = {}      -- list of {name=<string>, tune=<string or nil>}
local mclContainerName     = nil
local mclContainerKeyword  = nil
local mclIterationsCount   = 1
local mclRunning           = false   -- always reset on load; never resume mid-run after a reload
local mclCurrentIteration  = 1
local mclQueueIndex        = 1
local mclWaitingFor        = nil     -- nil, "comlink", or "container"
local mclPendingTune       = nil

-- ===================== Small helpers =====================

-- Semantic console palette; edit these RGB values to suit your Mudlet theme.
local palette = {
  heading = {255,190,70}, accent = {70,220,235}, text = {220, 226, 235}, muted = {151, 164, 184},
  success = {126, 214, 159}, warning = {242, 195, 110}, error = {255, 128, 139},
  frequency = {195, 170, 245},
}
local function paint(role, text)
  resetFormat(); setBold(false); setUnderline(false); setItalics(false)
  setFgColor(unpack(palette[role] or palette.text))
  echo(tostring(text)) -- Names remain literal, including <tags> and game colour codes.
  resetFormat()
end
local function row(...)
  for _, segment in ipairs({...}) do paint(segment[1], segment[2]) end
  echo("\n")
end
local function heading(title, subtitle)
  echo("\n")
  row({"heading", "  COMLINK CRAFTER v" .. M.version .. " | " .. title})
  if subtitle then row({"muted", "  " .. subtitle}) end
end
local function suggest(label, command)
  setFgColor(unpack(palette.accent))
  if type(echoLink) == "function" and type(printCmdLine) == "function" then
    echoLink(label, function() printCmdLine(command) end, "Fill input; review and press Enter: " .. command, true)
  else
    echo(label)
  end
  resetFormat()
end
local function actions(running)
  paint("muted", "  ")
  suggest("mcllist", "mcllist")
  paint("muted", "  ")
  suggest(running and "mclstatus" or "mclstart", running and "mclstatus" or "mclstart")
  paint("muted", "  ")
  suggest(running and "mclstop" or "mcladd", running and "mclstop" or "mcladd ''")
  paint("muted", "  ")
  suggest("mclhelp", "mclhelp")
  echo("\n\n")
end
local function notice(role, label, msg)
  row({"accent", "  MCL "}, {role, label .. "  "}, {"text", msg})
end
local function mclNote(msg)
  notice("success", "+", msg)
end
local function mclErr(msg)
  row({"error", "  MCL Error: "}, {"text", msg})
end
local function mclInfo(msg)
  row({"muted", "  " .. msg})
end

local function validText(value)
  local separator = type(getCommandSeparator) == "function" and (getCommandSeparator() or "") or ""
  return type(value) == "string" and #value <= 512 and value:match("%S")
    and not value:find("[%c;]") and (separator == "" or not value:find(separator, 1, true))
end
local function submit(command)
  if not mclRunning then return false end
  local ok, result, reason
  if validText(command) then ok, result, reason = pcall(send, command) end
  if not ok or result == false or (result == nil and reason ~= nil) then
    mclRunning = false; mclWaitingFor = nil; mclPendingTune = nil
    mclErr("command could not be sent; batch stopped. Check input and connection.")
    return false
  end
  return true
end

-- Extracts a quoted value from the start of str, delimited by either
-- single or double quotes (whichever is used) - so a name containing a
-- literal apostrophe can be wrapped in double quotes instead, and vice versa.
-- Returns value, remainder  OR  nil, nil if not quoted-at-start.
local function takeQuoted(str)
	local val, rest = str:match("^%s*'([^']*)'%s*(.-)$")
	if val then return val, rest end
	val, rest = str:match('^%s*"([^"]*)"%s*(.-)$')
	if val then return val, rest end
	return nil, nil
end

-- Strips a leading &#RRGGBB colour-code prefix (if present) and surrounding
-- punctuation, so words like "&#8a8f98case" or "[tag]" clean up sensibly.
local function cleanWord(word)
	word = word:gsub("^&#%x%x%x%x%x%x", "")
	word = word:gsub("^%p+", ""):gsub("%p+$", "")
	return word
end

-- Picks the first non-filler word out of a container's name to use as its
-- reference keyword. Returns nil if nothing usable was found.
local function deriveContainerKeyword(cname)
	for word in cname:gmatch("%S+") do
		local cleaned = cleanWord(word)
		if cleaned ~= "" then
			local lower = cleaned:lower()
			if not MCL_STOPWORDS[lower] then
				return lower
			end
		end
	end
	return nil
end

-- ===================== mcladd =====================

local function mclAdd(name, line, wildcards)
	local args = wildcards[1]
	if not args or args:match("^%s*$") then
		mclErr("no arguments given.")
		mclInfo("Usage: mcladd '<comlink name>' [<frequency>]")
		return
	end

	local cname, rest = takeQuoted(args)
	if not cname or not cname:match("%S") then
		mclErr("quote a nonempty name: mcladd '<name>' [frequency].")
		mclInfo("Usage: mcladd '<comlink name>' [<frequency>]")
		return
	end

	local tune = nil
	if rest and rest:match("%S") then
		local freq, rest2 = takeQuoted(rest)
		if not freq then
			freq, rest2 = rest:match("^%s*(%S+)%s*(.-)$")
		end
		if rest2 and rest2:match("%S") then
			mclErr("too many arguments. Unexpected extra text after <frequency>: '" .. rest2 .. "'.")
			mclInfo("Usage: mcladd '<comlink name>' [<frequency>]")
			return
		end
		if not freq or not freq:match("%S") then
      mclErr("frequency cannot be empty; omit it for an untuned comlink.")
      return
    end
    tune = freq
	end

	table.insert(mclQueue, {name = cname, tune = tune})
	mclNote("queued comlink #" .. #mclQueue .. ": '" .. cname .. "'" .. (tune and (" (tune to " .. tune .. ")") or " (no tune)"))
end

-- ===================== mclremove =====================

local function mclRemove(name, line, wildcards)
	local args = wildcards[1]
	local idxStr = args and args:match("^%s*(%S+)%s*$")
	local idx = idxStr and tonumber(idxStr)
	if not idx or idx ~= math.floor(idx) then
		mclErr("give the queue number to remove, e.g. mclremove 2. Use mcllist to see numbers.")
		return
	end
	if idx < 1 or idx > #mclQueue then
		mclErr("there is no queued comlink #" .. idxStr .. ". Use mcllist to see the current queue.")
		return
	end
	local removed = table.remove(mclQueue, idx)
	mclNote("removed queued comlink #" .. idx .. ": '" .. removed.name .. "'")
end

-- ===================== mclcontainer =====================

local function mclContainer(name, line, wildcards)
	local args = wildcards[1]
	if not args or args:match("^%s*$") then
		mclErr("no arguments given.")
		mclInfo("Usage: mclcontainer '<container name>' [<keyword>]   OR   mclcontainer clear")
		return
	end

	local trimmed = args:match("^%s*(.-)%s*$")
	if trimmed:lower() == "clear" or trimmed:lower() == "none" then
		mclContainerName = nil
		mclContainerKeyword = nil
		mclNote("container cleared - no container will be crafted, comlinks will just be held.")
		return
	end

	local cname, rest = takeQuoted(args)
	if not cname or not cname:match("%S") then
		mclErr("quote a nonempty name: mclcontainer '<name>' [keyword].")
		mclInfo("Usage: mclcontainer '<container name>' [<keyword>]   OR   mclcontainer clear")
		return
	end

	local keyword
	local autoDetected = false
	if rest and rest:match("%S") then
		local kw, rest2 = rest:match("^%s*(%S+)%s*(.-)$")
		if rest2 and rest2:match("%S") then
			mclErr("too many arguments. <keyword> must be a single word: '" .. rest2 .. "' left over.")
			mclInfo("Usage: mclcontainer '<container name>' [<keyword>]   OR   mclcontainer clear")
			return
		end
		keyword = kw:lower()
	else
		keyword = deriveContainerKeyword(cname)
		autoDetected = true
		if not keyword then
			mclErr("couldn't guess a keyword from that name (it's all filler words). Specify one explicitly: mclcontainer '" .. cname .. "' <keyword>")
			return
		end
	end

	mclContainerName = cname
	mclContainerKeyword = keyword
  row({"success", "  MCL +  "}, {"muted", "Container: "}, {"text", cname})
  row({"muted", "         Target: "}, {"accent", keyword},
    {autoDetected and "warning" or "muted", autoDetected and " (guessed; override if needed)" or " (explicit)"})

end

-- ===================== mcliterations =====================

local function mclIterations(name, line, wildcards)
	local args = wildcards[1]
	local numStr = args and args:match("^%s*(%S+)%s*$")
	local n = numStr and tonumber(numStr)
	if not n or n ~= math.floor(n) or n < 1 or n == math.huge then
		mclErr("<iterations> must be a whole number of at least 1. You gave: '" .. tostring(numStr) .. "'.")
		mclInfo("Usage: mcliterations <n>")
		return
	end
	mclIterationsCount = n
	mclNote("will repeat the batch " .. n .. " time(s).")
end

-- ===================== mcllist =====================

local function mclList(name, line, wildcards)
  heading("QUEUE", #mclQueue .. " design(s) / " .. mclIterationsCount .. " batch(es)")
  row({"muted", "  Status: "}, {mclRunning and "warning" or "success", mclRunning and "RUNNING" or "READY"})
  if #mclQueue == 0 then
    row({"muted", "  (no comlinks queued - use mcladd)"})
  else
    for i, entry in ipairs(mclQueue) do
      local role, state = "muted", "QUEUED"
      if mclRunning then
        if i < mclQueueIndex then role, state = "success", "MADE"
        elseif i == mclQueueIndex then role, state = "warning", "CRAFTING" end
      end
      row({"accent", string.format("  %02d  ", i)}, {"text", entry.name})
      row({"muted", "      "}, {role, state}, {"muted", "  /  "},
        {entry.tune and "frequency" or "muted", entry.tune and ("Tune " .. entry.tune) or "No tuning"})
    end
  end
  echo("\n")
  row({"muted", "  Container: "}, {"text", mclContainerName or "None"})
  if mclContainerName then row({"muted", "  Target:    "}, {"accent", mclContainerKeyword}) end
  row({"muted", "  Iterations: "}, {"accent", tostring(mclIterationsCount)},
    {"muted", "  /  Total: "}, {"text", tostring(#mclQueue * mclIterationsCount) .. " comlinks"})
  if mclRunning then
    row({"muted", "  Item markers describe the current batch."})
  end
  actions(mclRunning)
end

-- ===================== mclclear =====================

local function mclClearCmd(name, line, wildcards)
	if mclRunning then
		mclErr("can't clear while a batch is running. Use mclstop first.")
		return
	end
	mclQueue = {}
	mclContainerName = nil
	mclContainerKeyword = nil
	mclIterationsCount = 1
	mclNote("queue, container, and iteration count all cleared.")
end

-- ===================== mclstart / mclstop / mclstatus =====================

-- Forward declaration since mclCraftNext and mclFinishIteration call each other.
local mclCraftNext
local mclFinishIteration

local function mclStart(name, line, wildcards)
	if mclRunning then
		mclErr("a batch is already running. Use mclstatus to check progress, or mclstop to cancel.")
		return
	end
	if #mclQueue == 0 then
		mclErr("nothing queued. Use mcladd to queue at least one comlink first.")
		return
	end

	mclRunning = true
	mclCurrentIteration = 1
	mclQueueIndex = 1
	mclWaitingFor = nil
	mclPendingTune = nil

	notice("accent", "START", "starting batch: " .. #mclQueue .. " comlink(s) x " .. mclIterationsCount .. " iteration(s).")
	mclCraftNext()
end

local function mclStop(name, line, wildcards)
	if not mclRunning then
		mclErr("nothing is running.")
		return
	end
	mclRunning = false
	mclWaitingFor = nil
	mclPendingTune = nil
	notice("warning", "STOP", "batch stopped. A craft already in progress may still finish; wait for it before starting again.")
end

local function mclStatusCmd(name, line, wildcards)
  if not mclRunning then
    heading("STATUS")
    row({"success", "  READY  "}, {"text", "idle, nothing running."})
    actions(false)
    return
  end
  local made = (mclCurrentIteration - 1) * #mclQueue + math.min(mclQueueIndex - 1, #mclQueue)
  local total = #mclQueue * mclIterationsCount
  local filled = math.floor(made / total * 20)
  heading("PROGRESS", "Batch " .. mclCurrentIteration .. " of " .. mclIterationsCount)
  row({"muted", "  ["}, {"success", string.rep("=", filled)},
    {"muted", string.rep("-", 20 - filled) .. "]  "},
    {"text", made .. "/" .. total .. " comlinks crafted"})
  row({"muted", "  Waiting for: "}, {"warning", mclWaitingFor or "next step"})
  if mclWaitingFor == "comlink" and mclQueue[mclQueueIndex] then
    row({"muted", "  Item:        "}, {"text", mclQueue[mclQueueIndex].name})
    row({"muted", "  Tune:        "}, {"frequency", mclPendingTune or "None"})
  elseif mclWaitingFor == "container" then
    row({"muted", "  Container:   "}, {"text", mclContainerName})
  end
  actions(true)
end

-- ===================== mclhelp =====================

local function mclHelp()
  heading("Commands")
  row({"muted", "  Ported from Ruusm's MUSHclient script."})
  local entries = {
    {"mcladd '<name>' [frequency]", "Queue comlink", "mcladd ''"},
    {"mclremove <number>", "Remove entry", "mclremove "},
    {"mclcontainer '<name>' [keyword]", "Pack each batch", "mclcontainer ''"},
    {"mclcontainer clear", "No container"},
    {"mcliterations <n>", "Batch count", "mcliterations "},
    {"mcllist", "View queue"}, {"mclstart", "Start batches"},
    {"mclstatus", "Progress"}, {"mclstop", "Stop automation"},
    {"mclclear", "Clear settings"}, {"mclhelp", "Commands"},
  }
  for _, entry in ipairs(entries) do
    paint("muted", "  "); suggest(entry[1], entry[3] or entry[1])
    row({"text", "  " .. entry[2]})
  end
  row({"muted", "  Quote names. Click to edit; Enter runs it."})
  row({"muted", "  Settings save locally. mclstart begins from batch 1."})
end

-- ===================== The crafting state machine =====================

mclCraftNext = function()
	if mclQueueIndex > #mclQueue then
		-- Every comlink for this iteration has been made.
		if mclContainerName then
			row({"warning", "  MCL PACK  "}, {"muted", "Batch " .. mclCurrentIteration .. "/" .. mclIterationsCount .. "  "}, {"text", mclContainerName})
			mclWaitingFor = "container"
			submit("makecontainer " .. WEAR_LOCATION .. " " .. mclContainerName)
		else
			mclFinishIteration()
		end
		return
	end

	local entry = mclQueue[mclQueueIndex]
	row({"warning", "  MCL CRAFT "}, {"muted", "Batch " .. mclCurrentIteration .. "/" .. mclIterationsCount .. " | " .. mclQueueIndex .. "/" .. #mclQueue .. "  "}, {"text", entry.name})
	mclWaitingFor = "comlink"
	mclPendingTune = entry.tune
	submit("makecomlink " .. WEAR_LOCATION .. " " .. entry.name)
end

mclFinishIteration = function()
	if mclCurrentIteration >= mclIterationsCount then
		mclRunning = false
		mclWaitingFor = nil
		notice("success", "DONE", "batch complete! Crafted " .. mclIterationsCount .. " set(s) of " .. #mclQueue .. " comlink(s) each.")
	else
		mclCurrentIteration = mclCurrentIteration + 1
		mclQueueIndex = 1
		mclNote("--- starting iteration " .. mclCurrentIteration .. "/" .. mclIterationsCount .. " ---")
		mclCraftNext()
	end
end

local function mclOnComlinkFinished(name, line, wildcards)
	if not mclRunning or mclWaitingFor ~= "comlink" then
		return  -- not something we're waiting on; ignore (e.g. manual crafting outside a batch)
	end

	if mclPendingTune then
		row({"frequency", "  MCL TUNE  "}, {"text", mclPendingTune})
		if not submit("tune " .. COMLINK_KEYWORD .. " " .. mclPendingTune) then return end
	end

	mclQueueIndex = mclQueueIndex + 1
	mclWaitingFor = nil
	mclPendingTune = nil
	mclCraftNext()
end

local function mclOnContainerFinished(name, line, wildcards)
	if not mclRunning or mclWaitingFor ~= "container" then
		return
	end

	notice("accent", "STORE", "Packing " .. #mclQueue .. " comlink(s) into " .. mclContainerKeyword .. ".")
	for i = 1, #mclQueue do
		if not submit("put " .. COMLINK_KEYWORD .. " " .. mclContainerKeyword) then return end
	end

	mclWaitingFor = nil
	mclFinishIteration()
end

-- ===================== Mudlet integration =====================
local settingsFile = getMudletHomeDir() .. "/LotJComlink-settings.lua"

local function saveSettings()
  local settings = {
    queue = mclQueue,
    containerName = mclContainerName,
    containerKeyword = mclContainerKeyword,
    iterations = mclIterationsCount,
  }
  -- table.save returns no value on success, or nil + error on failure.
  local ok, _, err = pcall(table.save, settingsFile .. ".tmp", settings)
  if not ok or err then
    mclErr("could not save settings: " .. tostring(err or _))
    return
  end
  local renamed, renameErr = os.rename(settingsFile .. ".tmp", settingsFile)
  if not renamed then mclErr("could not save settings: " .. tostring(renameErr)) end
end

local function loadSettings()
  local file = io.open(settingsFile, "r")
  if not file then return end
  file:close()
  local settings = {}
  local ok, result, err = pcall(table.load, settingsFile, settings)
  if not ok or result == false or err then
    mclErr("could not load settings: " .. tostring(err or result))
    return
  end
  if type(settings.queue) ~= "table" then
    mclErr("saved queue is invalid; starting with an empty queue.")
    return
  end
  for _, entry in ipairs(settings.queue) do
    if type(entry) ~= "table" or not validText(entry.name)
      or (entry.tune ~= nil and not validText(entry.tune)) then
      mclErr("saved queue is invalid; starting with an empty queue.")
      return
    end
  end
  mclQueue = settings.queue
  if validText(settings.containerName) and validText(settings.containerKeyword)
    and not settings.containerKeyword:find("%s") then
    mclContainerName = settings.containerName
    mclContainerKeyword = settings.containerKeyword
  end
  local n = settings.iterations
  if type(n) == "number" and n >= 1 and n < math.huge and n == math.floor(n) then
    mclIterationsCount = n
  end
end

local commands = {
  mcladd = mclAdd, mclremove = mclRemove, mclcontainer = mclContainer,
  mcliterations = mclIterations, mcllist = mclList, mclclear = mclClearCmd,
  mclstart = mclStart, mclstop = mclStop, mclstatus = mclStatusCmd, mclhelp = mclHelp,
}
local edits = {mcladd=true, mclremove=true, mclcontainer=true, mcliterations=true, mclclear=true}
function M.dispatch(command, args)
  args = args or ""
  if args ~= "" and not validText(args) then
    mclErr("use one line without command separators (maximum 512 characters).")
    return
  end
  if edits[command] and mclRunning then
    mclErr("can't change the batch while it is running. Use mclstop first.")
    return
  end
  local callback = commands[command]
  if not callback then return end
  callback(command, args, {args})
  if edits[command] then saveSettings() end
end
M.mclOnComlinkFinished = mclOnComlinkFinished
M.mclOnContainerFinished = mclOnContainerFinished

function M.shutdown()
  mclRunning = false
  mclWaitingFor = nil
  mclPendingTune = nil
  for _, id in ipairs(handlers) do killAnonymousEventHandler(id) end
  handlers = {}
end

loadSettings()
handlers[#handlers + 1] = registerAnonymousEventHandler("sysDisconnectionEvent", function()
  if mclRunning then
    mclStop()
    mclInfo("MCL: disconnected; the batch will not resume automatically.")
  end
end)
handlers[#handlers + 1] = registerAnonymousEventHandler("sysUninstallPackage", function(_, package)
  if package == "LotJComlink" then
    M.shutdown()
    if LotJComlink == M then LotJComlink = nil end
  end
end)
mclNote("Comlink Crafter v" .. M.version .. " ready. Type mclhelp.")
