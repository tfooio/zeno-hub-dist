-- Run log: one JSON line per match in Data/runs/<UserName>.jsonl, built from game_finished; emits run_finished.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local HttpService = game:GetService("HttpService")
local user = game:GetService("Players").LocalPlayer.Name

local RunLog = {}
local dir = Core.paths.data .. "/runs"
if not isfolder(dir) then makefolder(dir) end
RunLog.file = ("%s/%s.jsonl"):format(dir, user)

-- Drop payload shapes are not verified; keep them as sent, minus anything JSON cannot hold (Instances, functions).
local function plain(v, depth)
    local t = type(v)
    if t == "number" or t == "string" or t == "boolean" then return v end
    if v == nil then return nil end
    if t ~= "table" or depth > 6 then return tostring(v) end
    local out = {}
    -- keep number keys so lists stay JSON arrays
    for k, x in v do out[type(k) == "number" and k or tostring(k)] = plain(x, depth + 1) end
    return out
end

function RunLog.record(result)
    local stats = result.stats or {}
    local ok, ld = pcall(function() return Game.loader().LevelData end)
    ld = ok and ld or {}
    local sok, stage = pcall(Game.stage, ld)
    return {
        stage = sok and stage or nil, -- Story, Raid, Challenge ... (Game.stage)
        date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        user = user,
        mode = ld._gamemode,
        map = ld.map,
        level = ld.id,
        name = ld.name,
        difficulty = ld._difficulty,
        victory = result.victory == true,
        waves = stats.waves_completed,
        num_waves = stats.num_waves,
        time = stats.time_taken,
        kills = stats.kills,
        damage = stats.damage_dealt,
        gems = result.gem_reward,
        gold = result.gold_reward,
        xp = result.xp_reward,
        resources = plain(result.resource_reward, 0),
        new_units = plain(result.new_units, 0),
        new_items = plain(result.new_items, 0),
        first_completion = result.first_completion,
    }
end

local unsub = Core.on("game_finished", function(result)
    if type(result) ~= "table" then return Core.log("runlog: game_finished without a table") end
    local rec = RunLog.record(result)
    local line = HttpService:JSONEncode(rec) .. "\n"
    if isfile(RunLog.file) then appendfile(RunLog.file, line) else writefile(RunLog.file, line) end
    Core.log("runlog:", rec.level, rec.victory and "win" or "loss", "waves", rec.waves)
    Core.emit("run_finished", rec)
end)
table.insert(Hub.connections, { Disconnect = unsub })

return RunLog
