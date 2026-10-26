-- Abilities (Game tab): Smart Auto Ability acts only on the units selected in "Select Smart Units", each
-- with the rule built for it: the buff chain director for Erwin / Wendy / Elfy (docs/features/auto-erwin.md),
-- the spaced rotation for Shadowgirl, the meter rotation for Snow Reaper (game-tab.md). Normal Auto Ability
-- casts ready abilities of every other hotbar unit. Options in Core.config.ability.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local LP = game:GetService("Players").LocalPlayer
local env = getgenv()

local cfg = Core.config.ability or {}
Core.config.ability = cfg
for k, v in { normal = false, smart = false, gap = 12 } do if cfg[k] == nil then cfg[k] = v end end
cfg.rules = nil -- the per-unit rule dropdowns are gone: a selected unit uses the rule built for it

local Abilities = {}
local function alive() return env.ZenoHub == Hub end

-- The units a smart rule is built for, in dropdown order, and the rule each uses.
local SMART_ORDER = { "erwin", "wendy", "leafa_evolved", "homura_evolved", "rukia_bankai_evolved" }
local SMART = { erwin = "Buff chain", wendy = "Buff chain", leafa_evolved = "Buff chain", homura_evolved = "Rotation (spaced)",
    rukia_bankai_evolved = "Meter rotation" }
-- First load of this option: select all of them, which is what the old single toggle did for these units.
if cfg.smart_units == nil then
    cfg.smart_units = {}
    for _, id in SMART_ORDER do cfg.smart_units[id] = true end
end
local function smartOn(id) return cfg.smart == true and cfg.smart_units[id] == true end

local defs = Game.data("Units")

-- Equipped unit ids: match hotbar (GUIService) or lobby profile. Abilities of units built from a
-- shared_setup_script (Elfy, Shadowgirl) are not in Units data, only on the placed unit's _stats.
local function equipped()
    local col
    pcall(function() col = Game.loader().load_client_service(script, "GUIService").session.collection.collection_profile_data end)
    if not col then local pd = Game.profile() col = pd and pd.collection end
    local out = {}
    for _, uuid in (col and col.equipped_units) or {} do
        local u = col.owned_units[uuid]
        if u and defs[u.unit_id] and not table.find(out, u.unit_id) then table.insert(out, u.unit_id) end
    end
    return out
end

-- In a match the hotbar (GUIService) is ready a few seconds after the hub loads and profile_data is nil
-- there, so a single read at load saw nothing and the unit rows never appeared (user, 2026-10-25): wait.
local function equippedWait()
    local tries = Hub.mode == "match" and 30 or 1
    for i = 1, tries do
        local ok, ids = pcall(equipped)
        if ok and #ids > 0 then return ids end
        if i < tries then task.wait(1) end
    end
    return {}
end
local equippedIds = equippedWait()

-- Smart handles a unit when Smart is on and the unit is selected (the macro skips its ability steps then).
function Abilities.handles(u)
    local st = u and u:FindFirstChild("_stats")
    return st and st:FindFirstChild("id") and smartOn(st.id.Value) or false
end

-- UI
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local box = Tabs.Game:AddLeftGroupbox("Abilities", "zap")
    box:AddToggle("AbilitySmart", { Text = "Smart Auto Ability", Tooltip = "Casts the units selected below by the rule built for each.", Default = cfg.smart, Callback = function(v) cfg.smart = v Core.save_config() end })
    local names, idByName, picked = {}, {}, {}
    for _, id in SMART_ORDER do
        if defs[id] then
            table.insert(names, defs[id].name)
            idByName[defs[id].name] = id
            if cfg.smart_units[id] then table.insert(picked, defs[id].name) end
        end
    end
    box:AddDropdown("AbilitySmartUnits", { Text = "Select Smart Units", Tooltip = "Smart Auto Ability only acts on these units.", Values = names, Multi = true, Default = picked, Callback = function(v)
        cfg.smart_units = {}
        for name, on in v do if on and idByName[name] then cfg.smart_units[idByName[name]] = true end end
        Core.save_config()
    end })
    box:AddToggle("AbilityNormal", { Text = "Normal Auto Ability", Tooltip = "Casts ready abilities of the hotbar units Smart does not handle.", Default = cfg.normal, Callback = function(v) cfg.normal = v Core.save_config() end })
    box:AddLabel("Buff chain (Commander, Windsong, Elfy): waits for 4 copies, then casts them at 0, 2, 30, 32 s per cooldown (more than 4: only 4 cast). Rotation (Shadowgirl): copies take turns, cooldown / copies apart but at least Min gap, only with an enemy in range. Meter rotation (Snow Reaper): one on at a time, switch before the bar runs out.", true)
    box:AddSlider("AbilityGap", { Text = "Rotation Min gap (s)", Tooltip = "Effect length + how long enemies cannot be hit by it again (game Buffs data: stun 8 s, freeze 10 s). Shadowgirl: 4 s timestop + 8 s = 12.", Default = cfg.gap, Min = 0, Max = 30, Rounding = 1, Callback = function(v) cfg.gap = v Core.save_config() end })
end

if Hub.mode ~= "match" then return Abilities end

-- Runtime ------------------------------------------------------------------------------------------------
-- Only hotbar units: summons (Erwin's aot_generic scouts) also carry an active_attack stat, and casting
-- them failed twice a second (406 failed calls in one match, 2026-10-23).
local hotbarIds = {}
for _, id in equippedIds do hotbarIds[id] = true end
task.spawn(function()
    for _ = 1, 30 do
        local ok, ids = pcall(equipped)
        if ok and #ids > 0 then for _, id in ids do hotbarIds[id] = true end return end
        task.wait(1)
    end
end)

local function mine()
    local out = {}
    local folder = workspace:FindFirstChild("_UNITS")
    for _, u in folder and folder:GetChildren() or {} do
        local st = u:FindFirstChild("_stats")
        local owner = st and st:FindFirstChild("player")
        local aa = st and st:FindFirstChild("active_attack")
        if owner and owner.Value == LP and st:FindFirstChild("id") and hotbarIds[st.id.Value] and aa and aa.Value ~= "" and aa.Value ~= "nil" then -- no ability: the game stores the text "nil"
            table.insert(out, u)
        end
    end
    return out
end
local function cooldown(u)
    local cd = u._stats:FindFirstChild("active_attack_cooldown")
    return cd and cd.Value or 60
end
-- last_active_cast is on the tick() clock (verified).
local function ready(u)
    local last = u._stats:FindFirstChild("last_active_cast")
    return not last or tick() >= last.Value + cooldown(u)
end
local function enemyNear(u)
    local st = u._stats
    local r = (st:FindFirstChild("range") and st.range.Value or 20) + 2
    local p = u:GetPivot().Position
    for _, e in workspace._UNITS:GetChildren() do
        local es = e:FindFirstChild("_stats")
        local owner = es and es:FindFirstChild("player")
        if owner and owner.Value == nil then
            local h = e:FindFirstChildOfClass("Humanoid")
            if (not h or h.Health > 0) and (e:GetPivot().Position - p).Magnitude <= r then return true end
        end
    end
    return false
end

local lastPress = {} -- model -> os.clock() of our last press (toggle abilities have a short press cooldown)
local failedAt = {} -- model -> os.clock() of the last refused cast; such a unit waits 5 s
local function cast(u, why)
    if os.clock() - (failedAt[u] or -99) < 5 then return false end
    lastPress[u] = os.clock()
    local ok, res = pcall(Game.invoke, "use_active_attack", u)
    if not ok or res ~= true then
        failedAt[u] = os.clock()
        Core.log("ability", u._stats.id.Value, why, "->", tostring(res))
        return false
    end
    return true
end

-- Buff timing guard. A cast that lands at (or just before) a copy's buff expiry does not renew that copy and
-- it then stays bare for ~30 s: seen live 2026-10-25 (cast at the exact expiry, 3 of 4 buffed for 30 s). With
-- a 60 s cooldown and 30 s buffs there is no slack, so a cast waits while another copy's buff is about to
-- expire, or is past its expected expiry but still on, and goes right after it turns off.
local BUFF_KEY = { erwin = "damage_buff__physical", wendy = "damage_buff__magic", leafa_evolved = "damage_buff__magic" }
local BUFF_LEN = 30 -- Erwin: buff_time = 30 in the buff_on payload; the logged "buff length" lines check it
local onAt, tracked = {}, {} -- model -> os.clock() its buff turned on (seen); models the chain tracks
local function buffOn(u)
    local b = u:FindFirstChild("_buffs")
    b = b and b:FindFirstChild(BUFF_KEY[u._stats.id.Value] or "")
    return b ~= nil and b.Value > 0
end
task.spawn(function()
    while alive() do
        for u in tracked do
            if u.Parent ~= workspace._UNITS then tracked[u], onAt[u] = nil, nil
            elseif buffOn(u) then onAt[u] = onAt[u] or os.clock()
            else
                if onAt[u] and os.clock() - onAt[u] > 1 then Core.log("buff length", ("%.2f"):format(os.clock() - onAt[u])) end
                onAt[u] = nil
            end
        end
        task.wait(0.05)
    end
end)
local function holdForExpiry(u, units)
    for _, o in units do
        local at = o ~= u and onAt[o]
        if at then
            local left = at + BUFF_LEN - os.clock()
            if left < 0.6 and left > -1.0 then return true end -- gives up 1 s past the estimate (estimate wrong)
        end
    end
    return false
end

-- Buff chain per unit id: 4 copies, pair casts 2 s apart, second pair 30 s after the first; the next cycle
-- starts one period (max cooldown of the 4, at least 60 s) after the first cast. Waits for readiness.
local OFFSETS = { 0, 2, 30, 32 }
local chains = {} -- id -> { units = {4}, key, step, anchor }
local function runChain(id, units)
    -- Hold until 4 copies (Nousigi too): early base casts lock targets on a weak buff for 30 s (user, 2026-10-23).
    if #units < 4 then chains[id] = nil return end
    -- Copies share a model name and _stats.uuid (one owned unit); the per-placement _SPAWN_UNIT_UUID
    -- attribute tells them apart, so a sold + replaced copy rebuilds the chain.
    local function uid(u) return tostring(u:GetAttribute("_SPAWN_UNIT_UUID") or u:GetDebugId()) end
    table.sort(units, function(a, b) return uid(a) < uid(b) end)
    local four = { table.unpack(units, 1, 4) }
    for _, u in four do tracked[u] = true end
    local key = table.concat({ uid(four[1]), uid(four[2]), uid(four[3]), uid(four[4]) }, "|")
    local c = chains[id]
    if not c or c.key ~= key then
        -- New chain: give the slots (0, 2, 30, 32 s) to the copies in the order they become ready and start
        -- at the earliest time every copy is ready for its slot. With period = cooldown, a copy that started
        -- late would otherwise stay late every cycle.
        -- One time per copy, taken once: a comparator that reads the clock is inconsistent for copies that
        -- are all ready now (fresh, never cast) and makes table.sort throw "invalid order function".
        local now = os.clock()
        local at = {}
        for _, u in four do
            local last = u._stats:FindFirstChild("last_active_cast")
            at[u] = math.max(now, last and now + (last.Value + cooldown(u) - tick()) or now)
        end
        table.sort(four, function(a, b) return at[a] < at[b] end)
        local anchor = now
        for i, u in four do anchor = math.max(anchor, at[u] - OFFSETS[i]) end
        c = { units = four, key = key, step = 1, anchor = anchor }
        chains[id] = c
        Core.log("buff chain", id, ("starts in %.1fs"):format(anchor - now))
    end
    local u = c.units[c.step]
    local due = c.anchor and c.anchor + OFFSETS[c.step] or 0
    if os.clock() >= due and ready(u) and not holdForExpiry(u, c.units) and cast(u, "chain " .. c.step) then
        if c.step == 1 then c.anchor = os.clock() end -- offsets count from the real first cast
        c.step += 1
        if c.step > 4 then
            local period = 60
            for _, m in c.units do period = math.max(period, cooldown(m)) end
            c.step, c.anchor = 1, c.anchor + period -- next cycle's first cast is due one period later
        end
    end
end

-- Rotation (spaced): one cast per turn, round-robin over the copies in a stable order; a turn comes every
-- max(cooldown / copies, Min gap) seconds while an enemy is in range. The next copy in order goes first;
-- if it is not ready, any ready copy takes the turn. Cooldowns are read live (they shrink with upgrades).
local rotations = {} -- id -> { last = os.clock() of the last cast, i = next index }
local function runRotation(id, units)
    table.sort(units, function(a, b) return tostring(a:GetAttribute("_SPAWN_UNIT_UUID")) < tostring(b:GetAttribute("_SPAWN_UNIT_UUID")) end)
    local r = rotations[id] or { last = -1e9, i = 1 }
    rotations[id] = r
    local cd = math.huge
    for _, u in units do cd = math.min(cd, cooldown(u)) end
    if os.clock() - r.last < math.max(cd / #units, cfg.gap) then return end
    local wanted = false
    for _, u in units do if enemyNear(u) then wanted = true break end end
    if not wanted then return end
    r.i = (r.i - 1) % #units + 1
    local pick = ready(units[r.i]) and units[r.i]
    if not pick then for _, u in units do if ready(u) then pick = u break end end end
    if pick and cast(pick, "rotation") then
        r.last = os.clock()
        r.i = table.find(units, pick) % #units + 1
    end
end

-- Meter rotation (toggle abilities with a draining bar, e.g. Snow Reaper): one on at a time while enemies
-- are in range; when its bar is low, turn on the fullest idle one, then the low one off. Tested 2026-10-23.
local SWITCH_AT, MIN_START, PRESS_CD = 12, 30, 4.2
local function barOf(u)
    for _, c in u._stats:GetChildren() do if c.Name:find("_active_bar$") then return c.Value end end
    return 100
end
local function isOn(u) return tostring(u._stats.active_attack.Value):sub(-4) == ":off" end
local function canPress(u) return os.clock() - (lastPress[u] or -99) >= PRESS_CD end
local function runMeter(units)
    local on, idle, wanted = {}, {}, false
    for _, u in units do
        table.insert(isOn(u) and on or idle, u)
        if enemyNear(u) then wanted = true end
    end
    table.sort(idle, function(a, b) return barOf(a) > barOf(b) end)
    if not wanted then
        for _, u in on do if canPress(u) then cast(u, "meter off, no enemies") end end
    elseif #on == 0 then
        local b = idle[1]
        if b and barOf(b) >= MIN_START and canPress(b) then cast(b, "meter start") end
    elseif #on == 1 then
        local b = idle[1]
        if barOf(on[1]) <= SWITCH_AT and b and barOf(b) >= MIN_START and canPress(b) then cast(b, "meter next") end
    else
        table.sort(on, function(a, b) return barOf(a) < barOf(b) end)
        if canPress(on[1]) then cast(on[1], "meter handoff off") end
    end
end

-- One pass over our units. The whole pass is protected: an error outside the per-unit pcall used to end
-- this loop for the rest of the match with nothing logged (Elfy never cast, 2026-10-25).
local function pass()
    local byId = {}
    for _, u in mine() do
        local id = u._stats.id.Value
        byId[id] = byId[id] or {}
        table.insert(byId[id], u)
    end
    for id, units in byId do
        local ok, err = pcall(function()
            if smartOn(id) then
                local rule = SMART[id]
                if rule == "Buff chain" then runChain(id, units)
                elseif rule == "Rotation (spaced)" then runRotation(id, units)
                else runMeter(units) end
            elseif cfg.normal then
                for _, u in units do if ready(u) then cast(u, "normal") end end
            end
        end)
        if not ok then Core.log("ERROR ability", id, err) end
    end
end
local lastErr
task.spawn(function()
    while alive() do
        if cfg.smart or cfg.normal then
            local ok, err = pcall(pass)
            if not ok and tostring(err) ~= lastErr then lastErr = tostring(err) Core.log("ERROR ability loop", lastErr) end
        end
        task.wait(0.25)
    end
end)

return Abilities
