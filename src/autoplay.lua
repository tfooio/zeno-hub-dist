-- Auto Play (Auto Play tab): places and upgrades the hotbar units with no recorded macro. docs/features/auto-play.md
-- Options live in Core.config.autoplay (hub.json) so they survive teleports.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local LP = game:GetService("Players").LocalPlayer
local CS = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local env = getgenv()

local function six(f) local t = {} for i = 1, 6 do t[i] = f(i) end return t end
local cfg = Core.config.autoplay or {}
Core.config.autoplay = cfg
local METHODS = { "Cheapest first (farms first)", "Smart (best value per yen)", "Hotbar left to right (until Max)", "Customize order (Upgrade Order)", "Round robin (lowest level first)" }
local KINDS = { "Enemy path (auto)", "My saved position" }
local PRIOS = { "Game default", "first", "last", "strongest", "weakest", "closest", "farthest" }
local defaults = {
    enable = false, upgrade = false, upgrade_place = false, focus_farm = false, opening = true, fuse = true,
    order = six(function(i) return i end), wave = six(function() return 0 end), limit = six(function() return 0 end),
    ulimit = six(function() return 0 end), uorder = six(function(i) return i end), uwave = six(function() return 0 end),
    method = METHODS[1], upgrade_one = false, priority = PRIOS[1], boss_priority = PRIOS[1], mode_preset = {},
    distance = 50, ground = 60, hill = 80, margin = 0.3, pack = true,
    hybrid_hill = true, -- units that can stand on ground or hills (not buffers, not farms) take a hill when one is in reach: only units on a hill hit Soaring enemies
    kind = {}, mid = {}, slotpos = {}, -- per stage key
    learned = {}, use_learned = true, -- per map: learned[map][slot] = { {x, y, z}, ... }
}
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end
-- Place order: Script = hotbar order, Custom = cfg.order. Someone who already moved a number keeps their order (Custom).
if cfg.place_custom == nil then
    cfg.place_custom = false
    for i = 1, 6 do if cfg.order[i] ~= i then cfg.place_custom = true end end
end
local function placeOrd(slot) return cfg.place_custom and cfg.order[slot] or slot end
-- Stage types used to be stored under the Nousigi names.
for key, v in cfg.kind do if v == "Middle Position" then cfg.kind[key] = "My saved position" elseif v == "Path (auto)" then cfg.kind[key] = nil end end
-- v2: the default upgrade method became Smart; the old default was never a deliberate choice.
if (cfg.version or 1) < 2 then
    if cfg.method == METHODS[3] then cfg.method = METHODS[1] end
    cfg.version = 2
    Core.save_config()
end

-- v3: Ground / Hill Percentage became radii around the path point (share of the unit's range); the old Hill Percentage was a share of units.
if (cfg.version or 1) < 3 then
    cfg.hill, cfg.version = 80, 3
    Core.save_config()
end
-- v4 (user): upgrade whatever is affordable, farms first, cheapest first, within the caps.
if cfg.version < 4 then
    cfg.method, cfg.version = METHODS[1], 4
    Core.save_config()
end

local AutoPlay = {}
-- Preset: option values applied together (the UI controls are moved so they show it).
local PRESETS = {
    ["None (manual)"] = false,
    ["Balanced"] = { opening = true, focus_farm = false, upgrade = true, method = METHODS[1] },
    ["Farm first (long runs)"] = { opening = true, focus_farm = true, upgrade = true, method = METHODS[1] },
    ["Max damage (short stages)"] = { opening = false, focus_farm = false, upgrade = true, method = METHODS[1] },
}
local PRESET_NAMES
PRESET_NAMES = { "None (manual)", "Balanced", "Farm first (long runs)", "Max damage (short stages)" }
local function alive() return env.ZenoHub == Hub end

-- LevelData is set a moment after the match loads.
local level
for _ = 1, 30 do
    level = Hub.mode == "match" and Game.loader().LevelData
    if level or Hub.mode ~= "match" then break end
    task.wait(1)
end
local function stageKey()
    if not level then return "-" end
    local mode, map = Game.stage(level)
    return ("%s | %s | %s"):format(tostring(mode), tostring(map), tostring(level._difficulty))
end
-- Map coordinates are the same in every mode that uses a map (raid and dungeon room: same spots), so learned data is per map.
local function mapKey()
    if not level then return "-" end
    local _, map = Game.stage(level)
    return tostring(level.map or map)
end

local function setPos(tbl, key, slot, v)
    tbl[key] = tbl[key] or {}
    tbl[key][slot] = v
    Core.save_config()
end

------------------------------------------------------------------ UI
local Tabs = Hub.UI and Hub.UI.Tabs
local ui = {}
local function standing()
    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    return hrp and { hrp.Position.X, hrp.Position.Y, hrp.Position.Z }
end
local function posText(p) return p and ("%.0f, %.0f, %.0f"):format(p[1], p[2], p[3]) or "none" end
if Tabs then
    local lib = Hub.UI.Library
    local function set(key, after) return function(v) cfg[key] = v Core.save_config() if after then after(v) end end end
    local function perSlot(box, field, title, min, max)
        for i = 1, 6 do
            box:AddSlider(("AP_%s%d"):format(field, i), { Text = ("%s %d"):format(title, i), Default = cfg[field][i], Min = min, Max = max, Rounding = 0,
                Callback = function(v) cfg[field][i] = v Core.save_config() end })
        end
    end

    -- Main panel: what most people touch.
    local main = Tabs.AutoPlay:AddLeftGroupbox("Auto Play", "bot")
    main:AddToggle("AutoPlayEnable", { Text = "Enable Auto Play", Tooltip = "Places your six units by itself. A macro assigned to the stage runs instead when Play Macro is on.", Default = cfg.enable, Callback = function(v)
        set("enable")(v)
        if v and AutoPlay.start then AutoPlay.start() end
    end })
    main:AddToggle("AutoPlayUpgrade", { Text = "Enable Auto Upgrade", Tooltip = "Upgrades the placed units, biggest gain per yen first.", Default = cfg.upgrade, Callback = set("upgrade") })
    main:AddToggle("AutoPlayFocusFarm", { Text = "Focus Farm Units", Tooltip = "Money units are placed and upgraded first.", Default = cfg.focus_farm, Callback = set("focus_farm") })
    main:AddToggle("AutoPlayShowPlan", { Text = "Show Plan", Tooltip = "Draws the spots the units still to place would take: a small stud with the hotbar slot number each, the path point, a green ring (ground radius) and a blue ring (hill radius) for the longest-range unit.", Default = false, Callback = function(v)
        if AutoPlay.showPlan then AutoPlay.showPlan(v) elseif v then lib:Notify("Show Plan works inside a match") end
    end })
    main:AddSlider("AP_Distance", { Text = "Distance Percentage", Tooltip = "Where along the enemy path your units stand: 0% = enemy spawn, 100% = your base.", Default = cfg.distance, Min = 0, Max = 100, Rounding = 0, Suffix = "%", Callback = set("distance") })
    main:AddSlider("AP_Ground", { Text = "Ground Percentage", Tooltip = "How far from that path point ground units may stand, as a share of each unit's range. 0% = right at the point, 100% = anywhere in range. Units fill outward from the point.", Default = cfg.ground, Min = 0, Max = 100, Rounding = 0, Suffix = "%", Callback = set("ground") })
    main:AddSlider("AP_Hill", { Text = "Hill Percentage", Tooltip = "The same for hill units (and units that can use either): how far from the path point they may stand on hills, as a share of their range.", Default = cfg.hill, Min = 0, Max = 100, Rounding = 0, Suffix = "%", Callback = set("hill") })
    main:AddToggle("AP_HybridHill", { Text = "Hybrid Units on Hills", Tooltip = "Units that can stand on ground or hills (not buffers, not money units) take a hill spot when one is within Hill Percentage of the path point, because Soaring enemies only take damage from units on a hill. With no hill in reach they stand on the ground as before.", Default = cfg.hybrid_hill, Callback = set("hybrid_hill") })
    -- Same saved key as the old Joiner > Portal Joiner toggle (joiner.portal.lanes), now for every stage.
    local jp = Core.config.joiner and Core.config.joiner.portal
    if jp then
        main:AddToggle("AP_Lanes", { Text = "Place Where Lanes Meet", Tooltip = "On a map with more than one enemy lane (Sky Island, Shibuya, Assassin Park) the units stand where every lane is within 18 studs of the others, instead of at Distance Percentage. Maps with one lane are not changed.", Default = jp.lanes ~= false, Callback = function(v) jp.lanes = v Core.save_config() end })
    end
    ui.status = main:AddLabel("Status: -", true)
    ui.slots = main:AddLabel("Slots: -", true)

    -- Per unit: a strip of the six hotbar portraits (clones of the game's own hotbar viewports); click one to edit its limits.
    local units = Game.data("Units")
    local sel, loading = 1, false
    local sliders, cells, shown, lastEq = {}, {}, "", {}
    local strip = Tabs.AutoPlay:AddLeftGroupbox("Units", "users")
    local picked = strip:AddLabel("Unit 1", true)
    local function new(class, props, parent)
        local o = Instance.new(class)
        for k, v in props do o[k] = v end
        o.Parent = parent
        return o
    end
    local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), VerticalAlignment = Enum.VerticalAlignment.Center }, holder)
    for i = 1, 6 do
        local b = new("TextButton", { Size = UDim2.new(1 / 6, -5, 1, 0), Text = "", AutoButtonColor = false, ClipsDescendants = true, LayoutOrder = i, BackgroundColor3 = lib.Scheme.MainColor })
        new("UICorner", { CornerRadius = UDim.new(0, 10) }, b)
        new("UIAspectRatioConstraint", { AspectType = Enum.AspectType.FitWithinMaxSize, DominantAxis = Enum.DominantAxis.Width }, b)
        local line = new("UIStroke", { Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
        new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(4, 2), Text = tostring(i), ZIndex = 5,
            TextColor3 = Color3.new(1, 1, 1), TextSize = 13, FontFace = lib.Scheme.Font, TextXAlignment = Enum.TextXAlignment.Left, TextStrokeTransparency = 0.4 }, b)
        b.Parent = holder
        cells[i] = { btn = b, line = line }
        b.MouseButton1Click:Connect(function() AutoPlay.selectSlot(i) end)
    end
    strip:AddUIPassthrough("AP_UnitStrip", { Instance = holder, Height = 62 })

    local function equipped()
        local ok, col = pcall(function()
            if Hub.mode == "match" then return Game.loader().load_client_service(script, "GUIService").session.collection.collection_profile_data end
            return Game.profile().collection
        end)
        local out = {}
        if ok and col then
            for i = 1, 6 do
                local uuid = col.equipped_units[i] or col.equipped_units[tostring(i)]
                local u = uuid and col.owned_units[uuid]
                out[i] = u and u.unit_id
            end
        end
        return out
    end
    local function unitName(i, eq) local d = eq[i] and units[eq[i]] return d and d.name or "empty" end
    local function paint(eq)
        for i, c in cells do c.line.Color = i == sel and lib.Scheme.AccentColor or lib.Scheme.OutlineColor end
        picked:SetText(("Unit %d: %s"):format(sel, unitName(sel, eq or equipped())))
    end
    local function portraits(eq)
        local hb = LP:FindFirstChild("PlayerGui") and LP.PlayerGui:FindFirstChild("spawn_units")
        hb = hb and hb:FindFirstChild("Lives") and hb.Lives.Frame.Units
        for i, c in cells do
            local old = c.btn:FindFirstChild("Portrait")
            if old then old:Destroy() end
            local src = hb and hb:FindFirstChild(tostring(i)) and hb[tostring(i)].Main:FindFirstChild("View")
            if src and eq[i] then
                local v = src:Clone()
                for _, k in v:GetChildren() do if k:IsA("UIScale") or k:IsA("UIAspectRatioConstraint") then k:Destroy() end end
                v.Name, v.Size, v.Position, v.AnchorPoint, v.BackgroundTransparency, v.ZIndex, v.Visible = "Portrait", UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero, 1, 2, true
                v.Parent = c.btn
            end
        end
    end
    function AutoPlay.selectSlot(i)
        sel = i
        loading = true
        for field, s in sliders do s:SetValue(cfg[field][i]) end
        loading = false
        paint()
    end
    -- The hotbar changes when the team does (Teams / Team Equipper): rebuild the portraits when the six ids differ.
    task.spawn(function()
        while not lib.Unloaded do
            local ok, err = pcall(function()
                local eq = equipped()
                local sig = table.concat({ eq[1] or "-", eq[2] or "-", eq[3] or "-", eq[4] or "-", eq[5] or "-", eq[6] or "-" }, ",")
                if sig ~= shown then
                    shown, lastEq = sig, eq
                    portraits(eq)
                    paint(eq)
                    if AutoPlay.refreshLists then AutoPlay.refreshLists() end
                end
            end)
            if not ok then Core.log("ERROR autoplay strip:", err) task.wait(10) end
            task.wait(2)
        end
    end)

    local function perUnit(box, field, title, min, max)
        sliders[field] = box:AddSlider("AP_" .. field, { Text = title, Default = cfg[field][1], Min = min, Max = max, Rounding = 0,
            Callback = function(v)
                if loading then return end
                cfg[field][sel] = v
                Core.save_config()
                if AutoPlay.refreshLists then AutoPlay.refreshLists() end
            end })
    end
    local per = Tabs.AutoPlay:AddLeftTabbox()
    local t1 = per:AddTab("Caps")
    t1:AddLabel("Place Cap: copies to place. 0 = as many as allowed, -1 = leave this slot out.", true)
    perUnit(t1, "limit", "Place Cap", -1, 10)
    t1:AddLabel("Upgrade Cap: level to stop at. 0 = maximum, -1 = after the other units, -2 = never.", true)
    perUnit(t1, "ulimit", "Upgrade Cap", -2, 12)
    local t2 = per:AddTab("Waves")
    t2:AddLabel("Wave a unit starts being placed or upgraded. 0 = from the start.", true)
    perUnit(t2, "wave", "Place on Wave", 0, 60)
    perUnit(t2, "uwave", "Upgrade on Wave", 0, 60)

    -- Everything else, grouped by purpose.
    local adv = Tabs.AutoPlay:AddRightTabbox()
    local a1 = adv:AddTab("Behavior")
    ui.preset = a1:AddDropdown("AP_Preset", { Text = "Preset", Tooltip = "Sets Smart Opening, Focus Farm, Auto Upgrade and Upgrade Method at once. It is remembered per stage type. None = leave everything as it is.", Values = PRESET_NAMES, Default = PRESET_NAMES[1], Callback = function(v)
        if AutoPlay.applyPreset then AutoPlay.applyPreset(v, true) end
    end })
    a1:AddToggle("AutoPlayOpening", { Text = "Smart Opening", Tooltip = "When your first unit is too expensive, place farm units first instead of waiting.", Default = cfg.opening, Callback = set("opening") })
    a1:AddToggle("AutoPlayUpgradePlace", { Text = "Upgrade Between Placements", Tooltip = "One upgrade after every placement. Off: place everything first, then upgrade.", Default = cfg.upgrade_place, Callback = set("upgrade_place") })
    a1:AddToggle("AutoPlayFuse", { Text = "Auto Fuse Vegito", Tooltip = "With Carrot (Ultra) and Vego (Mage II) both on the hotbar: upgrades them only to level 7, casts the fusion on the better one (stat potentials, level, relic), then upgrades the Fused Hero to its maximum.", Default = cfg.fuse, Callback = set("fuse") })
    a1:AddDropdown("AP_Method", { Text = "Upgrade Method", Tooltip = "Cheapest first = buys any upgrade it can afford, farm units first, then the cheapest (never waits on an expensive one). The others: Smart = most damage per yen, or hotbar order, your own order, or the lowest level first. Upgrade Cap always applies.", Values = METHODS, Default = cfg.method, Callback = set("method", function(v)
        if v ~= METHODS[4] then cfg.method_script = v end -- what Script mode in the Upgrade Order list returns to
        if AutoPlay.refreshLists then AutoPlay.refreshLists() end
    end) })

    local a2 = adv:AddTab("Position")
    ui.stage = a2:AddLabel("Stage: join a match", true)
    a2:AddSlider("AP_Gap", { Text = "Space Between Units", Tooltip = "Extra studs left between units (they only need to not touch).", Default = cfg.margin, Min = 0, Max = 6, Rounding = 1, Callback = set("margin") })
    a2:AddToggle("AP_Pack", { Text = "Pack Units Tight", Tooltip = "Needs Place Anywhere on (Game tab). Units stand 1 stud apart around the path point and may stand on the road. Off: hitboxes must not touch, the road is avoided, Space Between Units applies.", Default = cfg.pack, Callback = set("pack") })
    ui.kind = a2:AddDropdown("AP_Kind", { Text = "Center Units On", Tooltip = "The enemy path (automatic), or a position you saved for this stage.", Values = KINDS, Default = KINDS[1], Callback = function(v)
        cfg.kind[stageKey()] = v ~= KINDS[1] and v or nil
        Core.save_config()
    end })
    ui.target = a2:AddDropdown("AP_Target", { Text = "Save Position For", Values = { "All units", "Slot 1", "Slot 2", "Slot 3", "Slot 4", "Slot 5", "Slot 6" }, Default = "All units" })
    local function targetSlot() local v = ui.target.Value return v == "All units" and "mid" or tonumber(v:match("%d")) end
    local function assign(p)
        local key, t = stageKey(), targetSlot()
        if t == "mid" then cfg.mid[key] = p else setPos(cfg.slotpos, key, tostring(t), p) end
        Core.save_config()
        if AutoPlay.refreshLabels then AutoPlay.refreshLabels() end
    end
    a2:AddButton({ Text = "Save My Position", Tooltip = "Saves where your character stands. A slot position wins over the one for all units.", Func = function()
        local p = standing()
        if p then assign(p) else lib:Notify("No character") end
    end })
    a2:AddInput("AP_Coords", { Text = "Or Type Coordinates", Placeholder = "X, Y, Z then Enter", Default = "", Finished = true, Callback = function(v)
        local x, y, z = (v or ""):match("(-?[%d%.]+)[,%s]+(-?[%d%.]+)[,%s]+(-?[%d%.]+)")
        if x then assign({ tonumber(x), tonumber(y), tonumber(z) }) else lib:Notify("Use X, Y, Z") end
    end })
    a2:AddButton({ Text = "Clear This Position", Func = function() assign(nil) end })
    a2:AddButton({ Text = "Clear All Positions (this stage)", DoubleClick = true, Func = function()
        local key = stageKey()
        cfg.mid[key], cfg.slotpos[key] = nil, nil
        Core.save_config()
        if AutoPlay.refreshLabels then AutoPlay.refreshLabels() end
    end })
    ui.posinfo = a2:AddLabel("Saved: none", true)

    local a3 = adv:AddTab("Learn")
    a3:AddLabel("Turn Learn on, place your units by hand, turn it off. Auto Play then copies your spots on this map.", true)
    a3:AddToggle("AutoPlayLearn", { Text = "Learn My Placements", Tooltip = "Replaces what was learned before for this map.", Default = false, Callback = function(v)
        if AutoPlay.learn then AutoPlay.learn(v) elseif v then lib:Notify("Learn inside a match") end
    end })
    a3:AddToggle("AutoPlayUseLearned", { Text = "Use Learned Spots", Default = cfg.use_learned, Callback = set("use_learned") })
    a3:AddButton({ Text = "Forget Learned Spots (this map)", DoubleClick = true, Func = function()
        cfg.learned[mapKey()] = nil
        Core.save_config()
        lib:Notify("Forgot the learned spots of " .. mapKey())
    end })

    local a4 = adv:AddTab("Target")
    a4:AddDropdown("AP_Priority", { Text = "Target Priority", Tooltip = "Who your units shoot at. Game default leaves it alone.", Values = PRIOS, Default = cfg.priority, Callback = set("priority") })
    a4:AddDropdown("AP_BossPriority", { Text = "Boss Target Priority", Tooltip = "Used while the stage's boss is alive. Game default = no change.", Values = PRIOS, Default = cfg.boss_priority, Callback = set("boss_priority") })

    -- Order lists: Script = the hub decides, Custom = your order. Use / Skip leaves a unit in or out, the arrows move it.
    local lists = {}
    local S = lib.Scheme
    local function ranked(field)
        local s = { 1, 2, 3, 4, 5, 6 }
        table.sort(s, function(a, b)
            if cfg[field][a] ~= cfg[field][b] then return cfg[field][a] < cfg[field][b] end
            return a < b
        end)
        return s
    end
    local function syncSlider(field, slot)
        if slot ~= sel or not sliders[field] then return end
        loading = true
        sliders[field]:SetValue(cfg[field][slot])
        loading = false
    end
    local function arrow(icon, fallback, x, parent)
        local props = { Size = UDim2.fromOffset(22, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0) }
        local ic = lib:GetIcon(icon)
        local b
        if ic then
            props.ImageColor3 = S.FontColor
            b = lib:CreateIcon(ic, props, true)
        else
            props.Text, props.TextSize, props.BackgroundTransparency, props.TextColor3, props.FontFace = fallback, 14, 1, S.FontColor, S.Font
            b = new("TextButton", props)
        end
        b.Parent = parent
        return b
    end
    local USE, SKIP = { Color3.fromRGB(34, 72, 54), Color3.fromRGB(120, 230, 160) }, { Color3.fromRGB(78, 38, 48), Color3.fromRGB(240, 120, 130) }
    local function makeList(title, icon, def)
        local box = Tabs.AutoPlay:AddRightGroupbox(title, icon)
        box:AddLabel(def.hint, true)
        if def.extra then def.extra(box) end
        local frame = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
        new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, frame)
        local L, rows, segBtn = {}, {}, {}
        local seg = new("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = S.MainColor, LayoutOrder = 0 }, frame)
        new("UICorner", { CornerRadius = UDim.new(0, 8) }, seg)
        for n, name in { "Script", "Custom" } do
            local b = new("TextButton", { Size = UDim2.new(0.5, -4, 1, -6), Position = UDim2.new((n - 1) * 0.5, n == 1 and 3 or 1, 0, 3), Text = name,
                AutoButtonColor = false, TextSize = 14, FontFace = S.Font, BorderSizePixel = 0 }, seg)
            new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
            b.MouseButton1Click:Connect(function() def.setCustom(n == 2) L.refresh() end)
            segBtn[n] = b
        end
        local function move(k, dir)
            if not def.isCustom() or not rows[k + dir] then return end
            local s = ranked(def.field)
            for rank, slot in s do cfg[def.field][slot] = rank end -- ties become a strict order first
            cfg[def.field][s[k]], cfg[def.field][s[k + dir]] = k + dir, k
            Core.save_config()
            L.refresh()
        end
        for k = 1, 6 do
            local r = { k = k }
            r.frame = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = S.MainColor, LayoutOrder = k }, frame)
            new("UICorner", { CornerRadius = UDim.new(0, 8) }, r.frame)
            r.num = new("TextLabel", { Size = UDim2.fromOffset(22, 22), Position = UDim2.new(0, 6, 0.5, -11), BackgroundColor3 = S.OutlineColor, TextColor3 = S.FontColor, TextSize = 13, FontFace = S.Font }, r.frame)
            new("UICorner", { CornerRadius = UDim.new(0, 6) }, r.num)
            r.name = new("TextLabel", { Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -144, 1, 0), BackgroundTransparency = 1, TextColor3 = S.FontColor, TextSize = 14,
                FontFace = S.Font, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, r.frame)
            r.pill = new("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -58, 0.5, 0), Size = UDim2.fromOffset(46, 22), AutoButtonColor = false,
                TextSize = 13, FontFace = S.Font, BorderSizePixel = 0 }, r.frame)
            new("UICorner", { CornerRadius = UDim.new(0, 6) }, r.pill)
            r.up, r.down = arrow("chevron-up", "^", -30, r.frame), arrow("chevron-down", "v", -6, r.frame)
            r.pill.MouseButton1Click:Connect(function() def.toggle(r.slot) L.refresh() end)
            r.up.MouseButton1Click:Connect(function() move(r.k, -1) end)
            r.down.MouseButton1Click:Connect(function() move(r.k, 1) end)
            rows[k] = r
        end
        function L.refresh()
            local custom = def.isCustom()
            for n, b in segBtn do
                local on = (n == 2) == custom
                b.BackgroundTransparency, b.BackgroundColor3, b.TextColor3 = on and 0 or 1, S.AccentColor, on and S.BackgroundColor or S.FontColor
            end
            for k, slot in custom and ranked(def.field) or { 1, 2, 3, 4, 5, 6 } do
                local r, skip = rows[k], def.skipped(slot)
                local d = lastEq[slot] and units[lastEq[slot]]
                r.slot = slot
                r.name.Text = d and d.name or ("Slot " .. slot)
                r.name.TextTransparency = (skip or not d) and 0.55 or 0
                r.num.Text = tostring(custom and k or slot)
                r.pill.Text = skip and "Skip" or "Use"
                r.pill.BackgroundColor3, r.pill.TextColor3 = unpack(skip and SKIP or USE)
                r.up.Visible, r.down.Visible = custom and k > 1, custom and k < 6
            end
        end
        box:AddUIPassthrough("AP_" .. def.field .. "_list", { Instance = frame, Height = 244 })
        table.insert(lists, L)
    end
    makeList("Place Order", "list-ordered", {
        field = "order", hint = "Script = hotbar order (farm units first when Focus Farm is on). Custom = your order. Skip leaves the unit out.",
        isCustom = function() return cfg.place_custom end,
        setCustom = function(v) cfg.place_custom = v Core.save_config() end,
        skipped = function(slot) return cfg.limit[slot] == -1 end,
        toggle = function(slot) cfg.limit[slot] = cfg.limit[slot] == -1 and 0 or -1 Core.save_config() syncSlider("limit", slot) end,
    })
    makeList("Upgrade Order", "arrow-up-narrow-wide", {
        field = "uorder", hint = "Script = the Upgrade Method (Behavior tab) decides. Custom = your order. Skip never upgrades the unit.",
        extra = function(box)
            box:AddToggle("AP_UpgradeOne", { Text = "One at a time", Default = cfg.upgrade_one, Callback = set("upgrade_one"),
                Tooltip = "Custom order only. On: the first unit in the list is upgraded first and the hub waits for the money, never moving on. Off: buys the first affordable unit in your order, so cheaper units further down still get upgraded while it saves up." })
        end,
        isCustom = function() return cfg.method == METHODS[4] end,
        setCustom = function(v)
            local m = v and METHODS[4] or (cfg.method_script ~= METHODS[4] and cfg.method_script or METHODS[1])
            lib.Options.AP_Method:SetValue(m) -- the dropdown writes cfg.method and refreshes the lists
        end,
        skipped = function(slot) return cfg.ulimit[slot] == -2 end,
        toggle = function(slot) cfg.ulimit[slot] = cfg.ulimit[slot] == -2 and 0 or -2 Core.save_config() syncSlider("ulimit", slot) end,
    })
    function AutoPlay.refreshLists() for _, L in lists do L.refresh() end end
    lastEq = equipped()
    AutoPlay.refreshLists()
end

function AutoPlay.refreshLabels()
    if not ui.stage then return end
    local key = stageKey()
    ui.stage:SetText("Stage: " .. key)
    local parts = { "all units " .. posText(cfg.mid[key]) }
    for slot, p in cfg.slotpos[key] or {} do table.insert(parts, ("Slot %s %s"):format(slot, posText(p))) end
    local learned = cfg.learned[mapKey()]
    if learned then
        local n = 0
        for _, l in learned do n += #l end
        table.insert(parts, ("learned %d spots"):format(n))
    end
    ui.posinfo:SetText("Saved: " .. table.concat(parts, "; "))
    ui.kind:SetValue(cfg.kind[key] or KINDS[1])
end
if Tabs then pcall(AutoPlay.refreshLabels) end

-- Moves the UI controls (their callbacks write cfg); `remember` stores the choice for this match's stage type.
function AutoPlay.applyPreset(name, remember)
    local p = PRESETS[name]
    if remember and level then
        local mode = Game.stage(level)
        if mode then cfg.mode_preset[mode] = name Core.save_config() end
    end
    if not p then return end
    local lib = Hub.UI and Hub.UI.Library
    local ctl = { opening = "AutoPlayOpening", focus_farm = "AutoPlayFocusFarm", upgrade = "AutoPlayUpgrade", method = "AP_Method" }
    for key, v in p do
        cfg[key] = v
        local c = lib and (lib.Toggles[ctl[key]] or lib.Options[ctl[key]])
        if c then pcall(c.SetValue, c, v) end
    end
    Core.save_config()
end
if level then
    local mode = Game.stage(level)
    local saved = mode and cfg.mode_preset[mode]
    if saved and ui.preset then ui.preset:SetValue(saved) end
end

local lastStatus
local function status(text)
    if text ~= lastStatus and ui.status then ui.status:SetText("Status: " .. text) end
    lastStatus = text
end

if Hub.mode ~= "match" then return AutoPlay end

-- Summer Hunt started by Auto Summer Hunt: its own settings on top of nothing (src/summer.lua); the saved config is not read or written.
do
    -- pilot = the Hunt's own settings (a copy, nothing saved). lanePilot = the saved settings themselves, read and written through a proxy that only
    -- answers Distance Percentage from the lanes on a multi-lane map (in-match toggles used to land on a copy and were gone next match).
    local ok, ov, hunt = pcall(function()
        local p = Hub.Summer and Hub.Summer.pilot(defaults, METHODS)
        if p then return p, true end
        return Hub.Summer and Hub.Summer.lanePilot(cfg), false
    end)
    if ok and ov then
        cfg = ov
        if hunt then Core.log("autoplay: Summer autopilot settings") end
    elseif not ok then
        Core.log("ERROR autoplay pilot", ov)
    end
end

------------------------------------------------------------------ match side
local defs = Game.data("Units")
local Traits = Game.data("Traits")
local STEP = 2 -- studs between sampled path points and between candidate cells
local counts = { placed = 0, refused_pos = 0, refused_silent = 0, upgrades = 0, learned_cap = 0 }
local t0 = os.clock()

-- Hotbar: slot -> { uuid, id, def, owned }. The GUIService session appears a few seconds after the match loads.
local function hotbar()
    local gs = Game.loader().load_client_service(script, "GUIService")
    local col = gs.session.collection.collection_profile_data
    local out = {}
    for slot = 1, 6 do
        local uuid = col.equipped_units[slot] or col.equipped_units[tostring(slot)]
        local u = uuid and col.owned_units[uuid]
        local d = u and defs[u.unit_id]
        if d then out[slot] = { uuid = uuid, id = u.unit_id, def = d, owned = u, traits = u.traits } end
    end
    return out
end

local function modifier(name)
    local m = workspace:FindFirstChild("_DATA") and workspace._DATA:FindFirstChild("LevelModifiers")
    local v = m and m:FindFirstChild(name)
    return v and v.Value or 1
end
-- Real prices can be above the data: portals have modifiers, one doubles every cost unless Idol (Star) is on the team (user, 2026-11-09), and it is
-- not in _DATA.LevelModifiers (3 days of logs: 2,472 upgrades refused in portals at "cost scale 1.00"). So the scale is learned from what the server
-- takes for a purchase (rounded to 0.25: kill income lands in the same moment), and nudged up when an affordable upgrade is refused.
local paidScale = 1
local upBlock = setmetatable({}, { __mode = "k" }) -- unit -> os.clock() until which its upgrade is not tried again (it was just refused)
local function costScale() return modifier("player_cost_scale") * paidScale end
local function learnPaid(before, listed) -- money before the purchase, its price by the data (level modifier included)
    local res = LP._stats.resource
    for _ = 1, 10 do if res.Value < before then break end task.wait(0.05) end
    local k = math.floor((before - res.Value) / math.max(listed, 1) * 4 + 0.5) / 4
    if k >= 1 and k <= 3 and k ~= paidScale then
        paidScale = k
        Core.log(("autoplay prices: the server takes %.2f x the listed cost"):format(k))
    end
end

local function isFarm(def) return (def.farm_amount or 0) > 0 end
local function roleOf(def)
    if isFarm(def) then return "farm" end
    if def._show_as_buff_unit then return "buffer" end
    return "dps"
end
local function hitR(def) return def.override_hitbox_radius or 1.87 end

-- Range a unit will have once upgraded as far as Auto Upgrade takes it (placement is permanent).
local function plannedRange(slot, h)
    local lvl = 0
    local lim = cfg.ulimit[slot] or 0
    if cfg.upgrade and lim ~= -2 and h.def.upgrade then
        lvl = lim > 0 and math.min(lim, #h.def.upgrade) or #h.def.upgrade
    end
    local range = h.def.range or 10
    for l = lvl, 1, -1 do
        local up = h.def.upgrade[l]
        if up and up.range then range = up.range break end
    end
    local stat = h.owned and h.owned.trait_stats and h.owned.trait_stats.range_stat or 1
    return range * stat * modifier("player_range_scale")
end

-- spawn_cap (3 when the data has none: Dark Mage, user 2026-10-26; a wrong guess is corrected by the server's refusal, see learnedCap), or 1 for the "unique" trait
-- (the server refuses a second copy, verified 2026-10-25). Other `singular` traits (Divine, Golden, Reaper, Sniper ...) only mean "no tier numeral", not a placement limit.
local learnedCap = {} -- uuid -> cap the server enforced (a silent refusal while that many stand)
local function placementCap(h)
    local cap = h.def.spawn_cap or 3
    for _, t in h.traits or {} do
        if t.trait == "unique" then cap = 1 end
    end
    return math.min(cap, learnedCap[h.uuid] or math.huge)
end

------------------------------------------------------------------ path
-- Enemy lanes: _BASES.pve.LANES.<n> holds parts spawn, 1..k, final. Resampled every STEP studs; prog = 0 at the spawn, 1 at the base.
local lanes = {}
local function loadLanes()
    local out = {}
    local root = workspace:FindFirstChild("_BASES") and workspace._BASES:FindFirstChild("pve")
    root = root and root:FindFirstChild("LANES")
    for _, lane in root and root:GetChildren() or {} do
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
        if #pts >= 2 then
            local samples, total = {}, 0
            for i = 1, #pts - 1 do total += (pts[i + 1] - pts[i]).Magnitude end
            local run = 0
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                local len = (b - a).Magnitude
                for d = 0, len - 0.01, STEP do table.insert(samples, { p = a:Lerp(b, d / len), prog = (run + d) / total }) end
                run += len
            end
            table.insert(samples, { p = pts[#pts], prog = 1 })
            table.insert(out, { samples = samples, length = total, base = pts[#pts], first = pts[1] })
        end
    end
    return out
end
local function pathPoint(frac) -- point at fraction of the longest lane
    local best
    for _, l in lanes do if not best or l.length > best.length then best = l end end
    if not best then return nil end
    return best.samples[math.clamp(math.floor(frac * (#best.samples - 1)) + 1, 1, #best.samples)].p
end

------------------------------------------------------------------ placement ground and the game's own hitbox check
-- Raycast ground: same rule as the game's PlacementCore.is_valid_raycast_hit (ground / hill / terrain, first hit).
local T = workspace:WaitForChild("_terrain")
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Include
rp.FilterDescendantsInstances = { T }
local cells = {} -- ix * 100003 + iz -> { pos, cls = "G" | "H" } or false
local function cell(ix, iz, y0)
    local k = ix * 100003 + iz
    local c = cells[k]
    if c == nil then
        local r = workspace:Raycast(Vector3.new(ix * STEP, y0 + 80, iz * STEP), Vector3.new(0, -400, 0), rp)
        c = false
        if r and r.Instance.Name ~= "_donotplace" then
            local hill = T:FindFirstChild("hill")
            if r.Instance:IsDescendantOf(T.ground) then c = { pos = r.Position, cls = "G" }
            elseif hill and r.Instance:IsDescendantOf(hill) then c = { pos = r.Position, cls = "H" } end
        end
        cells[k] = c
    end
    return c
end

-- Same as cell() for any point (not only the grid), used for spots next to a standing unit.
local rays = {}
local function ray(x, z, y0)
    local k = math.floor(x * 4 + 0.5) * 1000003 + math.floor(z * 4 + 0.5)
    local c = rays[k]
    if c == nil then
        local r = workspace:Raycast(Vector3.new(x, y0 + 80, z), Vector3.new(0, -400, 0), rp)
        c = false
        if r and r.Instance.Name ~= "_donotplace" then
            local hill = T:FindFirstChild("hill")
            if r.Instance:IsDescendantOf(T.ground) then c = { pos = r.Position, cls = "G", key = k }
            elseif hill and r.Instance:IsDescendantOf(hill) then c = { pos = r.Position, cls = "H", key = k } end
        end
        rays[k] = c
    end
    return c
end

-- The game's placement preview asks the unit's hitbox cylinder what it touches (other player hitboxes, _road, _bounds).
-- We ask the same question with a ghost cylinder; _bounds lives in ReplicatedStorage, so a client-only copy sits in workspace.
local ghost, ovp, ovpB
-- Packed mode: Place Anywhere is on, so road and unit overlap are fine; the server only refuses a unit of the same type closer than ~0.75 studs.
-- Measured 2026-10-26: default-size units (hitbox radius 1.87) were accepted at 1.0, but a Speedwagon (override radius 3) refused anything
-- within 2.0 and accepted 2.18: larger hitboxes need ~0.75 x radius (shortcut: fits two data points; Bulma, radius 5, is a guess).
local PACK = 1.0
local function gapFor(a, b) local R = math.max(a, b) return R > 2 and 0.75 * R + 0.05 or PACK end
local function packed() return cfg.pack and (Core.config.game or {}).place_anywhere end
local function setupGhost()
    local folder = Instance.new("Folder")
    folder.Name = "ZenoGhost"
    local bounds = game.ReplicatedStorage:FindFirstChild("_bounds")
    local copy
    if bounds then
        copy = bounds:Clone()
        for _, d in copy:GetDescendants() do
            if d:IsA("BasePart") then d.Anchored, d.CanCollide, d.CanTouch, d.CanQuery, d.Transparency = true, false, false, true, 1 end
        end
        copy.Parent = folder
    end
    ghost = Instance.new("Part")
    ghost.Shape, ghost.Anchored, ghost.CanCollide, ghost.CanTouch, ghost.CanQuery, ghost.Transparency = Enum.PartType.Cylinder, true, false, false, false, 1
    ghost.Parent = folder
    folder.Parent = workspace
    table.insert(Hub.connections, { Disconnect = function() folder:Destroy() end })
    ovp = OverlapParams.new()
    ovp.FilterType = Enum.RaycastFilterType.Include
    local list = { workspace:FindFirstChild("_road"), workspace:FindFirstChild("_UNITS"), copy }
    for i = #list, 1, -1 do if not list[i] then table.remove(list, i) end end
    ovp.FilterDescendantsInstances = list
    ovp.MaxParts = 50
    if copy then -- bounds only (trees, walls: whether the server accepts them is unverified, so packed mode still avoids them)
        ovpB = OverlapParams.new()
        ovpB.FilterType = Enum.RaycastFilterType.Include
        ovpB.FilterDescendantsInstances = { copy }
        ovpB.MaxParts = 5
    end
end
local function touches(pos, r, boundsOnly)
    if boundsOnly and not ovpB then return end
    ghost.Size = Vector3.new(2.66, r * 2, r * 2)
    ghost.CFrame = CFrame.new(pos + Vector3.new(0, 1.33, 0)) * CFrame.Angles(0, 0, math.pi / 2)
    local units = workspace:FindFirstChild("_UNITS")
    for _, part in workspace:GetPartsInPart(ghost, boundsOnly and ovpB or ovp) do
        if not (units and part:IsDescendantOf(units)) then return part end -- _road or _bounds
        if part.Name == "_hitbox" and part.Parent and CS:HasTag(part.Parent, "player_units") then return part end -- another player's unit
    end
end
AutoPlay.touches = function(pos, r) return touches(pos, r) end

-- Other players' damage units (Summer autopilot in a party / matchmaking, user 2026-11-03): how many stand, and the median of where they stand as a
-- fraction of the longest lane (0 = enemy spawn, 1 = base: the same scale as Distance Percentage). Farms, buffers and units without damage do not count.
-- shortcut: an owner's summons (Elyssia's eels, scouts) are counted too when their id has damage; the median hardly moves, the count can run ahead.
-- UNVERIFIED live: read from the same `_stats.player` / `_stats.id` fields as myUnits, not yet run against a real teammate's units.
function AutoPlay.teammates()
    local lane
    for _, l in lanes do if not lane or l.length > lane.length then lane = l end end
    local folder = workspace:FindFirstChild("_UNITS")
    if not (lane and folder) then return 0, nil end
    local fracs = {}
    for _, u in folder:GetChildren() do
        local s = u:FindFirstChild("_stats")
        local owner = s and s:FindFirstChild("player")
        local id = s and s:FindFirstChild("id")
        local def = id and defs[id.Value]
        if owner and owner.Value and owner.Value ~= LP and def and (def.damage or 0) > 0 and not isFarm(def) and not def._show_as_buff_unit then
            local p, best, prog = u:GetPivot().Position, math.huge, nil
            for _, smp in lane.samples do
                local d = (smp.p.X - p.X) ^ 2 + (smp.p.Z - p.Z) ^ 2
                if d < best then best, prog = d, smp.prog end
            end
            if prog then table.insert(fracs, prog) end
        end
    end
    table.sort(fracs)
    return #fracs, fracs[1] and fracs[math.ceil(#fracs / 2)] or nil
end

------------------------------------------------------------------ units and planning
local function myUnits()
    local out = {}
    local folder = workspace:FindFirstChild("_UNITS")
    for _, u in folder and folder:GetChildren() or {} do
        local s = u:FindFirstChild("_stats")
        if s and s:FindFirstChild("player") and s.player.Value == LP and s:FindFirstChild("uuid") then table.insert(out, u) end
    end
    return out
end
-- Summons (Elyssia's eels, Erwin's scouts) carry the owner's uuid but another id: copies match both.
local function isCopy(u, h) return u._stats.uuid.Value == h.uuid and u._stats.id.Value == h.id end
local function slotOf(hb, u)
    for slot, h in hb do if isCopy(u, h) then return slot end end
end

local blacklist = {} -- cell key -> expiry (os.clock)
local recent = {}    -- { pos, r, t } placed a moment ago, maybe not in _UNITS yet
local hb -- hotbar, set when the loop starts

-- Auto Fuse (docs/features/summer-update.md, verified 2026-11-01): Carrot and Vego get their fusion ability at upgrade 7 of 8, and
-- the cast on either one returns true only when both are ready. They are capped at 7 (the last upgrade is wasted yen) and the cast
-- goes to the better unit first (stat potentials, level, relic). Vegito (not on the hotbar) is then upgraded by upgradeList.
local FUSE_CARROT, FUSE_VEGO, FUSE_LEVEL = "goku_ssj3_evolved", "vegeta_majin_evolved", 7
local function fuseOn()
    if not (cfg.fuse and hb) then return false end
    local c, v
    for _, h in hb do
        if h.id == FUSE_CARROT then c = true elseif h.id == FUSE_VEGO then v = true end
    end
    return c and v
end
-- shortcut: the game's own rule for whose stats Vegito keeps is unknown; this ranks potentials x2 + range + speed + level + relic. Check it when it is known.
local function fuseScore(u)
    local ok, col = pcall(function() return Game.loader().load_client_service(script, "GUIService").session.collection.collection_profile_data end)
    local o = ok and col.owned_units[u._stats.uuid.Value]
    if not o then return 0 end
    local ts = o.trait_stats or {}
    return (ts.potency_stat or 1) * 2 + (ts.range_stat or 1) + (ts.speed_stat or 1) + (o.xp or 0) / 4.4e6 + (o._equipped_relic and 0.3 or 0)
end
local lastFuse = 0
local function tryFuse(units)
    if not fuseOn() or os.clock() - lastFuse < 3 then return end
    local ready, has = {}, {}
    for _, u in units do
        local id = u._stats.id.Value
        local aa = u._stats:FindFirstChild("active_attack")
        if (id == FUSE_CARROT or id == FUSE_VEGO) and aa and tostring(aa.Value):find("fusion") then
            table.insert(ready, u)
            has[id] = true
        end
    end
    if not (has[FUSE_CARROT] and has[FUSE_VEGO]) then return end
    lastFuse = os.clock()
    table.sort(ready, function(a, b) return fuseScore(a) > fuseScore(b) end)
    for _, u in ready do
        local ok, res = pcall(Game.invoke, "use_active_attack", u)
        Core.log(("autoplay fuse cast on %s -> %s (score %.2f)"):format(u._stats.id.Value, tostring(ok and res), fuseScore(u)))
        if ok and res then return end
    end
end

-- Everything standing (or planned): { pos, r, range, attacks }
local function placedList(units, virtual)
    local out = {}
    for _, u in units do
        local slot = slotOf(hb, u)
        local h = slot and hb[slot]
        if h then
            local hbx = u:FindFirstChild("_hitbox")
            table.insert(out, { pos = u:GetPivot().Position, r = hbx and hbx.Size.Y / 2 or hitR(h.def), range = plannedRange(slot, h), attacks = not isFarm(h.def), buffer = roleOf(h.def) == "buffer", id = h.id,
                hybrid = h.def.hybrid_placement, hill = u:GetAttribute("_ap_hill") })
        end
    end
    for _, v in virtual or {} do table.insert(out, v) end
    return out
end

-- Square spiral order of the cell offsets around the origin: 0 = the origin cell, then right, down, left, up with growing sides.
local SPIRAL = {}
do
    local x, z, i, len, d = 0, 0, 0, 1, 1
    local dirs = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
    while len <= 100 do
        for _ = 1, 2 do
            for _ = 1, len do SPIRAL[x * 1000 + z] = i i += 1 x += dirs[d][1] z += dirs[d][2] end
            d = d % 4 + 1
        end
        len += 1
    end
end

-- Candidate spots for a slot, nearest first. `center` is the origin: the path point at Distance Percentage, or a saved position.
-- Ground units may stand on ground within Ground Percentage of their range from it, hill units (and units that use either) on
-- hills within Hill Percentage; `boost` widens both radii when nothing in the pass before passed the hitbox check. Candidates are
-- ordered by the square spiral around the origin (the origin cell first), the same origin for every unit, so the first free cell
-- in spiral order wins and the units grow outward in a packed square.
local function rank(slot, h, placed, center, around, boost)
    local def = h.def
    local R0 = plannedRange(slot, h)
    if roleOf(def) == "farm" then -- money units do not attack: use the longest range in the lineup so they stand with the others
        R0 = 0
        for sl, hh in hb do if not isFarm(hh.def) then R0 = math.max(R0, plannedRange(sl, hh)) end end
        if R0 == 0 then R0 = 20 end
    end
    local cap = R0 * 1.5 + 10
    local function radius(pct) return math.min(math.max(pct / 100 * R0, 8) * (boost or 1), cap) end
    local gR, hR = radius(cfg.ground), radius(cfg.hill)
    local cx, cz = math.floor(center.X / STEP + 0.5), math.floor(center.Z / STEP + 0.5)
    local n = math.ceil(math.max(gR, hR) / STEP)
    local out = {}
    for ix = cx - n, cx + n do
        for iz = cz - n, cz + n do
            local dx, dz = (ix - cx) * STEP, (iz - cz) * STEP
            local d = math.sqrt(dx * dx + dz * dz)
            local cl = d <= math.max(gR, hR) and cell(ix, iz, center.Y)
            if cl then
                local ok
                if cl.cls == "H" then ok = (def.hill_unit or def.hybrid_placement) and d <= hR
                else ok = not def.hill_unit and d <= gR end
                if ok then
                    table.insert(out, { pos = cl.pos, score = -(SPIRAL[(ix - cx) * 1000 + (iz - cz)] or 1e6), cls = cl.cls, key = ix * 100003 + iz })
                end
            end
        end
    end
    -- Touching spots come first: the origin itself, then the four sides (and corners, a little later) of every unit standing,
    -- at exactly hitbox + hitbox + gap, the ones closest to the origin (square distance) first. The grid cells above are the fallback.
    local r0, seen = hitR(def), {}
    local isBuf0 = roleOf(def) == "buffer"
    local function touching(x, z, bonus, lift)
        local ex, ez = x - center.X, z - center.Z
        local d = math.sqrt(ex * ex + ez * ez)
        if d > math.max(gR, hR) then return end
        local cl = ray(x, z, center.Y)
        if not cl or seen[cl.key] then return end
        seen[cl.key] = true
        local ok
        if cl.cls == "H" then ok = (def.hill_unit or def.hybrid_placement) and d <= hR
        else ok = not def.hill_unit and d <= gR end
        if ok then table.insert(out, { pos = cl.pos, score = 1e5 - (math.max(math.abs(ex), math.abs(ez)) + 0.3 * d) - bonus + (lift or 0), cls = cl.cls, key = cl.key }) end
    end
    touching(center.X, center.Z, 0)
    local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0.7071, 0.7071, 4 }, { -0.7071, 0.7071, 4 }, { 0.7071, -0.7071, 4 }, { -0.7071, -0.7071, 4 } }
    local hasCopy = false
    for _, pl in placed do if pl.id == h.id then hasCopy = true end end
    -- Copies of the same unit stand against each other first (all Leafas together, all Erwins together), then a buffer against buffers.
    local function rankOf(pl) return pl.id == h.id and 1 or ((isBuf0 and pl.buffer) and 2 or 3) end
    for pass = 1, 3 do
        for _, pl in placed do
            if rankOf(pl) == pass then
                local dist = packed() and gapFor(pl.r, r0) or (pl.r + r0 + cfg.margin + 0.1)
                local lift = pass == 1 and 2000 or (pass == 2 and 1000 or 0)
                for _, dir in DIRS do touching(pl.pos.X + dir[1] * dist, pl.pos.Z + dir[2] * dist, dir[3], lift) end
            end
        end
    end
    -- Buffs only reach units inside the buffer's range (Erwin 15, Leafa 25): a buffer takes the spots that reach the most units standing
    -- (two buffers: within the shorter range), and an attacker takes the spots inside a standing buffer's range. Nothing fits = no filter (the unit is still placed).
    local isBuf = roleOf(def) == "buffer"
    local anchors = {}
    for _, pl in placed do
        if pl.attacks and roleOf(def) ~= "farm" then
            if isBuf and pl.buffer then table.insert(anchors, { pos = pl.pos, reach = math.min(R0, pl.range) * 0.95 }) -- two buffers: the shorter range decides
            elseif isBuf then table.insert(anchors, { pos = pl.pos, reach = R0 * 0.95 })
            elseif pl.buffer then table.insert(anchors, { pos = pl.pos, reach = pl.range * 0.95 }) end
        end
    end
    -- Soaring enemies only take damage from units standing on a hill (game text, and `_on_hill` in its targeting code): a hybrid unit that attacks takes a hill
    -- spot whenever one is a candidate (ground spots stay as the fallback, and the buffer reach filter below does not drop hill spots).
    local hillFirst = cfg.hybrid_hill and def.hybrid_placement and not def.hill_unit and roleOf(def) ~= "buffer" and roleOf(def) ~= "farm"
    if #anchors > 0 and #out > 0 and not hasCopy then -- later copies follow their first copy (it was placed inside the reach)
        local best = 0
        for _, c in out do
            local n = 0
            for _, a in anchors do
                if (Vector3.new(c.pos.X - a.pos.X, 0, c.pos.Z - a.pos.Z)).Magnitude <= a.reach then n += 1 end
            end
            c.reach = n
            best = math.max(best, n)
        end
        if best > 0 then
            local kept = {}
            for _, c in out do if c.reach == best or (hillFirst and c.cls == "H") then table.insert(kept, c) end end
            out = kept
        end
    end
    if hillFirst then for _, c in out do if c.cls == "H" then c.score += 1e7 end end end
    table.sort(out, function(a, b) return a.score > b.score end)
    return out
end

-- Ghost check (road, bounds) plus hitbox spacing to every unit standing, planned or just placed: unit hitboxes are not
-- reachable by the ghost query (the server refused such spots), so spacing is measured by distance.
local function spotFree(c, h, virtual)
    if (blacklist[c.key] or 0) > os.clock() then return false end
    local r = hitR(h.def)
    local pk = packed()
    if touches(c.pos, r, pk) then return false end
    local m = cfg.margin
    for _, v in virtual or {} do
        if (Vector3.new(v.pos.X, 0, v.pos.Z) - Vector3.new(c.pos.X, 0, c.pos.Z)).Magnitude < (pk and gapFor(r, v.r) or r + v.r + m) then return false end
    end
    for i = #recent, 1, -1 do
        if os.clock() - recent[i].t > 3 then table.remove(recent, i)
        elseif (Vector3.new(recent[i].pos.X, 0, recent[i].pos.Z) - Vector3.new(c.pos.X, 0, c.pos.Z)).Magnitude < (pk and gapFor(r, recent[i].r) or r + recent[i].r + m) then return false end
    end
    -- the margin also applies to standing units (the ghost only needs them not to touch)
    if not pk and m > 0 and touches(c.pos, r + m) then return false end
    return true
end

-- Where a slot's units are centered: slot position, Middle Position (cluster tightly when the type says so), else the path point.
local function centerFor(slot)
    local key = stageKey()
    local sp = cfg.slotpos[key] and cfg.slotpos[key][tostring(slot)]
    local mid = cfg.mid[key]
    local midV = mid and Vector3.new(mid[1], mid[2], mid[3])
    if sp then return Vector3.new(sp[1], sp[2], sp[3]), true end
    if midV and cfg.kind[key] == KINDS[2] then return midV, true end
    local c = midV or pathPoint(cfg.distance / 100)
    if not c then
        local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        c = hrp and hrp.Position
    end
    return c, false
end

------------------------------------------------------------------ server messages and learning
local lastMsg, lastMsgAt = nil, 0
table.insert(Hub.connections, game.ReplicatedStorage:WaitForChild("endpoints"):WaitForChild("server_to_client"):WaitForChild("show_message").OnClientEvent:Connect(function(text)
    lastMsg, lastMsgAt = tostring(text), os.clock()
end))

local function learnedSpot(slot, nth)
    local l = cfg.learned[mapKey()]
    local list = l and l[tostring(slot)]
    local p = list and list[nth]
    return p and Vector3.new(p[1], p[2], p[3])
end

AutoPlay.learnedSpot, AutoPlay.mapKey = learnedSpot, mapKey -- exposed for checks from the executor
local logLine
-- One placement for a hotbar slot. Returns true, or false and a reason.
local slotBlock = {} -- slot -> os.clock() until which the slot is not tried again
local noSpot = {} -- slot -> "no spot" results in a row this match (the retry wait doubles)
local BOOSTS = { 1, 2, 4, 100 }
local function place(slot, h, units, live)
    local center, around = centerFor(slot)
    if not center then return false, "no position" end
    local placed = placedList(units)
    local list, checked, tries = {}, 0, 0
    for _, boost in BOOSTS do -- wider search when nothing in the pass before passed the hitbox check
    list = rank(slot, h, placed, center, around, boost)
    local nth = 1
    for _, u in units do if isCopy(u, h) then nth += 1 end end
    local lp = cfg.use_learned and learnedSpot(slot, nth)
    if lp then
        local c = cell(math.floor(lp.X / STEP + 0.5), math.floor(lp.Z / STEP + 0.5), lp.Y)
        table.insert(list, 1, { pos = lp, score = 1e9, cls = c and c.cls or "?", key = math.floor(lp.X / STEP + 0.5) * 100003 + math.floor(lp.Z / STEP + 0.5), learned = true })
    end
    checked, tries = 0, 0
    local silentRun = 0
    for _, c in list do
        if not live() then return false, "stopped" end
        if tries >= 6 or checked >= 700 then break end
        checked += 1
        if checked % 60 == 0 then task.wait() end
        if not spotFree(c, h, placed) then continue end
        tries += 1
        local tag = ""
        if packed() then -- what the packed spot overlaps, and the distance to the nearest other unit (for the log)
            local t, near = touches(c.pos, hitR(h.def)), math.huge
            for _, pl in placed do near = math.min(near, (Vector3.new(pl.pos.X, 0, pl.pos.Z) - Vector3.new(c.pos.X, 0, c.pos.Z)).Magnitude) end
            tag = (" packed%s near %.2f"):format(t and (t:IsDescendantOf(workspace._UNITS) and " on-unit" or " on-road") or "", near)
        end
        local look = Vector3.new(center.X, c.pos.Y, center.Z)
        local cf = (look - c.pos).Magnitude > 0.1 and CFrame.lookAt(c.pos, look) or CFrame.new(c.pos)
        local before = os.clock()
        -- A refusal with a message is final for this spot; a silent one is tried up to 3 times, then the next spot is used.
        local res
        local moneyBefore = LP._stats.resource.Value
        for attempt = 1, 3 do
            before = os.clock()
            -- The server itself errors on the first placement of every multi-lane match ("attempt to index nil with 'spawn'", 65 of 65 on Shibuya,
            -- Sky Island, Assassin Park; cause unknown): counted as a silent refusal instead of losing the tick.
            local okCall, r = pcall(Game.invoke, "spawn_unit", h.uuid, cf)
            res = okCall and r or nil
            if res == true or (lastMsgAt >= before - 0.05 and lastMsg) then break end
            if attempt < 3 then task.wait(0.35) end
        end
        if res == true then
            counts.placed += 1
            task.spawn(learnPaid, moneyBefore, h.def.cost * modifier("player_cost_scale"))
            if Hub.Misc and Hub.Misc.walkTo then Hub.Misc.walkTo(c.pos) end -- Misc > Walk To Units
            table.insert(recent, { pos = c.pos, r = hitR(h.def), t = os.clock() })
            logLine(("place slot %d %s %s at (%.1f, %.1f) score %.0f try %d checked %d wave %s money %.0f%s%s"):format(slot, h.id, c.cls, c.pos.X, c.pos.Z, c.score, tries, checked, tostring(workspace._wave_num.Value), LP._stats.resource.Value, c.learned and " learned" or "", tag))
            task.delay(1, function()
                -- tag the model (Hill Percentage share) and set the target priority
                for _, u in myUnits() do
                    local q = u:GetPivot().Position
                    if isCopy(u, h) and (q.X - c.pos.X) ^ 2 + (q.Z - c.pos.Z) ^ 2 < 1 then
                        u:SetAttribute("_ap_hill", c.cls == "H")
                        if cfg.priority ~= PRIOS[1] and roleOf(h.def) ~= "farm" and u._stats.priority.Value ~= cfg.priority then
                            pcall(Game.invoke, "change_priority", u, cfg.priority)
                        end
                    end
                end
            end)
            return true
        end
        -- Refused. A "Cannot place unit here!" message = bad spot; no message while copies stand = a cap the data does not show.
        local msgd = lastMsgAt >= before - 0.05 and lastMsg
        local capMsg = msgd and tonumber(msgd:match("[Cc]annot place more than (%d+)"))
        if capMsg then
            -- "(Global)" counts every player's copies (6 Elfy in a matchmaking Hunt): our cap is what we have standing, or the slot is asked for
            -- every 2 s for the rest of the match (2,029 refusals in 3 days of logs).
            if msgd:find("Global", 1, true) then
                capMsg = 0
                for _, u in units do if isCopy(u, h) then capMsg += 1 end end
            end
            learnedCap[h.uuid] = capMsg
            counts.learned_cap += 1
            logLine(("server cap %d for slot %d %s (%s)"):format(capMsg, slot, h.id, msgd))
            return false, "cap"
        end
        if msgd and not msgd:find("place unit here") then
            -- another reason (money, cooldown, mode rule): the spot is fine, wait before trying the slot again
            logLine(("slot %d %s refused: %s"):format(slot, h.id, msgd))
            return false, msgd
        end
        blacklist[c.key] = os.clock() + 120
        if msgd then
            counts.refused_pos += 1
            logLine(("refused slot %d %s at (%.1f, %.1f, %.1f): %s%s"):format(slot, c.cls, c.pos.X, c.pos.Y, c.pos.Z, msgd, tag))
        else
            counts.refused_silent += 1
            silentRun += 1
            local standing = 0
            for _, u in units do if isCopy(u, h) then standing += 1 end end
            -- A silent refusal is usually a bad spot. It only means a hidden cap when the data lists no cap (or the cap is reached) and
            -- three different spots in a row were refused.
            if standing > 0 and silentRun >= 3 and (not h.def.spawn_cap or standing >= h.def.spawn_cap) then
                learnedCap[h.uuid] = standing
                counts.learned_cap += 1
                logLine(("learned cap %d for slot %d %s (silent refusal)"):format(standing, slot, h.id))
                return false, "cap"
            end
            logLine(("refused slot %d %s at (%.1f, %.1f, %.1f): silent%s"):format(slot, c.cls, c.pos.X, c.pos.Y, c.pos.Z, tag))
        end
        task.wait(0.1)
    end
    if tries > 0 then break end
    end
    return false, ("no spot (%d candidates, %d checked, %d tried)"):format(#list, checked, tries)
end

-- Learn: the game's own spawn_unit calls (not ours) are recorded per map and slot.
local learning = false
local function installLearnHook()
    if env.ZenoLearnHook then return end
    env.ZenoLearnHook = true
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if env.ZenoLearnHandler and not checkcaller() and getnamecallmethod() == "InvokeServer" and self.Name == "spawn_unit" then
            pcall(env.ZenoLearnHandler, ...)
        end
        return old(self, ...)
    end))
end
env.ZenoLearnHandler = function(uuid, cf)
    if not (alive() and learning and typeof(cf) == "CFrame" and hb) then return end
    local pos = cf.Position
    task.delay(1.5, function()
        for slot, h in hb do
            if h.uuid == uuid then
                for _, u in myUnits() do
                    local q = u:GetPivot().Position
                    if isCopy(u, h) and (q.X - pos.X) ^ 2 + (q.Z - pos.Z) ^ 2 < 1.5 then
                        local mk = mapKey()
                        cfg.learned[mk] = cfg.learned[mk] or {}
                        local l = cfg.learned[mk][tostring(slot)] or {}
                        cfg.learned[mk][tostring(slot)] = l
                        table.insert(l, { pos.X, pos.Y, pos.Z })
                        Core.save_config()
                        logLine(("learned slot %d %s at (%.0f, %.0f) (#%d)"):format(slot, h.id, pos.X, pos.Z, #l))
                        if AutoPlay.refreshLabels then pcall(AutoPlay.refreshLabels) end
                        return
                    end
                end
            end
        end
    end)
end
function AutoPlay.learn(on)
    learning = on
    if on then
        installLearnHook()
        cfg.learned[mapKey()] = {}
        Core.save_config()
        Hub.UI.Library:Notify("Learning: place your units by hand. Turn it off when done.", 6)
    end
    if AutoPlay.refreshLabels then pcall(AutoPlay.refreshLabels) end
end

------------------------------------------------------------------ economy, upgrades, holds
-- Income estimate: positive money deltas over a 12 s window (spending shows as negative and is ignored).
local incomeLog, lastMoney = {}, nil
local function income(money)
    local now = os.clock()
    if lastMoney and money > lastMoney then table.insert(incomeLog, { now, money - lastMoney }) end
    lastMoney = money
    local sum, first = 0, now
    for i = #incomeLog, 1, -1 do
        if now - incomeLog[i][1] > 12 then table.remove(incomeLog, i) else sum += incomeLog[i][2] first = math.min(first, incomeLog[i][1]) end
    end
    local span = math.max(now - math.max(first, t0), 3)
    local rate = sum / math.min(span, 12)
    local base = LP._stats:FindFirstChild("resource_rate")
    return math.max(rate, base and base.Value or 0, 0.5)
end

-- Target Priority: Boss Target Priority while LevelData.boss is alive, else Target Priority (Game default leaves units alone,
-- but a unit switched for the boss goes back to "first").
local bossMode = false
local function bossAlive()
    local id = level and level.boss
    if not id then return false end
    local folder = workspace:FindFirstChild("_UNITS")
    for _, u in folder and folder:GetChildren() or {} do
        local s = u:FindFirstChild("_stats")
        if s and s:FindFirstChild("id") and s.id.Value == id and CS:HasTag(u, "pve_units") then return true end
    end
    return false
end
local function applyPriorities(units)
    local boss = cfg.boss_priority ~= PRIOS[1] and bossAlive()
    local want = boss and cfg.boss_priority or cfg.priority
    if want == PRIOS[1] then want = bossMode and "first" or nil end
    if boss ~= bossMode then bossMode = boss logLine(boss and ("boss alive: target " .. cfg.boss_priority) or "boss gone: target back") end
    if not want then return end
    local n = 0
    for _, u in units do
        local slot = slotOf(hb, u)
        if slot and roleOf(hb[slot].def) ~= "farm" and u._stats.priority.Value ~= want and n < 6 then
            n += 1
            pcall(Game.invoke, "change_priority", u, want)
        end
    end
end

local function holds()
    local d = Hub.Gameplay and Hub.Gameplay.done
    if d and (d.sell or d.leave) then return "units sold or leaving (Game tab)" end
    return nil
end

-- Next slot to place: wave reached, below its limit and cap, not blocked.
local function eligible(units)
    local count = {}
    for _, u in units do
        local slot = slotOf(hb, u)
        if slot then count[hb[slot].uuid] = (count[hb[slot].uuid] or 0) + 1 end
    end
    local wave = workspace._wave_num.Value
    local farmSold = Hub.Gameplay and Hub.Gameplay.done and Hub.Gameplay.done.farm
    -- While our Fused Hero stands the server refuses Carrot and Vego ("Unique units may not be placed with others of its kind"): both slots are full.
    local fused = false
    for _, u in units do if u._stats.id.Value == "vegito" then fused = true end end
    local list = {}
    for slot, h in hb do
        local lim = cfg.limit[slot]
        local cap = lim > 0 and math.min(lim, placementCap(h)) or placementCap(h)
        local farm = isFarm(h.def)
        if lim ~= -1 and wave >= cfg.wave[slot] and (count[h.uuid] or 0) < cap and (slotBlock[slot] or 0) < os.clock() and not (farm and farmSold)
            and not (fused and (h.id == FUSE_CARROT or h.id == FUSE_VEGO)) then
            table.insert(list, { slot = slot, h = h, farm = farm, cost = h.def.cost * costScale() })
        end
    end
    table.sort(list, function(a, b)
        local fa, fb = cfg.focus_farm and a.farm, cfg.focus_farm and b.farm
        if fa ~= fb then return fa end
        if placeOrd(a.slot) ~= placeOrd(b.slot) then return placeOrd(a.slot) < placeOrd(b.slot) end
        return a.slot < b.slot
    end)
    return list, count
end

-- What to place now: the first wanted unit when affordable. Smart Opening: otherwise farms first, and any unit when the wait is long.
local function choose(list, money, rate)
    local first = list[1]
    if not first then return nil end
    if money >= first.cost then return first end
    if cfg.opening then
        for _, e in list do if e.farm and money >= e.cost then return e, "farm first while saving" end end
        if (first.cost - money) / rate > 25 then
            local best
            for _, e in list do if money >= e.cost and (not best or e.cost > best.cost) then best = e end end
            if best then return best, "long wait" end
        end
    end
    return nil, ("slot %d %s: money %.0f / %.0f"):format(first.slot, first.h.def.name or first.h.id, money, first.cost)
end

local function dpsAt(def, level)
    local dmg, cd = def.damage or 0, def.attack_cooldown or 1
    for l = level, 1, -1 do
        local u = def.upgrade and def.upgrade[l]
        if u and u.damage then dmg = u.damage cd = u.attack_cooldown or cd break end
    end
    return dmg / math.max(cd, 0.1)
end
local function farmAt(def, level)
    if level <= 0 then return def.farm_amount or 0 end
    local u = def.upgrade and def.upgrade[level]
    return u and u.farm_amount or def.farm_amount or 0
end
local totalWaves = nil
do
    local w = level and level.waves
    if type(w) == "number" then totalWaves = w elseif type(w) == "table" then totalWaves = #w end
end

-- Upgrade candidates by Upgrade Limit / Method, best first: { unit, slot, lvl, cost, value }.
local function upgradeList(units)
    local list = {}
    local wave = workspace._wave_num.Value
    for _, u in units do
        local slot = slotOf(hb, u)
        -- A unit that is not on the hotbar but has upgrade levels (Vegito, the fusion of Carrot and Vegeta) is upgraded to its maximum too.
        local extra = not slot and u._stats.max_upgrade.Value > 0 and defs[u._stats.id.Value]
        if extra then slot = 7 end
        local lim = slot and (cfg.ulimit[slot] or 0)
        if slot and lim ~= -2 and wave >= (cfg.uwave[slot] or 0) and (upBlock[u] or 0) < os.clock() then
            local st = u._stats
            local lvl, max = st.upgrade.Value, st.max_upgrade.Value
            local goal = lim > 0 and math.min(lim, max) or max
            if (st.id.Value == FUSE_CARROT or st.id.Value == FUSE_VEGO) and fuseOn() then goal = math.min(goal, FUSE_LEVEL) end
            if lvl < goal then
                local def = extra or hb[slot].def
                local step = def.upgrade and def.upgrade[lvl + 1]
                local cost = step and step.cost and step.cost * costScale() or 0
                local farm = isFarm(def)
                local value
                if farm then
                    local gain = farmAt(def, lvl + 1) - farmAt(def, lvl)
                    local payback = gain > 0 and cost / gain or math.huge -- in waves, if farm_amount is per wave
                    value = gain > 0 and gain / math.max(cost, 1) * 50 or 0 -- weighted so early farm payback beats most damage gains
                    if totalWaves and totalWaves - wave < payback then value = -1 end -- cannot pay back before the end
                else
                    value = (dpsAt(def, lvl + 1) - dpsAt(def, lvl)) / math.max(cost, 1)
                end
                -- only a farm upgrade that cannot pay back before the last wave is skipped; a level that slows a unit still counts (range, new attacks)
                -- An unlisted unit (Vegito) needs a real upgrade price: Erwin's scouts (aot_generic) have levels but no cost data and every try is refused (2810 lines in one Hunt).
                if (not extra or cost > 0) and not (farm and value < 0) then
                    -- Auto Fuse: Carrot, Vego (up to 7) and the Fused Hero come right after the farms, whatever the method.
                    local id = st.id.Value
                    local prio = (id == FUSE_CARROT or id == FUSE_VEGO or id == "vegito") and fuseOn()
                    table.insert(list, { unit = u, slot = slot, id = id, lvl = lvl, cost = cost, late = lim == -1, farm = cfg.focus_farm and farm, isfarm = farm, prio = prio, value = value })
                end
            end
        end
    end
    local method = cfg.method
    table.sort(list, function(a, b)
        if a.late ~= b.late then return b.late end
        local ta = (a.farm or (method == METHODS[1] and a.isfarm)) and 0 or a.prio and 1 or 2
        local tb = (b.farm or (method == METHODS[1] and b.isfarm)) and 0 or b.prio and 1 or 2
        if ta ~= tb then return ta < tb end
        if method == METHODS[1] then -- farms first, then the cheapest
            if a.isfarm ~= b.isfarm then return a.isfarm end
            if a.cost ~= b.cost then return a.cost < b.cost end
            return a.slot < b.slot
        end
        if a.farm ~= b.farm then return a.farm end
        if method == METHODS[2] then
            if a.value ~= b.value then return a.value > b.value end
            return a.slot < b.slot
        elseif method == METHODS[5] then
            if a.lvl ~= b.lvl then return a.lvl < b.lvl end
            return a.slot < b.slot
        end
        local oa, ob = method == METHODS[4] and (cfg.uorder[a.slot] or 7) or a.slot, method == METHODS[4] and (cfg.uorder[b.slot] or 7) or b.slot
        if oa ~= ob then return oa < ob end
        if a.slot ~= b.slot then return a.slot < b.slot end
        if a.lvl ~= b.lvl then return a.lvl > b.lvl end -- finish one unit before the next
        return tostring(a.unit) < tostring(b.unit)
    end)
    return list
end
-- No method stalls on a far-off expensive upgrade (Elyssia's 70,000) while money sits idle: when the first one in the method's order is
-- more than 15 s of income away, the first affordable one in that same order is bought instead.
local function pickUpgrade(list, money, rate)
    local first = list[1]
    if not first or money >= first.cost then return first end
    if first.prio and (first.cost - money) / rate <= 20 then return first end -- save up for the fusion path instead of buying cheaper units first
    -- Carrot and Vego to level 7 come before every other unit (user, 2026-11-03: a Hunt upgraded Rukia and Berserker while they sat at 3 to 6): while one of
    -- them is below the fusion level only farms and the pair itself are bought, however far off the next level is.
    if fuseOn() then
        local pending
        for _, e in list do if e.prio and (e.id == FUSE_CARROT or e.id == FUSE_VEGO) then pending = true break end end
        if pending then
            for _, e in list do if money >= e.cost and (e.isfarm or e.prio) then return e end end
            return first
        end
    end
    if cfg.method == METHODS[4] then -- Custom order: One at a time waits for the first unit, otherwise the first affordable in the list's order
        if not cfg.upgrade_one then for _, e in list do if money >= e.cost then return e end end end
        return first
    end
    if cfg.method == METHODS[1] then -- anything affordable, in the list's order (farms first, then the cheapest)
        for _, e in list do if money >= e.cost then return e end end
        return first
    end
    if (first.cost - money) / rate > 15 then
        for _, e in list do if money >= e.cost then return e end end
    end
    return first
end

-- A stage macro takes priority when Play Macro is on.
local function macroOwns()
    local m = Core.config.macro
    if not (m and m.play and level and Hub.Macro and Hub.Macro.stageOf) then return false end
    local mode, map = Hub.Macro.stageOf(level)
    return mode and m.stage and m.stage[mode] and m.stage[mode][map] ~= nil
end

------------------------------------------------------------------ logging, snapshot, plan preview
local dayLog = Core.paths.logs
function logLine(text) Core.log("autoplay " .. text) end

-- Per-map snapshot for the offline sim (tools/autoplay-sim): lane samples and valid cells near the route.
local function snapshot()
    local dir = Core.paths.data .. "/autoplay_maps"
    if not isfolder(dir) then makefolder(dir) end
    local path = ("%s/%s.json"):format(dir, (mapKey():gsub("%W", "_")))
    if isfile(path) then return end
    local lanesOut, cellsOut = {}, {}
    for _, l in lanes do
        local pts = {}
        for i = 1, #l.samples, 2 do table.insert(pts, { math.floor(l.samples[i].p.X), math.floor(l.samples[i].p.Z) }) end
        table.insert(lanesOut, pts)
        local seen = {}
        for i = 1, #l.samples, 6 do
            local c = l.samples[i].p
            local cx, cz = math.floor(c.X / STEP + 0.5), math.floor(c.Z / STEP + 0.5)
            for ix = cx - 14, cx + 14 do
                for iz = cz - 14, cz + 14 do
                    local k = ix * 100003 + iz
                    if not seen[k] then
                        seen[k] = true
                        local cl = cell(ix, iz, c.Y)
                        if cl then table.insert(cellsOut, { ix * STEP, iz * STEP, cl.cls }) end
                    end
                end
            end
        end
    end
    pcall(writefile, path, HttpService:JSONEncode({ map = mapKey(), step = STEP, lanes = lanesOut, cells = cellsOut }))
end

local planFolder
local function clearPlan() if planFolder then planFolder:Destroy() planFolder = nil end end
local planOn = false
local COLORS = { Color3.fromRGB(255, 90, 90), Color3.fromRGB(255, 170, 60), Color3.fromRGB(240, 230, 70), Color3.fromRGB(90, 220, 110), Color3.fromRGB(80, 170, 255), Color3.fromRGB(190, 110, 255) }
-- Simulated lineup: the next free spot for every unit still to place, nothing is sent to the server.
local function ensureReady()
    if not hb then
        local ok, r = pcall(hotbar)
        if ok and next(r) then hb = r end
    end
    if not hb then return false end
    if #lanes == 0 then lanes = loadLanes() end
    if not ghost then setupGhost() end
    return true
end
local planInfo
local function planSpots(units)
    -- every wanted unit in Place Order, whatever the wave, money or pauses are right now
    local count, list = {}, {}
    for _, u in units do
        local slot = slotOf(hb, u)
        if slot then count[hb[slot].uuid] = (count[hb[slot].uuid] or 0) + 1 end
    end
    for slot, h in hb do
        if cfg.limit[slot] ~= -1 then table.insert(list, { slot = slot, h = h, farm = isFarm(h.def) }) end
    end
    table.sort(list, function(a, b)
        local fa, fb = cfg.focus_farm and a.farm, cfg.focus_farm and b.farm
        if fa ~= fb then return fa end
        if placeOrd(a.slot) ~= placeOrd(b.slot) then return placeOrd(a.slot) < placeOrd(b.slot) end
        return a.slot < b.slot
    end)
    local virtual, spots = {}, {}
    planInfo = nil
    do
        local first = list[1]
        local origin = first and centerFor(first.slot)
        local R0 = 0
        for sl, hh in hb do if not isFarm(hh.def) then R0 = math.max(R0, plannedRange(sl, hh)) end end
        if R0 == 0 then R0 = 20 end
        if origin then planInfo = { origin = origin, ground = math.max(cfg.ground / 100 * R0, 8), hill = math.max(cfg.hill / 100 * R0, 8) } end
    end
    for _, e in list do
        local lim = cfg.limit[e.slot]
        local cap = lim > 0 and math.min(lim, placementCap(e.h)) or placementCap(e.h)
        for _ = (count[e.h.uuid] or 0) + 1, cap do
            local center, around = centerFor(e.slot)
            if not center then break end
            local pl = placedList(units, virtual)
            local found
            for _, boost in BOOSTS do
                local ranked = rank(e.slot, e.h, pl, center, around, boost)
                for i = 1, math.min(#ranked, 300) do
                    if spotFree(ranked[i], e.h, pl) then found = ranked[i] break end
                end
                if found then break end
            end
            if not found then break end
            local hbx = hitR(e.h.def)
            table.insert(virtual, { pos = found.pos, r = hbx, range = plannedRange(e.slot, e.h), attacks = not e.farm, buffer = roleOf(e.h.def) == "buffer", id = e.h.id, hybrid = e.h.def.hybrid_placement, hill = found.cls == "H" })
            table.insert(spots, { slot = e.slot, pos = found.pos, r = hbx, cls = found.cls })
        end
    end
    return spots
end
function AutoPlay.simulate(units) -- the whole lineup as if `units` stood on the map (default: nothing); for checks from the executor
    if not ensureReady() then return end
    local spots = planSpots(units or {})
    return spots, planInfo
end
local function drawPlan(units)
    local spots = planSpots(units or myUnits())
    clearPlan()
    if #spots == 0 and Hub.UI then Hub.UI.Library:Notify("Show Plan: nothing left to place (every unit is already out, or no spot was found)", 5) end
    planFolder = Instance.new("Folder")
    planFolder.Name = "ZenoPlan"
    local function part(size, cf, color, transparency, shape)
        local p = Instance.new("Part")
        p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow = true, false, false, false, false
        if shape then p.Shape = shape end
        p.Size, p.CFrame, p.Color, p.Material, p.Transparency = size, cf, color, Enum.Material.Neon, transparency
        p.Parent = planFolder
        return p
    end
    local function label(p, text, color, size)
        local bb = Instance.new("BillboardGui")
        bb.Size, bb.AlwaysOnTop, bb.StudsOffset = UDim2.fromOffset(size, size), true, Vector3.new(0, 2, 0)
        local t = Instance.new("TextLabel")
        t.Size, t.BackgroundTransparency, t.TextColor3, t.Font, t.TextScaled, t.Text = UDim2.fromScale(1, 1), 1, color, Enum.Font.GothamBold, true, text
        t.Parent = bb
        bb.Parent = p
    end
    -- a ring hugging the ground: short neon segments, each dropped onto the terrain
    local function ring(origin, radius, color)
        local n = 72
        local pts = {}
        for k = 0, n do
            local a = k / n * math.pi * 2
            local x, z = origin.X + math.cos(a) * radius, origin.Z + math.sin(a) * radius
            local hit = workspace:Raycast(Vector3.new(x, origin.Y + 60, z), Vector3.new(0, -200, 0), rp)
            pts[k] = Vector3.new(x, (hit and hit.Position.Y or origin.Y) + 0.4, z)
        end
        for k = 0, n - 1 do
            local a, b = pts[k], pts[k + 1]
            local len = (b - a).Magnitude
            if len > 0.01 then part(Vector3.new(0.35, 0.2, len + 0.1), CFrame.lookAt((a + b) / 2, b), color, 0.15) end
        end
    end
    local info = planInfo
    if info then
        local o = info.origin
        local hit = workspace:Raycast(Vector3.new(o.X, o.Y + 60, o.Z), Vector3.new(0, -200, 0), rp)
        local base = hit and hit.Position or o
        ring(base, info.ground, Color3.fromRGB(90, 230, 120))
        ring(base, info.hill, Color3.fromRGB(80, 170, 255))
        local m = part(Vector3.new(1.4, 1.4, 1.4), CFrame.new(base + Vector3.new(0, 1.5, 0)), Color3.new(1, 1, 1), 0, Enum.PartType.Ball)
        label(m, "path point", Color3.new(1, 1, 1), 70)
    end
    for _, sp in spots do
        local base = sp.pos + Vector3.new(0, 0.5, 0)
        local stud = part(Vector3.new(0.5, 1.3, 1.3), CFrame.new(base) * CFrame.Angles(0, 0, math.pi / 2), COLORS[sp.slot], 0.05, Enum.PartType.Cylinder)
        label(stud, tostring(sp.slot), COLORS[sp.slot], 26)
    end
    planFolder.Parent = workspace
end
AutoPlay.draw = drawPlan -- drawPlan({}) draws the whole lineup as if nothing stood on the map (checks from the executor)
function AutoPlay.showPlan(on)
    planOn = on
    if not on then clearPlan() return end
    task.spawn(function()
        while planOn and alive() do
            local ok, err = pcall(function() if ensureReady() then drawPlan() end end)
            if not ok then Core.log("ERROR autoplay plan", err) end
            task.wait(2)
        end
        clearPlan()
    end)
end
table.insert(Hub.connections, { Disconnect = clearPlan })

-- Explainer: one line per slot.
local function explain(units, list, count)
    local wave = workspace._wave_num.Value
    local elig = {}
    for _, e in list do elig[e.slot] = true end
    local lines = {}
    for slot = 1, 6 do
        local h = hb[slot]
        if h then
            local lim = cfg.limit[slot]
            local cap = lim > 0 and math.min(lim, placementCap(h)) or placementCap(h)
            local n = count[h.uuid] or 0
            local why = ""
            if lim == -1 then why = "skipped"
            elseif n >= cap then why = "full"
            elseif wave < cfg.wave[slot] then why = "from wave " .. cfg.wave[slot]
            elseif (slotBlock[slot] or 0) > os.clock() then why = "no spot, retrying"
            elseif learnedCap[h.uuid] and n >= learnedCap[h.uuid] then why = "server cap" end
            table.insert(lines, ("%d %s %d/%d%s"):format(slot, h.def.name or h.id, n, cap, why ~= "" and (" (" .. why .. ")") or ""))
        end
    end
    if ui.slots then ui.slots:SetText("Slots: " .. table.concat(lines, "; ")) end
end

------------------------------------------------------------------ main loop
local runId = 0
function AutoPlay.stop() runId += 1 status("stopped") end

-- Enemy trail: ground enemies far from every lane sample mean the lane data misses part of their route.
local trail, trailSeen, trailOff = {}, 0, 0
local function sampleEnemies()
    local folder = workspace:FindFirstChild("_UNITS")
    for _, u in folder and folder:GetChildren() or {} do
        local s = u:FindFirstChild("_stats")
        local owner = s and s:FindFirstChild("player")
        if owner and not owner.Value and CS:HasTag(u, "pve_units") and not CS:HasTag(u, "units_with_passive__Flying") then
            local p = u:GetPivot().Position
            local best = math.huge
            for _, l in lanes do
                for i = 1, #l.samples, 2 do
                    local q = l.samples[i].p
                    local d = (q.X - p.X) ^ 2 + (q.Z - p.Z) ^ 2
                    if d < best then best = d end
                end
            end
            trailSeen += 1
            if best > 8 * 8 then
                trailOff += 1
                local k = math.floor(p.X / 4) * 100003 + math.floor(p.Z / 4)
                trail[k] = (trail[k] or 0) + 1
                if trail[k] == 3 then
                    logLine(("enemy trail off the lane at (%.0f, %.0f), %.0f studs from it"):format(p.X, p.Z, math.sqrt(best)))
                end
            end
        end
    end
end

local function doUpgrade(up)
    local money = LP._stats.resource.Value
    local ok = Game.invoke("upgrade_unit_ingame", up.unit) == true
    counts.upgrades += ok and 1 or 0
    if ok then
        if up.cost > 0 then task.spawn(learnPaid, money, up.cost / paidScale) end
    else
        -- Refused: the next one in the order gets its turn for 2 s (a refused first upgrade used to hold every other one back, up to 347 calls in a row),
        -- and with the money in hand the real price must be higher than we think.
        upBlock[up.unit] = os.clock() + 2
        if up.cost > 0 and money >= up.cost and paidScale < 3 then paidScale = math.min(3, paidScale * money / up.cost * 1.05) end
    end
    if ok and Hub.Misc and Hub.Misc.walkTo then pcall(function() Hub.Misc.walkTo(up.unit:GetPivot().Position) end) end -- Misc > Walk To Units
    logLine(("upgrade slot %d %s %d -> %d cost %.0f value %.4f %s"):format(up.slot, up.id, up.lvl, up.lvl + 1, up.cost, up.value or 0, ok and "ok" or "refused"))
    return ok
end

AutoPlay.sampleEnemies = sampleEnemies
function AutoPlay.stats() return counts, { seen = trailSeen, off = trailOff } end
local notified = false
function AutoPlay.start()
    runId += 1
    local myId = runId
    local function live() return alive() and cfg.enable and runId == myId end
    task.spawn(function()
        for _ = 1, 40 do
            local ok, r = pcall(hotbar)
            if ok and next(r) then hb = r break end
            if not live() then return end
            status("waiting for hotbar")
            task.wait(1)
        end
        if not hb then Core.log("ERROR autoplay hotbar unreadable") status("hotbar unreadable") return end
        ensureReady()
        pcall(snapshot)
        logLine(("start %s | %d lanes | cost scale %.2f"):format(stageKey(), #lanes, costScale()))
        local owed = false -- Upgrade and Place: one upgrade is due after a placement
        local lastProgress, lastTrail, lastExplain, lastPrio = os.clock(), 0, 0, 0
        local fullAt = nil
        while live() do
            local ok, err = pcall(function()
                local finished = workspace:FindFirstChild("_DATA") and workspace._DATA:FindFirstChild("GameFinished")
                if finished and finished.Value then status("match finished") lastProgress = os.clock() task.wait(2) return end
                if macroOwns() then status("a stage macro is playing") lastProgress = os.clock() task.wait(1) return end
                local units = myUnits()
                tryFuse(units)
                local money = LP._stats.resource.Value
                local rate = income(money)
                local list, count = eligible(units)
                if os.clock() - lastExplain > 1 then lastExplain = os.clock() pcall(explain, units, list, count) end
                if os.clock() - lastTrail > 0.7 and trailSeen < 600 then lastTrail = os.clock() pcall(sampleEnemies) end
                if os.clock() - lastPrio > 2 then lastPrio = os.clock() pcall(applyPriorities, units) end
                local hold = holds()
                if hold then status(hold) lastProgress = os.clock() task.wait(1) return end
                local want, why = choose(list, money, rate)
                local up = cfg.upgrade and pickUpgrade(upgradeList(units), money, rate)
                if owed then
                    owed = false
                    if up and money >= up.cost then
                        status(("upgrade slot %d"):format(up.slot))
                        doUpgrade(up)
                        lastProgress = os.clock()
                        return
                    end
                end
                if want then
                    local placed, reason = place(want.slot, want.h, units, live)
                    if placed then
                        noSpot[want.slot] = nil
                        owed = cfg.upgrade_place and cfg.upgrade
                        lastProgress = os.clock()
                        status(("placed slot %d %s%s"):format(want.slot, want.h.def.name or want.h.id, why and (" (" .. why .. ")") or ""))
                    else
                        -- No spot (a hill unit on a map with no hill in reach: Carrot on the Artifact stage, 46 tries): 10, 20, 40 ... 120 s, each try is a full search.
                        local wait = 10
                        if tostring(reason):find("^no spot") then
                            noSpot[want.slot] = (noSpot[want.slot] or 0) + 1
                            wait = math.min(10 * 2 ^ (noSpot[want.slot] - 1), 120)
                        end
                        slotBlock[want.slot] = os.clock() + (reason == "cap" and 2 or (tostring(reason):find("Unique") and 120 or wait)) -- "Unique units may not be placed with others of its kind": the unit is still around (fused), retrying every 10 s only fills the log
                        logLine(("slot %d %s blocked: %s"):format(want.slot, want.h.id, tostring(reason)))
                    end
                    return
                end
                if #list > 0 then
                    status(why or "waiting")
                    lastProgress = os.clock() -- waiting for money is not a stall
                    task.wait(0.25)
                    return
                end
                if not fullAt and counts.placed > 0 then
                    fullAt = os.clock() - t0
                    logLine(("lineup complete after %.0f s"):format(fullAt))
                end
                if up then
                    if money < up.cost then
                        status(("upgrade slot %d: money %.0f / %.0f"):format(up.slot, money, up.cost))
                        lastProgress = os.clock()
                    else
                        status(("upgrade slot %d to %d"):format(up.slot, up.lvl + 1))
                        doUpgrade(up)
                        lastProgress = os.clock()
                    end
                else
                    status("nothing to do")
                    lastProgress = os.clock()
                end
            end)
            if not ok then Core.log("ERROR autoplay", err) task.wait(2) end
            -- Watchdog: wanted and affordable but nothing happened for 25 s (notifies once per stall).
            if os.clock() - lastProgress < 5 then notified = false end
            if os.clock() - lastProgress > 25 and not notified then
                notified = true
                logLine(("watchdog: no progress for 25 s | status %s"):format(tostring(lastStatus)))
                if Hub.UI then Hub.UI.Library:Notify("Auto Play: no progress for 25 s: " .. tostring(lastStatus), 8) end
            end
            task.wait(0.3)
        end
    end)
end

-- One stats line per match for tuning (Data/autoplay_runs.log).
table.insert(Hub.connections, game.ReplicatedStorage:WaitForChild("endpoints"):WaitForChild("server_to_client"):WaitForChild("game_finished").OnClientEvent:Connect(function(data)
    if not cfg.enable or counts.placed + counts.upgrades == 0 then return end
    local line = HttpService:JSONEncode({
        t = os.date("%Y-%m-%d %H:%M:%S"), stage = stageKey(), map = mapKey(), victory = data and data.victory, wave = workspace._wave_num.Value,
        seconds = math.floor(os.clock() - t0), counts = counts, trail = { seen = trailSeen, off = trailOff },
        cfg = { distance = cfg.distance, ground = cfg.ground, hill = cfg.hill, method = cfg.method, opening = cfg.opening, upgrade = cfg.upgrade },
    }) .. "\n"
    local path = Core.paths.data .. "/autoplay_runs.log"
    pcall(function() if isfile(path) then appendfile(path, line) else writefile(path, line) end end)
end))

if cfg.enable then AutoPlay.start() end
return AutoPlay
