-- Game: read access to verified game data and remotes (docs/remotes.md). No actions are taken here.
local Hub = ...
local RS = game:GetService("ReplicatedStorage")
local LP = game:GetService("Players").LocalPlayer

local Game = {}

local Loader
-- Right after a teleport the game's own scripts have not required Loader yet; requiring it first
-- from our thread fails ("Cannot require a non-RobloxScript module"), so retry for up to 30 s.
function Game.loader()
    for _ = 1, 30 do
        if Loader then break end
        local ok, res = pcall(require, RS:WaitForChild("src"):WaitForChild("Loader"))
        if ok then Loader = res else task.wait(1) end
    end
    return assert(Loader, "Loader not available")
end

-- Units, Levels, Worlds, Maps, Items, Traits, Buffs, ...
-- Same early-teleport require error as Game.loader for data modules the game has not loaded yet.
function Game.data(name)
    local L = Game.loader()
    for _ = 1, 29 do
        local ok, res = pcall(L.load_data, script, name)
        if ok then return res end
        task.wait(1)
    end
    return L.load_data(script, name)
end

-- World ids of a kind ("story", "legend", "raid") in the in-game order (WorldLevelOrder, the same lists
-- Nousigi shows); worlds missing from it go last, A to Z by display name.
local ORDER_LISTS = { story = "WORLD_ORDER", legend = "LEGEND_WORLD_ORDER", raid = "RAID_WORLD_ORDER" }
function Game.world_kind(w)
    return w.legend_stage and "legend" or w.raid_world and "raid" or (w.levels and w.levels["1"] and "story") or nil
end
function Game.worlds(kind)
    local Worlds = Game.data("Worlds")
    local out, seen = {}, {}
    local ok, lists = pcall(Game.data, "WorldLevelOrder")
    for _, id in ok and lists[ORDER_LISTS[kind]] or {} do
        if Worlds[id] and Game.world_kind(Worlds[id]) == kind and not seen[id] then seen[id] = true table.insert(out, id) end
    end
    local rest = {}
    for id, w in Worlds do if not seen[id] and Game.world_kind(w) == kind then table.insert(rest, id) end end
    table.sort(rest, function(a, b) return Worlds[a].name < Worlds[b].name end)
    for _, id in rest do table.insert(out, id) end
    return out
end

-- Stage type (Nousigi's list) and map display name of a match's LevelData.
-- Verified: Story, Legend, Raid, Challenge, Daily Challenge, Infinity Mansion. From flags only (UNVERIFIED):
-- Infinite (id suffix), Portal, Assassin Contract, Dungeon Run.
Game.STAGE_TYPES = { "Story", "Infinite", "Legend", "Raid", "Infinity Mansion", "Challenge", "Daily Challenge", "Portal", "Assassin Contract", "Dungeon Run", "Event" }
function Game.stage(ld)
    if not ld then return end
    local Worlds, Maps = Game.data("Worlds"), Game.data("Maps")
    local w = ld.world and Worlds[ld.world]
    local mapName = Maps[ld.map or ""] and Maps[ld.map].name or ld._location_name
    local id = tostring(ld.id or "")
    if id == "__DAILY_CHALLENGE" then return "Daily Challenge", mapName end
    if ld._gamemode == "infinite_tower" then return "Infinity Mansion", mapName end
    if ld._gamemode == "challenge" then return "Challenge", w and w.name or mapName end
    if ld._event_contract then return "Assassin Contract", mapName end
    if ld._dungeon then return "Dungeon Run", mapName end
    if ld._is_map_or_portal_level then return "Portal", mapName end
    if w and w.legend_stage then return "Legend", w.name end
    if w and w.raid_world then return "Raid", w.name end
    if w then return id:find("_infinite$") and "Infinite" or "Story", w.name end
    -- No world: the current event (verified: april2_event, _gamemode "raid", Future City).
    return "Event", mapName
end

function Game.profile()
    local ok, svc = pcall(Game.loader().load_client_service, script, "LobbyServiceClient")
    return ok and svc and svc.session and svc.session.profile_data or nil
end

function Game.remote(name)
    -- Endpoints replicate a moment after the match place loads.
    return RS:WaitForChild("endpoints"):WaitForChild("client_to_server"):WaitForChild(name, 30)
end

function Game.invoke(name, ...)
    return Game.remote(name):InvokeServer(...)
end

local function value(parent, name)
    local v = parent and parent:FindFirstChild(name)
    return v and v.Value
end

-- Match-only values are nil in the lobby.
function Game.state()
    local base = workspace:FindFirstChild("_BASES")
    local hum = base and base:FindFirstChild("player") and base.player:FindFirstChild("base")
        and base.player.base:FindFirstChild("fake_unit") and base.player.base.fake_unit:FindFirstChild("Humanoid")
    local level = Hub.mode == "match" and Game.loader().LevelData
    return {
        money = value(LP:FindFirstChild("_stats"), "resource"),
        wave = value(workspace, "_wave_num"),
        wave_time = value(workspace, "_wave_time"),
        last_wave = value(workspace, "_is_last_wave"),
        hp = hum and hum.Health,
        max_hp = hum and hum.MaxHealth,
        level = level and level.id,
    }
end

return Game
