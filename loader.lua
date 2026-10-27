-- Zeno Hub loader (Anime Adventures). Entry point; also what queue_on_teleport re-runs.
-- Dev mode: modules come from workspace "Zeno Hub/Dev/" (mirrored from the repo by tools/sync.ps1,
-- since the executor cannot read outside workspace).
local LOBBY_PLACE = 8304191830
-- Failsafe for Roblox's own loading hanging: no module would ever run, so this one lives here (fixed 60 s,
-- no config read yet). The in-game Loading screen has its own, configurable one in match.lua.
task.spawn(function()
    task.wait(60)
    if not game:IsLoaded() then pcall(function() game:GetService("TeleportService"):Teleport(LOBBY_PLACE) end) end
end)
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
while not Players.LocalPlayer do task.wait() end

local DEV_DIR = "Zeno Hub/Dev/"
-- shortcut: no hosted build yet, set this when the repo is served somewhere reachable by HttpGet.
local BASE_URL = "https://raw.githubusercontent.com/tfooio/zeno-hub-dist/main/"

local env = getgenv()
if env.ZenoHub and env.ZenoHub.unload then pcall(env.ZenoHub.unload) end

-- getgenv().ZenoForceHosted = true before running makes a machine that has Dev files load the hosted build
-- (how the friend's setup is tested without moving the Dev folder).
local DEV = not env.ZenoForceHosted and isfile(DEV_DIR .. "loader.lua")
assert(DEV or BASE_URL, "Zeno Hub: no dev files and no BASE_URL")

local Hub = {
    dev = DEV,
    mode = game.PlaceId == LOBBY_PLACE and "lobby" or "match",
    connections = {},
}
env.ZenoHub = Hub

function Hub.require(name)
    local path = "src/" .. name .. ".lua"
    local src = DEV and readfile(DEV_DIR .. path) or game:HttpGet(BASE_URL .. path)
    local fn = assert(loadstring(src, "=Zeno/" .. path))
    return fn(Hub)
end

function Hub.unload()
    for _, c in Hub.connections do pcall(function() c:Disconnect() end) end
    if Hub.Core then Hub.Core.save_config() end
    if Hub.UI and Hub.UI.Library and not Hub.UI.Library.Unloaded then Hub.UI.Library:Unload() end
    if env.ZenoHub == Hub then env.ZenoHub = nil end
end

-- Queue first so a teleport during module load still re-injects. The executor keeps every queued
-- string (one per reload), so the queued code boots only once per server.
local qot = queue_on_teleport or (syn and syn.queue_on_teleport)
if qot and not env.ZenoHubQueued then
    env.ZenoHubQueued = true
    local boot = DEV and ('loadstring(readfile(%q))()'):format(DEV_DIR .. "loader.lua")
        or ('loadstring(game:HttpGet(%q))()'):format(BASE_URL .. "loader.lua")
    qot("if getgenv().ZenoHubBooted then return end getgenv().ZenoHubBooted = true " .. boot)
end

-- Re-run the loader (after a config import or reset) so every module reads the new hub.json.
function Hub.reload()
    local src = DEV and readfile(DEV_DIR .. "loader.lua") or game:HttpGet(BASE_URL .. "loader.lua")
    Hub.unload()
    task.defer(function() loadstring(src)() end)
end

Hub.Core = Hub.require("core")
Hub.Game = Hub.require("game")
-- Dev mirror version stamp written by tools/sync.ps1 (commit, uncommitted count, sync time).
local version = ""
if DEV then
    local vok, v = pcall(readfile, DEV_DIR .. "VERSION.txt")
    if vok then version = v:match("%S[^%c]*") or "" end
end
Hub.version = version
Hub.Core.log("loaded", Hub.mode, "place", game.PlaceId, DEV and "dev" or "hosted", version)

local ok, err = pcall(function() Hub.UI = Hub.require("ui") end)
if not ok then Hub.Core.log("ERROR ui:", err) end

ok, err = pcall(function() Hub.RunLog = Hub.require("runlog") end)
if not ok then Hub.Core.log("ERROR runlog:", err) end

ok, err = pcall(function() Hub.Webhook = Hub.require("webhook") end)
if not ok then Hub.Core.log("ERROR webhook:", err) end

ok, err = pcall(function() Hub.Match = Hub.require("match") end)
if not ok then Hub.Core.log("ERROR match:", err) end

ok, err = xpcall(function() Hub.Macro = Hub.require("macro") end, debug.traceback)
if not ok then Hub.Core.log("ERROR macro:", err) end

ok, err = xpcall(function() Hub.Dungeon = Hub.require("dungeon") end, debug.traceback)
if not ok then Hub.Core.log("ERROR dungeon:", err) end

ok, err = xpcall(function() Hub.Joiner = Hub.require("joiner") end, debug.traceback)
if not ok then Hub.Core.log("ERROR joiner:", err) end

ok, err = xpcall(function() Hub.Gameplay = Hub.require("gameplay") end, debug.traceback)
if not ok then Hub.Core.log("ERROR gameplay:", err) end

ok, err = xpcall(function() Hub.Abilities = Hub.require("abilities") end, debug.traceback)
if not ok then Hub.Core.log("ERROR abilities:", err) end

ok, err = xpcall(function() Hub.AutoPlay = Hub.require("autoplay") end, debug.traceback)
if not ok then Hub.Core.log("ERROR autoplay:", err) end

ok, err = xpcall(function() Hub.Lobby = Hub.require("lobby") end, debug.traceback)
if not ok then Hub.Core.log("ERROR lobby:", err) end

ok, err = xpcall(function() Hub.Party = Hub.require("party") end, debug.traceback)
if not ok then Hub.Core.log("ERROR party:", err) end

ok, err = xpcall(function() Hub.Misc = Hub.require("misc") end, debug.traceback)
if not ok then Hub.Core.log("ERROR misc:", err) end

return Hub
