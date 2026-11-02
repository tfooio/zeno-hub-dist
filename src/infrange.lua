-- Inf Range tab: moves your placed units on your screen so their attacks land somewhere else. docs/features/inf-range.md
-- Follow Enemy (Maximized / Closest to base per AOE type), Follow Player, Follow Cursor, Set Position.
-- The unit only attacks while an enemy is inside its ORIGINAL range; the move changes where the AOE lands.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local Players, RS, UIS, CS = game:GetService("Players"), game:GetService("RunService"), game:GetService("UserInputService"), game:GetService("CollectionService")
local LP = Players.LocalPlayer

local MODES = { "Follow Enemy", "Follow Player", "Follow Cursor", "Set Position" }
local STRATS = { "Maximized", "Closest to base" }
local SLOTS = { "Slot 1", "Slot 2", "Slot 3", "Slot 4", "Slot 5", "Slot 6" }
local cfg = Core.config.infrange or {}
Core.config.infrange = cfg
local defaults = { enable = false, mode = MODES[1], slots = {}, dist = 3.5, full = STRATS[1], cone = STRATS[1], line = STRATS[1], pos = {} }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

local InfRange = {}
local Attacks = Game.data("Attacks")

-- AOE shape of a unit's primary attack: full / cone / line / circle, nil when the attack is not in the data (strategy falls back to Full).
local shapeCache = {}
local function shapeOf(stats)
    local pa = stats:FindFirstChild("primary_attack") and stats.primary_attack.Value
    if not pa then return nil end
    if shapeCache[pa] ~= nil then return shapeCache[pa] or nil end
    local a = Attacks[pa]
    local found
    for _, e in type(a) == "table" and type(a.aoe) == "table" and a.aoe or {} do
        local t = type(e) == "table" and type(e.aoe_type) == "table" and e.aoe_type.type
        if t == "full_aoe" then found = "full" break
        elseif t == "cone" then found = found or "cone"
        elseif t == "straight" then found = found or "line"
        elseif t == "target_aoe_circ" then found = found or "circle" end
    end
    shapeCache[pa] = found or false
    return found
end

-- Hotbar: unit id -> slot (first slot wins). The GUIService session appears a few seconds after the match loads.
local idSlot = {}
local function refreshSlots()
    local ok, col = pcall(function() return Game.loader().load_client_service(script, "GUIService").session.collection.collection_profile_data end)
    if not (ok and col) then return end
    local m = {}
    for slot = 1, 6 do
        local uuid = col.equipped_units[slot] or col.equipped_units[tostring(slot)]
        local u = uuid and col.owned_units[uuid]
        if u and not m[u.unit_id] then m[u.unit_id] = slot end
    end
    idSlot = m
end

local function enemies()
    local out, folder = {}, workspace:FindFirstChild("_UNITS")
    for _, e in folder and folder:GetChildren() or {} do
        if CS:HasTag(e, "pve_units") and e.PrimaryPart then out[#out + 1] = { p = e.PrimaryPart.Position } end
    end
    return out
end

local bases
local function basePoints()
    if bases then return bases end
    local root = workspace:FindFirstChild("_BASES") and workspace._BASES:FindFirstChild("pve")
    root = root and root:FindFirstChild("LANES")
    local out = {}
    for _, lane in root and root:GetChildren() or {} do
        local f = lane:FindFirstChild("final")
        if f then out[#out + 1] = f.Position end
    end
    if #out > 0 then bases = out end
    return out
end
local function baseDist(p)
    local best
    for _, b in basePoints() do local d = (b - p).Magnitude if not best or d < best then best = d end end
    return best or 0
end

-- The enemy nearest the base is the one that must stay covered; Maximized then picks the spot (an enemy spot or the middle between
-- an enemy and the front one) that covers the most enemies within radius R. Closest to base just stands next to the front enemy.
local function pickTarget(list, R, strat)
    local front, fd
    for _, e in list do local d = baseDist(e.p) if not fd or d < fd then front, fd = e, d end end
    if not front then return nil end
    if strat == STRATS[2] then return front.p + Vector3.new(cfg.dist, 0, 0), 1 end
    local cands = {}
    for _, e in list do cands[#cands + 1] = e.p cands[#cands + 1] = e.p:Lerp(front.p, 0.5) end
    local best, bn, bd
    for _, c in cands do
        local df = (c - front.p).Magnitude
        if df <= R then
            local n = 0
            for _, e in list do if (e.p - c).Magnitude <= R then n += 1 end end
            if not bn or n > bn or (n == bn and df < bd) then best, bn, bd = c, n, df end
        end
    end
    return best or front.p, bn or 1
end

local ray = RaycastParams.new()
ray.FilterType = Enum.RaycastFilterType.Exclude
local mouse = LP:GetMouse()
local function groundHeight(orig)
    ray.FilterDescendantsInstances = { workspace:FindFirstChild("_UNITS") or workspace, LP.Character }
    local hit = workspace:Raycast(orig.Position + Vector3.new(0, 5, 0), Vector3.new(0, -60, 0), ray)
    return hit and (orig.Position.Y - hit.Position.Y) or 3
end

local handled = {} -- unit -> { orig, h, slot, target }
local status = { text = "Off" }

local function restore(u, st)
    if u.Parent then u:PivotTo(st.orig) end
    handled[u] = nil
end
local function restoreAll() for u, st in handled do restore(u, st) end end

-- ~10 Hz: which units are followed and where they should stand.
local function think()
    if not cfg.enable or Hub.mode ~= "match" then restoreAll() status.text = cfg.enable and "Waiting for a match" or "Off" return end
    refreshSlots()
    local want = {}
    local folder = workspace:FindFirstChild("_UNITS")
    for _, u in folder and folder:GetChildren() or {} do
        local s = u:FindFirstChild("_stats")
        if s and s:FindFirstChild("player") and s.player.Value == LP and s:FindFirstChild("id") then
            local slot = idSlot[s.id.Value]
            if slot and cfg.slots[SLOTS[slot]] then want[u] = slot end
        end
    end
    for u, st in handled do if not want[u] or not u.Parent then restore(u, st) end end
    local list = cfg.mode == MODES[1] and enemies() or nil
    local moved, inRange = 0, 0
    for u, slot in want do
        local st = handled[u]
        if not st then
            local o = u:GetPivot()
            st = { orig = o, h = groundHeight(o), slot = slot }
            handled[u] = st
        end
        local stats, orig, target = u._stats, st.orig, nil
        if cfg.mode == MODES[1] then
            local shape = shapeOf(stats)
            local R = stats:FindFirstChild("range") and stats.range.Value or 20
            local near = {}
            for _, e in list do if (e.p - orig.Position).Magnitude <= R then near[#near + 1] = e end end
            if shape ~= "circle" and #near > 0 then
                inRange += 1
                local t = pickTarget(list, R, cfg[shape or "full"])
                target = t and Vector3.new(t.X, orig.Position.Y, t.Z)
            end
        elseif cfg.mode == MODES[2] then
            local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
            if hrp then target = Vector3.new(hrp.Position.X, hrp.Position.Y - 3 + st.h, hrp.Position.Z) end
        elseif cfg.mode == MODES[3] then
            ray.FilterDescendantsInstances = { workspace:FindFirstChild("_UNITS") or workspace, LP.Character }
            local pos = UIS:GetMouseLocation()
            local r = workspace.CurrentCamera:ViewportPointToRay(pos.X, pos.Y)
            local hit = workspace:Raycast(r.Origin, r.Direction * 1000, ray)
            if hit then target = hit.Position + Vector3.new(0, st.h, 0) end
        else
            local p = cfg.pos[tostring(slot)]
            if p then target = Vector3.new(p[1], p[2] + st.h, p[3]) end
        end
        st.target = target
        if target then moved += 1 end
    end
    local n = 0 for _ in want do n += 1 end
    status.text = ("%s: %d unit(s) selected, %d moving%s"):format(cfg.mode, n, moved, cfg.mode == MODES[1] and (", " .. inRange .. " with an enemy in range") or "")
end

local Library = Hub.UI and Hub.UI.Library
task.spawn(function()
    while not (Library and Library.Unloaded) do
        local ok, err = pcall(think)
        if not ok then Core.log("ERROR infrange:", err) task.wait(5) end
        task.wait(0.1)
    end
    restoreAll()
end)

-- every frame: hold the position (the game moves the model back otherwise)
local conn = RS.RenderStepped:Connect(function()
    for u, st in handled do
        if st.target and u.Parent then u:PivotTo(CFrame.new(st.target) * (st.orig - st.orig.Position)) end
    end
end)
table.insert(Hub.connections, conn)
if Library then Library:OnUnload(function() restoreAll() end) end

------------------------------------------------------------------ UI
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs and Tabs.InfRange then
    local lib = Hub.UI.Library
    local function set(key) return function(v) cfg[key] = v Core.save_config() end end
    local main = Tabs.InfRange:AddLeftGroupbox("Inf Range", "move")
    main:AddToggle("IR_Enable", { Text = "Enable Inf Range", Default = cfg.enable, Callback = set("enable"),
        Tooltip = "Moves your placed units on your screen. A unit still only attacks while an enemy is inside its real (placed) range; the attack then lands where the unit was moved." })
    main:AddDropdown("IR_Mode", { Text = "Mode", Values = MODES, Default = cfg.mode, Callback = set("mode"),
        Tooltip = "Follow Enemy: stand where the AOE covers enemies. Follow Player / Cursor: stand on you or on the mouse. Set Position: stand on a spot you clicked on the map." })
    local sel = {}
    for slot in cfg.slots do sel[#sel + 1] = slot end
    main:AddDropdown("IR_Slots", { Text = "Units", Values = SLOTS, Multi = true, Default = sel,
        Tooltip = "Hotbar slots that follow. Every placed copy of that unit moves.",
        Callback = function(v) cfg.slots = {} for slot, on in v do if on then cfg.slots[slot] = true end end Core.save_config() end })
    main:AddSlider("IR_Dist", { Text = "Distance From Mob", Default = cfg.dist, Min = 0, Max = 10, Rounding = 1, Suffix = " studs", Callback = set("dist"),
        Tooltip = "Closest to base: how far from the front enemy the unit stands." })
    local label = main:AddLabel("Off", true)

    local fe = Tabs.InfRange:AddRightGroupbox("Follow Enemy", "swords")
    fe:AddLabel("Maximized = the spot that covers the most enemies while still reaching the one closest to your base. Closest to base = stand next to that enemy. Circle AOE units are not moved (it does not work on them).", true)
    for _, shape in { { "full", "Full AOE" }, { "cone", "Cone AOE" }, { "line", "Line AOE" } } do
        fe:AddDropdown("IR_" .. shape[1], { Text = shape[2], Values = STRATS, Default = cfg[shape[1]], Callback = set(shape[1]) })
    end

    local sp = Tabs.InfRange:AddRightGroupbox("Set Position", "map-pin")
    sp:AddLabel("Pick a slot, press Set Position, then click a spot on the map. In Set Position mode that unit stands there.", true)
    local slotSel = sp:AddDropdown("IR_PosSlot", { Text = "Slot", Values = SLOTS, Default = SLOTS[3] })
    local posLabel = sp:AddLabel("Saved: none", true)
    local waiting
    local function refreshPos()
        local t = {}
        for slot, p in cfg.pos do t[#t + 1] = ("Slot %s (%.0f, %.0f, %.0f)"):format(slot, p[1], p[2], p[3]) end
        table.sort(t)
        posLabel:SetText("Saved: " .. (#t > 0 and table.concat(t, ", ") or "none"))
    end
    sp:AddButton({ Text = "Set Position", Func = function()
        waiting = tostring(tonumber(slotSel.Value:match("%d")))
        lib:Notify("Click a spot on the map for slot " .. waiting, 5)
    end })
    sp:AddButton({ Text = "Clear This Slot", Func = function()
        cfg.pos[tostring(tonumber(slotSel.Value:match("%d")))] = nil
        Core.save_config()
        refreshPos()
    end })
    refreshPos()
    mouse.TargetFilter = workspace:FindFirstChild("_UNITS")
    table.insert(Hub.connections, UIS.InputBegan:Connect(function(input, processed)
        if not waiting or processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        local hit = mouse.Hit.Position
        cfg.pos[waiting] = { hit.X, hit.Y, hit.Z }
        Core.save_config()
        lib:Notify(("Slot %s position saved"):format(waiting), 3)
        waiting = nil
        refreshPos()
    end))

    task.spawn(function()
        while not lib.Unloaded do
            label:SetText(status.text)
            task.wait(1)
        end
    end)
end

InfRange.handled = handled
return InfRange
