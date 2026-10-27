-- Joiners (Joiner tab): World, Legend, Raid, Challenge, Daily Challenge from lobby pads (docs/features/joiners.md).
-- Options live in Core.config.joiner (hub.json) so they apply after every teleport back to the lobby.
-- Pads only (solo, friendsOnly); no matchmaking (it has a captcha path we do not touch).
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local env = getgenv()

local cfg = Core.config.joiner or {}
Core.config.joiner = cfg
local defaults = {
    cooldown = 5,
    order = { "Challenge", "Daily Challenge", "Raid", "Legend", "Infinity Mansion", "World" },
    world = { enable = false, world = nil, act = "Act 1", hard = false, highest = false },
    legend = { enable = false, world = nil, stage = "Stage 1" },
    raid = { enable = false, world = nil, level = "Level 1" },
    challenge = { enable = false, rewards = {}, done = nil },
    daily = { enable = false, done = nil },
    mansion = { enable = false, hard = false },
}
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

local Joiner = {}
local function alive() return env.ZenoHub == Hub end

local Worlds, Levels = Game.data("Worlds"), Game.data("Levels")
local function prog() return Game.loader().load_core_service(script, "ProgressionServiceCore") end
-- check_if_unlocked_* take profile_data.level_data (verified 2026-10-23).
local function unlocked(levelId)
    local pd = Game.profile()
    local ok, res = pcall(prog().check_if_unlocked_level, pd and pd.level_data, levelId)
    return ok and res == true
end

-- Display name -> world id per kind, and the names in in-game order (Game.worlds).
local kinds, ordered = {}, {}
for _, kind in { "story", "legend", "raid" } do
    kinds[kind], ordered[kind] = {}, {}
    for _, id in Game.worlds(kind) do
        local n = Worlds[id].name
        if not kinds[kind][n] then kinds[kind][n] = id table.insert(ordered[kind], n) end
    end
end
local function names(kind) return table.clone(ordered[kind]) end
-- Worlds[id].levels is keyed "1", "2" ... with { id = levelId } values.
local function levelOf(worldId, label)
    local l = Worlds[worldId].levels[tostring(tonumber(label:match("%d+")))]
    return l and l.id
end

-- Highest unlocked story level by the game's own ranks.
local function highest()
    local best, bw, bl
    for id, l in Levels do
        local w, r = tonumber(l.story_world_rank), tonumber(l.story_level_rank)
        if w and r and kinds.story[Worlds[l.world] and Worlds[l.world].name or ""] and unlocked(id)
            and (not bw or w > bw or (w == bw and r > bl)) then
            best, bw, bl = id, w, r
        end
    end
    return best
end

local function freePad(folder)
    for _, p in folder:GetChildren() do
        if p:FindFirstChild("Owner") and p.Owner.Value == nil and not (p:FindFirstChild("Teleporting") and p.Teleporting.Value) then return p end
    end
end

local function rewardItems(c)
    local out = {}
    for _, r in (c and c.current_reward and c.current_reward._show_rewards) or {} do
        if r.type == "item" and r.params then out[r.params.item_id] = true end
    end
    return out
end

-- Each returns { pad folder, level id (nil = pad preset by the server), difficulty, tag } or nil + reason.
local modes = {}
function modes.challenge()
    local c = Game.invoke("get_normal_challenge")
    if not c then return nil, "no challenge" end
    -- shortcut: a challenge is tried once per uuid (win or loss); a retry option can come later.
    if cfg.challenge.done == c.current_uuid then return nil, "done" end
    local items, want = rewardItems(c), cfg.challenge.rewards
    if next(want) then
        local hit = false
        for id in want do if items[id] then hit = true end end
        if not hit then return nil, "reward not wanted" end
    end
    return { folder = workspace._CHALLENGES.Challenges, tag = c.current_uuid }
end
function modes.daily()
    local c = Game.invoke("get_daily_challenge")
    local tag = c and c.current_level and c.current_level._override_random_seed
    if not tag then return nil, "no daily" end
    if cfg.daily.done == tag then return nil, "done" end
    return { folder = workspace._CHALLENGES.DailyChallenge, tag = tag }
end
function modes.raid()
    local wid = kinds.raid[cfg.raid.world or ""]
    if not wid then return nil, "no world" end
    local lv = levelOf(wid, cfg.raid.level)
    if not lv or not unlocked(lv) then return nil, "locked" end
    return { folder = workspace._RAID.Raid, level = lv, diff = "Hard" }
end
function modes.legend()
    local wid = kinds.legend[cfg.legend.world or ""]
    if not wid then return nil, "no world" end
    local lv = levelOf(wid, cfg.legend.stage)
    if not lv or not unlocked(lv) then return nil, "locked" end
    return { folder = workspace._LOBBIES.Story, level = lv, diff = "Hard" }
end
function modes.world()
    local w = cfg.world
    local lv
    if w.highest then
        lv = highest()
    else
        local wid = kinds.story[w.world or ""]
        if not wid then return nil, "no world" end
        if w.act == "Infinite" then
            lv = Worlds[wid].infinite and Worlds[wid].infinite.id
        else
            lv = levelOf(wid, w.act)
        end
    end
    if not lv or not unlocked(lv) then return nil, "locked" end
    local diff = "Normal"
    -- Infinite is Hard only (the game's picker hides Normal for it; Normal is refused).
    if (Levels[lv] and Levels[lv].infinite) or lv:find("_infinite$") then diff = "Hard"
    elseif w.hard then
        local pd = Game.profile()
        local ok, res = pcall(prog().check_if_unlocked_difficulty, pd and pd.level_data, lv, "Hard")
        if ok and res then diff = "Hard" end
    end
    return { folder = workspace._LOBBIES.Story, level = lv, diff = diff }
end

-- No pad: the game's own start button calls request_start_infinite_tower(floor, difficulty) (decompiled).
function modes.mansion()
    local pd = Game.profile()
    local t = pd and pd.level_data and pd.level_data.infinite_tower
    return { direct = { "request_start_infinite_tower", t and t.floor_reached or 1, cfg.mansion.hard and "Hard" or "Normal" } }
end

-- Dungeon Run (src/dungeon.lua): resolves shop / shrine / chest / death, then the room to enter.
function modes.dungeon()
    if not Hub.Dungeon then return nil, "no dungeon module" end
    local room, why = Hub.Dungeon.next_room()
    if not room then return nil, why end
    return { direct = { "dungeon_enter_room", room } }
end

-- UI name -> mode key; cfg.order is the user's priority (first = tried first).
local MODES = { World = "world", Legend = "legend", Raid = "raid", ["Infinity Mansion"] = "mansion", Challenge = "challenge", ["Daily Challenge"] = "daily", ["Dungeon Run"] = "dungeon" }
local MODE_NAMES = { "World", "Legend", "Raid", "Infinity Mansion", "Challenge", "Daily Challenge", "Dungeon Run" }
-- A mode missing from the saved order (new mode, or a cleared slot) goes to the end, so it still runs.
for _, n in MODE_NAMES do
    if not table.find(cfg.order, n) then
        local gap = table.find(cfg.order, false)
        if gap then cfg.order[gap] = n else table.insert(cfg.order, n) end
    end
end
local function order()
    local out, seen = {}, {}
    for _, n in cfg.order do
        if MODES[n] and not seen[n] then seen[n] = true table.insert(out, MODES[n]) end
    end
    return out
end
local backoff = {} -- mode -> os.clock() before which it is not retried

local function try(mode)
    local ok, plan, why = pcall(modes[mode])
    if not ok then Core.log("ERROR joiner", mode, plan) return false end
    if not plan then return false, why end
    if plan.direct then
        Core.log("joiner", mode, table.unpack(plan.direct, 2))
        Core.save_config()
        local ok2, err = pcall(Game.invoke, table.unpack(plan.direct))
        if not ok2 then Core.log("ERROR joiner", mode, err) end
        task.wait(20)
        if alive() then Core.log("joiner: no teleport after start", mode) end
        return true
    end
    local pad = freePad(plan.folder)
    if not pad then return false, "no free pad" end
    Core.log("joiner", mode, plan.level or pad.Level.Value, plan.diff or "", pad.Name)
    if Game.invoke("request_join_lobby", pad.Name) ~= true then Core.log("joiner: join refused", mode, pad.Name) return false end
    if plan.level and Game.invoke("request_lock_level", pad.Name, plan.level, true, plan.diff) ~= true then
        Core.log("joiner: lock refused", mode, plan.level)
        Game.invoke("request_leave_lobby", pad.Name)
        return false
    end
    if plan.tag then cfg[mode].done = plan.tag end
    Core.save_config() -- before the teleport (OnTeleport does not fire)
    -- Pads preset by the server (challenge, daily) ignore request_start_game and start when their timer ends.
    if plan.level then
        task.wait(1)
        -- Party farming, Host Mode: wait for the listed players to be on the pad first.
        if Hub.Party then pcall(Hub.Party.wait_for_party, pad) end
        Game.invoke("request_start_game", pad.Name)
    end
    -- Still here after that: the start did not take; free the pad and let the next mode try.
    task.wait(plan.level and 20 or 90)
    if alive() then
        Core.log("joiner: no teleport after start", mode, pad.Name)
        pcall(Game.invoke, "request_leave_lobby", pad.Name)
        if plan.tag then cfg[mode].done = nil end
    end
    return true
end

if Hub.mode == "lobby" then
    task.spawn(function()
        task.wait(cfg.cooldown)
        while alive() do
            for _, mode in order() do
                -- Party farming, Follow Host: this account joins the host's pad instead of making its own.
                if Hub.Party and Hub.Party.following() then break end
                if cfg[mode].enable and (backoff[mode] or 0) < os.clock() then
                    local started = try(mode)
                    if started then backoff[mode] = os.clock() + 60 break end
                end
            end
            task.wait(3)
        end
    end)
end

-- UI
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local function set(t, key) return function(v) t[key] = v Core.save_config() end end
    local function multi(t, key) return function(v) t[key] = v Core.save_config() end end
    local T = Tabs.Joiner

    local setting = T:AddLeftGroupbox("Auto Join Setting", "settings-2")
    setting:AddSlider("JoinCooldown", { Text = "Joiner Cooldown (second)", Tooltip = "Wait in the lobby before joining.", Default = cfg.cooldown, Min = 0, Max = 60, Rounding = 0, Callback = set(cfg, "cooldown") })
    setting:AddLabel("Priority: when several joiners are on, the first available one in this order is joined.", true)
    for i = 1, #MODE_NAMES do
        setting:AddDropdown("JoinPriority" .. i, { Text = "Priority " .. i, Values = MODE_NAMES, Default = cfg.order[i], AllowNull = true, Callback = function(v)
            cfg.order[i] = v or false -- false keeps the list's length; order() skips it
            Core.save_config()
        end })
    end

    local world = T:AddLeftGroupbox("World Joiner", "globe")
    world:AddToggle("JoinWorld", { Text = "Auto Join World", Default = cfg.world.enable, Callback = set(cfg.world, "enable") })
    world:AddDropdown("JoinWorldWorld", { Text = "Select World", Values = names("story"), Default = cfg.world.world, AllowNull = true, Callback = set(cfg.world, "world") })
    world:AddDropdown("JoinWorldAct", { Text = "Select Act", Values = { "Act 1", "Act 2", "Act 3", "Act 4", "Act 5", "Act 6", "Infinite" }, Default = cfg.world.act, Callback = set(cfg.world, "act") })
    world:AddToggle("JoinWorldHard", { Text = "Hard Mode", Default = cfg.world.hard, Callback = set(cfg.world, "hard") })
    world:AddToggle("JoinWorldHighest", { Text = "Join Highest", Tooltip = "Furthest unlocked story act; ignores Select World / Act.", Default = cfg.world.highest, Callback = set(cfg.world, "highest") })

    local legend = T:AddLeftGroupbox("Legend Joiner", "crown")
    legend:AddToggle("JoinLegend", { Text = "Auto Join Legend", Default = cfg.legend.enable, Callback = set(cfg.legend, "enable") })
    legend:AddDropdown("JoinLegendWorld", { Text = "Select World", Values = names("legend"), Default = cfg.legend.world, AllowNull = true, Callback = set(cfg.legend, "world") })
    legend:AddDropdown("JoinLegendStage", { Text = "Select Stage", Values = { "Stage 1", "Stage 2", "Stage 3", "Stage 4", "Stage 5", "Stage 6" }, Default = cfg.legend.stage, Callback = set(cfg.legend, "stage") })

    local raid = T:AddRightGroupbox("Raid Joiner", "swords")
    raid:AddToggle("JoinRaid", { Text = "Auto Join Raid", Default = cfg.raid.enable, Callback = set(cfg.raid, "enable") })
    raid:AddDropdown("JoinRaidWorld", { Text = "Select World", Values = names("raid"), Default = cfg.raid.world, AllowNull = true, Callback = set(cfg.raid, "world") })
    raid:AddDropdown("JoinRaidLevel", { Text = "Select Level", Values = { "Level 1", "Level 2", "Level 3", "Level 4", "Level 5" }, Default = cfg.raid.level, Callback = set(cfg.raid, "level") })

    local REWARDS = { "StarFruit", "StarFruitGreen", "StarFruitRed", "StarFruitPink", "StarFruitBlue", "StarFruitEpic", "star_remnant" }
    local chal = T:AddRightGroupbox("Challenge Joiner", "trophy")
    chal:AddToggle("JoinChallenge", { Text = "Auto Join Challenge", Default = cfg.challenge.enable, Callback = set(cfg.challenge, "enable") })
    chal:AddDropdown("JoinChallengeReward", { Text = "Select Reward", Tooltip = "Join only if the current challenge gives one of these. None selected = any. StarFruitEpic = Rainbow.", Values = REWARDS, Multi = true, Default = Core.keys(cfg.challenge.rewards), Callback = multi(cfg.challenge, "rewards") })

    local mansion = T:AddRightGroupbox("Infinity Mansion Joiner", "castle")
    mansion:AddToggle("JoinMansion", { Text = "Auto Join Infinity Mansion", Tooltip = "Starts the highest room reached.", Default = cfg.mansion.enable, Callback = set(cfg.mansion, "enable") })
    mansion:AddToggle("JoinMansionHard", { Text = "Hard Mode", Default = cfg.mansion.hard, Callback = set(cfg.mansion, "hard") })

    local daily = T:AddRightGroupbox("Daily Challenge Joiner", "calendar")
    daily:AddToggle("JoinDaily", { Text = "Auto Join Daily Challenge", Tooltip = "Solo, from the daily pad (no matchmaking).", Default = cfg.daily.enable, Callback = set(cfg.daily, "enable") })
end

Joiner.modes, Joiner.highest = modes, highest
return Joiner
