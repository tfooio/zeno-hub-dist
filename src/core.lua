-- Core: folders, file log, per-account JSON config, event bus.
local Hub = ...
local HttpService = game:GetService("HttpService")
local user = game:GetService("Players").LocalPlayer.Name

local Core = {}

local ROOT = "Zeno Hub"
Core.paths = {
    root = ROOT,
    macro = ROOT .. "/Macro/AnimeAdventures",
    config = ROOT .. "/Config/" .. user,
    data = ROOT .. "/Data",
    logs = ROOT .. "/Logs",
}
-- makefolder is not always recursive, so build one level at a time.
for _, p in { ROOT, ROOT .. "/Macro", Core.paths.macro, ROOT .. "/Config", Core.paths.config, Core.paths.data, Core.paths.logs } do
    if not isfolder(p) then makefolder(p) end
end

-- Log: one file per account per day (several accounts can run at once).
local logFile = ("%s/%s_%s.log"):format(Core.paths.logs, user, os.date("%Y-%m-%d"))
function Core.log(...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    local line = ("[%s] [%s] %s\n"):format(os.date("%H:%M:%S"), Hub.mode, table.concat(parts, " ", 1, parts.n))
    if not pcall(appendfile, logFile, line) then pcall(writefile, logFile, line) end
end

-- Config: hub state that is not a UI option (UI options go through Obsidian's SaveManager).
local configFile = Core.paths.config .. "/hub.json"
Core.config = {}
if isfile(configFile) then
    local ok, data = pcall(HttpService.JSONDecode, HttpService, readfile(configFile))
    if ok and type(data) == "table" then Core.config = data else Core.log("config unreadable, starting empty") end
end
function Core.save_config()
    local ok, err = pcall(function() writefile(configFile, HttpService:JSONEncode(Core.config)) end)
    if not ok then Core.log("ERROR save_config:", err) end
end
if not isfile(configFile) then Core.save_config() end

-- Event bus: on() returns an unsubscribe function; handler errors are logged, not raised.
local handlers = {}
function Core.on(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
    return function()
        local i = table.find(handlers[name], fn)
        if i then table.remove(handlers[name], i) end
    end
end
function Core.emit(name, ...)
    for _, fn in table.clone(handlers[name] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then Core.log("ERROR event", name, err) end
    end
end

-- Keys of a set ({name = true}) as a list: multi-select dropdowns store sets but take a list as Default.
function Core.keys(set)
    local out = {}
    for k, v in set or {} do if v then table.insert(out, k) end end
    return out
end

return Core
