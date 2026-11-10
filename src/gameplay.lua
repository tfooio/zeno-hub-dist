-- Game tab: Auto Sell Unit / Auto Sell Farm, Auto Leave, Performance (Performance Mode, Black Screen), Place Anywhere.
-- Options live in Core.config.game (hub.json) so they apply after every teleport.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local LP = game:GetService("Players").LocalPlayer
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local env = getgenv()

local cfg = Core.config.game or {}
Core.config.game = cfg
local defaults = {
    sell = { enable = false, wave = 0, types = {} },
    sell_farm = { enable = false, wave = 0, types = {} },
    leave = { enable = false, wave = 0 },
    black_screen = false, performance_mode = false, place_anywhere = true,
    modifier = { enable = false, rank = {}, cap = {} },
}
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end
-- Delete Map and Boost FPS were removed 2026-11-10 (Performance Mode does both): whoever had one on keeps the effect through Performance Mode.
if cfg.delete_map or cfg.boost_fps then cfg.performance_mode = true Core.save_config() end
cfg.delete_map, cfg.boost_fps = nil, nil

local Gameplay = {}

-- Modifier cards in Nousigi's default priority (1 = picked first); rank/cap per card in cfg.modifier.
local CARDS = { "Yen I", "Yen II", "Yen III", "Active Cooldown I", "Active Cooldown II", "Active Cooldown III",
    "Cooldown I", "Cooldown II", "Cooldown III", "Boss Damage I", "Boss Damage II", "Boss Damage III",
    "Random Blessings I", "Random Blessings II", "Random Blessings III", "Enemy Shield I", "Enemy Shield II",
    "Enemy Shield III", "Explosive Deaths I", "Explosive Deaths II", "Explosive Deaths III", "Random Curses I",
    "Random Curses II", "Random Curses III", "Enemy Health III", "Enemy Health II", "Enemy Health I",
    "Enemy Speed III", "Enemy Speed II", "Enemy Speed I", "Enemy Regen III", "Enemy Regen II", "Enemy Regen I",
    "Attack I", "Attack II", "Attack III", "Range I", "Range II", "Range III", "Double Attack", "New Path" }
for i, c in CARDS do
    if cfg.modifier.rank[c] == nil then cfg.modifier.rank[c] = i end
    if cfg.modifier.cap[c] == nil then cfg.modifier.cap[c] = 0 end
end
local function alive() return env.ZenoHub == Hub end

-- Performance -------------------------------------------------------------------------------------------
-- The decorative parts: children of workspace._map and the _terrain.terrain folder (buildings, props). Placement raycasts only count
-- _terrain.ground / .hill, so those, _road, _BASES and _map.obstacles are never touched.
local function mapDecor()
    local list, map, terr = {}, workspace:FindFirstChild("_map"), workspace:FindFirstChild("_terrain")
    for _, c in map and map:GetChildren() or {} do
        if c.Name ~= "obstacles" then table.insert(list, c) end
    end
    local deco = terr and terr:FindFirstChild("terrain")
    if deco then table.insert(list, deco) end
    return list
end
local MATCH = Hub.mode == "match" -- every Performance option is match-only: the lobby world holds the pads and NPCs
-- Nothing here may touch the game while it loads (Performance Mode destroying things mid-load is the suspected
-- cause of a stuck Loading screen, 2026-10-26): wait until PlayerGui.Loading is closed and the character exists
-- (or 20 s without one), plus a short grace for the game's own post-load setup.
local function waitLoaded()
    local pg, t0 = LP:WaitForChild("PlayerGui"), os.clock()
    while alive() do
        local g = pg:FindFirstChild("Loading")
        if not (g and g.Enabled) and (LP.Character or os.clock() - t0 > 20) then
            task.wait(3)
            return alive()
        end
        task.wait(0.5)
    end
    return false
end
-- The map is built after injection; ready = placement ground exists. The lobby never gets one (gives up quietly).
local function whenMapReady(fn)
    task.spawn(function()
        if not waitLoaded() then return end
        local terr = workspace:WaitForChild("_terrain", 30)
        if terr and terr:WaitForChild("ground", 30) and workspace:WaitForChild("_map", 30) then fn() end
    end)
end

-- Performance Mode (omega optimizer): destroys the map decor, every texture, decal, effect and light, plain
-- materials, lowest quality, and hides every unit / enemy model (they stay in the tree, so Auto Play and the
-- rest still work). Keeps _terrain.ground / .hill (placeable), _road, _BASES. One-way: off applies next match.
local KILL = { "Decal", "SurfaceAppearance", "ParticleEmitter", "Trail", "Beam", "Smoke", "Fire", "Sparkles", "Light" } -- not Highlight: the game's hover / select outline
local omegaOn, omegaUnits = false, nil
-- Your own units get one welded colored block so you can see and click them. The game's click is a raycast on
-- _UNITS that climbs to the model with a HumanoidRootPart and _stats, so a block inside the model counts.
local BLOCK = "ZenoBlock"
local function blockFor(m)
    local hrp, st = m:WaitForChild("HumanoidRootPart", 5), m:WaitForChild("_stats", 5)
    local owner = st and st:WaitForChild("player", 2)
    if not (hrp and owner and owner.Value == LP) or m:FindFirstChild(BLOCK) then return end
    local lo, hi
    for _, p in m:GetDescendants() do
        if p:IsA("BasePart") and p.Name:sub(1, 1) ~= "_" then -- _hitbox / _shadow are not the body
            local h = p.Size / 2
            lo = lo and lo:Min(p.Position - h) or p.Position - h
            hi = hi and hi:Max(p.Position + h) or p.Position + h
        end
    end
    if not lo then return end
    local b = Instance.new("Part")
    b.Name, b.Material, b.Color, b.CastShadow = BLOCK, Enum.Material.SmoothPlastic, Color3.fromRGB(60, 140, 255), false
    b.CanCollide, b.CanTouch, b.Massless = false, false, true
    b.Size = ((hi - lo) * 0.5):Max(Vector3.one):Min(Vector3.one * 4) -- half the body box, 1 to 4 studs
    b.Position = (lo + hi) / 2
    local weld = Instance.new("WeldConstraint")
    weld.Part0, weld.Part1 = hrp, b
    b.Parent, weld.Parent = m, b
end
local function omegaOne(d)
    for _, c in KILL do
        if d:IsA(c) then d:Destroy() return end
    end
    if d:IsA("BasePart") then
        d.Material, d.CastShadow, d.Reflectance = Enum.Material.SmoothPlastic, false, 0
        if d:IsA("MeshPart") then d.TextureID, d.RenderFidelity = "", Enum.RenderFidelity.Performance end
        if omegaUnits and d.Name ~= BLOCK and d:IsDescendantOf(omegaUnits) then d.Transparency = 1 end
    elseif d:IsA("SpecialMesh") then
        d.TextureId = ""
    end
end
local function omega(on)
    if not on or omegaOn or not MATCH then return end
    omegaOn = true
    task.spawn(function()
        if not waitLoaded() then return end
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
        Lighting.GlobalShadows, Lighting.FogEnd = false, 9e9
        for _, e in Lighting:GetChildren() do
            if e:IsA("PostEffect") or e:IsA("Atmosphere") or e:IsA("Sky") or e:IsA("Clouds") then e:Destroy() end
        end
        local water = workspace.Terrain
        pcall(function() water.WaterWaveSize, water.WaterWaveSpeed, water.WaterReflectance = 0, 0, 0 end)
    end)
    whenMapReady(function()
        for _, c in mapDecor() do c:Destroy() end
        omegaUnits = workspace:WaitForChild("_UNITS")
        local function track(m) if m:IsA("Model") then task.spawn(pcall, blockFor, m) end end
        for _, m in omegaUnits:GetChildren() do track(m) end
        table.insert(Hub.connections, omegaUnits.ChildAdded:Connect(track))
        local cam = workspace:WaitForChild("Camera")
        table.insert(Hub.connections, workspace.DescendantAdded:Connect(function(d)
            task.defer(pcall, function() if not d:IsDescendantOf(cam) then omegaOne(d) end end)
        end))
        for i, d in workspace:GetDescendants() do
            if not d:IsDescendantOf(cam) then pcall(omegaOne, d) end
            if i % 3000 == 0 then task.wait() end
        end
    end)
end

-- Black Screen: 3D rendering off; right-click flips it while the option is on.
local rendering = true -- RunService has no getter for this
-- With 3D off the screen keeps stale frames on white; a black backdrop under the game's HUD hides them.
local backdrop = Instance.new("ScreenGui")
backdrop.Name, backdrop.IgnoreGuiInset, backdrop.DisplayOrder, backdrop.Enabled = "ZenoBlack", true, -100, false
local frame = Instance.new("Frame")
frame.Size, frame.BackgroundColor3, frame.BorderSizePixel = UDim2.fromScale(1, 1), Color3.new(0, 0, 0), 0
frame.Parent = backdrop
backdrop.Parent = LP:WaitForChild("PlayerGui")
table.insert(Hub.connections, { Disconnect = function() backdrop:Destroy() end })
local function setRendering(on)
    rendering = on
    RunService:Set3dRenderingEnabled(on)
    backdrop.Enabled = not on
end
local function blackScreen(on) if MATCH or not on then setRendering(not on) end end
table.insert(Hub.connections, UIS.InputBegan:Connect(function(input, processed)
    if MATCH and cfg.black_screen and not processed and input.UserInputType == Enum.UserInputType.MouseButton2 then
        setRendering(not rendering)
    end
end))
local function restoreAll()
    setRendering(true)
end
table.insert(Hub.connections, { Disconnect = restoreAll }) -- unload puts the game back as it was

-- UI ----------------------------------------------------------------------------------------------------
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local function set(t, key, after) return function(v) t[key] = v Core.save_config() if after then after(v) end end end
    local T = Tabs.Game

    local sell = T:AddLeftGroupbox("Auto Sell", "badge-dollar-sign")
    sell:AddToggle("SellUnit", { Text = "Auto Sell Unit", Tooltip = "Sells every unit you have placed in this match at the wave below (your collection is not touched). Unsellable units (Bulby) are skipped.", Default = cfg.sell.enable, Callback = set(cfg.sell, "enable") })
    sell:AddSlider("SellUnitWave", { Text = "Sell at Wave", Tooltip = "0 = the stage's last wave; stages with no last wave are skipped.", Default = cfg.sell.wave, Min = 0, Max = 100, Rounding = 0, Callback = set(cfg.sell, "wave") })
    sell:AddDropdown("SellUnitTypes", { Text = "Select Stage Type", Tooltip = "None selected = every stage type.", Values = Game.STAGE_TYPES, Multi = true, Default = Core.keys(cfg.sell.types), Callback = set(cfg.sell, "types") })
    sell:AddDivider()
    sell:AddToggle("SellFarm", { Text = "Auto Sell Farm", Tooltip = "Sells your placed farm (money) units at the wave below. Your collection is not touched. Unsellable units are skipped.", Default = cfg.sell_farm.enable, Callback = set(cfg.sell_farm, "enable") })
    sell:AddSlider("SellFarmWave", { Text = "Sell at Wave", Tooltip = "0 = the stage's last wave.", Default = cfg.sell_farm.wave, Min = 0, Max = 100, Rounding = 0, Callback = set(cfg.sell_farm, "wave") })
    sell:AddDropdown("SellFarmTypes", { Text = "Select Stage Type", Tooltip = "None selected = every stage type.", Values = Game.STAGE_TYPES, Multi = true, Default = Core.keys(cfg.sell_farm.types), Callback = set(cfg.sell_farm, "types") })

    local leave = T:AddLeftGroupbox("Auto Leave", "log-out")
    leave:AddToggle("AutoLeave", { Text = "Auto Leave", Tooltip = "Return to the lobby at the wave below, after that wave's sales.", Default = cfg.leave.enable, Callback = set(cfg.leave, "enable") })
    leave:AddSlider("AutoLeaveWave", { Text = "Leave at Wave", Tooltip = "0 = never leave.", Default = cfg.leave.wave, Min = 0, Max = 100, Rounding = 0, Callback = set(cfg.leave, "wave") })

    local mod = T:AddRightGroupbox("Auto Modifier", "layers")
    mod:AddToggle("ModAuto", { Text = "Auto Select Modifier", Tooltip = "Pick the offered modifier with the best priority (lowest number) that is under its cap.", Default = cfg.modifier.enable, Callback = set(cfg.modifier, "enable") })
    local prio = T:AddRightGroupbox("Modifier Priority", "list-ordered")
    prio:AddLabel("Top card is picked first. - N + = most picks per run (0 = no limit). Type a number or use the arrows (Shift = 5, Ctrl = top or bottom).", true)
    local CARD_ICONS = { { "Yen", "coins" }, { "Active Cooldown", "timer-reset" }, { "Cooldown", "timer" }, { "Boss", "skull" }, { "Blessings", "sparkles" }, { "Shield", "shield" },
        { "Explosive", "bomb" }, { "Curses", "ghost" }, { "Health", "heart" }, { "Speed", "gauge" }, { "Regen", "heart-pulse" }, { "Double", "zap" }, { "Attack", "swords" },
        { "Range", "crosshair" }, { "New Path", "route" } }
    local function cardIcon(c) for _, p in CARD_ICONS do if c:find(p[1], 1, true) then return p[2] end end end
    local items = {}
    for _, c in CARDS do items[#items + 1] = { key = c, text = c, icon = cardIcon(c) } end
    local list
    list = Hub.UIKit.rankList(Hub.UI.Library, prio, "ModPriorityList", {
        items = items,
        get = function()
            local keys = table.clone(CARDS)
            table.sort(keys, function(a, b)
                local ra, rb = cfg.modifier.rank[a] or 1000, cfg.modifier.rank[b] or 1000
                if ra ~= rb then return ra < rb end
                return table.find(CARDS, a) < table.find(CARDS, b)
            end)
            return keys
        end,
        set = function(keys) for i, c in keys do cfg.modifier.rank[c] = i end Core.save_config() end,
        counter = { min = 0, max = 10, get = function(c) return cfg.modifier.cap[c] or 0 end, set = function(c, v) cfg.modifier.cap[c] = v Core.save_config() end },
    })
    mod:AddButton("Reset Modifier Priority", function()
        for i, c in CARDS do cfg.modifier.rank[c] = i end
        Core.save_config()
        list.refresh()
    end)

    local perf = T:AddRightGroupbox("Performance (match only)", "gauge")
    perf:AddToggle("PerfMode", { Text = "Performance Mode", Tooltip = "Cuts lag: destroys map decor, textures, effects and lights, plain materials, lowest quality, hides enemy models and shows your own units as colored blocks (still clickable). Only ground, hills and paths stay. Cannot be undone mid-match: off applies next match.", Default = cfg.performance_mode, Callback = set(cfg, "performance_mode", omega) })
    perf:AddToggle("PerfBlackScreen", { Text = "Black Screen (right-click shows the game)", Tooltip = "Turns 3D rendering off to save power. While it is on, right-click to bring the picture back or hide it again.", Default = cfg.black_screen, Callback = set(cfg, "black_screen", blackScreen) })

    local place = T:AddLeftGroupbox("Placement (match only)", "map-pin")
    place:AddToggle("PlaceAnywhere", { Text = "Place Anywhere", Tooltip = "Click-place units on the road and on top of other units. A click inside a copy of the same unit is moved 0.85 studs aside (the server refuses closer). Unit cap and money still apply.", Default = cfg.place_anywhere, Callback = set(cfg, "place_anywhere") })
end
-- Apply saved choices after a teleport (toggle callbacks do not fire for their Default).
if cfg.performance_mode then omega(true) end
if cfg.black_screen then
    task.spawn(function()
        if not waitLoaded() then return end
        blackScreen(true)
    end)
end

if Hub.mode ~= "match" then return Gameplay end

-- Place Anywhere ----------------------------------------------------------------------------------------
-- Road and unit overlap are only checked by the client preview (`can_place`); the server refuses just two
-- copies of one unit closer than ~0.75 studs. A click with a ground position is forced through (docs/features/place-anywhere.md).
local PLACE_GAP = 0.85 -- accepted at 0.8, refused at 0.7: margin on top
-- A click inside a standing copy of the same unit (same owned uuid) is pushed out to PLACE_GAP in X/Z.
local function nudge(pos, uuid)
    for _ = 1, 4 do -- pushing out of one copy can land inside the next
        local moved = false
        for _, m in workspace._UNITS:GetChildren() do
            local u = m:FindFirstChild("_stats") and m._stats:FindFirstChild("uuid")
            if u and u.Value == uuid then
                local c = m:GetPivot().Position
                local off = Vector3.new(pos.X - c.X, 0, pos.Z - c.Z)
                if off.Magnitude < PLACE_GAP then
                    pos = Vector3.new(c.X, pos.Y, c.Z) + (off.Magnitude > 1e-3 and off.Unit or Vector3.xAxis) * PLACE_GAP
                    moved = true
                end
            end
        end
        if not moved then break end
    end
    return pos
end
local okPlace, placement = pcall(Game.loader().load_client_service, script, "PlacementServiceClient")
if okPlace and placement then
    local origOnPlace = placement.on_place
    placement.on_place = function(...)
        if cfg.place_anywhere and placement.equipped_unit_uuid and placement.p then
            placement.can_place = true
            if typeof(placement.p) == "Vector3" then placement.p = nudge(placement.p, placement.equipped_unit_uuid) end
        end
        return origOnPlace(...)
    end
    table.insert(Hub.connections, { Disconnect = function() placement.on_place = origOnPlace end })
end

-- Sell / Leave ------------------------------------------------------------------------------------------
local defs = Game.data("Units")
local stageType = Game.stage(Game.loader().LevelData)
local waveVal, lastVal = workspace:WaitForChild("_wave_num"), workspace:WaitForChild("_is_last_wave")

local function applies(opt)
    return opt.enable and (not next(opt.types) or (stageType and opt.types[stageType]))
end
-- Wave 0 means the last wave, which needs _is_last_wave (infinite stages never set it).
local function reached(wave) return (wave == 0 and lastVal.Value) or (wave > 0 and waveVal.Value >= wave) end

local function sellAll(farmOnly)
    local n = 0
    for _, u in workspace._UNITS:GetChildren() do
        local st = u:FindFirstChild("_stats")
        local d = st and st:FindFirstChild("id") and defs[st.id.Value]
        local owner = st and st:FindFirstChild("player")
        if d and owner and owner.Value == LP and not d.unsellable and (not farmOnly or (d.farm_amount or 0) > 0) then
            local ok, res = pcall(Game.invoke, "sell_unit_ingame", u)
            if ok and res == true then n += 1 end
        end
    end
    Core.log(farmOnly and "auto sell farm" or "auto sell", n, "units at wave", waveVal.Value)
end

local done = {}
Gameplay.done = done -- read by Auto Play: nothing is placed or upgraded once its units were sold
local function check()
    if not alive() then return end
    if applies(cfg.sell_farm) and not done.farm and reached(cfg.sell_farm.wave) then done.farm = true sellAll(true) end
    if applies(cfg.sell) and not done.sell and reached(cfg.sell.wave) then done.sell = true sellAll(false) end
    if cfg.leave.enable and cfg.leave.wave > 0 and not done.leave and waveVal.Value >= cfg.leave.wave then
        done.leave = true
        Core.log("auto leave at wave", waveVal.Value)
        Core.save_config() -- before the teleport (OnTeleport does not fire)
        pcall(Game.invoke, "teleport_back_to_lobby")
    end
end
-- Auto Modifier: show_roguelike_options carries the options ({[slot] = {title, effects}}); the game's own
-- Confirm button sends select_roguelike_option(slot). Every offer is logged for checking the format.
local picked = {} -- card -> picks this run
-- A seamless replay keeps the hub loaded, so "this run" has to end with the match (the caps turned into permanent blocks after a few replays).
table.insert(Hub.connections, { Disconnect = Core.on("game_finished", function() table.clear(picked) end) })
-- Titles already in Data/roguelike_cards.jsonl: the list used to start empty at every match, so 292 cards became 4,740 lines.
local cardTextSeen = {}
pcall(function()
    for title in readfile(Core.paths.data .. "/roguelike_cards.jsonl"):gmatch('"title":"(.-)"') do cardTextSeen[title] = true end
end)
local function cardOf(title) return (tostring(title or ""):gsub("^%+%s*", ""):match("^%s*(.-)%s*$")) end
table.insert(Hub.connections, game:GetService("ReplicatedStorage").endpoints.server_to_client:WaitForChild("show_roguelike_options").OnClientEvent:Connect(function(...)
    local args, options = table.pack(...), nil
    for i = 1, args.n do
        local a = args[i]
        if type(a) == "table" then
            for _, v in a do if type(v) == "table" and v.title then options = a break end end
        end
        if options then break end
    end
    local titles = {}
    for slot, v in options or {} do titles[tostring(slot)] = cardOf(v.title) end
    local logPath = Core.paths.data .. "/roguelike_offers.log"
    local effects = {}
    for slot, v in options or {} do effects[tostring(slot)] = v.effects end -- Summer Medium preset reads the health amount from here (format unverified)
    local line = game:GetService("HttpService"):JSONEncode({ wave = waveVal.Value, n = args.n, titles = titles, effects = effects }) .. "\n"
    pcall(function() if isfile(logPath) then appendfile(logPath, line) else writefile(logPath, line) end end) -- appendfile fails on a missing file
    -- Card texts (title, description, as the game's own card UI shows them) for ranking the weather cards from data: once per title, Data/roguelike_cards.jsonl.
    task.spawn(function()
        task.wait(0.8)
        local ok, ui = pcall(function() return Game.loader().load_client_service(script, "GUIService").roguelike_select_ui end)
        if not (ok and ui and type(ui.option_frames) == "table") then return end
        for slot, f in ui.option_frames do
            local title = titles[tostring(slot)]
            if title and not cardTextSeen[title] and typeof(f) == "Instance" then
                cardTextSeen[title] = true
                local texts = {}
                for _, d in f:GetDescendants() do if d:IsA("TextLabel") and d.Text ~= "" then texts[#texts + 1] = d.Text end end
                local path, row = Core.paths.data .. "/roguelike_cards.jsonl", game:GetService("HttpService"):JSONEncode({ title = title, texts = texts }) .. "\n"
                pcall(function() if isfile(path) then appendfile(path, row) else writefile(path, row) end end)
            end
        end
    end)
    -- An autopilot Summer Hunt votes whatever the Auto Select Modifier toggle says (a friend with the toggle off got no votes at all, 2026-11-03).
    local pilot = Hub.Summer and Hub.Summer.piloting()
    if not ((cfg.modifier.enable or pilot) and options) then return end
    local best, bestRank
    for slot, v in options do
        local c = cardOf(v.title)
        local cap = pilot and 0 or (cfg.modifier.cap[c] or 0) -- the Hunt autopilot has its own caps; a Game-tab cap would hide a card (a Star card too) from it
        local rank = (cap > 0 and (picked[c] or 0) >= cap) and math.huge or (cfg.modifier.rank[c] or 1000)
        local pilotRank = rank ~= math.huge and Hub.Summer and Hub.Summer.cardRank(c, v) -- Summer autopilot: its own card order
        if pilotRank then rank = pilotRank end
        if rank ~= math.huge and rank > -1e8 and Hub.Summer and Hub.Summer.avoidCard(c) then rank = 1e9 end -- Summer autopilot: no regen cards without a bleed unit (not for a Star card)
        if not bestRank or rank < bestRank then best, bestRank = slot, rank end
    end
    if best == nil then return end
    local c = cardOf(options[best].title)
    task.wait(0.5) -- let the game finish opening its own choice UI
    local ok, err = pcall(Game.invoke, "select_roguelike_option", best)
    if ok then
        picked[c] = (picked[c] or 0) + 1
        if Hub.Summer then Hub.Summer.cardPicked(c, waveVal.Value, titles, options[best]) end -- Summer run logger / card tuner
    end
    Core.log("auto modifier", c, "slot", tostring(best), ok and "" or tostring(err))
end))

table.insert(Hub.connections, waveVal.Changed:Connect(check))
table.insert(Hub.connections, lastVal.Changed:Connect(check))
check()

return Gameplay
