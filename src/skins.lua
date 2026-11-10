-- Summer Skins (docs/features/summer-update.md): puts every owned summer skin on the best copy of its unit.
-- Apply sequence (verified 2026-11-01): the unit must be off the hotbar and without a skin, so
-- unequip_unit -> remove_skin -> use_unique_item -> equip_unit back to the same slot.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local env = getgenv()

local cfg = Core.config.skins or {}
Core.config.skins = cfg
if cfg.all == nil then cfg.all = false end -- also the older *_summer skins

local Skins = {}
local Units, SkinData, Items = Game.data("Units"), Game.data("Skins"), Game.data("Items")
local busy = false
local function alive() return env.ZenoHub == Hub end
local function profile() return Game.loader().load_client_service(script, "LobbyServiceClient").session.profile_data end

local function isSummer(sk)
    if sk._skin_set == "summer2" then return true end
    return cfg.all and (sk._skin_set == "summer" or sk.id:find("_summer$") ~= nil)
end

-- A unit fits a skin when it, or the unit it evolved from, is the skin's unit.
local function fits(sk, unitId)
    while unitId do
        if sk.for_unit == unitId or (sk.for_units and sk.for_units[unitId]) then return true end
        local ev = Units[unitId] and Units[unitId].evolved
        unitId = ev and ev.from
    end
    return false
end

local function depth(unitId)
    local n = 0
    while Units[unitId] and Units[unitId].evolved do unitId = Units[unitId].evolved.from n += 1 end
    return n
end

-- Evolved first, then more traits, then more xp.
local function score(o) return depth(o.unit_id) * 1e9 + #(o.traits or {}) * 1e7 + (o.xp or 0) end

Skins.score = score
Skins.fits = fits -- src/summer.lua (Auto Sell Skins)
Skins.wearsSummer = function(o) local sk = o.skin and SkinData[o.skin._skin_id] return sk ~= nil and isSummer(sk) end

-- A unit that still has an evolved form gets nothing from a skin (user, 2026-11-02): the skin only counts on evolved units and on units that never evolve.
local evolvesTo = {}
for _, d in Units do if d.evolved and d.evolved.from then evolvesTo[d.evolved.from] = true end end
Skins.canEvolve = function(unitId) return evolvesTo[unitId] == true end

-- Summer Pearl bonus of a worn summer skin by its rarity (user: Bulby's Epic skin +5%, Homura's Legendary +25%, Giselle's Mythic skin +40% (2026-11-04,
-- was 50); Rare and Common are not known and count 0).
local PEARL = { Epic = 5, Legendary = 25, Mythic = 40 }
function Skins.pearlBoost(o)
    local id = o.skin and o.skin._skin_id
    local sk = id and SkinData[id]
    if not (sk and isSummer(sk)) or evolvesTo[o.unit_id] then return 0 end
    return PEARL[sk._skin_rarity] or 0
end

-- Returns a list of { skin, item, unit, wearing } to apply.
function Skins.plan()
    local pd = profile()
    local owned = pd.collection.owned_units
    local bySkin = {}
    for _, it in pd.inventory.unique_items do
        local use = Items[it.item_id] and Items[it.item_id].usage
        local sk = use and use.type == "apply_skin" and SkinData[use.skin_id]
        if sk and isSummer(sk) then
            bySkin[sk.id] = bySkin[sk.id] or { sk = sk, items = {} }
            table.insert(bySkin[sk.id].items, it.uuid)
        end
    end
    -- Skins already worn by a summer skin are left alone; bigger damage boost claims a unit first.
    local list = Core.keys(bySkin)
    table.sort(list, function(a, b)
        local x, y = bySkin[a].sk._damage_boost or 0, bySkin[b].sk._damage_boost or 0
        if x ~= y then return x > y end
        return a < b
    end)
    local taken, plan = {}, {}
    for _, id in list do
        local e = bySkin[id]
        local best
        for uuid, o in owned do
            if not taken[uuid] and fits(e.sk, o.unit_id) and not evolvesTo[o.unit_id] and (not best or score(o) > score(owned[best])) then best = uuid end
        end
        if best then
            taken[best] = true
            local worn = owned[best].skin and owned[best].skin._skin_id
            local wornSk = worn and SkinData[worn]
            if worn ~= id and not (wornSk and isSummer(wornSk)) then
                table.insert(plan, { skin = id, item = e.items[1], unit = best, unitId = owned[best].unit_id, wearing = worn })
            end
        end
    end
    return plan
end

local function waitFor(pred, sec)
    local t = os.clock()
    while os.clock() - t < sec do
        if pred() then return true end
        task.wait(0.25)
    end
    return false
end

-- One unit, always put back on its slot. Returns true when the skin is on.
local function apply(step)
    local o = profile().collection.owned_units[step.unit]
    local slot = o.equipped_slot
    local ok = pcall(function()
        if slot then
            Game.invoke("unequip_unit", step.unit)
            waitFor(function() return not o.equipped_slot end, 5)
        end
        if o.skin then
            Game.invoke("remove_skin", step.unit)
            waitFor(function() return not o.skin end, 5)
        end
        Game.invoke("use_unique_item", step.item, { unit_uuid = step.unit })
    end)
    local done = ok and waitFor(function() return o.skin and o.skin._skin_id == step.skin end, 5)
    if slot then pcall(Game.invoke, "equip_unit", step.unit, tostring(slot)) end
    return done
end

function Skins.run()
    if busy or Hub.mode ~= "lobby" then return end
    busy = true
    local ok, err = pcall(function()
        local plan = Skins.plan()
        if #plan == 0 then return end -- also called before every Hunt: say nothing when there is nothing to do
        local done = 0
        for _, step in plan do
            if not alive() then break end
            local name = (Units[step.unitId] and Units[step.unitId].name) or step.unitId
            if apply(step) then
                done += 1
                Core.log("skins: put", step.skin, "on", name)
            else
                Core.log("ERROR skins: could not put", step.skin, "on", name)
            end
        end
        Hub.UI.Library:Notify(("Summer skins: %d of %d applied"):format(done, #plan), 6)
    end)
    busy = false
    if not ok then Core.log("ERROR skins", err) end
end

if Hub.UI and Hub.UI.Tabs then
    local box = Hub.UI.Tabs.Summer:AddRightGroupbox("Summer Skins", "shirt")
    if Hub.mode ~= "lobby" then box:AddLabel("Works in the lobby only.", true) end
    box:AddToggle("SkinsAll", { Text = "Include older summer skins", Tooltip = "Off: only this event's skins. On: every owned *_summer skin too.", Default = cfg.all, Callback = function(v) cfg.all = v Core.save_config() end })
    box:AddButton({ Text = "Show Plan", Tooltip = "Lists which skin would go on which unit. Changes nothing.", Func = function()
        if not Game.profile() then return Hub.UI.Library:Notify("Needs the lobby: your profile is not readable here", 5) end
        local ok, plan = pcall(Skins.plan)
        if not ok then return Core.log("ERROR skins plan", plan) end
        for _, s in plan do Core.log("skins plan:", s.skin, "->", s.unitId, s.wearing and ("(replaces " .. s.wearing .. ")") or "") end
        Hub.UI.Library:Notify(#plan == 0 and "Nothing to equip" or (#plan .. " skins to equip, the list is in the log"), 5)
    end })
    box:AddButton({ Text = "Equip Summer Skins", Tooltip = "Puts each owned summer skin on the best copy of its unit (evolved first, then traits, then xp). Hotbar units are taken off and put back in the same slot.", Func = function() task.spawn(Skins.run) end })
end

return Skins
