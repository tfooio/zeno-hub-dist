-- Relic farming (Joiner tab): craft relics from the game's own recipes, farm the missing ingredients on the best
-- stage the joiner can enter, craft, repeat (docs/features/relics.md). Planning and crafting run in the lobby;
-- a match only asks Relics.want_lobby() so every run ends back in the lobby, where the inventory is readable.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local env = getgenv()
local HttpService = game:GetService("HttpService")
local LP = game:GetService("Players").LocalPlayer

local cfg = Core.config.relics or {}
Core.config.relics = cfg
local defaults = { cap = 5, chains = false, want = {}, tries = {}, running = false }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end
if Hub.mode == "lobby" then cfg.running = false end -- on_join sets it again when this load starts a farm run

local Relics = { status = "off" }

local Items, Levels, Units, Worlds = Game.data("Items"), Game.data("Levels"), Game.data("Units"), Game.data("Worlds")
local CRAFT_UI = "craft_relics_ui" -- second argument of craft_item: the game's relic crafting window
local PRIOR_KILLS = 150 -- enemies killed per run, for ingredients that drop from kills (a 15 wave raid had 196)
local PRIOR_WIN = 0.5 -- win rate assumed for stages the game warns about, until runs say otherwise
local PRIOR_WEIGHT = 2 -- the prior counts as this many runs when blended with the run log

-- Recipes: everything the relic window crafts. Targets are relics no other recipe uses.
local recipe, used = {}, {}
for id, it in Items do
    if it._craft_type == "Relics" and it.crafting_recipe then
        recipe[id] = it
        for ing in it.crafting_recipe do used[ing] = true end
    end
end
local relics = {}
for id, it in recipe do
    if it.item_group == "Relics" and not used[id] then table.insert(relics, id) end
end
table.sort(relics, function(a, b) return Items[a].name < Items[b].name end)
local function isChain(id) -- a relic that eats other relics (the server picks which copies; UNVERIFIED if equipped ones go)
    for ing in recipe[id].crafting_recipe do
        if Items[ing] and Items[ing].item_group == "Relics" then return true end
    end
    return false
end
local function name(id) return Items[id] and Items[id].name or id end

-- Expected amount per clear from one reward group. Weights are the chances; _item_multichoice picks k of them.
-- shortcut: a group of several chance-1 items without _item_multichoice would count as one pick; none holds a relic ingredient.
local function groupYield(g, out)
    if type(g) ~= "table" or type(g.item) ~= "table" then return end
    local mc = g._item_multichoice
    local k = mc and (mc.min + mc.max) / 2 or 1
    local total = 0
    for _, e in g.item do total += e.chance or 0 end
    if total <= 0 then return end
    for _, e in g.item do
        if e.item_id then
            local p = math.min(1, k * (e.chance or 0) / total)
            out[e.item_id] = (out[e.item_id] or 0) + p * ((e.min_amount or 1) + (e.max_amount or 1)) / 2
        end
    end
end
local function rewardYield(lv)
    local out, r = {}, lv.rewards
    if type(r) ~= "table" then return out end
    if r.item then groupYield(r, out) else for _, g in r do groupYield(g, out) end end
    return out
end

-- Per-kill drop chance of an item (enemy kill_rewards, story-type matches).
local kill = {}
for _, u in Units do
    for _, kr in u.kill_rewards or {} do
        local c = kr.item_id and kr.drop_chance and kr.drop_chance.story
        if c and c > (kill[kr.item_id] or 0) then kill[kr.item_id] = c end
    end
end

-- Stages the joiner can enter by pad (legend, raid, story) that drop something a recipe needs.
local needed = {}
for _, r in recipe do for ing in r.crafting_recipe do needed[ing] = true end end
local stages = {}
for _, kind in { "legend", "raid", "story" } do
    for _, wid in Game.worlds(kind) do
        for _, l in Worlds[wid].levels or {} do
            local lv = type(l) == "table" and Levels[l.id]
            if lv and not stages[l.id] and not lv.required_keys then
                local y = rewardYield(lv)
                -- Kill drops are only listed in _show_rewards ("Varies"); the amount is chance x kills.
                for _, sr in lv._show_rewards or {} do
                    local id = sr.type == "item" and sr.params and sr.params.item_id
                    if id and not y[id] and kill[id] then y[id] = kill[id] * PRIOR_KILLS end
                end
                local any = false
                for id in y do if needed[id] then any = true else y[id] = nil end end
                if any then
                    stages[l.id] = {
                        id = l.id, kind = kind, yield = y, limit = lv._raid_daily_tries,
                        win = lv.warning_message and PRIOR_WIN or 1,
                        rank = (tonumber(lv.story_world_rank) or 99) * 1000 + (tonumber(lv.story_level_rank) or 0) * 10 + (tonumber(l.id:match("(%d+)$")) or 0),
                    }
                end
            end
        end
    end
end

-- Real yields from the run log (Data/runs/<user>.jsonl): items gained per run on each stage, losses included.
local learned = {}
do
    local f = Hub.mode == "lobby" and Hub.RunLog and Hub.RunLog.file
    if f and isfile(f) then
        for line in readfile(f):gmatch("[^\n]+") do
            local ok, r = pcall(HttpService.JSONDecode, HttpService, line)
            if ok and type(r) == "table" and stages[r.level] then
                local L = learned[r.level] or { runs = 0, got = {} }
                learned[r.level] = L
                L.runs += 1
                for _, it in r.new_items or {} do
                    if type(it) == "table" and it.item_id then L.got[it.item_id] = (L.got[it.item_id] or 0) + (it.amount or 1) end
                end
            end
        end
    end
end
local function yieldOf(s, id)
    local prior = (s.yield[id] or 0) * s.win
    if prior <= 0 then return 0 end
    local L = learned[s.id]
    if not L then return prior end
    return ((L.got[id] or 0) + prior * PRIOR_WEIGHT) / (L.runs + PRIOR_WEIGHT)
end

local blocked = {} -- stage id -> os.clock() until which the server refused it
local function today() return os.date("!%Y%m%d") end
local function triesLeft(s)
    if not s.limit then return math.huge end
    local t = cfg.tries[s.id]
    return (t and t.day == today()) and s.limit - t.n or s.limit
end
local function eligible()
    local out = {}
    for _, s in stages do
        if (blocked[s.id] or 0) < os.clock() and triesLeft(s) > 0 and Hub.Joiner.unlocked(s.id) then table.insert(out, s) end
    end
    return out
end

local function inventory()
    local ok, svc = pcall(Game.loader().load_client_service, script, "LobbyServiceClient")
    return ok and svc and svc.session and svc.session.inventory or nil
end
local function owned(inv, id)
    local ok, n = pcall(inv.get_number_of_owned_item, inv, id)
    return ok and n or 0
end
local function gold()
    local ok, v = pcall(function() return LP._stats.gold_amount.Value end)
    return ok and v or 0
end

-- Craft `qty` of `id`: ingredients come from stock first (owned relics are never counted, so none is eaten),
-- the rest is crafted from raw materials. `raw` = what still has to be farmed, `steps` = crafts in order.
local function expand(id, qty, have, raw, steps)
    local it = Items[id]
    local take = (it and it.item_group == "Relics") and 0 or math.min(qty, have[id])
    have[id] -= take
    local miss = qty - take
    if miss <= 0 then return end
    if not recipe[id] then raw[id] = (raw[id] or 0) + miss return end
    for ing, n in recipe[id].crafting_recipe do expand(ing, n * miss, have, raw, steps) end
    for _ = 1, miss do table.insert(steps, id) end
end

-- One entry per relic: steps / raw / runs (estimated runs to farm; nil = cannot be finished, see why), best first.
local function evaluate(inv, open)
    local stock = setmetatable({}, { __index = function(t, id) local n = owned(inv, id) t[id] = n return n end })
    local best = {}
    for id in needed do
        for _, s in open do best[id] = math.max(best[id] or 0, yieldOf(s, id)) end
    end
    local g, out = gold(), {}
    for _, id in relics do
        local it = Items[id]
        local c = { id = id, name = it.name }
        table.insert(out, c)
        if next(cfg.want) and not cfg.want[it.name] then c.why = "not selected"
        elseif owned(inv, id) >= cfg.cap then c.why = "owned " .. cfg.cap
        elseif isChain(id) and not cfg.chains then c.why = "relic chain, off"
        else
            local have = setmetatable({}, { __index = stock })
            local raw, steps = {}, {}
            for ing, n in it.crafting_recipe do expand(ing, n, have, raw, steps) end
            table.insert(steps, id)
            c.steps, c.raw = steps, raw
            local cost, runs = 0, 0
            for _, sid in steps do cost += Items[sid].crafting_cost or 0 end
            for rid, miss in raw do
                if (best[rid] or 0) <= 0 then c.why = "no open stage drops " .. name(rid) break end
                runs += miss / best[rid]
            end
            if not c.why and cost > g then c.why = "needs " .. cost .. " gold" end
            if not c.why then c.runs = runs end
        end
    end
    table.sort(out, function(a, b)
        if (a.runs ~= nil) ~= (b.runs ~= nil) then return a.runs ~= nil end
        if a.runs and a.runs ~= b.runs then return a.runs < b.runs end
        return a.name < b.name
    end)
    return out
end

-- Stage for the item that needs the most runs (the bottleneck); ties go to stages that also drop other missing
-- items, then to the lower stage.
local function pickStage(raw, open)
    local bot, botRuns
    for id, miss in raw do
        local b = 0
        for _, s in open do b = math.max(b, yieldOf(s, id)) end
        if b > 0 and (not botRuns or miss / b > botRuns) then bot, botRuns = id, miss / b end
    end
    local pick, pickScore
    for _, s in open do
        local y = yieldOf(s, bot)
        if y > 0 then
            local score = y
            for id, miss in raw do if id ~= bot then score += 0.1 * math.min(yieldOf(s, id), miss) end end
            score = math.floor(score * 100 + 0.5)
            if not pick or score > pickScore or (score == pickScore and s.rank < pick.rank) then pick, pickScore = s, score end
        end
    end
    return pick, bot
end

local function craft(inv, id)
    local before = owned(inv, id)
    local ok, res = pcall(Game.invoke, "craft_item", id, CRAFT_UI)
    for _ = 1, 20 do
        if owned(inv, id) > before then return true end
        task.wait(0.3)
    end
    Core.log("relics: craft not confirmed", id, ok, res)
    return false
end

local statusLabel
local function setStatus(text)
    if text ~= Relics.status then Core.log("relics:", text) end
    Relics.status = text
    if statusLabel then pcall(statusLabel.SetText, statusLabel, text) end
end

local hold = 0
-- Lobby: craft every relic that is complete, then return a joiner plan for the stage to farm next (nil + reason if none).
function Relics.plan()
    if os.clock() < hold then return nil, "craft failed, waiting" end
    local inv = inventory()
    if not inv then return nil, "inventory not loaded" end
    local open = eligible()
    for _ = 1, 40 do
        local c = evaluate(inv, open)[1]
        if not c.runs then setStatus("nothing to farm (" .. c.name .. ": " .. tostring(c.why) .. ")") return nil, c.why end
        if c.runs > 0 then
            local s, item = pickStage(c.raw, open)
            if not s then return nil, "no stage" end
            local lv = Levels[s.id]
            local w = Worlds[lv.world]
            setStatus(("%s: farming %s on %s %s (%.2f/run)"):format(c.name, name(item), w and w.name or "", lv.name or s.id, yieldOf(s, item)))
            return {
                folder = s.kind == "raid" and workspace._RAID.Raid or workspace._LOBBIES.Story,
                level = s.id, diff = s.kind == "story" and "Normal" or "Hard",
                on_join = function()
                    cfg.running = s.id
                    if s.limit then
                        local t = cfg.tries[s.id]
                        if not t or t.day ~= today() then t = { day = today(), n = 0 } cfg.tries[s.id] = t end
                        t.n += 1
                    end
                end,
                on_fail = function() blocked[s.id] = os.clock() + 3600 end,
            }
        end
        for _, sid in c.steps do
            if not craft(inv, sid) then hold = os.clock() + 120 setStatus("craft of " .. name(sid) .. " not confirmed") return nil, "craft failed" end
            Core.log("relics: crafted", name(sid))
        end
        if Hub.UI then Hub.UI.Library:Notify("Relic crafted: " .. c.name, 6) end
    end
    return nil, "craft limit"
end

-- Match: a farm run ends in the lobby, so the inventory is read and the next stage chosen from fresh numbers.
function Relics.want_lobby()
    if Hub.mode ~= "match" or not cfg.running then return false end
    local ok, id = pcall(function() return Game.loader().LevelData.id end)
    return ok and id == cfg.running
end

function Relics.report()
    local inv = inventory()
    if not inv then return { "inventory not loaded (lobby only)" } end
    local out = {}
    for _, c in evaluate(inv, eligible()) do
        table.insert(out, c.runs and ("%s: %s"):format(c.name, c.runs == 0 and "ready to craft" or ("~" .. math.ceil(c.runs) .. " runs")) or (c.name .. ": " .. c.why))
    end
    return out
end

-- UI
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local jcfg = Core.config.joiner
    local box = Tabs.Joiner:AddRightGroupbox("Relic Farm", "gem")
    box:AddToggle("RelicFarm", { Text = "Auto Farm Relics", Tooltip = "Crafts the relic that needs the fewest runs, farms its missing ingredients on the best open stage, crafts, repeats. Needs a macro or Auto Play for those stages and Priority set in Auto Join Setting.", Default = jcfg.relics.enable, Callback = function(v) jcfg.relics.enable = v Core.save_config() end })
    box:AddSlider("RelicCap", { Text = "Max Owned Per Relic", Tooltip = "Stop crafting a relic once you own this many.", Default = cfg.cap, Min = 1, Max = 50, Rounding = 0, Callback = function(v) cfg.cap = v Core.save_config() end })
    box:AddToggle("RelicChains", { Text = "Allow Relic Chains", Tooltip = "Also craft relics made from other relics (Tear Crown). Off by default: the server decides which owned copies are used up.", Default = cfg.chains, Callback = function(v) cfg.chains = v Core.save_config() end })
    local names = {}
    for _, id in relics do table.insert(names, Items[id].name) end
    box:AddDropdown("RelicWant", { Text = "Select Relics", Tooltip = "Relics to farm and craft. None selected = all of them.", Values = names, Multi = true, Default = Core.keys(cfg.want), Callback = function(v) cfg.want = v Core.save_config() end })
    statusLabel = box:AddLabel(Relics.status, true)
    box:AddButton("Show Plan", function()
        local lines = Relics.report()
        Core.log("relics plan:", table.concat(lines, " | "))
        Hub.UI.Library:Notify(table.concat(lines, "\n", 1, math.min(#lines, 8)), 12)
    end)
end

return Relics
