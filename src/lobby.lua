-- Lobby tab (docs/features/lobby-tab.md): claimers, gold shop, star opening, auto summoners, codes, misc.
-- Options live in Core.config.lobby (hub.json) so they apply after every teleport. Loops run in the lobby only;
-- in a match the module just answers Lobby.want_lobby() (used by src/match.lua at game end).
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local env = getgenv()
local RS = game:GetService("ReplicatedStorage")
local LP = game:GetService("Players").LocalPlayer

local cfg = Core.config.lobby or {}
Core.config.lobby = cfg
local defaults = {
    claim = { quest = false, mission = false, level = false, battlepass = false },
    shop = { enable = false, items = {}, known = {} },
    stars = { enable = false, items = {} },
    -- done[banner] = the featured set already handled, so a rotation is summoned once (and a match is not
    -- sent back to the lobby for it again).
    summon = { sell = {}, unselect = false, teleport = false, reserve = 5000, done = {} },
    special = { enable = false, units = {} },
    legacy = { enable = false, units = {}, exchange = 0 },
    event = { enable = false, banner = nil },
    codes = { enable = false, tried = {} },
}
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

local Lobby = {}
local function alive() return env.ZenoHub == Hub end

local function call(name, ...)
    local ok, res = pcall(Game.invoke, name, ...)
    if not ok then Core.log("ERROR lobby", name, res) end
    return ok and res
end

local Items, Units, Banners = Game.data("Items"), Game.data("Units"), Game.data("Banners")
local function svc() return Game.loader().load_client_service(script, "LobbyServiceClient") end
local function core(name) return Game.loader().load_core_service(script, name) end

-- Banner data from the server: rateup_units (the featured ones now) and the unit pools per rarity.
local hatchData, hatchAt
local function hatch()
    if not hatchData or os.clock() - hatchAt > 60 then
        local ok, a, b, c = pcall(Game.invoke, "get_hatch_setup_data")
        if ok and a then hatchData, hatchAt = { rateup = a, legacy = b, special = c }, os.clock() end
    end
    return hatchData
end
local BANNER = { special = "EventClover", legacy = "Legacy" }
-- Featured unit ids of a banner, and a key that changes when the rotation does.
local function featured(banner)
    local d, out = hatch(), {}
    for _, id in (d and d.rateup[banner] and d.rateup[banner].rateup_units) or {} do out[id] = true end
    local ids = Core.keys(out)
    table.sort(ids)
    return out, banner .. ":" .. table.concat(ids, ",")
end

-- A selected target is featured and its rotation was not handled yet.
local function pending(key)
    local c = cfg[key]
    if not c.enable then return nil end
    local feat, fkey = featured(BANNER[key])
    local hit = {}
    for id in feat do if c.units[id] then hit[id] = true end end
    if next(hit) and cfg.summon.done[BANNER[key]] ~= fkey then return hit, fkey end
end

-- Game end in a match (src/match.lua): go to the lobby when a selected unit just became featured.
function Lobby.want_lobby()
    if not cfg.summon.teleport then return false end
    for key in BANNER do
        local ok, hit = pcall(pending, key)
        if ok and hit then Core.log("lobby: new banner target, returning to the lobby", key) return true end
    end
    return false
end

if Hub.mode ~= "lobby" then return Lobby end

local s2c = RS:WaitForChild("endpoints"):WaitForChild("server_to_client")
local stats = LP:WaitForChild("_stats")

-- Quiet mode: the game's handlers of the reveal events are switched off (show_hatch_effect = the star and unit
-- reveal, show_item_hatch_effect = star items, show_unit_and_item_rewards = the unit info popup; verified for
-- the last one: it stays closed and pulls still count). Held by the auto loops and by the Hide Summon Animation
-- toggle; counted because they overlap. units_hatched_through_banner (the game's own auto sell) stays on.
-- Needs getconnections; without it the animation just plays.
local QUIET_EVENTS = { "show_hatch_effect", "show_item_hatch_effect", "show_unit_and_item_rewards" }
local quietN = 0
local function quiet(on)
    quietN = math.max(0, quietN + (on and 1 or -1))
    if (on and quietN ~= 1) or (not on and quietN ~= 0) or not getconnections then return end
    for _, name in QUIET_EVENTS do
        local ev = s2c:FindFirstChild(name)
        local ok, cs = pcall(getconnections, ev and ev.OnClientEvent)
        for _, c in ok and cs or {} do pcall(on and c.Disable or c.Enable, c) end
    end
end
local function quietly(fn, ...)
    quiet(true)
    local ok, err = xpcall(fn, debug.traceback, ...)
    quiet(false)
    if not ok then error(err, 0) end
end
table.insert(Hub.connections, { Disconnect = function() quietN = 1 quiet(false) end })

-- The server answers a summon sent inside its cooldown with this red label (and no spend); hide that one only.
do
    local mui = Game.loader().load_client_service(script, "GUIService").message_ui
    if mui then
        local orig = mui.show_message
        mui.show_message = function(self, text, ...)
            if type(text) == "string" and text:lower():find("summoning too fast", 1, true) then return end
            return orig(self, text, ...)
        end
        table.insert(Hub.connections, { Disconnect = function() mui.show_message = nil end })
    end
end

local function notify(title, text)
    local lib = Hub.UI and Hub.UI.Library
    if lib then pcall(lib.Notify, lib, { Title = title, Description = text, Time = 5 }) end
end

-- Claimers ------------------------------------------------------------------------------------------------
local function claim()
    local c = cfg.claim
    local session = svc().session
    local pd = session.profile_data
    local complete = {} -- quest info id -> done, from the game's own check
    local QC = core("QuestClassesCore")
    for uuid, q in pd.quest_handler.quests do
        local ok, done = pcall(QC.is_quest_complete, session, q)
        complete[uuid] = ok and done or false
        if q.quest_info and q.quest_info.id then complete[q.quest_info.id] = complete[uuid] end
    end
    if c.quest then
        for uuid, done in complete do
            if done and uuid:sub(1, 1) == "{" then
                Core.log("lobby claim quest", uuid)
                call("redeem_quest", uuid)
                task.wait(1)
            end
        end
    end
    if c.mission then
        local cur, interval = Game.invoke("request_current_dailymissions")
        local md = pd.dailymissions_data
        for _, id in cur or {} do
            local claimed = md.highest_claimed_interval and md.highest_claimed_interval >= interval and md.claimed_missions[id]
            -- A mission's quest is "<id>__quest"; no such quest in the profile = let the server decide.
            local done = complete[id .. "__quest"]
            if not claimed and done ~= false then
                Core.log("lobby claim mission", id)
                call("request_claim_dailymission", id)
                task.wait(1)
            end
        end
    end
    if c.level then
        local lvl = core("LevelServiceCore").calculate_level(LP, stats.player_xp.Value)
        for _, r in Game.data("PlayerLevelRewards") do
            if tonumber(r.level) <= lvl and not pd.level_rewards_claimed[r.level] then
                Core.log("lobby claim level", r.level)
                call("claim_player_level_rewards", r.level)
                task.wait(1)
            end
        end
    end
    if c.battlepass then call("claim_battlepass_rewards") end
end

-- Gold shop -----------------------------------------------------------------------------------------------
-- The client's stock number never drops; what is left is stock minus gold_shop_data.bought_items[id] (the
-- game's shop UI does the same), and the server caps an over-buy.
local function shop()
    local G = Game.loader().load_client_service(script, "GoldShopServiceClient")
    local stock = G.shop_items_for_sale
    if not stock then return end
    local bought = svc().session.profile_data.gold_shop_data.bought_items or {}
    local gold = stats.gold_amount.Value
    for id in stock do cfg.shop.known[id] = true end
    for id, on in cfg.shop.items do
        local it = stock[id]
        local n = on and it and math.min(it.stock - (bought[id] or 0), math.floor(gold / it.gold_cost)) or 0
        if n > 0 then
            Core.log("lobby shop", id, n)
            call("buy_gold_shop_item", id, tostring(n))
            gold -= n * it.gold_cost
            task.wait(2)
        end
    end
end

-- Stars (capsule items opened from the inventory with use_item) -------------------------------------------
local function count(id)
    local inv = svc().session.profile_data.inventory.normal_items
    return inv[id] or 0
end
local function rewardText(items, uuids)
    local t = {}
    for _, r in items or {} do
        if r.item_id then table.insert(t, ((Items[r.item_id] and Items[r.item_id].name) or r.item_id) .. " x" .. (r.amount or 1)) end
    end
    local col = svc().session.collection
    for _, uuid in uuids or {} do
        local cu = col:get_unit_by_uuid(uuid)
        if cu then table.insert(t, (Units[cu.unit_id] and Units[cu.unit_id].name) or cu.unit_id) end
    end
    return #t > 0 and table.concat(t, ", ") or "nothing listed"
end

-- Opens every owned copy of one star; the popup lists what the star gave (show_unit_and_item_rewards payload).
local function openStar(id)
    local last
    local c = s2c.show_unit_and_item_rewards.OnClientEvent:Connect(function(items, uuids) last = { items, uuids } end)
    while alive() and cfg.stars.enable and count(id) > 0 do
        local n = count(id)
        last = nil
        Core.log("lobby open star", id, n)
        call("use_item", id)
        local t = os.clock()
        while count(id) == n and os.clock() - t < 3 do task.wait(0.1) end
        if count(id) == n then break end -- did not open; do not loop forever
        t = os.clock()
        while not last and os.clock() - t < 1.5 do task.wait(0.05) end
        notify((Items[id] and Items[id].name) or id, last and rewardText(last[1], last[2]) or "opened")
    end
    c:Disconnect()
end
local function stars()
    for id, on in cfg.stars.items do
        if on and count(id) > 0 then quietly(openStar, id) end
    end
end

-- Summoning -----------------------------------------------------------------------------------------------
-- unit_added fires once per unit the server hands out (verified: one per pull).
local got = {}
table.insert(Hub.connections, s2c:WaitForChild("unit_added").OnClientEvent:Connect(function(u) table.insert(got, u) end))

-- The server ignores a summon sent within 3.35 s of the last accepted one (measured: accepted calls land
-- 3.35 s apart however often they are sent; no spend when refused), so a 10-pull is the fastest way. Wait
-- out the cooldown, then retry a refused call every 0.4 s until units arrive.
local COOLDOWN = 3.35
local lastPull = 0
local function pull(banner, opt)
    local want = opt:find("10") and 10 or 1
    local gap = COOLDOWN - (os.clock() - lastPull)
    if gap > 0 then task.wait(gap) end
    got = {}
    local t, sent = os.clock(), os.clock()
    while #got == 0 and os.clock() - t < 12 do
        sent = os.clock()
        Game.invoke("buy_from_banner", banner, opt)
        local w = os.clock()
        while #got == 0 and os.clock() - w < 0.4 do task.wait(0.05) end
    end
    if #got > 0 then
        lastPull = sent
        local w = os.clock()
        while #got < want and os.clock() - w < 3 do task.wait(0.05) end
    end
    return got
end

-- "Rare 6, Epic 2, Mythic 1" plus the names of everything above Epic.
local RARITIES = { "Exclusive", "Secret", "Mythic", "Legendary", "Epic", "Rare" }
local function summarize(res)
    local by, top, parts = {}, {}, {}
    for _, u in res do
        local un = Units[u.unit_id]
        local r = un and un.rarity or "?"
        by[r] = (by[r] or 0) + 1
        if r ~= "Rare" and r ~= "Epic" then table.insert(top, ((un and un.name) or u.unit_id) .. (u.shiny and " (shiny)" or "")) end
    end
    for _, r in RARITIES do if by[r] then table.insert(parts, r .. " " .. by[r]) end end
    return table.concat(parts, ", ") .. (#top > 0 and "\n" .. table.concat(top, ", ") or "")
end

local function allTargets()
    local t = {}
    for _, key in { "special", "legacy" } do for id, on in cfg[key].units do if on then t[id] = true end end end
    return t
end

-- Sells summoned units of the chosen rarities: never a target, locked, shiny or with traits (the game's
-- own auto sell has separate switches for those).
-- Unit ids the banners can give (the server's pools plus the featured ones); anything else is never sold.
local function obtainable()
    local d, set = hatch(), {}
    for _, pool in { d and d.legacy or {}, d and d.special or {} } do
        for _, list in pool do for _, id in list do set[id] = true end end
    end
    for _, b in (d and d.rateup) or {} do for _, id in b.rateup_units or {} do set[id] = true end end
    return set
end

-- Only units that are in the collection (so the lock can be read), unlocked, not shiny, without traits.
local function sellSummoned(res)
    local targets, can, ids, rows = allTargets(), obtainable(), {}, {}
    local col = svc().session.collection
    for _, u in res do
        local rarity = Units[u.unit_id] and Units[u.unit_id].rarity
        local cu = col:get_unit_by_uuid(u.uuid)
        if rarity and cfg.summon.sell[rarity] and can[u.unit_id] and not targets[u.unit_id] and cu
            and not cu._locked and not cu.shiny and not u.shiny and next(cu.traits or {}) == nil then
            table.insert(ids, u.uuid)
            table.insert(rows, u.unit_id)
        end
    end
    if #ids > 0 then
        local r = call("sell_units", ids)
        task.wait(1)
        local left = 0
        for _, uuid in ids do if col:get_unit_by_uuid(uuid) then left += 1 end end
        Core.log("lobby sell summoned", #ids, "ret", tostring(r), "still owned", left, table.concat(rows, ","))
        return #ids - left
    end
    return 0
end

-- One popup per pull: what came out, and how many were sold.
local function report(title, res)
    local sold = sellSummoned(res)
    notify(title, summarize(res) .. (sold > 0 and ("\nSold " .. sold) or ""))
end

local gems = function() return stats.gem_amount.Value end
local function legacyGems() return stats._resourceGemsLegacy.Value end
local plans = {
    special = function()
        local cost, g = Banners.EventClover.gem_cost, gems() - cfg.summon.reserve
        return g >= cost * 10 and "gems10" or g >= cost and "gems" or nil
    end,
    legacy = function()
        local cost, c = Banners.Legacy.resource_cost.amount, cfg.legacy
        if legacyGems() < cost * 10 and c.exchange > 0 and gems() - c.exchange >= cfg.summon.reserve then
            call("exchange_legacy_gems", c.exchange)
            task.wait(1)
        end
        local r = legacyGems()
        return r >= cost * 10 and "gems10" or r >= cost and "gems" or nil
    end,
}

local unitOpt = {} -- key -> dropdown option name, set with the UI below
local nameOf, idOf = {}, {}
local function deselect(key, id)
    cfg[key].units[id] = nil
    Core.save_config()
    local o = Hub.UI and Hub.UI.Library and Hub.UI.Library.Options[unitOpt[key]]
    if not o then return end
    local v = {}
    for k, on in cfg[key].units do if on and nameOf[k] then v[nameOf[k]] = true end end
    pcall(o.SetValue, o, v)
end

local function targetLoop(key, hit, fkey)
    local banner = BANNER[key]
    Core.log("lobby summon", banner, "targets", table.concat(Core.keys(hit), ","))
    while alive() and cfg[key].enable and next(hit) do
        local opt = plans[key]()
        if not opt then Core.log("lobby summon", banner, "stopped: gems at the reserve or no currency") break end
        local res = pull(banner, opt)
        if #res == 0 then Core.log("lobby summon", banner, "no result") break end
        report(key == "special" and "Summon (Special)" or "Summon (Legacy)", res)
        for _, u in res do
            if hit[u.unit_id] then
                Core.log("lobby summon got", u.unit_id)
                hit[u.unit_id] = nil
                if cfg.summon.unselect then deselect(key, u.unit_id) end
            end
        end
    end
    -- Handled either way (done or gave up), so a match is not sent back for the same rotation again.
    cfg.summon.done[banner] = fkey
    Core.save_config()
end

local function runTargets(key)
    local hit, fkey = pending(key)
    if hit then quietly(targetLoop, key, hit, fkey) end
end

-- Event banner: spends the banner's own currency (gems10 while it lasts, then singles).
local function runEvent()
    local c = cfg.event
    local b = c.banner and Banners[c.banner]
    if not b then return end
    local function have()
        if b.resource_cost then return stats["_resource" .. b.resource_cost.id].Value, b.resource_cost.amount end
        if b.item_cost then return count(b.item_cost.item_id), b.item_cost.amount end
        return 0, 1
    end
    while alive() and c.enable do
        local n, cost = have()
        n = math.floor(n / cost)
        local opt = n >= 10 and "gems10" or n >= 1 and "gems"
        if not opt then return end
        local res = pull(c.banner, opt)
        if #res == 0 then Core.log("lobby summon", c.banner, "no result") return end
        report("Summon (" .. c.banner .. ")", res)
    end
end

local function summon()
    for _, key in { "special", "legacy" } do
        local ok, err = xpcall(runTargets, debug.traceback, key)
        if not ok then Core.log("ERROR lobby summon", key, err) end
    end
    if cfg.event.enable then
        local ok, err = xpcall(quietly, debug.traceback, runEvent)
        if not ok then Core.log("ERROR lobby summon event", err) end
    end
end

-- Codes ---------------------------------------------------------------------------------------------------
-- Same source as Nousigi; only strong-tagged uppercase words of 5+ characters are tried, each once.
local CODES_URL = "https://videogameschronicle.com/guide/anime-adventures-codes-roblox"
local function redeemCodes()
    local ok, html = pcall(game.HttpGet, game, CODES_URL)
    if not ok then return Core.log("lobby codes: fetch failed") end
    for code in html:gmatch("<strong>%s*([A-Z0-9_]+)%s*</strong>") do
        if #code >= 5 and not cfg.codes.tried[code] then
            cfg.codes.tried[code] = true
            Core.save_config()
            Core.log("lobby code", code, tostring(call("redeem_code", code)))
            task.wait(2)
        end
    end
end

-- Loops ---------------------------------------------------------------------------------------------------
local function every(name, sec, enabled, fn)
    task.spawn(function()
        task.wait(5)
        while alive() do
            if enabled() then
                local ok, err = xpcall(fn, debug.traceback)
                if not ok then Core.log("ERROR lobby", name, err) end
            end
            task.wait(sec)
        end
    end)
end
every("claim", 60, function() local c = cfg.claim return c.quest or c.mission or c.level or c.battlepass end, claim)
every("shop", 30, function() return cfg.shop.enable end, function() shop() Core.save_config() end)
every("stars", 15, function() return cfg.stars.enable end, stars)
every("summon", 20, function() return cfg.special.enable or cfg.legacy.enable or cfg.event.enable end, summon)
every("zoom", 5, function() return cfg.zoom end, function() LP.CameraMaxZoomDistance = cfg.zoom end)
if cfg.codes.enable then task.spawn(function() task.wait(8) pcall(redeemCodes) end) end

-- UI ------------------------------------------------------------------------------------------------------
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local T = Tabs.Lobby
    local function set(t, key) return function(v) t[key] = v Core.save_config() end end

    -- Dropdown labels: display name, with the id added when two entries share a name.
    local function labels(ids, nameFn)
        local seen, out = {}, {}
        for _, id in ids do local n = nameFn(id) or id seen[n] = (seen[n] or 0) + 1 end
        for _, id in ids do
            local n = nameFn(id) or id
            if seen[n] > 1 then n = ("%s [%s]"):format(n, id) end
            nameOf[id], idOf[n] = n, id
            table.insert(out, n)
        end
        return out
    end
    local function selected(sel)
        local out = {}
        for id, on in sel do if on and nameOf[id] then table.insert(out, nameOf[id]) end end
        return out
    end
    local function picker(t, key) return function(v)
        local o = {}
        for name, on in v do if on and idOf[name] then o[idOf[name]] = true end end
        t[key] = o
        Core.save_config()
    end end
    local unitName = function(id) return Units[id] and Units[id].name end
    local itemName = function(id) return Items[id] and Items[id].name end

    -- Misc
    local misc = T:AddLeftGroupbox("Misc", "settings-2")
    misc:AddToggle("LobbyCodes", { Text = "Redeem all Codes", Tooltip = "Reads codes from videogameschronicle.com and redeems the ones not tried yet.", Default = cfg.codes.enable, Callback = function(v)
        cfg.codes.enable = v
        Core.save_config()
        if v then task.spawn(function() pcall(redeemCodes) end) end
    end })
    misc:AddSlider("LobbyZoom", { Text = "Max Camera Zoom Distance", Default = math.clamp(math.floor(cfg.zoom or LP.CameraMaxZoomDistance), 10, 1000), Min = 10, Max = 1000, Rounding = 0, Callback = function(v)
        cfg.zoom = v
        LP.CameraMaxZoomDistance = v
        Core.save_config()
    end })

    -- Open GUI: any of the game's own windows.
    local gui = Game.loader().load_client_service(script, "GUIService")
    local guiKey, guiNames = {}, {}
    for k, w in gui do
        if type(k) == "string" and k:match("_ui$") and type(w) == "table" and type(w.toggle) == "function" then
            local n = (k:sub(1, -4):gsub("_", " ")):gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end)
            guiKey[n] = k
            table.insert(guiNames, n)
        end
    end
    table.sort(guiNames)
    local open = T:AddLeftGroupbox("Open GUI", "layout-grid")
    open:AddDropdown("LobbyOpenGui", { Text = "Open GUI", Values = guiNames, AllowNull = true, Callback = function(v)
        if not v then return end
        local w = gui[guiKey[v]]
        pcall(w.toggle, w)
        Hub.UI.Library.Options.LobbyOpenGui:SetValue(nil)
    end })

    -- Claimer
    local cl = T:AddLeftGroupbox("Claimer", "gift")
    cl:AddToggle("LobbyClaimQuest", { Text = "Auto Claim Quest", Default = cfg.claim.quest, Callback = set(cfg.claim, "quest") })
    cl:AddToggle("LobbyClaimMission", { Text = "Auto Accept Daily Mission", Default = cfg.claim.mission, Callback = set(cfg.claim, "mission") })
    cl:AddToggle("LobbyClaimLevel", { Text = "Auto Claim Level Milestone", Default = cfg.claim.level, Callback = set(cfg.claim, "level") })
    cl:AddToggle("LobbyClaimBattlepass", { Text = "Auto Claim Battlepass", Default = cfg.claim.battlepass, Callback = set(cfg.claim, "battlepass") })

    -- Shop
    local pool = {}
    for id in cfg.shop.known do table.insert(pool, id) end
    local ok, G = pcall(function() return Game.loader().load_client_service(script, "GoldShopServiceClient") end)
    for id in (ok and G.shop_items_for_sale) or {} do if not cfg.shop.known[id] then table.insert(pool, id) end end
    table.sort(pool)
    local sh = T:AddLeftGroupbox("Shop", "shopping-cart")
    sh:AddToggle("LobbyShop", { Text = "Auto Gold Shop", Tooltip = "Buys only the checked items, once per shop rotation, as many as the stock and your gold allow.", Default = cfg.shop.enable, Callback = set(cfg.shop, "enable") })
    local shopValues = labels(pool, itemName)
    sh:AddDropdown("LobbyShopItems", { Text = "Select Buy Item", Values = shopValues, Multi = true, Default = selected(cfg.shop.items), Callback = picker(cfg.shop, "items") })

    -- Inventory: stars
    local starIds = {}
    for id, it in Items do if type(it) == "table" and it.item_group == "Stars" and it.usage_from_inventory then table.insert(starIds, id) end end
    table.sort(starIds)
    local inv = T:AddRightGroupbox("Inventory", "package")
    inv:AddToggle("LobbyStars", { Text = "Auto Open Star (Capsule)", Tooltip = "Opens every owned star of the selected types.", Default = cfg.stars.enable, Callback = set(cfg.stars, "enable") })
    inv:AddDropdown("LobbyStarItems", { Text = "Select Star", Values = labels(starIds, itemName), Multi = true, Default = selected(cfg.stars.items), Callback = picker(cfg.stars, "items") })

    -- Auto Summon Banner
    local sb = T:AddRightGroupbox("Auto Summon Banner", "sparkles")
    local held = false
    local function hold(v)
        if v ~= held then held = v quiet(v) end
    end
    sb:AddToggle("LobbyNoAnim", { Text = "Hide Summon Animation", Tooltip = "Removes the star and unit reveal for every summon and star opening (also your manual ones). A popup per auto pull replaces it.", Default = cfg.summon.hideAnim ~= false, Callback = function(v)
        cfg.summon.hideAnim = v
        Core.save_config()
        hold(v)
    end })
    hold(cfg.summon.hideAnim ~= false)
    sb:AddToggle("LobbyUnselect", { Text = "Unselect if Summoned", Tooltip = "Unselects a target from Special and Legacy once it is obtained.", Default = cfg.summon.unselect, Callback = set(cfg.summon, "unselect") })
    sb:AddToggle("LobbyTeleportBanner", { Text = "Teleport Lobby new Banner", Tooltip = "At the end of a match, return to the lobby instead of replaying or starting the next stage when a selected unit is newly featured.", Default = cfg.summon.teleport, Callback = set(cfg.summon, "teleport") })
    sb:AddDropdown("LobbySellRarity", { Text = "Select Auto Sell Rarity (Summon)", Tooltip = "Sells summoned units of these rarities. Never sells targets, locked units, shinies or units with traits. Mythic and Secret are never sold.", Values = { "Rare", "Epic", "Legendary" }, Multi = true, Default = Core.keys(cfg.summon.sell), Callback = set(cfg.summon, "sell") })
    sb:AddSlider("LobbyGemReserve", { Text = "Keep Gems", Tooltip = "Auto summon never spends below this many gems.", Default = cfg.summon.reserve, Min = 0, Max = 100000, Rounding = 0, Callback = set(cfg.summon, "reserve") })

    local sp = T:AddRightGroupbox("Auto Summoner - Special", "star")
    sp:AddToggle("LobbySpecial", { Text = "Auto Summon (Special)", Tooltip = "Summons only while one of your selected Mythic units is featured in the Special banner.", Default = cfg.special.enable, Callback = set(cfg.special, "enable") })
    unitOpt.special = "LobbySpecialUnits"
    sp:AddDropdown("LobbySpecialUnits", { Text = "Select Summon Unit", Values = {}, Multi = true, Default = {}, Callback = picker(cfg.special, "units") })

    local lg = T:AddRightGroupbox("Auto Summoner - Legacy", "history")
    lg:AddToggle("LobbyLegacy", { Text = "Auto Summon (Legacy)", Tooltip = "Summons only while one of your selected Legacy targets is featured.", Default = cfg.legacy.enable, Callback = set(cfg.legacy, "enable") })
    unitOpt.legacy = "LobbyLegacyUnits"
    lg:AddDropdown("LobbyLegacyUnits", { Text = "Select Summon Unit", Values = {}, Multi = true, Default = {}, Callback = picker(cfg.legacy, "units") })
    lg:AddSlider("LobbyLegacyExchange", { Text = "Auto Exchange Legacy Gem Amount", Tooltip = "Gems exchanged 1:1 into Legacy Gems when they run low. 0 = never.", Default = cfg.legacy.exchange, Min = 0, Max = 5000, Rounding = 0, Callback = set(cfg.legacy, "exchange") })

    local ev = T:AddRightGroupbox("Auto Summoner - Event", "calendar")
    local banners = {}
    for id, b in Banners do if b.active and b._does_not_rotate then table.insert(banners, id) end end
    table.sort(banners)
    ev:AddToggle("LobbyEvent", { Text = "Auto Summon (Event)", Tooltip = "Spends the selected banner's event currency. Select a banner first.", Default = cfg.event.enable, Callback = set(cfg.event, "enable") })
    ev:AddDropdown("LobbyEventBanner", { Text = "Select Banner", Values = banners, Default = cfg.event.banner, AllowNull = true, Callback = set(cfg.event, "banner") })

    -- Unit lists come from the server; fill the two dropdowns once they arrive.
    task.spawn(function()
        local d
        for _ = 1, 30 do d = hatch() if d then break end task.wait(1) end
        if not d or not alive() then return end
        local Options = Hub.UI.Library.Options
        for key, pool in { special = d.special, legacy = d.legacy } do
            local o = Options[unitOpt[key]]
            o:SetValues(labels(pool.Mythic or {}, unitName))
            local want = selected(cfg[key].units)
            local v = {}
            for _, n in want do v[n] = true end
            o:SetValue(v)
        end
    end)
end

return Lobby
