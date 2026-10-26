-- Dungeon Run (Joiner tab): start, pick rooms, shop, shrine, chests, death (docs/features/dungeon.md).
-- No pad: everything is remotes on profile_data.dungeon_data. Options live in Core.config.joiner.dungeon
-- (hub.json) so they survive teleports. Lobby: the joiner calls Dungeon.next_room(). Match: after
-- game_finished this module resolves the room's shop/shrine/chest and enters the next room itself.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local env = getgenv()

local function alive() return env.ZenoHub == Hub end

-- Room order is the user's (2026-10-25: chests and shrines first), best first; shop, shrine and curse lists are the friend's.
-- "Open Chest" (6) and "Final Boss" (5) are not choices: every room offered at depths 5, 10 and 15 carries Open Chest, and depth 20 is the boss room alone.
-- They stay in the dropdowns but are left out of the order, where they would only rank the same flag in every room.
local ROOM_DEFAULT = { "3", "4", "7", "1", "2", "0" }
local ROOM_LABEL = { ["5"] = "Final Boss", ["6"] = "Open Chest", ["3"] = "Rare Chest", ["1"] = "Shop", ["7"] = "Shrine", ["4"] = "Chest", ["2"] = "Hoard", ["0"] = "Curse" }
local BUY_ORDER = { "gold_branch", "gold_mask", "gold_shroom", "genie_lamp", "tome", "belt", "mage_coat", "hook", "hook2", "icebane",
    "hammer_legendary", "moon_fragment", "philospher_stone", "scythe", "stormbringer", "sword1", "sword2", "sword3", "boots", "bow3",
    "bow_legendary", "celestial_blade", "chest_mock_item", "cloak", "bow1", "bow2", "deathcap", "fire_axe", "frost_axe" }
local DECLINE_DEFAULT = { "_curse_super_health", "_curse_speed", "_curse_super_burst", "_curse_regen", "_curse_super_regen", "_curse_random", "_curse_fly" }
local function set(list) local s = {} for _, v in list do s[v] = true end return s end

local joiner = Core.config.joiner or {}
Core.config.joiner = joiner
local cfg = joiner.dungeon or {}
joiner.dungeon = cfg
local defaults = { enable = false, start = false, shrine = false, chest_depth = 20, chest_end = true, rooms = ROOM_DEFAULT, buy = set(BUY_ORDER), buy_order = BUY_ORDER, decline = set(DECLINE_DEFAULT), preset = "Balanced", room_preset = "Chests & Shrines" }
for k, v in defaults do if cfg[k] == nil then cfg[k] = type(v) == "table" and table.clone(v) or v end end


-- Run presets: `focus` is bought first (in this order), then the friend's order; `ignore` is never bought.
-- Item effects are read from DungeonServiceCore.ITEMS (see the Dungeon Info tab).
local PRESETS = {
    { name = "Magic + Big Items (only)", only = true, focus = { "philospher_stone", "deathcap", "celestial_blade", "stormbringer", "tome", "mage_coat", "genie_lamp", "moon_fragment", "gold_mask", "bow_legendary" }, ignore = {}, note = "Buys only these, in this order: Philosopher's Stone (all chests rare), Archmage's Hat, Celestial Blade, Stormbringer, Magic Tome, Mage Coat, Genie Lamp, Moon Fragment, Mask of Riches, Sylvanthorn. Skips every small item and the physical-only ones." },
    { name = "Balanced", focus = {}, ignore = { "axe", "axe_legendary" }, note = "The friend's order: cheaper units, chest luck, magic damage and attack speed first." },
    { name = "Damage - Physical", focus = { "hammer_legendary", "celestial_blade", "fire_axe", "sword3", "sword2", "sword1", "axe_legendary", "axe", "scythe" }, ignore = { "tome", "deathcap", "mage_coat" }, note = "Physical and all-damage items first (Aureus Maul, Celestial Blade, Headsplitter, swords, crit axes, Reaper Scythe). Skips magic-only items." },
    { name = "Damage - Magic", focus = { "deathcap", "celestial_blade", "tome", "mage_coat", "sword3", "sword2", "sword1", "scythe" }, ignore = { "fire_axe", "hammer_legendary", "axe", "axe_legendary" }, note = "Magic and all-damage items first (Archmage's Hat, Celestial Blade, Magic Tome, Mage Coat, swords). Skips physical-only items." },
    { name = "Attack Speed (-SPA)", focus = { "stormbringer", "boots", "belt", "cloak" }, ignore = { "axe", "axe_legendary" }, note = "Attack-cooldown items first (Stormbringer -50%, Speedy Boots -20%, Ninja Belt -12%, Nimble Cloak -7%)." },
    { name = "Range", focus = { "bow_legendary", "bow3", "bow2", "bow1" }, ignore = { "axe", "axe_legendary" }, note = "Range items first (Sylvanthorn +150%, Elf Bow, Longbow, Bow)." },
    { name = "Economy (unit cost)", focus = { "gold_mask", "gold_shroom", "gold_branch" }, ignore = { "axe", "axe_legendary" }, note = "Placement/upgrade cost cuts first (Mask of Riches -50%, Golden Mushroom -30%, Golden Branch -15%)." },
    { name = "Control (slow enemies)", focus = { "frost_axe", "icebane" }, ignore = { "axe", "axe_legendary" }, note = "Enemy slows first (Glacial Axe -30%, Ice Dagger -20%)." },
    { name = "Rewards (chest luck)", focus = { "genie_lamp", "hook2", "hook", "moon_fragment", "philospher_stone", "chest_mock_item" }, ignore = { "axe", "axe_legendary" }, note = "Chest luck and chest items first (Genie Lamp, Golden Fishhook, Fishhook, Shimmering Moon Fragment, Philosopher's Stone, Treasure Chest). Shop only: Auto Accept Shrine is a separate toggle." },
}
local PRESET_NAMES = {}
for _, p in PRESETS do table.insert(PRESET_NAMES, p.name) end

-- Room presets: type ids best first ("3" Rare Chest, "4" Chest, "7" Shrine, "1" Shop, "2" Hoard, "0" Curse).
local ROOM_PRESETS = {
    { name = "Chests & Shrines", order = ROOM_DEFAULT, note = "Rare chest and chest rooms first (chests are opened after the last room), then shrines, shop, hoard (the default)." },
    { name = "Power Up (items)", order = { "1", "2", "7", "3", "4", "0" }, note = "Shop, Hoard and Shrine first to build the run, then chests." },
    { name = "Safe", order = { "1", "2", "3", "4", "7", "0" }, note = "Shop and hoard first, then chests; shrines and cursed rooms last (curses make enemies harder)." },
    { name = "Cursed (hard)", order = { "7", "0", "3", "4", "1", "2" }, note = "Shrines and cursed rooms first, then chests: harder enemies for a chance at better rewards (the effect on rewards is unverified)." },
}
local ROOM_PRESET_NAMES = {}
for _, p in ROOM_PRESETS do table.insert(ROOM_PRESET_NAMES, p.name) end

local Dungeon = {}

local S
do
    local keep, drop = {}, false
    for _, ty in cfg.rooms do
        if ty == "6" or ty == "5" then drop = true elseif ty then table.insert(keep, ty) end
    end
    if drop then
        while #keep < #ROOM_DEFAULT do table.insert(keep, false) end
        cfg.rooms = keep
        Core.save_config()
    end
end
local function core()
    S = S or Game.loader().load_core_service(script, "DungeonServiceCore")
    return S
end
local svc
local function data()
    if not svc then
        local ok, res = pcall(Game.loader().load_client_service, script, "DungeonServiceClient")
        svc = ok and res or nil
    end
    local pd = svc and svc.session and svc.session.profile_data
    return pd and pd.dungeon_data
end

local function dump(t, d)
    if type(t) ~= "table" then return tostring(t) end
    if d == 0 then return "{..}" end
    local out = {}
    for k, v in t do if k ~= "_l" then table.insert(out, tostring(k) .. "=" .. dump(v, d - 1)) end end
    return "{" .. table.concat(out, ",") .. "}"
end
local function has(t, ty) return t and (t[ty] ~= nil or t[tonumber(ty)] ~= nil) end

-- What the server is waiting on, as one string: used to see whether a call took effect.
local function sig(d)
    local r = d._resources or {}
    local c = d.current_shops and d.current_shops[1]
    return table.concat({ tostring(r.money), tostring(r.treasure), tostring(r.treasure_gold), #(d._items or {}), #(d.current_shops or {}), c and c._t or "-",
        tostring(d._started), tostring(d._dead ~= nil), tostring(d.selected_next and d.selected_next.choice_str), tostring(d._finished) }, "|")
end
local function call(name, ...)
    local d = data()
    local before = d and sig(d)
    local ok, res = pcall(Game.invoke, name, ...)
    Core.log("dungeon", name, ..., "->", ok and tostring(res) or ("ERROR " .. tostring(res)))
    if not ok then return false end
    -- the server answers true even when nothing happened: wait for the profile to change
    for _ = 1, 12 do
        local nd = data()
        if nd and sig(nd) ~= before then return true end
        task.wait(0.25)
    end
    return false
end
local seen = {}
local function trace(tag, d)
    d = d or data()
    if not d then return end
    local r, c = d._resources or {}, d.current_shops and d.current_shops[1]
    local items = {}
    for _, it in d._items or {} do table.insert(items, it.id) end
    Core.log("dungeon state", tag, "lives", d.selected_next and d.selected_next.lives, "money", r.money, "chest", r.treasure, "rare", r.treasure_gold,
        "items", table.concat(items, ","), "room", c and c._t, "finished", d._finished, "dead", d._dead ~= nil)
    -- unseen rooms: keep the first raw dump of each kind (docs/features/dungeon.md verification)
    local kind = d._dead and "dead" or c and ("room" .. tostring(c._t)) or d._finished and "finished" or nil
    if kind and not seen[kind] then
        seen[kind] = true
        Core.log("dungeon first", kind, dump(c or d._dead or d, 4):sub(1, 1500))
    end
end

-- Depth of the room just played: the match knows it; in the lobby use the one saved when we entered it.
local function depth()
    local ld = Hub.mode == "match" and Game.loader().LevelData
    if ld and ld._dungeon then return ld._dungeon.depth end
    return cfg.depth or 0
end

local function buyRank()
    local rank, i = {}, 0
    for _, id in cfg.buy_order do i += 1 if cfg.buy[id] then rank[id] = i end end
    for id in cfg.buy do if not rank[id] then i += 1 rank[id] = i end end -- items outside the friend's list go last
    return rank
end

local function shop()
    local rank, bought = buyRank(), {}
    for _ = 1, 15 do
        local d = data()
        local cur = d and d.current_shops and d.current_shops[1]
        if not cur or cur._t ~= core().TYPES.SHOP then return end
        local mult = math.max(0, core().sum_item_values(d, "shop_prices") + 1)
        local money, best, bi, br = d._resources.money, nil, nil, nil
        for i, it in cur.data do
            local item = core().ITEMS[it.id]
            if item and rank[it.id] and not bought[it.id] and math.ceil(item.cost * mult) <= money and (not br or rank[it.id] < br) then
                best, bi, br = it.id, i, rank[it.id]
            end
        end
        -- Saving up: an offered Philosopher's Stone (all chests rare) we cannot afford yet and do not own is worth more than anything cheaper.
        local stone = false
        local saving = cfg.preset == PRESETS[1].name -- only this preset saves coins; every other buy order is unchanged
        for _, it in cur.data do
            if it.id == "philospher_stone" and rank[it.id] and math.ceil(core().ITEMS[it.id].cost * mult) > money then stone = true end
        end
        for _, it in d._items or {} do if it.id == "philospher_stone" then stone = false end end
        if saving and stone and (not br or rank[best] ~= rank.philospher_stone) then Core.log("dungeon buy: saving coins for philospher_stone", "money", money) break end
        if not best then break end
        bought[best] = true
        Core.log("dungeon buy", best, "slot", bi, "money", money)
        call("dungeon_buy_shop", bi)
    end
    call("dungeon_continue_shop")
end

local function shrine(cur)
    local ids, decline = {}, false
    for _, v in cur.data do
        if v._t == "Item" then
            table.insert(ids, v.id)
            if cfg.decline[v.id] then decline = true end
        end
    end
    Core.log("dungeon shrine offers", table.concat(ids, ","), "accept", cfg.shrine and not decline)
    if cfg.shrine and not decline and call("dungeon_shrine_accept") then
        local d = data()
        local now = d and d.current_shops and d.current_shops[1]
        if now and now._t == cur._t then call("dungeon_continue_shop") end -- still on the shrine
    else
        call("dungeon_continue_shop")
    end
end

-- Chests still closed (normal + rare).
local function chestsLeft(d)
    local r = d and d._resources or {}
    return (r.treasure or 0) + (r.treasure_gold or 0)
end

-- Opens every stored chest, rare first. The last room (`_finished`) always opens them all, whatever Open All Chest after Depth says:
-- "Finish" ends the run and the game warns that unopened chests are lost. There the room is only finished once none are left.
local keysBefore
local function writeChestLog(rec)
    local path = Core.paths.data .. "/dungeon_chests.log"
    local line = game:GetService("HttpService"):JSONEncode(rec) .. "\n"
    pcall(function() if isfile(path) then appendfile(path, line) else writefile(path, line) end end)
end
local function keyCount()
    local pd = Game.profile()
    local n = pd and pd.inventory and pd.inventory.normal_items and pd.inventory.normal_items.dungeon_key
    return n
end
local function chests(d)
    local last = d._finished == true or depth() >= (core().NUM_ROOMS or 20)
    local want = last and cfg.chest_end ~= false -- only after the last room: that is when the luck multiplier is highest
    local conns, events = {}, {}
    local tally = { items = {}, res = {}, units = {}, messages = {} } -- what the chests gave, from the server's reward events
    local normal0, rare0, luck, itemIds = d._resources.treasure or 0, d._resources.treasure_gold or 0, nil, {}
    if want then
        pcall(function() luck = core().calculate_luck_multiplier(d) end)
        for _, it in d._items or {} do table.insert(itemIds, it.id) end
        -- the opens return nothing: record every event the server sends meanwhile, to see what the chests gave
        local logged = 0
        for _, ev in game:GetService("ReplicatedStorage").endpoints.server_to_client:GetChildren() do
            if ev:IsA("RemoteEvent") then
                table.insert(conns, ev.OnClientEvent:Connect(function(...)
                    local args = table.pack(...)
                    local name = ev.Name
                    pcall(function()
                        if name == "show_unit_and_item_rewards" then
                            for _, it in args[1] or {} do if type(it) == "table" and it.item_id then tally.items[it.item_id] = (tally.items[it.item_id] or 0) + (it.amount or 1) end end
                            for _, un in args[2] or {} do table.insert(tally.units, type(un) == "table" and tostring(un.unit_id or un.id or dump(un, 2)) or tostring(un)) end
                            local r6 = args[6]
                            for _, rr in r6 and r6.new_resources or {} do tally.res[rr.resource] = (tally.res[rr.resource] or 0) + (rr.amount or 0) end
                        elseif name == "show_message" then
                            table.insert(tally.messages, tostring(args[1]))
                        end
                    end)
                    -- only the events that say something about the rewards; the fight's effects and buffs are not logged
                    if name == "show_unit_and_item_rewards" or name == "show_message" or name:find("item") or name:find("unit_added") or name:find("dungeon") and name ~= "dungeon_changed" then
                        logged += 1
                        local text = name .. " " .. dump(args, 4):sub(1, 400)
                        if logged <= 80 then Core.log("dungeon chest event", text) table.insert(events, text) end
                    end
                end))
            end
        end
        keysBefore = keyCount()
        Core.log("dungeon keys before the chests:", tostring(keysBefore))
    end
    Core.log("dungeon chest room depth", depth(), "last", last, "open", want, "chest", d._resources.treasure, "rare", d._resources.treasure_gold)
    if want then
        for _, rare in { true, false } do
            local key = rare and "treasure_gold" or "treasure"
            local fails = 0
            for _ = 1, 200 do
                local nd = data()
                local n = nd and nd._resources[key]
                if not n or n <= 0 or fails >= 4 then break end
                local ok = rare and call("dungeon_open_chest", true) or not rare and call("dungeon_open_chest")
                if ok then fails = 0 else fails += 1 task.wait(1) end
            end
        end
        if want and chestsLeft(data()) > 0 then
            for _, c in conns do c:Disconnect() end
            Core.log("dungeon: chests still closed in the last room, not finishing yet:", chestsLeft(data()))
            return
        end
    end
    if want then
        task.wait(2) -- let the rewards arrive before the room is closed
        Core.log("dungeon keys after the chests:", tostring(keyCount()))
    end
    call("dungeon_continue_shop")
    if want then
        task.wait(3)
        for _, c in conns do c:Disconnect() end
        -- one record per run: the chest log file, the webhook, and a marker so the lobby can report what the inventory gained
        local rec = { kind = "opened", date = os.date("!%Y-%m-%dT%H:%M:%SZ"), user = game:GetService("Players").LocalPlayer.Name, depth = depth(),
            normal = normal0, rare = rare0, luck = luck, items = itemIds, keys_before = keysBefore, keys_after = keyCount(), events = events }
        local lines = {}
        for id, n in tally.items do table.insert(lines, ("%s x%d"):format(id, n)) end
        for r, n in tally.res do table.insert(lines, ("%s x%d"):format(r, n)) end
        for _, u in tally.units do table.insert(lines, "unit " .. u) end
        table.sort(lines)
        rec.rewards, rec.messages = lines, tally.messages
        Core.log("dungeon chest rewards (server events):", table.concat(lines, ", "), "| messages:", table.concat(tally.messages, " | "))
        writeChestLog(rec)
        Core.emit("dungeon_chests", rec)
        cfg.pending_chests = { normal = normal0, rare = rare0, luck = luck, depth = depth(), date = rec.date }
        Core.save_config()
    end
end

-- Best of the 1-3 offered rooms by the user's order; a room's score is its best flag, then the sum of its flags.
local function pick(d)
    local sel = d.selected_next and d.selected_next.choice_str
    local rank, worst = {}, #cfg.rooms + 1
    for i, ty in cfg.rooms do if ty then rank[ty] = i end end
    local best, bk, bs
    local seen = {}
    for c = 1, 3 do
        local room = d.next and d.next[tostring(c)]
        if room then
            local top, sum, names = worst, 0, {}
            for ty, on in room._t or {} do
                local r = rank[tostring(ty)] or worst
                if on then top = math.min(top, r) sum += r table.insert(names, ROOM_LABEL[tostring(ty)] or tostring(ty)) end
            end
            table.insert(seen, ("%d: %s (depth %s)"):format(c, #names > 0 and table.concat(names, "+") or "plain", tostring(room._d)))
            if not best or top < bk or (top == bk and sum < bs) then best, bk, bs = tostring(c), top, sum end
        end
    end
    local desc = table.concat(seen, " | ")
    if sel and d.next and d.next[tostring(sel)] then return tostring(sel), desc .. " -> room " .. sel .. " (locked: already entered, lives " .. tostring(d.selected_next.lives) .. ")" end
    return best, desc .. (best and (" -> room " .. best .. " by your room priority") or "")
end

local lastPick -- UI label, set below

local backoff = 0
-- Resolves what the server is waiting on, then returns the room to enter ("1".."3"), or nil + reason.
function Dungeon.next_room(noStart)
    if os.clock() < backoff then return nil, "cooling down" end
    for _ = 1, 30 do
        local d = data()
        if not d then return nil, "no dungeon data" end
        local cur = d.current_shops and d.current_shops[1]
        local before = sig(d)
        if d._dead then
            trace("dead", d)
            if not call("dungeon_continue_death") then backoff = os.clock() + 15 return nil, "death not accepted" end
        elseif cur then
            trace("room", d)
            local T = core().TYPES
            if cur._t == T.SHOP then shop()
            elseif cur._t == T.SHRINE then shrine(cur)
            elseif cur._t == T.OPEN_CHEST then chests(d)
            else
                Core.log("dungeon unknown room state", dump(cur, 3))
                if not call("dungeon_continue_shop") then backoff = os.clock() + 15 return nil, "unknown room state" end
            end
            local nd = data()
            if nd and sig(nd) == before then backoff = os.clock() + 15 return nil, "room not resolved" end
        elseif not d._started then
            if noStart then return nil, "run finished" end
            if not cfg.start then return nil, "not started" end
            if not call("dungeon_start") then backoff = os.clock() + 15 return nil, "start refused" end
        else
            local c, desc = pick(d)
            if not c then return nil, "no rooms" end
            cfg.depth = d.next[c]._d
            trace("pick " .. c, d)
            Core.log("dungeon pick", desc)
            if lastPick then lastPick:SetText("Last pick: " .. desc) end
            return c
        end
    end
    return nil, "stuck"
end

-- Sets the buy order and selection from a preset; returns the preset (nil if unknown).
function Dungeon.apply_preset(name)
    local p
    for _, x in PRESETS do if x.name == name then p = x end end
    if not p then return end
    local skip, order, put = set(p.ignore), {}, {}
    local function add(id) if not skip[id] and not put[id] then put[id] = true table.insert(order, id) end end
    for _, id in p.focus do add(id) end
    for _, id in BUY_ORDER do if not p.only then add(id) end end -- `only` presets buy exactly their focus list
    cfg.buy_order, cfg.buy, cfg.preset = order, set(order), name
    Core.save_config()
    Core.log("dungeon preset", name, "buy", table.concat(order, ","))
    return p
end

-- Sets the room order from a room preset; returns the preset (nil if unknown).
function Dungeon.apply_room_preset(name)
    for _, p in ROOM_PRESETS do
        if p.name == name then
            cfg.rooms, cfg.room_preset = table.clone(p.order), name
            Core.save_config()
            Core.log("dungeon room preset", name, table.concat(p.order, ","))
            return p
        end
    end
end

-- Match: this module ends dungeon matches (Match skips its own next/replay/lobby chain).
local isDungeon = false
if Hub.mode == "match" then
    local ld = Game.loader().LevelData
    isDungeon = ld ~= nil and ld._dungeon ~= nil
end
function Dungeon.owns_finish() return isDungeon and cfg.enable end

if isDungeon then
    -- The room we are in decides whether the server hands us a shop / shrine / chest after the win.
    -- nil until the profile has the room; read again at the end if it was not there at load.
    local expect
    local function roomExpect()
        if expect ~= nil then return expect end
        local d0 = data()
        local room = d0 and d0.next and d0.next[tostring(Game.loader().LevelData._dungeon.choice_str)]
        if not room then return nil end
        expect = false
        for _, ty in { "1", "5", "6", "7" } do if has(room._t, ty) then expect = true end end
        return expect
    end
    roomExpect()
    local s2c = game:GetService("ReplicatedStorage"):WaitForChild("endpoints"):WaitForChild("server_to_client")
    table.insert(Hub.connections, s2c:WaitForChild("game_finished").OnClientEvent:Connect(function(result)
        if not cfg.enable then return end
        local victory = type(result) == "table" and result.victory
        task.wait((Core.config.auto and Core.config.auto.finish_delay) or 3)
        local t, e = os.clock(), roomExpect()
        -- unknown room = wait a little; a known shop/shrine/chest room = wait for the server to hand it over
        local limit = e == nil and 10 or e and 25 or 0
        while alive() and victory and os.clock() - t < limit and not (data() and data().current_shops and data().current_shops[1]) do task.wait(0.5) end
        trace("finished victory=" .. tostring(victory) .. " expect=" .. tostring(e))
        -- The last room: the chests are opened (next_room does it), Finish ends the run, and nothing is started from here.
        local d0 = data()
        local lastRoom = (d0 and d0._finished == true) or depth() >= (core().NUM_ROOMS or 20)
        if lastRoom then Core.log("dungeon: last room finished, chests", chestsLeft(d0), "stored") end
        for _ = 1, 3 do
            if not alive() then return end
            local c, why = Dungeon.next_room(lastRoom)
            if not c then Core.log("dungeon: nothing to enter:", why) break end
            Core.log("dungeon enter", c, "from match")
            Core.save_config()
            pcall(Game.invoke, "dungeon_enter_room", c)
            task.wait(20)
        end
        -- Never leave the last room with chests still closed: keep trying for as long as it takes (alert after 5 minutes).
        local waited, unreadable = 0, 0
        while alive() do
            local d = data()
            if d == nil and unreadable < 12 then -- never read "no data" as "no chests left"
                unreadable += 1
                task.wait(5)
                continue
            end
            if not (d and d._finished and chestsLeft(d) > 0) then break end
            if waited % 12 == 0 then Core.log("dungeon: waiting to open the last chests:", chestsLeft(d), "waited", waited * 5, "s") end
            if waited == 60 then
                local rec = { kind = "stuck", date = os.date("!%Y-%m-%dT%H:%M:%SZ"), user = game:GetService("Players").LocalPlayer.Name, depth = depth(),
                    normal = d._resources.treasure, rare = d._resources.treasure_gold }
                writeChestLog(rec)
                Core.emit("dungeon_chests", rec)
                if Hub.UI then Hub.UI.Library:Notify("Dungeon: chests will not open in the last room, still trying", 10) end
            end
            backoff = 0
            pcall(Dungeon.next_room, true)
            task.wait(5)
            waited += 1
        end
        local over = data()
        over = over and not over._started and not over._dead
        if over then Core.log("dungeon: run finished") end
        if alive() and ((Core.config.auto and Core.config.auto.lobby) or over) then
            Core.log("dungeon: back to lobby")
            Core.save_config()
            pcall(Game.invoke, "teleport_back_to_lobby")
        end
    end))
    -- A line every minute: lives, money, stored chests, whether the run is finished.
    task.spawn(function()
        while alive() do
            task.wait(60)
            if cfg.enable then pcall(trace, "heartbeat wave " .. tostring(workspace:FindFirstChild("_wave_num") and workspace._wave_num.Value)) end
        end
    end)
end

-- Lobby: compare the inventory with the snapshot of the last lobby visit and report what a run with opened chests gained.
if Hub.mode == "lobby" then
    task.spawn(function()
        local pd
        for _ = 1, 40 do
            pd = Game.profile()
            if pd and pd.inventory and pd.inventory.normal_items then break end
            task.wait(1)
        end
        if not (pd and pd.inventory and pd.inventory.normal_items) then return end
        local snap = { items = {}, gems = pd.gem_amount, gold = pd.gold_amount, units = 0 }
        for id, n in pd.inventory.normal_items do if type(n) == "number" then snap.items[id] = n end end
        for _ in pd.collection and pd.collection.owned_units or {} do snap.units += 1 end
        local path = Core.paths.data .. "/dungeon_inv.json"
        local HS = game:GetService("HttpService")
        local ok, prev = pcall(function() return isfile(path) and HS:JSONDecode(readfile(path)) end)
        local pend = cfg.pending_chests
        if pend and ok and prev then
            local gained = {}
            local ids = {}
            for id in snap.items do ids[id] = true end
            for id in prev.items or {} do ids[id] = true end
            for id in ids do
                local diff = (snap.items[id] or 0) - ((prev.items or {})[id] or 0)
                if diff ~= 0 then table.insert(gained, ("%s %s%d"):format(id, diff > 0 and "+" or "", diff)) end
            end
            table.sort(gained)
            if (snap.units or 0) ~= (prev.units or 0) then table.insert(gained, ("units %+d"):format(snap.units - (prev.units or 0))) end
            if (snap.gems or 0) ~= (prev.gems or 0) then table.insert(gained, ("gems %+d"):format(snap.gems - (prev.gems or 0))) end
            if (snap.gold or 0) ~= (prev.gold or 0) then table.insert(gained, ("gold %+d"):format(snap.gold - (prev.gold or 0))) end
            local rec = { kind = "rewards", date = os.date("!%Y-%m-%dT%H:%M:%SZ"), user = game:GetService("Players").LocalPlayer.Name, depth = pend.depth,
                normal = pend.normal, rare = pend.rare, luck = pend.luck, gained = gained, since = prev.date }
            writeChestLog(rec)
            Core.emit("dungeon_chests", rec)
            Core.log("dungeon chest rewards (inventory change since the last lobby visit):", table.concat(gained, ", "))
            cfg.pending_chests = nil
            Core.save_config()
        end
        snap.date = os.date("!%Y-%m-%dT%H:%M:%SZ")
        pcall(writefile, path, HS:JSONEncode(snap))
    end)
end

-- UI (own tab; "Dungeon Run" is also a mode in the Joiner tab's priority list)
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local function set1(key) return function(v) cfg[key] = v Core.save_config() end end
    local T = Tabs.Dungeon
    local run = T:AddLeftGroupbox("Dungeon Run", "skull")
    run:AddToggle("JoinDungeonRun", { Text = "Auto Join Dungeon Run", Tooltip = "Enters the best room of the current run (lobby, and after each dungeon match), and handles shop, shrine and chest rooms.", Default = cfg.enable, Callback = set1("enable") })
    run:AddToggle("DungeonStart", { Text = "Auto Start Dungeon", Tooltip = "Starts a new run when none is active (may use a Dungeon Run Key).", Default = cfg.start, Callback = set1("start") })
    run:AddToggle("DungeonChestEnd", { Text = "Open All Chests at the End", Tooltip = "After beating the last room (your luck is highest then) every stored chest is opened before leaving. Chest rooms on the way only keep them. Off = chests are never opened.", Default = cfg.chest_end ~= false, Callback = set1("chest_end") })
    lastPick = run:AddLabel("Last pick: -", true)

    local labels, byLabel = {}, {}
    for _, ty in ROOM_DEFAULT do table.insert(labels, ROOM_LABEL[ty]) byLabel[ROOM_LABEL[ty]] = ty end
    local rooms = T:AddRightGroupbox("Room Priority", "list-ordered")
    local roomDD, roomNote = {}, nil
    local function roomNoteOf(name) for _, x in ROOM_PRESETS do if x.name == name then return x.note end end return "" end
    rooms:AddDropdown("DungeonRoomPreset", { Text = "Room Preset", Values = ROOM_PRESET_NAMES, Default = cfg.room_preset, Callback = function(v)
        cfg.room_preset = v
        if roomNote then roomNote:SetText(roomNoteOf(v)) end
    end })
    roomNote = rooms:AddLabel(roomNoteOf(cfg.room_preset), true)
    rooms:AddButton("Apply Room Preset", function()
        local p = Dungeon.apply_room_preset(cfg.room_preset)
        if not p then return end
        for i = 1, #roomDD do roomDD[i]:SetValue(p.order[i] and ROOM_LABEL[p.order[i]] or nil) end
        Hub.UI.Library:Notify(("Room preset applied: %s"):format(p.name))
    end)
    rooms:AddLabel("The room with the best flag by this order is entered; ties go to the room with more good flags. You can still change each slot.", true)
    for i = 1, #ROOM_DEFAULT do
        roomDD[i] = rooms:AddDropdown("DungeonRoom" .. i, { Text = "Priority " .. i, Values = labels, Default = ROOM_LABEL[cfg.rooms[i] or ""], AllowNull = true, Callback = function(v)
            cfg.rooms[i] = v and byLabel[v] or false
            Core.save_config()
        end })
    end

    -- Item names for the dropdowns; the module's data may not be loaded yet right after a teleport.
    local ok, items = pcall(function() return core().ITEMS end)
    if ok and items then
        local buyNames, curseNames, idOf = {}, {}, {}
        local function addShop(id) if items[id] then table.insert(buyNames, items[id].name) idOf[items[id].name] = id end end
        for _, id in BUY_ORDER do addShop(id) end
        local curses = {}
        for id, it in items do
            if id:find("^_curse_") then table.insert(curses, id) idOf[it.name] = id
            elseif not table.find(BUY_ORDER, id) then addShop(id) end
        end
        table.sort(curses)
        for _, id in curses do table.insert(curseNames, items[id].name) end
        local function pickSet(key) return function(v)
            local out = {}
            for name, on in v do if on and idOf[name] then out[idOf[name]] = true end end
            cfg[key] = out
            Core.save_config()
        end end
        local function names(setT) local out = {} for id in setT do if items[id] then table.insert(out, items[id].name) end end return out end
        local shrine = T:AddLeftGroupbox("Shrine", "flame")
        local shrineT = shrine:AddToggle("DungeonShrine", { Text = "Auto Accept Shrine", Tooltip = "Accept a shrine's curse unless it is in Decline Shrine Curse. Off = always skip shrines.", Default = cfg.shrine, Callback = set1("shrine") })
        shrine:AddDropdown("DungeonDecline", { Text = "Decline Shrine Curse", Values = curseNames, Multi = true, Default = names(cfg.decline), Callback = pickSet("decline") })
        local shop = T:AddRightGroupbox("Shop", "shopping-cart")
        local buyDD = shop:AddDropdown("DungeonBuy", { Text = "Auto Buy Dungeon Shop", Tooltip = "Items to buy in shops, best first in the order of the Shop Preset (default Balanced = the friend's). Needs the coins; none selected = buy nothing.", Values = buyNames, Multi = true, Default = names(cfg.buy), Callback = pickSet("buy") })

        -- Shop presets set only the shop's buy list and order (nothing else), in one click.
        local function noteOf(name) for _, x in PRESETS do if x.name == name then return x.note end end return "" end
        local note
        shop:AddDropdown("DungeonPreset", { Text = "Shop Preset", Values = PRESET_NAMES, Default = cfg.preset, Callback = function(v)
            cfg.preset = v
            if note then note:SetText(noteOf(v)) end
        end })
        note = shop:AddLabel(noteOf(cfg.preset), true)
        shop:AddButton("Apply Shop Preset", function()
            local p = Dungeon.apply_preset(cfg.preset)
            if not p then return end
            local sel = {}
            for id in cfg.buy do if items[id] then sel[items[id].name] = true end end
            buyDD:SetValue(sel)
            Hub.UI.Library:Notify(("Shop preset applied: %s"):format(p.name))
        end)
        shop:AddLabel("Applying replaces only the Shop selection and its buy order.", true)

        -- Dungeon Info tab: the game's own data, read live.
        local I = Tabs.DungeonInfo
        if I then
            local howto = I:AddLeftGroupbox("How a run works", "book-open")
            for _, line in {
                "Get a Dungeon Run Key from the Gambler's shop in the lobby (from the game's own tutorial text).",
                "A run is 20 depths. At each depth you pick 1 of up to 3 rooms; every room is a normal match with a special flag.",
                "You have 5 hearts. A lost match costs 1 heart and you must replay the same room; at 0 hearts the run ends.",
                "Chests are collected as you go. Open them in a chest-open room (every 5 depths) or at the end; waiting for the end gives a chance at a secret limited unit.",
                "Hoard rooms drop dungeon coins. Spend them in shops after a won match; items last for the rest of the run. Dungeon matches start with 2500 yen.",
                "Cursed items make enemies harder. Shrines offer stronger curses at a chance of greatly boosted rewards (what exactly it boosts: UNVERIFIED).",
            } do howto:AddLabel(line, true) end

            local rooms = I:AddLeftGroupbox("Rooms", "door-open")
            for _, line in {
                "Hoard: coins to spend in shops.",
                "Shop: after the match, buy up to 3 offered items with coins.",
                "Chest / Rare Chest: +1 chest (rare chest) to open later.",
                "Open Chest: a checkpoint every 5 depths (5, 10, 15) that every room of that depth carries, so it is not a choice. The hub keeps the chests stored and opens them all after the last room, when your luck is highest.",
                "Shrine: offered a curse; accept for a chance at better rewards, or decline.",
                "Curse: the room carries a curse item that is active in the match.",
                "Final Boss: the last depth of the run.",
            } do rooms:AddLabel(line, true) end

            local function sorted(pred)
                local out = {}
                for id, it in items do if pred(id, it) then table.insert(out, it) end end
                table.sort(out, function(a, b) return a.name < b.name end)
                return out
            end
            local function fill(box, list, shop)
                for _, it in list do
                    local extra = shop and (it.chance and it.chance > 0 and (" (%d%% shop chance)"):format(it.chance * 100) or " (not sold in shops)") or ""
                    box:AddLabel(shop and ("%s - %d coins%s: %s"):format(it.name, it.cost, extra, it.description) or ("%s: %s"):format(it.name, it.description), true)
                end
            end
            local shopBox = I:AddRightTabbox()
            for _, tier in { { "1", "T1" }, { "2", "T2" }, { "3", "T3" }, { "legendary", "Legend" } } do
                fill(shopBox:AddTab(tier[2]), sorted(function(id, it) return not id:find("^_curse_") and it.tier == tier[1] end), true)
            end
            local curseBox = I:AddRightTabbox()
            fill(curseBox:AddTab("Curses"), sorted(function(id, it) return id:find("^_curse_") and it.tier ~= "super" end))
            fill(curseBox:AddTab("Super Curses"), sorted(function(id, it) return id:find("^_curse_") and it.tier == "super" end))
        end
    end
end

Dungeon.cfg, Dungeon.data = cfg, data
return Dungeon
