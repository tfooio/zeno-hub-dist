-- Summer tab (docs/features/summer-update.md): Auto Summer Hunt with its own team planner and autopilot settings, plus saved teams per weather.
-- The current weather is the event pad's Weather value (lobby) / LevelData._weather (match); the map comes from get_lobby_more_params.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local env = getgenv()
local LOBBY = Hub.mode == "lobby"
local PAD = "_lobbytemplate_event3"

local cfg = Core.config.summer or {}
Core.config.summer = cfg
cfg.teams = cfg.teams or {} -- saved teams: teams[weather or "default"] = { [slot 1..6] = unit_id }
if cfg.enable == nil then cfg.enable = false end
if cfg.manual == nil then cfg.manual = false end -- true: use the saved teams instead of the planner
cfg.bleed = nil -- the Bleed Instead of Slow toggle is gone (user): see Summer.avoidCard
cfg.edit = cfg.edit or "default"
cfg.needVegito = cfg.needVegito or {} -- weather -> true once it was lost twice in a row without the Vegito pair
cfg.losses = cfg.losses or {} -- weather -> losses in a row
cfg.tune = cfg.tune or { L = 1 } -- card tuner: how many debuff cards a run takes (raised after a win, lowered after a loss)
cfg.follow = cfg.follow or {}
if cfg.follow.enable == nil then cfg.follow.enable = true end
cfg.follow.units = cfg.follow.units or 3 -- teammates' damage units to wait for
cfg.follow.wave = cfg.follow.wave or 7 -- or this wave, whichever comes first
cfg.shop = cfg.shop or { enable = false, keep = 2000 } -- Auto Summon Summer Banner: on / Summer Pearls to leave untouched (a first run keeps 2,000; an existing saved value is not touched)
cfg.sellSkins = cfg.sellSkins or { enable = false, rarity = { Rare = true } } -- Auto Sell Skins: on / skin rarities to sell
cfg.merchant = cfg.merchant or { enable = false, items = {}, known = {}, gemKeep = 5000 } -- Auto Buy Summer Merchant: on / item ids to buy / ids seen so far / gems never spent
cfg.bingo = cfg.bingo or { enable = false } -- Auto Claim Summer Bingo
cfg.portals = nil -- the Summer portal options moved into the Portal Joiner (Joiner tab): Joiner config portal = { order, min, max, lanes }

local Summer = {}
local Units, Weather = Game.data("Units"), Game.data("Weather")
local function alive() return env.ZenoHub == Hub end
local function profile() return Game.loader().load_client_service(script, "LobbyServiceClient").session.profile_data end
-- profile() errors while the game's session is not built yet (a few seconds after a teleport: 929 "attempt to index nil with 'profile_data'" lines in the logs
-- 2026-11-06 to 11-09 from sell skins, plan, bingo, merchant), so the lobby jobs below wait for ready() instead.
local function ready() return Game.profile() ~= nil end
local function call(name, ...) local ok, res = pcall(Game.invoke, name, ...) if not ok then Core.log("ERROR summer", name, res) end return ok and res end
local function wait(pred, sec)
    local t = os.clock()
    while os.clock() - t < sec do if pred() then return true end task.wait(0.25) end
    return false
end
local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in v do o[k] = copy(x) end
    return o
end

local ORDER = { "clear", "rain", "underwater", "windy", "snow", "fire", "sandstorm", "mana", "downpour", "meteor_shower" }
local WEATHERS = {}
for _, id in ORDER do if Weather[id] then table.insert(WEATHERS, id) end end
local function weatherName(id) return id == "default" and "Any weather (default)" or (Weather[id] and Weather[id].name) or id end

function Summer.weather()
    if LOBBY then
        local pad = workspace:FindFirstChild("_EVENT_CHALLENGES") and workspace._EVENT_CHALLENGES.Lobbies:FindFirstChild(PAD)
        local w = pad and pad:FindFirstChild("Weather")
        return w and w.Value ~= "" and w.Value or nil
    end
    return Game.loader().LevelData._weather
end

-- Roles ----------------------------------------------------------------------------------------------------
-- Attack data only holds the debuffs of base units (an evolved unit's setup script is server side), so a unit's attack family is found by
-- cutting its id at the underscores (rukia_bankai_evolved -> rukia_bankai -> rukia). The curated lists below are the user's rules.
local Attacks, Buffs = Game.data("Attacks"), Game.data("Buffs")
local SLOW_B = { slow = true, freeze = true, stun = true, haki_stun = true, rukia_bankai_freeze = true }
local BLEED_B = { bleed = true, power_bleed = true }
local FIRE_B = { amaterasu_fire = true, amaterasu_fire_2 = true, black_fire = true, marco_fire = true, fire = true }
local FIRE_UNITS = { sasuke_3_evolved = true, sasuke_3 = true } -- user: Shinobi (Eternal)'s damage over time is fire (its data tag is lightning_damage)
-- No client data says who bleeds (checked 2026-11-01 on Berserker (Rage) and Menace (Terror): their entries only carry an element tag, their setup
-- scripts are cosmetic, placed units show no bleed stat). This is the wiki's Bleed list (user, 2026-11-01) as unit ids; the wiki still uses old
-- names for some (Juozu = juuzou, Cursed King = sukuna, Demon Girl = nezuko, Elize (True Heart) = erza_samurai), matched through the client
-- setup-script modules that mention bleed. Add ids here when the wiki grows.
local BLEED_UNITS = {}
for id in ("rohan_evolved daki daki_evolved denji denji_evolved denji_secret hidan_unit hidan_unit_evolved atsushi atsushi_evolved erza_samurai " ..
    "ban ban_evolved guts guts_berserker hange hange_evolved juuzou juuzou_evolved levi levi_evolved osaragi osaragi_evolved pitou pitou_evolved " ..
    "stain stain_evolved sukuna unohana nobara kaneki_2 nezuko"):gmatch("%S+") do BLEED_UNITS[id] = true end
local SLOW_FIRST = { "rukia_bankai_evolved", "rukia_bankai", "rukia" } -- user: Rukia is the first choice for slow
local BULBY, CARROT, VEGO = "bulma", "goku_ssj3_evolved", "vegeta_majin_evolved"

local familyBuffs = {}
for id, a in Attacks do
    local fam = tostring(id):match("^(.-):") or tostring(id)
    familyBuffs[fam] = familyBuffs[fam] or {}
    local function scan(v, d)
        if type(v) ~= "table" or d > 8 then return end
        for _, x in v do
            if type(x) == "string" and rawget(Buffs, x) ~= nil then familyBuffs[fam][x] = true elseif type(x) == "table" then scan(x, d + 1) end
        end
    end
    scan(a.hit, 0)
end
local evolvesTo = {}
for id, d in Units do if d.evolved and d.evolved.from then evolvesTo[d.evolved.from] = true end end

local roles = {}
function Summer.role(id)
    if roles[id] then return roles[id] end
    local d = Units[id]
    local r = { id = id }
    roles[id] = r
    if not d then return r end
    r.type = d._base_damage_type
    r.hill = d.hill_unit == true
    if (d.farm_amount or 0) > 0 then r.farm = true return r end
    if id == "erwin" or id == "wendy" or id == "leafa_evolved" then r.buffer = true return r end
    local name = id
    while name do
        for b in familyBuffs[name] or {} do
            if SLOW_B[b] then r.slow = true elseif BLEED_B[b] then r.bleed = true elseif FIRE_B[b] then r.fire = true end
        end
        name = name:match("^(.+)_[^_]+$")
    end
    -- Elements are in the unit data: _secondary_damage_types = { fire_damage = true, ... } (fire 86 units, ice 79, dark 85, lightning 83 ...).
    if FIRE_UNITS[id] or (d._secondary_damage_types and d._secondary_damage_types.fire_damage) then r.fire = true end
    if BLEED_UNITS[id] then r.bleed = true end
    if table.find(SLOW_FIRST, id) then r.slow = true end
    return r
end

-- Planner ----------------------------------------------------------------------------------------------------
-- shortcut: damage / attack cooldown x stat potency only. Upgrade levels, range, AoE, damage over time and trait strength are not modelled, and the
-- weather factors are guesses (Magical / Sandstorm +25% vs resisted type, Blizzard x3 for fire). Replace with measured numbers when there are some.
local function weatherFactor(w, r)
    if r.type ~= "physical" and r.type ~= "magic" then -- true damage ignores resistances
        if w == "snow" then return r.fire and 3 or 0.6 end
        return (w == "windy" and r.hill) and 1.5 or 1
    end
    if w == "mana" then return r.type == "magic" and 1.25 or 0.7 end
    if w == "sandstorm" then return r.type == "physical" and 1.25 or 0.7 end
    if w == "snow" then return r.fire and 3 or 0.6 end
    if w == "windy" then return r.hill and 1.5 or 1 end
    return 1
end

-- Returns { Bulby, Rukia, bleed unit, DPS 1, DPS 2, buffer } as unit ids ("" = nothing), and a text for the log.
function Summer.plan(w, owned, party)
    owned = owned or profile().collection.owned_units
    local cands = {}
    for _, o in owned do
        local c = cands[o.unit_id]
        if Units[o.unit_id] and (not c or Hub.Skins.score(o) > Hub.Skins.score(c.o)) then cands[o.unit_id] = { id = o.unit_id, d = Units[o.unit_id], o = o, r = Summer.role(o.unit_id) } end
    end
    local function usable(c) return (c.o.xp or 0) > 0 end -- level 1 does nothing
    local function score(c)
        local d, ts = c.d, c.o.trait_stats or {}
        -- base numbers only: upgrade tables exist for some units and not for others, so mixing them ranks by data availability
        local s = (d.damage or 0) / math.max(d.attack_cooldown or 1, 0.1) * (ts.potency_stat or 1) * weatherFactor(w, c.r)
        if evolvesTo[c.id] then s *= 0.25 end -- an unevolved unit that can evolve
        return usable(c) and s or s * 0.05
    end
    local used = {}
    local function best(filter)
        local pick
        for _, c in cands do
            if not used[c.id] and filter(c) and (not pick or score(c) > score(pick)) then pick = c end
        end
        return pick
    end
    local function take(c) if c then used[c.id] = true end return c end
    local function dps(c) return not (c.r.farm or c.r.buffer or c.d._show_as_buff_unit) and (c.d.damage or 0) > 0 end
    -- Summer Pearl bonus (user, 2026-11-04): only Summer event units give any. Giselle's skin +40%, Water Goddess and Fishi +40% each ("I believe", UNVERIFIED
    -- against the game), Bulby's Epic skin +5%, Legendary skins +25%; skins only on evolved units. Other evolved Mythics (Elyssia, Elfy ...) give nothing.
    local UNIT_BOOST = { aqua_evolved = 40, ishmael_evolved = 40 }
    local function boost(c) return (UNIT_BOOST[c.id] or 0) + Hub.Skins.pearlBoost(c.o) end
    -- Carry pick: the most pearl bonus among the units that are at least a quarter as strong as the strongest candidate, then the strongest.
    local function carry(filter)
        local top = 0
        for _, c in cands do if not used[c.id] and filter(c) then top = math.max(top, score(c)) end end
        local pick
        for _, c in cands do
            if not used[c.id] and filter(c) and score(c) >= top * 0.25 then
                if not pick or boost(c) > boost(pick) or (boost(c) == boost(pick) and score(c) > score(pick)) then pick = c end
            end
        end
        return pick
    end

    local team, notes = { "", "", "", "", "", "" }, {}
    team[1] = take(cands[BULBY]) and BULBY or ""

    -- Support slots (user, 2026-11-02: no C.E.O., money is not a problem): Rukia in slot 2 and a bleed unit in slot 3, every weather. Rukia is the
    -- only slow unit; a missing one falls back to a damage dealer below.
    for _, id in SLOW_FIRST do
        if cands[id] and not used[id] and usable(cands[id]) then team[2] = take(cands[id]).id break end
    end
    local bleeder = take(best(function(c) return c.r.bleed and usable(c) end))
    if bleeder then team[3] = bleeder.id end

    local d1, d2
    if party then
        -- Party team (user, from friends, 2026-11-03: "best team, +100% reward boost"): Bulby, Elyssia, Zombie (Giselle), Aqua, the best pearl-boost unit
        -- and the buffer. Slots 2 and 3 are upgraded last, so the weaker two sit there. A unit that is not owned or still level 1 is replaced by a damage dealer.
        local function pick(ids) for _, id in ids do if cands[id] and not used[id] and usable(cands[id]) then return take(cands[id]) end end end
        local function any() -- evolved units first, an unevolved one only when no evolved damage dealer is left
            return take(carry(function(c) return dps(c) and usable(c) and not evolvesTo[c.id] end) or carry(function(c) return dps(c) and usable(c) end))
        end
        d1 = pick({ "elyssia_evolved", "elyssia" }) or any()
        d2 = pick({ "giselle_evolved" }) or any() -- user, 2026-11-03: Zombie only evolved, never the unevolved copy
        local aqua = pick({ "aqua_evolved", "aqua" }) or any()
        -- the pearl-bonus unit must be evolved too (user): an unevolved unit that can still evolve never gets the slot
        -- A unit with pearl bonus wins over a stronger one without (Fishi's damage is far under a quarter of the top unit's, so carry() skipped it).
        local booster
        for _, c in cands do
            if not used[c.id] and dps(c) and usable(c) and not evolvesTo[c.id] and boost(c) > 0
                and (not booster or boost(c) > boost(booster) or (boost(c) == boost(booster) and score(c) > score(booster))) then booster = c end
        end
        booster = take(booster or carry(function(c) return dps(c) and usable(c) and not evolvesTo[c.id] end))
        if aqua then team[2] = aqua.id end
        if booster then team[3] = booster.id table.insert(notes, ("pearl bonus unit +%d%%"):format(boost(booster))) end
        if d1 then team[4] = d1.id end
        if d2 then team[5] = d2.id end
        table.insert(notes, "party")
    else
        -- Support slots (user, 2026-11-02: no C.E.O., money is not a problem): Rukia in slot 2 and a bleed unit in slot 3, every weather. Rukia is the
        -- only slow unit; a missing one falls back to a damage dealer below.
        for _, id in SLOW_FIRST do
            if cands[id] and not used[id] and usable(cands[id]) then team[2] = take(cands[id]).id break end
        end
        local bleeder = take(best(function(c) return c.r.bleed and usable(c) end))
        if bleeder then team[3] = bleeder.id end

        -- DPS: solo plays the Vegito pair (user, 2026-11-03: "solo, still prioritize Vegito"); without both of them, or in Blizzard with a fire unit
        -- owned, the carries with the most pearl bonus (see carry).
        local fire = carry(function(c) return c.r.fire and dps(c) and usable(c) end)
        local carrot, vego = cands[CARROT], cands[VEGO]
        if carrot and vego and usable(carrot) and usable(vego) and not (w == "snow" and fire) then
            d1, d2 = take(carrot), take(vego)
            table.insert(notes, "Vegito pair")
        else
            if w == "snow" and fire then d1 = take(fire) end
            d1 = d1 or take(carry(function(c) return dps(c) and usable(c) end))
            d2 = take(carry(function(c) return dps(c) and usable(c) end))
            if d1 and d2 then table.insert(notes, ("pearl bonus %d%%"):format(boost(d1) + boost(d2))) end
        end
        if d1 then team[4] = d1.id end
        if d2 then team[5] = d2.id end
        for _, slot in { 2, 3 } do -- no Rukia / no bleed unit owned: a damage dealer instead
            if team[slot] == "" then
                local d3 = take(carry(function(c) return dps(c) and usable(c) end))
                if d3 then team[slot] = d3.id end
            end
        end
    end

    -- Buffer follows the damage type of the two carries (Commander: physical, Elfy / Windsong: magic).
    local phys, mag = 0, 0
    for _, c in { d1, d2 } do
        if c.r.type == "magic" then mag += score(c) else phys += score(c) end
    end
    local want = phys >= mag and { "erwin", "leafa_evolved", "wendy" } or { "leafa_evolved", "wendy", "erwin" }
    for _, id in want do
        if cands[id] and not used[id] and usable(cands[id]) then team[6] = id break end
    end
    local names = {}
    for i, id in team do names[i] = id ~= "" and (Units[id].name or id) or "-" end
    return team, ("%s: %s%s"):format(weatherName(w), table.concat(names, ", "), #notes > 0 and (" (" .. table.concat(notes, ", ") .. ")") or "")
end

-- Multi farming (user, 2026-11-03): cfg.role "Host" invites the listed players (Joiner > Party Farming) into a party and starts the Hunt for it,
-- "Member" accepts the invite and only equips the party team; a party of two or more plays the party team, alone the Vegito team.
-- UNVERIFIED: that the Summer Hunt pad takes a party (party_pulled_into_lobby is the game's own event for pulling members along).
cfg.role = (cfg.role == "Host" or cfg.role == "Member") and cfg.role or "Off"
function Summer.partyActive() return cfg.role ~= "Off" and Hub.Party ~= nil and Hub.Party.size() >= 2 end
function Summer.member() return cfg.enable and cfg.role == "Member" end -- src/match.lua: the host decides what happens at match end

-- The team to use for a weather: the saved one when Use My Saved Teams is on and it exists, else the planner's.
local function teamFor(w)
    if cfg.manual then
        local t = (w and cfg.teams[w]) or cfg.teams.default
        if t and next(t) then return t, "saved team" end
    end
    if not ready() then return nil end -- the planner reads the profile
    local ok, t, text = pcall(Summer.plan, w, nil, Summer.partyActive())
    if ok then return t, text end
    Core.log("ERROR summer plan", t)
end

-- Equip ---------------------------------------------------------------------------------------------------------
-- Best owned copy of a unit id (evolved, traits, xp: the same ranking Summer Skins uses).
local function best(unitId, owned, taken)
    local pick
    for uuid, o in owned do
        if o.unit_id == unitId and not taken[uuid] and (not pick or Hub.Skins.score(o) > Hub.Skins.score(owned[pick])) then pick = uuid end
    end
    return pick
end

-- Puts a team on the hotbar. Slots left empty are not touched. Returns true when the hotbar matches.
function Summer.apply(t, label)
    if not (LOBBY and t) then return false end
    local col = profile().collection
    local owned = col.owned_units
    local want, taken = {}, {}
    for slot = 1, 6 do
        local id = t[slot]
        if id and id ~= "" then
            want[slot] = best(id, owned, taken)
            if want[slot] then taken[want[slot]] = true else Core.log("summer: no copy of", id, "for slot", slot) end
        end
    end
    local function at(slot) return col.equipped_units[tostring(slot)] or col.equipped_units[slot] end
    -- The server drops calls sent right after another one (found live: back-to-back unequips left a unit on the hotbar), so every
    -- call is checked against the profile and sent again once if it did not take.
    local function step(fn, done)
        for _ = 1, 2 do
            if done() then return end
            fn()
            if wait(done, 2.5) then return end
        end
    end
    local out = {}
    for slot, uuid in want do
        local cur = at(slot)
        if cur and cur ~= uuid then out[cur] = true end
        if owned[uuid].equipped_slot and tostring(owned[uuid].equipped_slot) ~= tostring(slot) then out[uuid] = true end
    end
    for uuid in out do
        step(function() call("unequip_unit", uuid) end, function() return not owned[uuid].equipped_slot end)
    end
    for slot, uuid in want do
        step(function() call("equip_unit", uuid, tostring(slot)) end, function() return at(slot) == uuid end)
    end
    local ok = true
    for slot, uuid in want do if at(slot) ~= uuid then ok = false end end
    Core.log("summer: team", label or "", ok and "equipped" or "NOT fully equipped")
    return ok
end

-- Hunt loop (lobby). One join per 40 s so a slow teleport is not repeated.
local busyUntil, memberKey = 0, nil
function Summer.nudge() busyUntil, memberKey = 0, nil end -- src/watchdog.lua: try the join / the team again right now
local function hunt()
    if os.clock() < busyUntil then return end
    -- Right after a teleport the game's lobby services are not built yet (2026-11-03: the first pass 2 s after load failed on profile_data and the popup UI
    -- and a 120 s wait was already set), so nothing starts until the profile is readable.
    -- A lobby that sits idle says why every 60 s (reported 2026-11-03: matchmaking left the match but never queued again, cause not visible in the log).
    local function idle(why)
        if os.clock() - (Summer.idleLogged or 0) > 60 then Summer.idleLogged = os.clock() Core.log("summer: not joining,", why) end
    end
    if not pcall(profile) then return idle("profile not readable yet") end
    local w = Summer.weather()
    if not w then return idle("no weather on the Hunt pad") end
    if cfg.role == "Member" then -- the host joins the pad and starts; this account equips the team for the weather once it is in the party
        if not Summer.partyActive() then memberKey = nil return end
        local key = w .. tostring(game:GetService("Players").LocalPlayer:GetAttribute("PartyId"))
        if key == memberKey then return end
        busyUntil = os.clock() + 20
        pcall(Hub.Skins.run)
        local t, text = teamFor(w)
        Core.log("summer: party member, team for", text or "-")
        if t and Summer.apply(t, weatherName(w)) then memberKey = key end
        return
    end
    busyUntil = os.clock() + 40
    if cfg.role == "Host" and Hub.Party then Hub.Party.fill(45) end -- invite the listed players and wait for them; alone after that = the solo team
    pcall(Hub.Skins.run) -- summer skins on the best evolved copies first: they carry pearl bonus and damage (nothing to do = silent)
    local t, text = teamFor(w)
    Core.log("summer: team for", text or "-")
    if t and not Summer.apply(t, weatherName(w)) then
        Core.log("ERROR summer: team not equipped, not joining")
        return
    end
    Core.save_config()
    -- Matchmaking that finds no match (2026-11-07: 41 queues in 100 min, 10 watchdog rejoins, nothing started): after two queues in a row with no Hunt,
    -- this Hunt is played from the pad, solo (user, 2026-11-09). cfg.mmFails is saved (a watchdog rejoin reloads the hub) and cleared when a Hunt loads.
    local mm = cfg.matchmaking and Hub.Joiner ~= nil
    if mm and (cfg.mmFails or 0) >= 2 then
        mm, cfg.mmFails = false, 0
        Core.log("summer: matchmaking found no match twice in a row, this Hunt goes through the pad (solo)")
    end
    Core.log("summer: joining the Hunt,", weatherName(w), mm and "(matchmaking)" or "")
    if mm then
        cfg.mmFails = (cfg.mmFails or 0) + 1
        Core.save_config()
        -- MiniTipex's log (2026-11-03): a join 6 s after the lobby loaded died on the popup UI not existing yet ("show_matchmaking_popup" on nil) and the 120 s
        -- wait set below was already running, so that Hunt was lost for two minutes. Wait for the UI, and retry a failed call soon.
        local function uiReady()
            for _ = 1, 60 do
                local ok, ui = pcall(function() return Game.loader().load_client_service(script, "GUIService").notification_windows_ui end)
                if ok and ui and ui.show_matchmaking_popup then return true end
                task.wait(0.5)
            end
        end
        busyUntil = os.clock() + 120 -- a queue can take a while; the lobby teleports us when it finds a match
        local ok, entered = false, "popup UI never appeared"
        if uiReady() then ok, entered = pcall(Hub.Joiner.matchmake, "summer2_event") end
        if not (ok and entered) then
            Core.log("summer: matchmaking not entered", ok and "" or tostring(entered))
            busyUntil = os.clock() + 10
        else
            Core.log("summer: matchmaking queue entered, try", cfg.mmFails)
        end
        return
    end
    call("request_join_lobby", PAD)
    task.wait(1.5)
    call("request_start_game", PAD)
end
if LOBBY then
    task.spawn(function()
        while alive() do
            if cfg.enable then local ok, err = pcall(hunt) if not ok then Core.log("ERROR summer hunt", err) end end
            task.wait(5)
        end
    end)
    -- In a party every player has to press Start on the pad (user, 2026-11-03; the first test with only the host's call let the pad's timer run out): the member
    -- sends its own request_start_game as soon as the host's join pulled it onto the Hunt pad.
    task.spawn(function()
        local lastStart = 0
        while alive() do
            task.wait(1)
            if cfg.enable and cfg.role == "Member" and os.clock() - lastStart > 4 then
                local ok, onPad = pcall(function()
                    local pad = workspace._EVENT_CHALLENGES.Lobbies[PAD]
                    if pad.Teleporting.Value then return false end
                    for _, v in pad.Players:GetChildren() do if v.Value == game:GetService("Players").LocalPlayer then return true end end
                end)
                if ok and onPad then
                    lastStart = os.clock()
                    Core.log("summer: party member on the Hunt pad, start", tostring(call("request_start_game", PAD)))
                end
            end
        end
    end)
end

-- Auto Summon Summer Banner. The banner "Summer2026" is the Sunny Star capsule in banner form (`_MOCK_CAPSULE_BANNER`): 150 Summer Pearls a pull, drops are
-- mostly summer skins plus three Mythic units, pity in `capsule_pity_data`, and its Summon x1 / x10 buttons send buy_from_banner(banner, "gems" | "gems10")
-- like any banner (read from the game's UI code, tested). No unit_added fires for a skin, so success is read from the pearls dropping (the shared lobby pull
-- loop would resend the paid call). The server ignores a call within 3.35 s of the last accepted one without charging.
local BANNER, PULL = "Summer2026", 150
-- The live amount is LocalPlayer._stats._resourceSummerPearls; profile_data.resources.SummerPearls does not follow a purchase (checked 2026-11-02: 33589 stayed while this went to 33439).
local function pearls()
    local st = game:GetService("Players").LocalPlayer:FindFirstChild("_stats")
    local v = st and st:FindFirstChild("_resourceSummerPearls")
    return v and v.Value or 0
end
local function summonBanner()
    for _, n in { 10, 1 } do
        while alive() and cfg.shop.enable and pearls() - cfg.shop.keep >= PULL * n do
            local before = pearls()
            local taken
            for _ = 1, 3 do -- a refused call (cooldown) costs nothing: wait it out and try again, at most 3 times
                call("buy_from_banner", BANNER, n == 10 and "gems10" or "gems")
                taken = wait(function() return pearls() < before end, 4)
                if taken then break end
                task.wait(3.5)
            end
            if not taken then Core.log("ERROR summer banner: a pull of", n, "was not taken") return end
            Core.log("summer banner: summoned", n, "pearls left", pearls())
            task.wait(1.5) -- the new items arrive a moment after the pearls drop
            if cfg.sellSkins.enable then pcall(Summer.sellSkins) end -- right after each pull, not on the loop's timer: a full inventory refuses new items
            task.wait(1.9) -- 3.4 s in all, the server's cooldown between pulls
        end
    end
end
if LOBBY then
    task.spawn(function()
        while alive() do
            if cfg.shop.enable then
                local ok, err = pcall(function()
                    if Hub.Lobby and Hub.Lobby.quietly then Hub.Lobby.quietly(summonBanner) else summonBanner() end
                end)
                if not ok then Core.log("ERROR summer banner", err) end
            end
            task.wait(20)
        end
    end)
end

-- Auto Buy Summer Merchant (user, 2026-11-04: Bulby on the ship, "all the possible items in the shop"). The shop is BSDShop: request_current_bsd_shop returns
-- { [id] = { stock, resource_cost = { id = "SummerPearls", amount } | gem_cost } } for the current interval (read 2026-11-04: star_remnant_limited 5000 x15,
-- StarFruitCapsule 2250 x9, dungeon_key 10000 x1, summer_pearls_exchange 250 gems x10), bought with buy_bsd_shop_item(id, "1"), the same shape as the other category
-- shops (the UI sends "1" / "10" / "100"). The call was only tested without enough pearls (returns nil, nothing spent); a real purchase is UNVERIFIED.
-- Gems go to pearls first (the 5,000-pearl items need them), then the pearl items by the shop's own order. The banner summon spends everything above Keep Summer Pearls,
-- so what the merchant gets is what the summon leaves: raise Keep Summer Pearls to save for the 5,000-pearl items.
local EXCHANGE = "summer_pearls_exchange"
local function gems()
    local st = game:GetService("Players").LocalPlayer:FindFirstChild("_stats")
    local v = st and st:FindFirstChild("gem_amount")
    return v and v.Value or 0
end
local function merchant()
    local ok, shop = pcall(Game.invoke, "request_current_bsd_shop")
    if not (ok and type(shop) == "table") then return end
    -- The stock the shop reports never drops (read 2026-11-04: 10 exchanges bought, stock still 10, and the 30 s loop kept trying); what is left is stock minus
    -- profile_data.bsd_shop_data.bought_items[id], the way the gold shop does it. Right after a purchase the profile may lag, so a refused buy still stops an item.
    local bought = (profile().bsd_shop_data or {}).bought_items or {}
    local list = {}
    for id, it in shop do
        if cfg.merchant.known[id] == nil then cfg.merchant.known[id] = true cfg.merchant.items[id] = true end -- a new item is on until it is unticked
        it.left = (tonumber(it.stock) or 0) - (bought[id] or 0)
        if cfg.merchant.items[id] and it.left > 0 then table.insert(list, it) end
    end
    table.sort(list, function(a, b)
        if (a.id == EXCHANGE) ~= (b.id == EXCHANGE) then return a.id == EXCHANGE end
        return (a.LayoutOrder or 0) < (b.LayoutOrder or 0)
    end)
    for _, it in list do
        local gemCost, rc = tonumber(it.gem_cost), it.resource_cost
        local have, cost, spend
        if gemCost then
            have, cost, spend = function() return gems() - cfg.merchant.gemKeep end, gemCost, gems
        elseif rc and rc.id == "SummerPearls" then
            have, cost, spend = pearls, tonumber(rc.amount), pearls
        end
        if cost and cost > 0 then
            local n = math.min(it.left, math.floor(math.max(have(), 0) / cost))
            for _ = 1, n do
                if not (alive() and cfg.merchant.enable) then return end
                local before = spend()
                call("buy_bsd_shop_item", it.id, "1")
                if not wait(function() return spend() < before end, 4) then
                    Core.log("ERROR summer merchant: buying", it.id, "was not taken (currency stayed at", before .. ")")
                    break
                end
                Core.log("summer merchant: bought", it.id, "for", cost)
                task.wait(0.4)
            end
        end
    end
end
-- Summer Bingo (user, 2026-11-04: "just claim when it's ready"). Ready = the board has a claimable line, the check the game's own NPC marker uses; the claim is
-- the Bingo window's Claim button, claim_summer2_map_board_lines with no arguments (never run for real: the board had nothing claimable when this was written).
local function bingoReady()
    local core = Game.loader().load_core_service(script, "Summer2MapBoardCore")
    local pd = profile()
    local board = core.get_board(game:GetService("Players").LocalPlayer.UserId)
    if not board then return false end
    local wins = pd._summer2_hunt_wins and pd._summer2_hunt_wins.maps or {}
    return #core.get_claimable_lines(board, wins, pd._summer2_map_board_claimed_lines or {}) > 0
end
local function bingo()
    if not bingoReady() then return end
    Core.log("summer bingo: claiming")
    call("claim_summer2_map_board_lines")
    task.wait(5)
    if bingoReady() then Core.log("summer bingo: still claimable after the claim") task.wait(55) end
end
if LOBBY then
    task.spawn(function()
        task.wait(10)
        while alive() do
            for key, fn in { merchant = merchant, bingo = bingo } do
                if cfg[key].enable and ready() then
                    local ok, err = pcall(function()
                        if Hub.Lobby and Hub.Lobby.quietly then Hub.Lobby.quietly(fn) else fn() end
                    end)
                    if not ok then Core.log("ERROR summer", key, err) end
                end
            end
            task.wait(30)
        end
    end)
end

-- Auto Sell Skins (user, 2026-11-02). The game has no sell for skins, only "Confirm Delete" (delete_unique_items with a list of item uuids, read from its
-- inventory UI code). Only this event's skins of the ticked rarities, and one copy of a skin is always kept while an owned unit that can wear it
-- (never a unit that can still evolve) has no summer skin on yet.
local ITEMS, SKIN = Game.data("Items"), Game.data("Skins")
local function skinsToSell()
    local pd = profile()
    local owned = pd.collection.owned_units
    local by = {}
    for _, it in pd.inventory.unique_items do
        local use = ITEMS[it.item_id] and ITEMS[it.item_id].usage
        local sk = use and use.type == "apply_skin" and SKIN[use.skin_id]
        if sk and sk._skin_set == "summer2" and cfg.sellSkins.rarity[sk._skin_rarity] then
            by[sk.id] = by[sk.id] or { sk = sk, uuids = {} }
            table.insert(by[sk.id].uuids, it.uuid)
        end
    end
    local list = {}
    for _, e in by do
        local needed = false
        for _, o in owned do
            if Hub.Skins.fits(e.sk, o.unit_id) and not Hub.Skins.canEvolve(o.unit_id) and not Hub.Skins.wearsSummer(o) then needed = true break end
        end
        for i = needed and 2 or 1, #e.uuids do table.insert(list, e.uuids[i]) end
    end
    return list
end
Summer.skinsToSell = skinsToSell
local selling = false -- the loop and the summon both call it
function Summer.sellSkins()
    if selling then return 0 end
    selling = true
    local ok, res = pcall(function()
        return Summer.sellSkinsNow()
    end)
    selling = false
    if not ok then error(res, 0) end
    return res
end
function Summer.sellSkinsNow()
    local list = skinsToSell()
    local pd = profile()
    local function have() local n = 0 for _ in pd.inventory.unique_items do n += 1 end return n end
    for i = 1, #list, 50 do
        local chunk = { table.unpack(list, i, math.min(i + 49, #list)) }
        local before = have()
        call("delete_unique_items", chunk)
        wait(function() return have() < before end, 4)
        Core.log("summer: sold skins", #chunk, "items left", have())
    end
    return #list
end
if LOBBY then
    task.spawn(function()
        while alive() do
            if cfg.sellSkins.enable and ready() then local ok, err = pcall(Summer.sellSkins) if not ok then Core.log("ERROR summer sell skins", err) end end
            task.wait(4) -- the inventory fills 10 skins every 3.4 s while Auto Summon runs
        end
    end)
end

-- Match: the weather rotates every hour (told by the update log); a replay after the hour changed gets the new weather but the old
-- team, so go back to the lobby and let the hunt loop equip the right one. UNVERIFIED that the rotation lines up with the hour.
local hourAtLoad = math.floor(workspace:GetServerTimeNow() / 3600)
local function inHunt()
    local ok, id = pcall(function() return Game.loader().LevelData.id end)
    return ok and id == "summer2_event"
end
function Summer.want_lobby()
    if not (cfg.enable and not LOBBY and inHunt()) then return false end
    -- Use Matchmaking (user, 2026-11-03): every run ends in the lobby, never a replay with the same strangers (runs 90, 93, 95 replayed in place).
    if cfg.matchmaking then return true end
    return math.floor(workspace:GetServerTimeNow() / 3600) ~= hourAtLoad
end

-- Autopilot -------------------------------------------------------------------------------------------------------
-- Inside a Hunt started with Auto Summer Hunt on, Auto Play and the ability module run on these settings instead of the saved ones
-- (nothing from the saved Auto Play config is read, nothing is saved). Rules (user, 2026-11-01): farms are placed first and upgraded as soon
-- as the money is there, before any other unit is placed; Rukia and the bleed unit placed to their cap and upgraded once the carries are done;
-- buffers placed at most 4 times and never upgraded; the carries by damage per yen (Auto Fuse stops Carrot and Vego at 7, casts, then
-- puts the money into Vegito first). Which unit is in a slot is read from the hotbar when the setting is first asked.
local function slotUnit(slot)
    local ok, col = pcall(function() return Game.loader().load_client_service(script, "GUIService").session.collection.collection_profile_data end)
    if not ok then return nil end
    local uuid = col.equipped_units[slot] or col.equipped_units[tostring(slot)]
    local u = uuid and col.owned_units[uuid]
    return u and u.unit_id
end
local function rule(slot) -- place cap, upgrade cap (Auto Play: 0 = as many / max, -1 = after the others, -2 = never)
    local id = slotUnit(slot)
    if not id then return 0, 0 end
    local r = Summer.role(id)
    if r.farm then return 0, 0 end
    if r.buffer then return 4, -2 end -- placed at most 4 times, never upgraded (user)
    -- user, 2026-11-02: every unit but the buffers gets its most placements (Somber / Osaragi, a bleed unit, caps at 4 itself); the support
    -- slots (2 Rukia, 3 bleed unit) are upgraded once the carries are done
    if slot == 2 or slot == 3 then return 0, -1 end
    return 0, 0
end

local function pilotOn() return cfg.enable and not LOBBY and inHunt() end
Summer.piloting = pilotOn -- src/match.lua: an autopilot Hunt always replays, whatever the Game tab says

-- Regen: no enemy in the Hunt's data regenerates (checked 2026-11-01: roster summer2_1..5, bosses, rider, shade, star golem, no regen field
-- anywhere in Units); it only comes from the "Enemy Regen" challenge cards, and the card picker is ours. So during an autopilot Hunt the
-- picker skips those cards unless a bleed unit (it stops regen, user) is on the hotbar, and the planner puts one there in Inferno.
-- Card order inside an autopilot Hunt (user, after a loss at wave 43 with Enemy Health x5, Enemy Speed II and Random Curses II picked):
-- stat buffs first, special / weather cards next, then the debuff cards from the mildest up. Lower number = picked first.
local BUFF_ORDER = { "Yen", "Attack", "Range", "Active Cooldown", "Cooldown", "Boss Damage", "Double Attack", "Random Blessings", "Explosive Deaths", "New Path" }
local DEBUFF_ORDER = { "Enemy Health", "Plated Enemies", "Resistant Enemies", "Spellproof Enemies", "Enemy Shield", "Random Curses", "Enemy Regen", "Enemy Speed" }
local function parseCard(card)
    local name = tostring(card):gsub("^%W+%s*", ""):gsub("^%-%s*", "")
    local base, tier = name:match("^(.-)%s+([IV]+)$")
    return base or name, ({ I = 1, II = 2, III = 3 })[tier or ""] or 1
end

-- Card tuner (user, 2026-11-02: maximize currency while still clearing the stage). Debuff cards raise the pearl reward and the risk. A run takes
-- cfg.tune.L debuff cards (the mildest first) and otherwise buffs; the run logger raises L after a win and lowers it after a loss, so it settles
-- at the hardest setting that still wins. A card is forced when only debuffs are offered.
-- Card presets (user, from friends' advice 2026-11-02), cfg.cardMode: Easy = buffs only; Medium = also Enemy Regen and Enemy Shield (the only
-- debuffs that are okay), first so they pay out; Hard = the tuner above; Impossible = every debuff first, highest tier, for the biggest reward.
-- A debuff the preset ignores is ranked last, so it is only picked when nothing else is offered.
-- Fallback when a preset ignores every card offered (user, 2026-11-03): the debuff that hurts least comes first, the lowest tier of it first. Shield and
-- Health / Speed are the ones friends call fine, Regen is harmless with a bleed unit (avoidCard puts it last without one), resists "a no no always".
local FALLBACK_ORDER = { "Enemy Shield", "Enemy Health", "Enemy Speed", "Enemy Regen", "Random Curses", "Plated Enemies", "Spellproof Enemies", "Resistant Enemies" }
local function ignored(name, tier) return 500 + (table.find(FALLBACK_ORDER, name) or #FALLBACK_ORDER + 1) * 10 + tier end
local CARD_MODES = { "Easy", "Medium", "Hard", "Impossible", "Custom" }
cfg.cardMode = table.find(CARD_MODES, cfg.cardMode) and cfg.cardMode or "Easy"
-- Custom preset (friends' request, 2026-11-03): the same kind of priority list as the Game tab's Modifier Priority, kept apart in this tab, plus one entry
-- for the weather cards (their titles start with an emoji and change with the weather). Rank 1 first; the counter is the most picks per run (0 = no limit).
local CUSTOM_CARDS = { "Yen I", "Yen II", "Yen III", "Active Cooldown I", "Active Cooldown II", "Active Cooldown III",
    "Cooldown I", "Cooldown II", "Cooldown III", "Boss Damage I", "Boss Damage II", "Boss Damage III",
    "Random Blessings I", "Random Blessings II", "Random Blessings III", "Weather Cards", "Enemy Shield I", "Enemy Shield II",
    "Enemy Shield III", "Explosive Deaths I", "Explosive Deaths II", "Explosive Deaths III", "Random Curses I",
    "Random Curses II", "Random Curses III", "Enemy Health III", "Enemy Health II", "Enemy Health I",
    "Enemy Speed III", "Enemy Speed II", "Enemy Speed I", "Enemy Regen III", "Enemy Regen II", "Enemy Regen I",
    "Attack I", "Attack II", "Attack III", "Range I", "Range II", "Range III", "Double Attack", "New Path",
    -- the resist cards (seen in the offers log, missing from Nousigi's list); last by default: friends say resists are never worth it
    "Plated Enemies I", "Plated Enemies II", "Plated Enemies III", "Resistant Enemies I", "Resistant Enemies II", "Resistant Enemies III",
    "Spellproof Enemies I", "Spellproof Enemies II", "Spellproof Enemies III" }
-- Every weather card seen in the offers log (2026-11-03), by name; the card's title in game carries the weather emoji in front. { row tag, icon, names }
local WEATHER_CARDS = {
    { "Snow", "snowflake", { "Bonfire", "Frostbite", "Hailstorm", "Ice Breaker", "Permafrost", "Whiteout" } },
    { "Mana", "sparkles", { "Arcane Storm", "Arcane Ward", "Dispel", "Leyline", "Mana Shield", "Mana Surge" } },
    { "Storm", "cloud-lightning", { "Conductor", "Eye of the Storm", "Lightning Rod", "Squall", "Supercell", "Thunderhead" } },
    { "Flood", "waves", { "Low Tide", "Rising Tide", "Salvage", "Tidal Surge", "Tsunami" } },
    { "Star", "star", { "Cosmic Rays", "Doomsday", "Stardust", "Starforged", "Wishing Star" } },
    { "Rain", "cloud-rain", { "Flash Flood", "Mud", "Rain Barrel", "Torrent", "Washout" } },
    { "Wind", "wind", { "Crosswind", "Cyclone", "Gale", "Grounded", "Kite Strings" } },
    { "Sand", "sun", { "Buried Treasure", "Clear Skies", "Dust Devil", "Haboob", "Sand Armor", "Sandblast" } },
    { "Fire", "flame", { "Cinders", "Firebreak", "Heatwave", "Phoenix", "Scorch" } },
}
-- The weather cards have their own list (user, 2026-11-03, for organization): the main list holds one "Weather Cards" row, the position of the whole group among
-- the standard cards, and Custom Weather Card Priority orders the cards inside the group (cfg.weatherRank). "Other Weather" = a weather card not in the list.
local WEATHER_OF, WEATHER_LIST = {}, {} -- card name -> { tag, icon, names }; names in list order
for _, w in WEATHER_CARDS do
    for _, n in w[3] do WEATHER_OF[n] = w table.insert(WEATHER_LIST, n) end
end
table.insert(WEATHER_LIST, "Other Weather")
cfg.customRank, cfg.customCap, cfg.weatherRank = cfg.customRank or {}, cfg.customCap or {}, cfg.weatherRank or {}
for n in WEATHER_OF do cfg.customRank[n] = nil end -- an earlier build kept them in the main list
for i, c in CUSTOM_CARDS do
    if cfg.customRank[c] == nil then cfg.customRank[c] = i end
    if cfg.customCap[c] == nil then cfg.customCap[c] = 0 end
end
for i, n in WEATHER_LIST do if cfg.weatherRank[n] == nil then cfg.weatherRank[n] = i end end
-- Row key of a card title: its name without the "+ " / "- " / weather emoji in front; a weather card that is not listed is "Other Weather".
local function customKey(card)
    local s = tostring(card)
    local name = (s:gsub("^[^%w]+", ""))
    if WEATHER_OF[name] then return name end
    if (s:byte(1) or 0) > 127 then return "Other Weather" end
    return name
end
-- Enemy Health and Enemy Speed are okay up to a point (friends, user: "about 150%" for health; resist cards never). Each is capped at cfg.<cap> percent
-- over the run. The amount is read from the offer's effects (format below, verified from the offers log 2026-11-03: Health I / II / III = +50 / 80 / 200 %,
-- Speed I / II / III = +25 / 50 / 100 %); a capped card whose amount cannot be read is logged and then taken without a cap.
local OKAY_DEBUFFS = { ["Enemy Regen"] = true, ["Enemy Shield"] = true, ["Enemy Health"] = true, ["Enemy Speed"] = true }
-- Effects as the offers log shows them (2026-11-03): Health = { type = "enemy_stat_mul", stat = "health", amount = 0.5 }, Speed = { type = "enemy_speedup", amount = 0.25 };
-- every debuff card also carries { type = "candy_multiplier", amount = 0.3 }, the pearl bonus it adds (Squall's weather card 0.5).
local CAPPED = { ["Enemy Health"] = { type = "enemy_stat_mul", stat = "health", cap = "hpCap" }, ["Enemy Speed"] = { type = "enemy_speedup", cap = "speedCap" } }
cfg.hpCap = tonumber(cfg.hpCap) or 150
cfg.speedCap = tonumber(cfg.speedCap) or 50 -- guess, no number from the user yet
local run = { cards = {}, debuffs = 0, total = {}, picked = {} } -- total[card] = percent taken so far this run, picked[custom key] = picks
local function amountOf(opt, spec) -- percent a card adds, nil when the offer carries no readable amount
    local sum
    for _, e in type(opt) == "table" and type(opt.effects) == "table" and opt.effects or {} do
        if type(e) == "table" and e.type == spec.type and e.stat == spec.stat and tonumber(e.amount) then sum = (sum or 0) + e.amount * 100 end
    end
    return sum
end
-- Weather cards (user, 2026-11-03: "do the presets support the weather ones?"). Read from the 44 weather offers in the offers log: a card that gives pearls
-- (candy_multiplier) is a debuff card and a card without it is free (Ice Breaker boss damage, Leyline, Frostbite -30 % enemy speed, Salvage yen ...).
-- A debuff weather card is mild when its only harm is more shield / regen / health / speed (Squall, Hailstorm, Permafrost, Mana Shield, Sand Armor ...) and harsh
-- when it adds resistance, cuts our range or speeds up our cooldowns, flying chance and so on (Whiteout, Supercell, Haboob, Cosmic Rays, Cyclone ...).
-- UNVERIFIED: the meaning of burst_speed, golem_chance and lightning_strikes (Tidal Surge, Wishing Star, Lightning Rod); the first two count as harsh when paired with pearls.
local MILD_TYPES = { enemy_shield = true, enemy_regen = true, enemy_stat_mul = true, enemy_speedup = true, candy_multiplier = true, secret_drop = true }
local GOOD_TYPES = { enemy_amp_specific = true, boss_damage = true, resource_gain = true }
local function weatherInfo(opt) -- pearls bonus (fraction), mild
    local pearls, mild = 0, true
    for _, e in type(opt) == "table" and type(opt.effects) == "table" and opt.effects or {} do
        if type(e) == "table" then
            if e.type == "candy_multiplier" then pearls += tonumber(e.amount) or 0 end
            if (e.type == "enemy_stat_mul" and e.stat ~= "health") or not (MILD_TYPES[e.type] or GOOD_TYPES[e.type]) then mild = false end
        end
    end
    return pearls, mild
end
local function isWeatherCard(card) return (tostring(card):byte(1) or 0) > 127 end

-- Star cards (user, 2026-11-09, after days afk: "a toggle that always selects the card that gives you Star Remnants or Broken Star"). The offers log shows
-- Star Remnants as a card effect: { type = "add_reward", reward = { item = { { item_id = "star_remnant_limited", amount = 5, chance = 1 } } } }, seen on 37 of ~600
-- offers of the tier III debuff cards (Enemy Health / Regen / Shield / Speed III, Resistant and Spellproof Enemies III) and Random Curses II, at waves 38, 41 and 47.
-- Broken Star (Limited) is in no card (0 mentions in the three logs); the game says it is "rarely dropped by Star Golems during Starfall weather", so the Starfall
-- card 🌠 Wishing Star (+100% Star Golem Chance, effect golem_chance) is the card that raises it. A reward card wins over Wishing Star, both over every other card.
local STAR_ITEMS = { "star_remnant", "broken_star" } -- item id prefixes (star_remnant_limited, broken_star_limited)
function Summer.starCard(opt)
    local golem
    for _, e in type(opt) == "table" and type(opt.effects) == "table" and opt.effects or {} do
        if type(e) == "table" then
            if e.type == "add_reward" and type(e.reward) == "table" then
                for _, it in type(e.reward.item) == "table" and e.reward.item or {} do
                    for _, p in STAR_ITEMS do if tostring(it.item_id):sub(1, #p) == p then return "reward" end end
                end
            elseif e.type == "golem_chance" and (tonumber(e.amount) or 0) > 0 then golem = true end
        end
    end
    return golem and "golem" or nil
end

function Summer.cardRank(card, opt)
    if not pilotOn() then return nil end
    if cfg.starCards then
        local star = Summer.starCard(opt)
        if star then return star == "reward" and -2e9 or -1e9 end -- below every other rank, and gameplay.lua skips avoidCard for it
    end
    -- "Double Attack, Double Cooldown" doubles ability cooldowns too and breaks the Auto Commander / Rukia chains (user): last in every preset, picked
    -- only when it is the whole offer. (The "- Cooldown" cards are the other way round: they cut cooldowns.)
    if tostring(card):find("Double Cooldown", 1, true) then return 2e9 end
    if cfg.cardMode == "Custom" then
        local key = customKey(card)
        -- a weather card sits behind its group's row in the main list, in the order of the weather list (that is always under 1 rank apart)
        if WEATHER_OF[key] or key == "Other Weather" then return 100 + (cfg.customRank["Weather Cards"] or 1000) + (cfg.weatherRank[key] or 1000) / 1000 end
        local cap = cfg.customCap[key] or 0
        if cap > 0 and (run.picked[key] or 0) >= cap then return 5e8 end -- over its cap: only when nothing else is offered
        return 100 + (cfg.customRank[key] or 1000)
    end
    if isWeatherCard(card) then
        local pearls, mild = weatherInfo(opt)
        if pearls <= 0 then return 250 end -- a free weather card: after the stat buffs, before any debuff
        local mode, okay = cfg.cardMode, false
        if mode == "Impossible" then return 50 - pearls * 10 end -- the most pearls first
        if mode == "Medium" then
            okay = mild
            for name, spec in CAPPED do -- its health / speed counts toward the same caps as the standard cards
                local a = amountOf(opt, spec)
                if okay and a and a > 0 and (run.total[name] or 0) + a > cfg[spec.cap] then okay = false end
            end
        elseif mode == "Hard" then
            okay = run.debuffs < cfg.tune.L
        end
        return okay and 60 or (mild and 525 or 605) -- ignored: the mild ones before the harsh ones, both behind every standard debuff in the fallback
    end
    local base, tier = parseCard(card)
    for i, n in DEBUFF_ORDER do
        if base == n then
            local mode = cfg.cardMode
            if mode == "Impossible" then return 50 + i * 10 + (4 - tier) end
            if mode == "Medium" then
                local okay = OKAY_DEBUFFS[n]
                local capped = CAPPED[n]
                if okay and capped then
                    local pct = amountOf(opt, capped)
                    if not pct then Core.log("summer: " .. n .. " card without a readable amount, cap not applied") end
                    if pct and (run.total[n] or 0) + pct > cfg[capped.cap] then okay = false end
                end
                return okay and (50 + i * 10 + (4 - tier)) or ignored(n, tier)
            end
            if mode == "Easy" then return ignored(n, tier) end
            return run.debuffs < cfg.tune.L and (50 + i * 10 + tier) or ignored(n, tier)
        end
    end
    for i, n in BUFF_ORDER do if base == n then return 100 + i * 10 + (4 - tier) end end -- a higher tier of a buff first
    return 300 -- weather and other special cards
end

function Summer.cardPicked(card, wave, offered, opt)
    if not pilotOn() then return end
    if cfg.starCards and Summer.starCard(opt) then Core.log("summer: star card taken,", card, Summer.starCard(opt)) end
    table.insert(run.cards, { wave = wave, card = card, offered = offered })
    run.picked[customKey(card)] = (run.picked[customKey(card)] or 0) + 1
    local base = parseCard(card)
    if table.find(DEBUFF_ORDER, base) then run.debuffs += 1 end
    if isWeatherCard(card) and weatherInfo(opt) > 0 then run.debuffs += 1 end -- a pearl weather card is a debuff card for the tuner
    for name, spec in CAPPED do -- standard and weather cards alike add to the health / speed totals
        local a = amountOf(opt, spec)
        if a then run.total[name] = (run.total[name] or 0) + a end
    end
end

local bleedOnHotbar
function Summer.avoidCard(card)
    if not (pilotOn() and tostring(card):find("Regen")) then return false end
    if bleedOnHotbar == nil then
        bleedOnHotbar = false
        for slot = 1, 6 do
            local id = slotUnit(slot)
            if id and Summer.role(id).bleed then bleedOnHotbar = true end
        end
    end
    return not bleedOnHotbar
end

-- Run logger (Data/summer_runs.jsonl, one JSON line per Hunt round) and the tuner's update. The pearl reward is stored as the game sends it.
if not LOBBY then
    -- A Hunt loaded: matchmaking works (LevelData is set a moment after the match loads, hence the delay).
    task.delay(20, function()
        if alive() and (cfg.mmFails or 0) > 0 and inHunt() then cfg.mmFails = 0 Core.save_config() end
    end)
    local HttpService = game:GetService("HttpService")
    local function hotbarRecord()
        local out = {}
        local ok, col = pcall(function() return Game.loader().load_client_service(script, "GUIService").session.collection.collection_profile_data end)
        if not ok then return out end
        for slot = 1, 6 do
            local uuid = col.equipped_units[slot] or col.equipped_units[tostring(slot)]
            local o = uuid and col.owned_units[uuid]
            if o then out[slot] = { unit = o.unit_id, skin = o.skin and o.skin._skin_id, xp = math.floor(o.xp or 0) } end
        end
        return out
    end
    table.insert(Hub.connections, { Disconnect = Core.on("game_finished", function(result)
        if not pilotOn() or type(result) ~= "table" then return end
        local w = Summer.weather()
        local stats = result.stats or {}
        local victory = result.victory == true
        local rewards = {}
        for k, v in result.resource_reward or {} do rewards[tostring(k)] = tonumber(v) or 0 end
        local rec = {
            date = os.date("!%Y-%m-%dT%H:%M:%SZ"), weather = w, map = Game.loader().LevelData.map, victory = victory,
            waves = stats.waves_completed, time = stats.time_taken, kills = stats.kills, L = cfg.tune.L, debuffs = run.debuffs,
            cards = run.cards, team = hotbarRecord(), needVegito = cfg.needVegito[w] == true, rewards = rewards, gems = result.gem_reward,
        }
        local path = Core.paths.data .. "/summer_runs.jsonl"
        local line = HttpService:JSONEncode(rec) .. "\n"
        pcall(function() if isfile(path) then appendfile(path, line) else writefile(path, line) end end)
        -- Tuner: L follows the result; two losses in a row at a weather switch it to the Vegito pair, four wins in a row there try the boost team again.
        if cfg.cardMode == "Hard" then cfg.tune.L = victory and math.min(cfg.tune.L + 1, 8) or math.max(cfg.tune.L - 1, 0) end -- other presets are fixed
        if victory then
            cfg.losses[w] = 0
            cfg.wins = cfg.wins or {}
            cfg.wins[w] = (cfg.wins[w] or 0) + 1
            if cfg.needVegito[w] and cfg.wins[w] >= 4 then cfg.needVegito[w] = nil cfg.wins[w] = 0 end
        else
            cfg.losses[w] = (cfg.losses[w] or 0) + 1
            if cfg.wins then cfg.wins[w] = 0 end
            if cfg.losses[w] >= 2 then cfg.needVegito[w] = true end
        end
        Core.log(("summer: run %s %s %s waves %s debuff cards %d -> tuner L %d%s"):format(tostring(w), rec.map, victory and "WIN" or "loss", tostring(rec.waves), run.debuffs, cfg.tune.L, cfg.needVegito[w] and " (Vegito pair needed)" or ""))
        run = { cards = {}, debuffs = 0, total = {}, picked = {} }
        Core.save_config()
    end) })
end

function Summer.pilot(defaults, methods)
    if not pilotOn() then return nil end
    local o = copy(defaults)
    o.enable, o.upgrade, o.upgrade_place, o.focus_farm, o.opening, o.fuse = true, true, false, true, true, true
    o.method = methods[2] -- most damage per yen (farms and the fusion pair still come first, see upgradeList)
    -- Placement order (user: everything placed as soon as possible, only the farms first): farms, then the two carries, the buffer, the support unit last.
    o.order = { 1, 6, 2, 3, 4, 5 }
    -- Auto Play only reads `order` when place_custom is set (it was not, so every Hunt placed in hotbar order: log 2026-11-09, slots 1, 2, 2, 2, 2, 3, 3, 6 ...).
    -- The order is made for the planner's team (support unit in slot 2); a saved team keeps the hotbar order, farms first.
    o.place_custom = not cfg.manual
    o.kind, o.mid, o.slotpos, o.mode_preset = {}, {}, {}, {}
    -- Follow Teammates (user, 2026-11-03, for Use Matchmaking runs with strangers; not for parties): the farms are placed at once, the other units wait until
    -- cfg.follow.units damage units of the others stand or wave cfg.follow.wave is reached (Bulby is upgraded meanwhile, no cap on farms), then stand
    -- where the others' damage units are (median distance along the lane). Alone in the match nothing is held.
    local Players = game:GetService("Players")
    -- Matchmaking only (user, 2026-11-03): friends running the same script would all wait for each other, so a party, or a Hunt that did not come from
    -- the Use Matchmaking queue, places normally.
    local function following()
        return cfg.follow.enable and cfg.matchmaking and #Players:GetPlayers() > 1 and Hub.AutoPlay ~= nil
            and not (Hub.Party and Hub.Party.size() >= 2)
    end
    o.wave = setmetatable({}, { __index = function(_, slot)
        if not following() then return 0 end
        local id = slotUnit(slot)
        if not id or Summer.role(id).farm then return 0 end
        local ok, n = pcall(Hub.AutoPlay.teammates)
        if ok and n >= cfg.follow.units then return 0 end
        return workspace._wave_num.Value >= cfg.follow.wave and 0 or math.huge
    end })
    local baseDistance = o.distance
    o.distance = nil
    setmetatable(o, { __index = function(_, k)
        if k ~= "distance" then return nil end
        if following() then
            local ok, n, med = pcall(Hub.AutoPlay.teammates)
            if ok and n > 0 and med then return med * 100 end
        end
        return (Summer.laneDistance and Summer.laneDistance()) or baseDistance -- more than one lane: where they meet (below)
    end })
    o.limit = setmetatable({}, { __index = function(_, slot) return (rule(slot)) end })
    o.ulimit = setmetatable({}, { __index = function(_, slot) return select(2, rule(slot)) end })
    return o
end

function Summer.pilotAbility(smartOrder)
    if not pilotOn() then return nil end
    local o = { smart = true, normal = true, smart_units = {} }
    for _, id in smartOrder do o.smart_units[id] = true end
    return o
end

-- Summer portals (user, 2026-11-04: use the Auto Play settings, and merge this into the Portal Joiner, which opens the portals, with tiers). The Summer 2026
-- portals are the Sky Portal (portal_item__skypiea, tiered by portal_depth, 20 waves) and the secret Explosion Mage's Portal (portal_summer2_secret, 30 waves);
-- both levels have portal_group "summer2". In such a match, with Joiner > Portal Joiner > Place Where Lanes Meet on, Auto Play runs on the user's saved
-- settings with one change: Distance Percentage comes from the lanes. With more than one lane the units stand where the lanes have met (read 2026-11-04, a tier 3
-- Sky Portal: 3 lanes of 492 / 644 / 622 studs that all end at the base and are within 20 studs of each other from 93% of the longest lane; at 85% a unit on
-- lane 2 was 30 studs from lane 1, out of its 21 range; the user called 93% "the perfect spot").
local PORTAL_REACH = 18 -- studs: every other lane has to be this close to the spot (a unit's range is about 21 before upgrades)
-- Every stage with more than one lane (user, 2026-11-09; it was Summer portals only): a Hunt on Sky Island stood at 50% of one lane, 116 studs from the
-- other two, and the three multi-lane Hunt maps won 7 of 17 rounds against 154 of 192 on single-lane maps (summer_runs.jsonl). Saved maps with more than
-- one lane: skypiea (lanes meet at 93%), shibuya (86%), assassin_park (64%). The toggle is still Joiner config portal.lanes (Auto Play tab).
local function lanesOn()
    local j = Core.config.joiner and Core.config.joiner.portal
    return not LOBBY and not (j and j.lanes == false)
end

local laneCache -- nil: not read yet, false: one lane (nothing to change), number: percent along the longest lane
local function laneDistance()
    if laneCache ~= nil then return laneCache or nil end
    local root = workspace:FindFirstChild("_BASES") and workspace._BASES:FindFirstChild("pve")
    root = root and root:FindFirstChild("LANES")
    if not root or #root:GetChildren() == 0 then return nil end -- the map is still loading: ask again next time
    local lanes = {}
    for _, lane in root:GetChildren() do
        local num, spawn, final = {}, nil, nil
        for _, p in lane:GetChildren() do
            if p:IsA("BasePart") then
                if p.Name == "spawn" then spawn = p elseif p.Name == "final" then final = p elseif tonumber(p.Name) then table.insert(num, p) end
            end
        end
        table.sort(num, function(a, b) return tonumber(a.Name) < tonumber(b.Name) end)
        local pts = {}
        if spawn then table.insert(pts, spawn.Position) end
        for _, p in num do table.insert(pts, p.Position) end
        if final then table.insert(pts, final.Position) end
        local total = 0
        for i = 1, #pts - 1 do total += (pts[i + 1] - pts[i]).Magnitude end
        if #pts >= 2 and total > 0 then table.insert(lanes, { pts = pts, total = total }) end
    end
    if #lanes == 0 then return nil end
    local function at(l, frac)
        local want, run = frac * l.total, 0
        for i = 1, #l.pts - 1 do
            local len = (l.pts[i + 1] - l.pts[i]).Magnitude
            if run + len >= want then return l.pts[i]:Lerp(l.pts[i + 1], (want - run) / math.max(len, 1e-6)) end
            run += len
        end
        return l.pts[#l.pts]
    end
    local ref = lanes[1]
    for _, l in lanes do if l.total > ref.total then ref = l end end
    local function gap(l, a)
        local best = math.huge
        for g = 0, 100 do best = math.min(best, (at(l, g / 100) - a).Magnitude) end
        return best
    end
    local from = 1
    if #lanes > 1 then
        for f = 100, 0, -1 do
            local a, ok = at(ref, f / 100), true
            for _, l in lanes do if l ~= ref and gap(l, a) > PORTAL_REACH then ok = false break end end
            if not ok then break end
            from = f / 100
        end
        from = math.clamp(from, 0.5, 0.95)
    end
    laneCache = #lanes > 1 and from * 100 or false
    if #lanes > 1 then Core.log(("lanes: %d, units stand at %.0f%% of the longest lane"):format(#lanes, from * 100)) end
    return laneCache or nil
end
function Summer.laneDistance() return lanesOn() and laneDistance() or nil end

-- The saved Auto Play settings behind a proxy that answers Distance Percentage from the lanes. Not a copy: what the Auto Play tab changes in the match
-- is read at once and saved (a copy lost it at the next match).
function Summer.lanePilot(saved)
    if not lanesOn() then return nil end
    return setmetatable({}, {
        __index = function(_, k)
            if k == "distance" then return laneDistance() or saved.distance end
            return saved[k]
        end,
        __newindex = function(_, k, v) saved[k] = v end,
    })
end

-- UI --------------------------------------------------------------------------------------------------------
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local lib = Hub.UI.Library
    -- Options that do not apply to the current choices are hidden (docs/review/findings.md, UI proposal B1); applyVis runs after every box exists and on each choice.
    local function applyVis() end -- replaced below; a saved-config load may fire a callback before then
    local followT, followU, followW, hpS, speedS, cbox, wbox
    local hunt_box = Tabs.Summer:AddLeftGroupbox("Summer Hunt", "sun")
    if not LOBBY then hunt_box:AddLabel("Works in the lobby only (saved here).", true) end
    hunt_box:AddToggle("SummerMM", { Text = "Use Matchmaking", Tooltip = "Queues in Global Matchmaking instead of the solo pad; the hub types the game's captcha for you. Turning it on shows the Follow Teammates options.", Default = cfg.matchmaking, Callback = function(v) cfg.matchmaking = v Core.save_config() applyVis() end })
    hunt_box:AddToggle("SummerHunt", { Text = "Auto Summer Hunt", Tooltip = "Fully automatic: in the lobby it plans and equips the team for the current weather (this swaps your equipped units), joins the Summer Hunt and starts it. In the Hunt, Auto Play and the abilities run on their own settings (your saved Auto Play settings are not used). At match end it returns to the lobby when the hour changed.", Default = cfg.enable, Callback = function(v) cfg.enable = v Core.save_config() end })
    hunt_box:AddToggle("SummerManual", { Text = "Use My Saved Teams", Tooltip = "Use the teams saved under Weather Teams instead of the planner (a weather without a team falls back to the planner).", Default = cfg.manual, Callback = function(v) cfg.manual = v Core.save_config() end })
    hunt_box:AddDropdown("SummerRole", { Text = "Multi Farm Role", Tooltip = "Off: solo, plays the Vegito team. Host: invites the players listed in Joiner > Party Farming into a party, waits for them, then joins the Hunt and starts it; a party plays Elyssia, Zombie, Aqua, the best pearl-bonus unit, a buffer and Bulby. Member: accepts the host's invite (turn on Auto Accept Party Invite there) and equips the party team; the host does the joining.", Values = { "Off", "Host", "Member" }, Default = cfg.role, Callback = function(v) cfg.role = v Core.save_config() end })
    followT = hunt_box:AddToggle("SummerFollow", { Text = "Follow Teammates' Placement", Tooltip = "Only with Use Matchmaking on and no party: farms go down at once, the other units wait for the other players' damage units (or the wave below), then stand where theirs stand along the path. In a party or with friends your units place normally.", Default = cfg.follow.enable, Callback = function(v) cfg.follow.enable = v Core.save_config() applyVis() end })
    followU = hunt_box:AddSlider("SummerFollowUnits", { Text = "Wait for Teammate Units", Tooltip = "Damage units of the other players to wait for before placing yours.", Default = cfg.follow.units, Min = 1, Max = 12, Rounding = 0, Callback = function(v) cfg.follow.units = v Core.save_config() end })
    followW = hunt_box:AddSlider("SummerFollowWave", { Text = "Place Anyway at Wave", Tooltip = "Your units are placed at this wave even when the teammates have not placed enough.", Default = cfg.follow.wave, Min = 1, Max = 30, Rounding = 0, Callback = function(v) cfg.follow.wave = v Core.save_config() end })
    hunt_box:AddDropdown("SummerCardMode", { Text = "Card Preset", Tooltip = "Easy: buffs only, debuff cards ignored. Medium: also Enemy Regen and Enemy Shield, nothing else. Hard: the card tuner (takes more debuff cards after a win, fewer after a loss). Impossible: every debuff card, highest tier first, for the biggest pearl reward. Custom: your own order from Custom Card Priority. Medium shows the Enemy Health / Speed Cap sliders, Custom shows the two priority lists.", Values = CARD_MODES, Default = cfg.cardMode, Callback = function(v) cfg.cardMode = v Core.save_config() applyVis() end })
    hunt_box:AddToggle("SummerStarCards", { Text = "Always Take Star Cards", Tooltip = "Inside Auto Summer Hunt, always takes the card that gives 5 Star Remnants (the late tier III debuff cards at waves 38, 41 and 47, and Random Curses II), whatever the preset or the health / speed caps say, and the Starfall card Wishing Star (+100% Star Golem Chance, the golems drop Broken Star). Those debuff cards make the stage harder.", Default = cfg.starCards, Callback = function(v) cfg.starCards = v Core.save_config() end })
    hpS = hunt_box:AddSlider("SummerHpCap", { Text = "Enemy Health Cap (%)", Tooltip = "Medium preset: Enemy Health cards are taken until their total extra enemy health reaches this; a card that would pass it is skipped.", Default = cfg.hpCap, Min = 0, Max = 500, Rounding = 0, Callback = function(v) cfg.hpCap = v Core.save_config() end })
    speedS = hunt_box:AddSlider("SummerSpeedCap", { Text = "Enemy Speed Cap (%)", Tooltip = "Medium preset: same as the health cap, for Enemy Speed cards.", Default = cfg.speedCap, Min = 0, Max = 200, Rounding = 0, Callback = function(v) cfg.speedCap = v Core.save_config() end })
    local status = hunt_box:AddLabel("Weather: -", true)
    local plan = hunt_box:AddLabel("Plan: -", true)
    if LOBBY then
        task.spawn(function()
            while alive() do
                local w = Summer.weather()
                local ok, p = pcall(function() return Game.invoke("get_lobby_more_params") end)
                local map = ok and p and p[PAD] and p[PAD]._level_data and p[PAD]._level_data.map
                pcall(function() status:SetText(("Weather: %s | Map: %s"):format(w and weatherName(w) or "-", tostring(map or "-"))) end)
                local pok, t, text = pcall(teamFor, w)
                pcall(function() plan:SetText("Plan: " .. (pok and text or "-")) end)
                task.wait(30)
            end
        end)
    end

    -- Custom card preset: the list the Custom entry of Card Preset follows.
    if Hub.UIKit then
        cbox = Tabs.Summer:AddRightGroupbox("Custom Card Priority", "list-ordered")
        cbox:AddLabel("Used with Card Preset = Custom. Top card is picked first. Type a number or use the arrows (Shift = 5, Ctrl = top or bottom).", true)
        -- Short row names (the "Enemy" prefix is on 21 of the 42 cards) and the Game tab's card icons, so a narrow window still shows what each row is.
        local ICONS = { { "Yen", "coins" }, { "Active Cooldown", "timer-reset" }, { "Cooldown", "timer" }, { "Boss", "skull" }, { "Blessings", "sparkles" }, { "Shield", "shield" },
            { "Explosive", "bomb" }, { "Curses", "ghost" }, { "Health", "heart" }, { "Speed", "gauge" }, { "Regen", "heart-pulse" }, { "Double", "zap" }, { "Attack", "swords" },
            { "Range", "crosshair" }, { "New Path", "route" }, { "Weather", "cloud-sun" } }
        local items = {}
        for _, c in CUSTOM_CARDS do
            local ic, text = nil, (c:gsub("^Enemy ", ""):gsub("Random ", "Rnd. "):gsub(" Enemies", ""))
            if c == "Weather Cards" then ic, text = "cloud-sun", "Weather Cards (list below)"
            else for _, p in ICONS do if c:find(p[1], 1, true) then ic = p[2] break end end end
            items[#items + 1] = { key = c, text = text, icon = ic }
        end
        local list
        list = Hub.UIKit.rankList(lib, cbox, "SummerCardPriorityList", {
            items = items,
            get = function()
                local keys = table.clone(CUSTOM_CARDS)
                table.sort(keys, function(a, b)
                    local ra, rb = cfg.customRank[a] or 1000, cfg.customRank[b] or 1000
                    if ra ~= rb then return ra < rb end
                    return table.find(CUSTOM_CARDS, a) < table.find(CUSTOM_CARDS, b)
                end)
                return keys
            end,
            set = function(keys) for i, c in keys do cfg.customRank[c] = i end Core.save_config() end,
            -- no - N + counter here: in this column it left 68 px for the name (measured); per-card caps stay in cfg.customCap (all 0 = no limit)
        })
        cbox:AddButton("Reset Custom Priority", function()
            for i, c in CUSTOM_CARDS do cfg.customRank[c] = i cfg.customCap[c] = 0 end
            Core.save_config()
            list.refresh()
        end)

        -- The weather cards, ordered among themselves; where the group stands is the Weather Cards row above.
        wbox = Tabs.Summer:AddRightGroupbox("Custom Weather Card Priority", "cloud-sun")
        wbox:AddLabel("Order of the weather cards among themselves (Custom preset). Where they rank overall is the Weather Cards row above.", true)
        local witems = {}
        for _, n in WEATHER_LIST do
            local w = WEATHER_OF[n]
            witems[#witems + 1] = { key = n, text = w and (w[1] .. ": " .. n) or "Other Weather", icon = w and w[2] or "cloud-sun" }
        end
        local wlist
        wlist = Hub.UIKit.rankList(lib, wbox, "SummerWeatherPriorityList", {
            items = witems,
            get = function()
                local keys = table.clone(WEATHER_LIST)
                table.sort(keys, function(a, b)
                    local ra, rb = cfg.weatherRank[a] or 1000, cfg.weatherRank[b] or 1000
                    if ra ~= rb then return ra < rb end
                    return table.find(WEATHER_LIST, a) < table.find(WEATHER_LIST, b)
                end)
                return keys
            end,
            set = function(keys) for i, c in keys do cfg.weatherRank[c] = i end Core.save_config() end,
        })
        wbox:AddButton("Reset Weather Priority", function()
            for i, n in WEATHER_LIST do cfg.weatherRank[n] = i end
            Core.save_config()
            wlist.refresh()
        end)
    end
    applyVis = function()
        local function vis(o, on) if o then o:SetVisible(on and true or false) end end
        local follow = cfg.matchmaking and true or false
        vis(followT, follow)
        vis(followU, follow and cfg.follow.enable)
        vis(followW, follow and cfg.follow.enable)
        vis(hpS, cfg.cardMode == "Medium")
        vis(speedS, cfg.cardMode == "Medium")
        vis(cbox, cfg.cardMode == "Custom")
        vis(wbox, cfg.cardMode == "Custom")
    end
    applyVis()

    local shop = Tabs.Summer:AddRightGroupbox("Summer Shop", "shopping-cart")
    shop:AddToggle("SummerShopStars", { Text = "Auto Summon Summer Banner", Tooltip = "Summons the Summer banner (150 Summer Pearls a pull, x10 while the pearls allow, then singles). It spends every pearl above Keep Summer Pearls.", Default = cfg.shop.enable, Callback = function(v) cfg.shop.enable = v Core.save_config() end })
    shop:AddSlider("SummerShopKeep", { Text = "Keep Summer Pearls", Tooltip = "Pearls the auto buy never spends (for the 5,000-pearl items).", Default = cfg.shop.keep, Min = 0, Max = 100000, Rounding = 0, Callback = function(v) cfg.shop.keep = v Core.save_config() end })

    shop:AddToggle("SummerSellSkins", { Text = "Auto Sell Skins (DELETES them)", Tooltip = "Permanently deletes this event's skins of the rarities below (the game has no sell for skins). One copy of a skin stays while a unit that can wear it has no summer skin yet.", Default = cfg.sellSkins.enable, Callback = function(v) cfg.sellSkins.enable = v Core.save_config() end })
    shop:AddDropdown("SummerSellRarity", { Text = "Select Auto Sell Rarity (Skins)", Tooltip = "Rare is Ichigo's, Epic Sakamoto's and Bulby's, Legendary Homura's, Frieren's, Gilgamesh's, Law's and Saber's, Mythic Giselle's.", Values = { "Rare", "Epic", "Legendary", "Mythic" }, Multi = true, Default = Core.keys(cfg.sellSkins.rarity), Callback = function(v)
        cfg.sellSkins.rarity = {}
        for name, on in v do if on then cfg.sellSkins.rarity[name] = true end end
        Core.save_config()
    end })

    -- Summer Merchant and Bingo (see merchant() / bingo() above).
    local mbox = Tabs.Summer:AddRightGroupbox("Summer Merchant", "ship-wheel")
    local labelItem = {}
    local function merchantLabels()
        local names, chosen = {}, {}
        for id in cfg.merchant.known do
            local n = (ITEMS[id] and ITEMS[id].name) or (id == EXCHANGE and "Gems to Summer Pearls") or id
            labelItem[n] = id
            table.insert(names, n)
            if cfg.merchant.items[id] then chosen[n] = true end
        end
        table.sort(names)
        return names, chosen
    end
    mbox:AddToggle("SummerMerchantBuy", { Text = "Auto Buy Summer Merchant", Tooltip = "Buys the ticked items from Bulby's shop (gems to Summer Pearls first, then the pearl items) while you are in the lobby. The banner summon spends every pearl above Keep Summer Pearls, so raise that to save for the 5,000-pearl items.", Default = cfg.merchant.enable, Callback = function(v) cfg.merchant.enable = v Core.save_config() end })
    local mitems = mbox:AddDropdown("SummerMerchantItems", { Text = "Select Merchant Items", Tooltip = "Every item the shop has shown (filled in when you are in the lobby); a new item starts ticked.", Values = (merchantLabels()), Multi = true, Default = {}, Callback = function(v)
        cfg.merchant.items = {}
        for name, on in v do if on and labelItem[name] then cfg.merchant.items[labelItem[name]] = true end end
        Core.save_config()
    end })
    mbox:AddSlider("SummerMerchantGems", { Text = "Keep Gems", Tooltip = "Gems the gem exchange never spends.", Default = cfg.merchant.gemKeep, Min = 0, Max = 100000, Rounding = 0, Callback = function(v) cfg.merchant.gemKeep = v Core.save_config() end })
    local function refreshMerchant()
        local names, chosen = merchantLabels()
        mitems:SetValues(names)
        mitems:SetValue(chosen)
    end
    refreshMerchant()
    if LOBBY then
        task.spawn(function() -- a first run has no known items yet: read the shop once so the list is not empty
            task.wait(8)
            local ok, shop = pcall(Game.invoke, "request_current_bsd_shop")
            if not (ok and type(shop) == "table") then return end
            for id in shop do
                if cfg.merchant.known[id] == nil then cfg.merchant.known[id] = true cfg.merchant.items[id] = true end
            end
            Core.save_config()
            refreshMerchant()
        end)
    end
    -- In the Shop box, not the Merchant's: it claims a reward board, it buys nothing.
    shop:AddToggle("SummerBingo", { Text = "Auto Claim Summer Bingo", Tooltip = "Claims the Summer Bingo board whenever a row, column or diagonal is ready (checked every 30 s in the lobby).", Default = cfg.bingo.enable, Callback = function(v) cfg.bingo.enable = v Core.save_config() end })

    -- Team editor: one weather at a time, six slots (slot order is your hotbar order, so Auto Play's per-slot settings follow it).
    local box = Tabs.Summer:AddLeftGroupbox("Weather Teams", "users")
    local names, byLabel, labelOf = {}, {}, {}
    local function addUnit(id)
        if labelOf[id] then return end
        local n = (Units[id] and Units[id].name) or id
        if byLabel[n] and byLabel[n] ~= id then n = ("%s [%s]"):format(n, id) end
        byLabel[n], labelOf[id] = id, n
        table.insert(names, n)
    end
    for _, t in cfg.teams do for _, id in t do addUnit(id) end end
    -- The profile is not readable for a few seconds after a teleport (2026-11-04: the slot lists held only the 6 saved units), so this is retried until it is.
    local function addOwned()
        local ok, pd = pcall(profile)
        if not ok then return false end
        for _, o in pd.collection.owned_units do addUnit(o.unit_id) end
        table.sort(names)
        return true
    end
    local filled = LOBBY and addOwned()
    table.sort(names)
    local weatherLabels, weatherOf = {}, {}
    for _, id in { "default", table.unpack(WEATHERS) } do
        local n = weatherName(id)
        weatherOf[n] = id
        table.insert(weatherLabels, n)
    end
    local loading = false
    local slots = {}
    local function show()
        loading = true
        local t = cfg.teams[cfg.edit] or {}
        for i = 1, 6 do slots[i]:SetValue(t[i] and t[i] ~= "" and labelOf[t[i]] or nil) end
        loading = false
    end
    box:AddDropdown("SummerWeather", { Text = "Weather", Tooltip = "Pick a weather, then set its six slots. Used only with Use My Saved Teams. Any weather (default) is used when a weather has no team of its own.", Values = weatherLabels, Default = weatherName(cfg.edit), Callback = function(v)
        cfg.edit = weatherOf[v] or "default"
        show()
    end })
    for i = 1, 6 do
        slots[i] = box:AddDropdown("SummerSlot" .. i, { Text = "Slot " .. i, Values = names, AllowNull = true, Searchable = true, Callback = function(v)
            if loading then return end
            cfg.teams[cfg.edit] = cfg.teams[cfg.edit] or {}
            cfg.teams[cfg.edit][i] = v and byLabel[v] or nil
            Core.save_config()
        end })
    end
    show()
    if LOBBY and not filled then
        task.spawn(function()
            for _ = 1, 40 do
                task.wait(3)
                if not alive() then return end
                if addOwned() then
                    for i = 1, 6 do slots[i]:SetValues(names) end
                    show()
                    return
                end
            end
        end)
    end
    box:AddButton({ Text = "Fill Saved Teams from Planner (double-click)", Tooltip = "Writes the planner's team for every weather into the saved teams, so you can adjust single slots.", DoubleClick = true, Func = function()
        local ok, err = pcall(function()
            for _, id in WEATHERS do cfg.teams[id] = (Summer.plan(id)) end
            cfg.teams.default = (Summer.plan("clear"))
            for _, t in cfg.teams do for _, id in t do if id ~= "" then addUnit(id) end end end
            Core.save_config()
            show()
        end)
        lib:Notify(ok and "Saved teams filled from the planner" or "Planner failed, details are in the log", 4)
        if not ok then Core.log("ERROR summer fill", err) end
    end })
    box:AddButton({ Text = "Copy to All Weathers (double-click)", Tooltip = "Copies this weather's team to every weather, then edit the ones that differ.", DoubleClick = true, Func = function()
        local src = cfg.teams[cfg.edit] or {}
        for _, id in WEATHERS do cfg.teams[id] = table.clone(src) end
        cfg.teams.default = table.clone(src)
        Core.save_config()
        lib:Notify("Copied to every weather", 4)
    end })
    box:AddButton({ Text = "Clear This Weather (double-click)", Risky = true, DoubleClick = true, Func = function()
        cfg.teams[cfg.edit] = nil
        Core.save_config()
        show()
    end })
end

return Summer
