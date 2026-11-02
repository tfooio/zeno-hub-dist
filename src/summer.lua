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
cfg.shop = cfg.shop or { enable = false, keep = 0 } -- Auto Summon Summer Banner: on / Summer Pearls to leave untouched
cfg.sellSkins = cfg.sellSkins or { enable = false, rarity = { Rare = true } } -- Auto Sell Skins: on / skin rarities to sell

local Summer = {}
local Units, Weather = Game.data("Units"), Game.data("Weather")
local function alive() return env.ZenoHub == Hub end
local function profile() return Game.loader().load_client_service(script, "LobbyServiceClient").session.profile_data end
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
function Summer.plan(w, owned)
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
    -- Summer Pearl bonus (user, 2026-11-02): evolved Mythic units +50%, a worn Mythic skin +50%, Legendary +25%, Epic +5%, skins only on evolved units.
    local function boost(c) return (c.d.rarity == "Mythic" and c.d.evolved and 50 or 0) + Hub.Skins.pearlBoost(c.o) end
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

    -- DPS: the carries with the most pearl bonus (see carry); Blizzard needs a fire unit. The Vegito pair is used only for a weather that could not be
    -- cleared without it (cfg.needVegito, set by the run logger after two losses in a row there; user: currency first unless the stage is not beatable).
    local fire = carry(function(c) return c.r.fire and dps(c) and usable(c) end)
    local carrot, vego = cands[CARROT], cands[VEGO]
    local d1, d2
    if cfg.needVegito[w] and carrot and vego and usable(carrot) and usable(vego) and not (w == "snow" and fire) then
        d1, d2 = take(carrot), take(vego)
        table.insert(notes, "Vegito pair (needed)")
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

-- The team to use for a weather: the saved one when Use My Saved Teams is on and it exists, else the planner's.
local function teamFor(w)
    if cfg.manual then
        local t = (w and cfg.teams[w]) or cfg.teams.default
        if t and next(t) then return t, "saved team" end
    end
    local ok, t, text = pcall(Summer.plan, w)
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
local busyUntil = 0
local function hunt()
    if os.clock() < busyUntil then return end
    local w = Summer.weather()
    if not w then return end
    busyUntil = os.clock() + 40
    pcall(Hub.Skins.run) -- summer skins on the best evolved copies first: they carry pearl bonus and damage (nothing to do = silent)
    local t, text = teamFor(w)
    Core.log("summer: team for", text or "-")
    if t and not Summer.apply(t, weatherName(w)) then
        Core.log("ERROR summer: team not equipped, not joining")
        return
    end
    Core.save_config()
    Core.log("summer: joining the Hunt,", weatherName(w))
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
            if cfg.sellSkins.enable then local ok, err = pcall(Summer.sellSkins) if not ok then Core.log("ERROR summer sell skins", err) end end
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
local CARD_MODES = { "Easy", "Medium", "Hard", "Impossible" }
cfg.cardMode = table.find(CARD_MODES, cfg.cardMode) and cfg.cardMode or "Easy"
-- Enemy Health and Enemy Speed are okay up to a point (friends, user: "about 150%" for health; resist cards never). Each is capped at cfg.<cap> percent
-- over the run. The amount is read from the offer's effects ({stat = "health" / "speed", amount = fraction}, as the enemy buff list shows health).
-- UNVERIFIED: the offer's effects format and the speed stat name; the offers log now stores the effects, and a capped card whose amount cannot
-- be read is logged (and then taken without a cap).
local OKAY_DEBUFFS = { ["Enemy Regen"] = true, ["Enemy Shield"] = true, ["Enemy Health"] = true, ["Enemy Speed"] = true }
local CAPPED = { ["Enemy Health"] = { stat = "health", cap = "hpCap" }, ["Enemy Speed"] = { stat = "speed", cap = "speedCap" } }
cfg.hpCap = tonumber(cfg.hpCap) or 150
cfg.speedCap = tonumber(cfg.speedCap) or 50 -- guess, no number from the user yet
local run = { cards = {}, debuffs = 0, total = {} } -- total[card] = percent taken so far this run
local function amountOf(opt, stat) -- percent a card adds, nil when the offer carries no readable amount
    local sum
    for _, e in type(opt) == "table" and type(opt.effects) == "table" and opt.effects or {} do
        if type(e) == "table" and e.stat == stat and tonumber(e.amount) then sum = (sum or 0) + e.amount * 100 end
    end
    return sum
end
function Summer.cardRank(card, opt)
    if not pilotOn() then return nil end
    -- "Double Attack, Double Cooldown" doubles ability cooldowns too and breaks the Auto Commander / Rukia chains (user): last in every preset, picked
    -- only when it is the whole offer. (The "- Cooldown" cards are the other way round: they cut cooldowns.)
    if tostring(card):find("Double Cooldown", 1, true) then return 2e9 end
    local base, tier = parseCard(card)
    for i, n in DEBUFF_ORDER do
        if base == n then
            local mode = cfg.cardMode
            if mode == "Impossible" then return 50 + i * 10 + (4 - tier) end
            if mode == "Medium" then
                local okay = OKAY_DEBUFFS[n]
                local capped = CAPPED[n]
                if okay and capped then
                    local pct = amountOf(opt, capped.stat)
                    if not pct then Core.log("summer: " .. n .. " card without a readable amount, cap not applied") end
                    if pct and (run.total[n] or 0) + pct > cfg[capped.cap] then okay = false end
                end
                return (okay and 50 or 500) + i * 10 + (4 - tier)
            end
            if mode == "Easy" then return 500 + i * 10 + tier end
            return (run.debuffs < cfg.tune.L and 50 or 500) + i * 10 + tier
        end
    end
    for i, n in BUFF_ORDER do if base == n then return 100 + i * 10 + (4 - tier) end end -- a higher tier of a buff first
    return 300 -- weather and other special cards
end

function Summer.cardPicked(card, wave, offered, opt)
    if not pilotOn() then return end
    table.insert(run.cards, { wave = wave, card = card, offered = offered })
    local base = parseCard(card)
    if table.find(DEBUFF_ORDER, base) then run.debuffs += 1 end
    if CAPPED[base] then run.total[base] = (run.total[base] or 0) + (amountOf(opt, CAPPED[base].stat) or 0) end
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
        run = { cards = {}, debuffs = 0, total = {} }
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
    o.kind, o.mid, o.slotpos, o.mode_preset = {}, {}, {}, {}
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

-- UI --------------------------------------------------------------------------------------------------------
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local lib = Hub.UI.Library
    local hunt_box = Tabs.Summer:AddLeftGroupbox("Summer Hunt", "sun")
    if not LOBBY then hunt_box:AddLabel("Works in the lobby only (saved here).", true) end
    hunt_box:AddToggle("SummerHunt", { Text = "Auto Summer Hunt", Tooltip = "Fully automatic: in the lobby it plans and equips the team for the current weather, joins the Summer Hunt and starts it. In the Hunt, Auto Play and the abilities run on their own settings (your saved Auto Play settings are not used). At match end it returns to the lobby when the hour changed.", Default = cfg.enable, Callback = function(v) cfg.enable = v Core.save_config() end })
    hunt_box:AddToggle("SummerManual", { Text = "Use My Saved Teams", Tooltip = "Use the teams saved under Weather Teams instead of the planner (a weather without a team falls back to the planner).", Default = cfg.manual, Callback = function(v) cfg.manual = v Core.save_config() end })
    hunt_box:AddDropdown("SummerCardMode", { Text = "Card Preset", Tooltip = "Easy: buffs only, debuff cards ignored. Medium: also Enemy Regen and Enemy Shield, nothing else. Hard: the card tuner (takes more debuff cards after a win, fewer after a loss). Impossible: every debuff card, highest tier first, for the biggest pearl reward.", Values = CARD_MODES, Default = cfg.cardMode, Callback = function(v) cfg.cardMode = v Core.save_config() end })
    hunt_box:AddSlider("SummerHpCap", { Text = "Enemy Health Cap (%)", Tooltip = "Medium preset: Enemy Health cards are taken until their total extra enemy health reaches this; a card that would pass it is skipped.", Default = cfg.hpCap, Min = 0, Max = 500, Rounding = 0, Callback = function(v) cfg.hpCap = v Core.save_config() end })
    hunt_box:AddSlider("SummerSpeedCap", { Text = "Enemy Speed Cap (%)", Tooltip = "Medium preset: same as the health cap, for Enemy Speed cards.", Default = cfg.speedCap, Min = 0, Max = 200, Rounding = 0, Callback = function(v) cfg.speedCap = v Core.save_config() end })
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

    local shop = Tabs.Summer:AddRightGroupbox("Summer Shop", "shopping-cart")
    shop:AddToggle("SummerShopStars", { Text = "Auto Summon Summer Banner", Tooltip = "Summons the Summer banner (150 Summer Pearls a pull, x10 while the pearls allow, then singles). It spends every pearl above Keep Summer Pearls.", Default = cfg.shop.enable, Callback = function(v) cfg.shop.enable = v Core.save_config() end })
    shop:AddSlider("SummerShopKeep", { Text = "Keep Summer Pearls", Tooltip = "Pearls the auto buy never spends (for the 5,000-pearl items).", Default = cfg.shop.keep, Min = 0, Max = 100000, Rounding = 0, Callback = function(v) cfg.shop.keep = v Core.save_config() end })

    shop:AddToggle("SummerSellSkins", { Text = "Auto Sell Skins", Tooltip = "Deletes this event's skins of the rarities below (the game has no sell for skins). One copy of a skin stays while a unit that can wear it has no summer skin yet.", Default = cfg.sellSkins.enable, Callback = function(v) cfg.sellSkins.enable = v Core.save_config() end })
    shop:AddDropdown("SummerSellRarity", { Text = "Select Auto Sell Rarity (Skins)", Tooltip = "Rare is Ichigo's, Epic Sakamoto's and Bulby's, Legendary Homura's, Frieren's, Gilgamesh's, Law's and Saber's, Mythic Giselle's.", Values = { "Rare", "Epic", "Legendary", "Mythic" }, Multi = true, Default = Core.keys(cfg.sellSkins.rarity), Callback = function(v)
        cfg.sellSkins.rarity = {}
        for name, on in v do if on then cfg.sellSkins.rarity[name] = true end end
        Core.save_config()
    end })

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
    if LOBBY then
        local ok, pd = pcall(profile)
        if ok then for _, o in pd.collection.owned_units do addUnit(o.unit_id) end end
    end
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
    box:AddButton({ Text = "Fill Saved Teams from Planner", Tooltip = "Writes the planner's team for every weather into the saved teams, so you can adjust single slots.", DoubleClick = true, Func = function()
        local ok, err = pcall(function()
            for _, id in WEATHERS do cfg.teams[id] = (Summer.plan(id)) end
            cfg.teams.default = (Summer.plan("clear"))
            for _, t in cfg.teams do for _, id in t do if id ~= "" then addUnit(id) end end end
            Core.save_config()
            show()
        end)
        lib:Notify(ok and "Saved teams filled from the planner" or "Planner failed, see the log", 4)
        if not ok then Core.log("ERROR summer fill", err) end
    end })
    box:AddButton({ Text = "Copy to All Weathers", Tooltip = "Copies this weather's team to every weather, then edit the ones that differ.", DoubleClick = true, Func = function()
        local src = cfg.teams[cfg.edit] or {}
        for _, id in WEATHERS do cfg.teams[id] = table.clone(src) end
        cfg.teams.default = table.clone(src)
        Core.save_config()
        lib:Notify("Copied to every weather", 4)
    end })
    box:AddButton({ Text = "Clear This Weather", DoubleClick = true, Func = function()
        cfg.teams[cfg.edit] = nil
        Core.save_config()
        show()
    end })
end

return Summer
