-- Game tab: Auto Sell Unit / Auto Sell Farm, Auto Leave, Performance (Delete Map, Boost FPS, Black Screen).
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
    delete_map = false, boost_fps = false, black_screen = false, performance_mode = false,
    modifier = { enable = false, rank = {}, cap = {} },
}
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

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
-- Delete Map: decorative children of workspace._map and the _terrain.terrain folder (buildings, props) are
-- unparented and kept for restore. Placement raycasts only count _terrain.ground / .hill, so those, _road,
-- _BASES and _map.obstacles stay.
local removed = {} -- { instance, original parent }
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
local function deleteMap(on)
    if on then
        if not MATCH then return end
        for _, c in mapDecor() do table.insert(removed, { c, c.Parent }) c.Parent = nil end
    else
        for _, r in removed do pcall(function() r[1].Parent = r[2] end) end
        removed = {}
    end
end
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

-- Boost FPS: every property we change is remembered and put back when turned off.
local changed, boostConn = {}, nil
local function setProp(inst, prop, value)
    if inst[prop] == value then return end
    table.insert(changed, { inst, prop, inst[prop] })
    inst[prop] = value
end
local function boostOne(d)
    if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles") then
        setProp(d, "Enabled", false)
    elseif d:IsA("BasePart") then
        setProp(d, "Material", Enum.Material.SmoothPlastic)
        setProp(d, "CastShadow", false)
    elseif d:IsA("Decal") or d:IsA("Texture") then
        setProp(d, "Transparency", 1)
    end
end
local function boostFps(on)
    if on then
        if not MATCH then return end
        setProp(Lighting, "GlobalShadows", false)
        for _, e in Lighting:GetChildren() do
            if e:IsA("PostEffect") then setProp(e, "Enabled", false) end
        end
        for _, d in workspace:GetDescendants() do pcall(boostOne, d) end
        boostConn = workspace.DescendantAdded:Connect(function(d) task.defer(pcall, boostOne, d) end)
        table.insert(Hub.connections, boostConn)
    else
        if boostConn then boostConn:Disconnect() boostConn = nil end
        for i = #changed, 1, -1 do
            local c = changed[i]
            pcall(function() c[1][c[2]] = c[3] end)
        end
        changed = {}
    end
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
    deleteMap(false)
    boostFps(false)
    setRendering(true)
end
table.insert(Hub.connections, { Disconnect = restoreAll }) -- unload puts the game back as it was

-- UI ----------------------------------------------------------------------------------------------------
local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local function set(t, key, after) return function(v) t[key] = v Core.save_config() if after then after(v) end end end
    local T = Tabs.Game

    local sell = T:AddLeftGroupbox("Auto Sell", "badge-dollar-sign")
    sell:AddToggle("SellUnit", { Text = "Auto Sell Unit", Tooltip = "Sell all your units at the wave below. Unsellable units (Bulby) are skipped.", Default = cfg.sell.enable, Callback = set(cfg.sell, "enable") })
    sell:AddSlider("SellUnitWave", { Text = "Sell at Wave", Tooltip = "0 = the stage's last wave; stages with no last wave are skipped.", Default = cfg.sell.wave, Min = 0, Max = 100, Rounding = 0, Callback = set(cfg.sell, "wave") })
    sell:AddDropdown("SellUnitTypes", { Text = "Select Stage Type", Tooltip = "None selected = every stage type.", Values = Game.STAGE_TYPES, Multi = true, Default = Core.keys(cfg.sell.types), Callback = set(cfg.sell, "types") })
    sell:AddDivider()
    sell:AddToggle("SellFarm", { Text = "Auto Sell Farm", Tooltip = "Sell your farm (money) units at the wave below. Unsellable units are skipped.", Default = cfg.sell_farm.enable, Callback = set(cfg.sell_farm, "enable") })
    sell:AddSlider("SellFarmWave", { Text = "Sell at Wave", Tooltip = "0 = the stage's last wave.", Default = cfg.sell_farm.wave, Min = 0, Max = 100, Rounding = 0, Callback = set(cfg.sell_farm, "wave") })
    sell:AddDropdown("SellFarmTypes", { Text = "Select Stage Type", Tooltip = "None selected = every stage type.", Values = Game.STAGE_TYPES, Multi = true, Default = Core.keys(cfg.sell_farm.types), Callback = set(cfg.sell_farm, "types") })

    local leave = T:AddLeftGroupbox("Auto Leave", "log-out")
    leave:AddToggle("AutoLeave", { Text = "Auto Leave", Tooltip = "Return to the lobby at the wave below, after that wave's sales.", Default = cfg.leave.enable, Callback = set(cfg.leave, "enable") })
    leave:AddSlider("AutoLeaveWave", { Text = "Leave at Wave", Default = cfg.leave.wave, Min = 0, Max = 100, Rounding = 0, Callback = set(cfg.leave, "wave") })

    local mod = T:AddRightGroupbox("Auto Modifier", "layers")
    mod:AddToggle("ModAuto", { Text = "Auto Select Modifier", Tooltip = "Pick the offered modifier with the best priority (lowest number) that is under its cap.", Default = cfg.modifier.enable, Callback = set(cfg.modifier, "enable") })
    local rankSliders = {}
    mod:AddButton("Reset Modifier Priority", function()
        for i, c in CARDS do rankSliders[c]:SetValue(i) end
    end)
    local prio = T:AddRightGroupbox("Modifier Priority (1 = first)", "list-ordered")
    for _, c in CARDS do
        rankSliders[c] = prio:AddSlider("ModRank_" .. c:gsub("%W", "_"), { Text = c, Default = cfg.modifier.rank[c], Min = 1, Max = #CARDS, Rounding = 0, Callback = function(v) cfg.modifier.rank[c] = v Core.save_config() end })
    end
    local caps = T:AddRightGroupbox("Modifier Cap-Amount", "hash")
    caps:AddLabel("Most picks per run for each card. 0 = no limit.", true)
    for _, c in CARDS do
        caps:AddSlider("ModCap_" .. c:gsub("%W", "_"), { Text = c, Default = cfg.modifier.cap[c], Min = 0, Max = 10, Rounding = 0, Callback = function(v) cfg.modifier.cap[c] = v Core.save_config() end })
    end

    local perf = T:AddRightGroupbox("Performance (match only)", "gauge")
    perf:AddToggle("PerfMode", { Text = "Performance Mode", Tooltip = "Omega optimizer: destroys map decor, textures, effects and lights, plain materials, lowest quality, hides enemy models and shows your own units as colored blocks (still clickable). Only ground, hills and paths stay. Cannot be undone mid-match: off applies next match.", Default = cfg.performance_mode, Callback = set(cfg, "performance_mode", omega) })
    perf:AddToggle("PerfDeleteMap", { Text = "Delete Map", Tooltip = "Hides decorative map parts and buildings; placeable ground, hills and paths stay. Off restores them.", Default = cfg.delete_map, Callback = set(cfg, "delete_map", deleteMap) })
    perf:AddToggle("PerfBoostFps", { Text = "Boost FPS", Tooltip = "Plain materials, no shadows, effects or textures. Off restores them.", Default = cfg.boost_fps, Callback = set(cfg, "boost_fps", boostFps) })
    perf:AddToggle("PerfBlackScreen", { Text = "Black Screen", Tooltip = "Turns 3D rendering off. Right-click toggles it while on.", Default = cfg.black_screen, Callback = set(cfg, "black_screen", blackScreen) })
end
-- Apply saved choices after a teleport (toggle callbacks do not fire for their Default).
if cfg.delete_map then whenMapReady(function() if cfg.delete_map then deleteMap(true) end end) end
if cfg.performance_mode then omega(true) end
if cfg.boost_fps or cfg.black_screen then
    task.spawn(function()
        if not waitLoaded() then return end
        if cfg.boost_fps then boostFps(true) end
        if cfg.black_screen then blackScreen(true) end
    end)
end

if Hub.mode ~= "match" then return Gameplay end

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
    local line = game:GetService("HttpService"):JSONEncode({ wave = waveVal.Value, n = args.n, titles = titles }) .. "\n"
    pcall(function() if isfile(logPath) then appendfile(logPath, line) else writefile(logPath, line) end end) -- appendfile fails on a missing file
    if not (cfg.modifier.enable and options) then return end
    local best, bestRank
    for slot, v in options do
        local c = cardOf(v.title)
        local cap = cfg.modifier.cap[c] or 0
        local rank = (cap > 0 and (picked[c] or 0) >= cap) and math.huge or (cfg.modifier.rank[c] or 1000)
        if not bestRank or rank < bestRank then best, bestRank = slot, rank end
    end
    if best == nil then return end
    local c = cardOf(options[best].title)
    task.wait(0.5) -- let the game finish opening its own choice UI
    local ok, err = pcall(Game.invoke, "select_roguelike_option", best)
    if ok then picked[c] = (picked[c] or 0) + 1 end
    Core.log("auto modifier", c, "slot", tostring(best), ok and "" or tostring(err))
end))

table.insert(Hub.connections, waveVal.Changed:Connect(check))
table.insert(Hub.connections, lastVal.Changed:Connect(check))
check()

return Gameplay
