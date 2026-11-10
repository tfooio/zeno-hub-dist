-- Map Picker (Auto Play tab): click the spots of the six hotbar slots on a map drawn from our own snapshots (Data/autoplay_maps).
-- Saves into the per-map spot store Auto Play reads (key names from the removed Learn Placements), cfg.learned[map][unit id] = { {x, y, z}, ... } (the n-th copy of a unit takes the n-th spot;
-- the spots belong to the unit, not to the hotbar slot, so they follow it into any slot or team),
-- so Auto Play needs no new option. Y is saved as 0: Auto Play looks the ground height up when it places. docs/features/map-picker.md
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local Tabs = Hub.UI and Hub.UI.Tabs
local cfg = Core.config.autoplay
if not (Tabs and cfg) then return {} end
local lib = Hub.UI.Library
local S = lib.Scheme
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")

local MAX_SPOTS = 10 -- the Place Cap slider's maximum
local SNAP = 6 -- studs: a click takes the nearest valid cell within this
local N = 80 -- plot resolution: cells are merged into an N x N grid so a big map stays a few thousand frames
local DIR = Core.paths.data .. "/autoplay_maps"
local COLORS = { Color3.fromRGB(255, 90, 90), Color3.fromRGB(255, 170, 60), Color3.fromRGB(240, 230, 70), Color3.fromRGB(90, 220, 110), Color3.fromRGB(80, 170, 255), Color3.fromRGB(190, 110, 255) }
local GROUND, HILL, ROUTE, BLOCKED = Color3.fromRGB(70, 112, 96), Color3.fromRGB(150, 118, 72), Color3.fromRGB(235, 235, 245), Color3.fromRGB(104, 82, 132)

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in props do o[k] = v end
    o.Parent = parent
    return o
end

local Picker = {}
cfg.learned = cfg.learned or {}

------------------------------------------------------------------ maps on disk
local okM, Maps = pcall(Game.data, "Maps")
local function label(id)
    local m = okM and Maps[id]
    return m and m.name and ("%s (%s)"):format(m.name, id) or id
end
local labels, byLabel, idLabel = {}, {}, {}
local function scan()
    table.clear(labels) table.clear(byLabel) table.clear(idLabel)
    if isfolder(DIR) then
        for _, f in listfiles(DIR) do
            local id = f:match("([^/\\]+)%.json$")
            if id then
                local l = label(id)
                byLabel[l], idLabel[id] = id, l
                table.insert(labels, l)
            end
        end
    end
    table.sort(labels)
end
scan()

-- Snapshot -> map: the plot is the square around every lane point and valid cell (z grows downwards, no rotation).
local function loadMap(id)
    local ok, d = pcall(function() return HttpService:JSONDecode(readfile(("%s/%s.json"):format(DIR, id))) end)
    if not (ok and type(d) == "table" and type(d.cells) == "table" and type(d.lanes) == "table") then return nil end
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    local function grow(x, z) x0, x1, z0, z1 = math.min(x0, x), math.max(x1, x), math.min(z0, z), math.max(z1, z) end
    for _, l in d.lanes do for _, p in l do grow(p[1], p[2]) end end
    for _, c in d.cells do grow(c[1], c[2]) end
    for _, c in d.blocked or {} do grow(c[1], c[2]) end
    if x0 == math.huge then return nil end
    local side = math.max(x1 - x0, z1 - z0, 20)
    side += math.max(side * 0.04, 4)
    local step = d.step or 2
    local m = { id = id, key = tostring(d.map or id), step = step, lanes = d.lanes, cells = d.cells, blocked = d.blocked or {}, v = d.v or 1, scan = d.scan, side = side, cx = (x0 + x1) / 2, cz = (z0 + z1) / 2, hash = {} }
    for _, c in d.cells do m.hash[math.floor(c[1] / step + 0.5) * 100003 + math.floor(c[2] / step + 0.5)] = c end
    return m
end

------------------------------------------------------------------ state
local map, sel = nil, 1 -- sel = the hotbar slot the buttons edit; the data belongs to the unit standing in it
local ui = {}
local function unitOf(slot) -- unit id of hotbar slot `slot` (nil = empty)
    local f = Hub.AutoPlay and Hub.AutoPlay.unitId
    local ok, id = pcall(function() return f and f(slot) end)
    return ok and id and tostring(id) or nil
end
local function spotsOf(id, create)
    if not (map and id) then return {} end
    local store = cfg.learned[map.key]
    if create then
        store = store or {}
        cfg.learned[map.key] = store
        store[id] = store[id] or {}
    end
    return store and store[id] or {}
end
local function count(slot) return #spotsOf(unitOf(slot)) end

local function slotName(slot)
    local f = Hub.AutoPlay and Hub.AutoPlay.unitName
    local ok, n = pcall(function() return f and f(slot) end)
    return ok and n or nil
end

local function paintStatus()
    if not ui.status then return end
    if not map then
        ui.status:SetText(#labels == 0 and "No map saved yet: play a match with Auto Play on, each map is saved the first time." or "Pick a map.")
        return
    end
    local total = 0
    for _, l in cfg.learned[map.key] or {} do total += #l end
    local name = slotName(sel)
    local text
    if unitOf(sel) then
        text = ("%s | Slot %d %s: %d spot%s | all units on this map: %d"):format(label(map.id), sel, name or "", count(sel), count(sel) == 1 and "" or "s", total)
    else
        text = ("%s | Slot %d is empty | all units on this map: %d"):format(label(map.id), sel, total)
    end
    if map.v < 2 then
        text ..= " | old scan (28 studs around the route, no details): play this map, or press Rescan in a match on it"
    elseif map.scan then
        text ..= (" | scan: %d placeable, %d under scenery, %d no ground"):format(map.scan.ground + map.scan.hill, map.scan.scenery, map.scan.none)
    end
    if cfg.use_learned == false then text ..= " | Use Map Picker Spots is OFF (Advanced > Position)" end
    ui.status:SetText(text)
end

local function paintSlots()
    for i, b in ui.slotBtn or {} do
        local n = count(i)
        b.btn.Text = n > 0 and ("%d: %d"):format(i, n) or tostring(i)
        b.btn.BackgroundTransparency = unitOf(i) and 0 or 0.65
        b.line.Color = i == sel and S.AccentColor or S.OutlineColor
        b.line.Thickness = i == sel and 3 or 1
    end
end

-- Spots of the six equipped units, coloured like their slot button; spots of other units saved on this map are small grey dots.
local function paintSpots()
    if not ui.spotLayer then return end
    ui.spotLayer:ClearAllChildren()
    if not map then return end
    local drawn, selId = {}, unitOf(sel)
    for slot = 1, 6 do
        local id = unitOf(slot)
        if id and not drawn[id] then
            drawn[id] = true
            local on = id == selId
            for _, p in spotsOf(id) do
                local dot = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5 + (p[1] - map.cx) / map.side, 0.5 + (p[3] - map.cz) / map.side),
                    Size = UDim2.fromScale(0.06, 0.06), BackgroundColor3 = COLORS[slot], BorderSizePixel = 0, ZIndex = on and 30 or 20 }, ui.spotLayer)
                new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
                new("UIAspectRatioConstraint", {}, dot)
                new("UIStroke", { Color = on and Color3.new(1, 1, 1) or Color3.new(0, 0, 0), Thickness = on and 2 or 1 }, dot)
                new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = tostring(slot), TextColor3 = Color3.new(0, 0, 0), TextScaled = true,
                    FontFace = S.Font, ZIndex = 31 }, dot)
            end
        end
    end
    for id, list in cfg.learned[map.key] or {} do
        if not drawn[id] then
            for _, p in list do
                local dot = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5 + (p[1] - map.cx) / map.side, 0.5 + (p[3] - map.cz) / map.side),
                    Size = UDim2.fromScale(0.035, 0.035), BackgroundColor3 = Color3.fromRGB(150, 150, 165), BackgroundTransparency = 0.35, BorderSizePixel = 0, ZIndex = 15 }, ui.spotLayer)
                new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
                new("UIAspectRatioConstraint", {}, dot)
            end
        end
    end
end

local function refresh()
    paintSlots()
    paintSpots()
    paintStatus()
    if Hub.AutoPlay and Hub.AutoPlay.refreshLabels then pcall(Hub.AutoPlay.refreshLabels) end
end

-- Draws the map layers: valid cells (ground / hill), the enemy route with S (spawn) and B (base).
local function build()
    for _, k in { "cellLayer", "laneLayer" } do if ui[k] then ui[k]:ClearAllChildren() end end
    if not map then return refresh() end
    local grid = {}
    for _, c in map.cells do
        local gx = math.clamp(math.floor((0.5 + (c[1] - map.cx) / map.side) * N), 0, N - 1)
        local gz = math.clamp(math.floor((0.5 + (c[2] - map.cz) / map.side) * N), 0, N - 1)
        local k = gx * N + gz
        if grid[k] == nil or (grid[k] == "H" and c[3] == "G") then grid[k] = c[3] end -- ground wins a mixed bucket (most units stand on it)
    end
    local blocked = {}
    for _, c in map.blocked do
        local gx = math.clamp(math.floor((0.5 + (c[1] - map.cx) / map.side) * N), 0, N - 1)
        local gz = math.clamp(math.floor((0.5 + (c[2] - map.cz) / map.side) * N), 0, N - 1)
        local k = gx * N + gz
        if grid[k] == nil then blocked[k] = true end -- a bucket with any placeable cell stays green
    end
    local cellHolder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
    for k in blocked do
        new("Frame", { Position = UDim2.fromScale((k // N) / N, (k % N) / N), Size = UDim2.fromScale(1 / N, 1 / N), BackgroundColor3 = BLOCKED,
            BackgroundTransparency = 0.45, BorderSizePixel = 0 }, cellHolder)
    end
    for k, cls in grid do
        new("Frame", { Position = UDim2.fromScale((k // N) / N, (k % N) / N), Size = UDim2.fromScale(1 / N, 1 / N), BackgroundColor3 = cls == "H" and HILL or GROUND,
            BackgroundTransparency = 0.2, BorderSizePixel = 0 }, cellHolder)
    end
    for _, c in cellHolder:GetChildren() do c.Parent = ui.cellLayer end
    cellHolder:Destroy()
    for _, l in map.lanes do
        local stride = math.max(1, math.floor(#l / 400))
        for i = 1, #l, stride do
            new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5 + (l[i][1] - map.cx) / map.side, 0.5 + (l[i][2] - map.cz) / map.side),
                Size = UDim2.fromOffset(4, 4), BackgroundColor3 = ROUTE, BorderSizePixel = 0, ZIndex = 5 }, ui.laneLayer)
        end
        for tag, p in { S = l[1], B = l[#l] } do
            if p then
                new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5 + (p[1] - map.cx) / map.side, 0.5 + (p[2] - map.cz) / map.side),
                    Size = UDim2.fromOffset(18, 18), BackgroundColor3 = tag == "S" and Color3.fromRGB(70, 170, 100) or Color3.fromRGB(200, 70, 80), TextColor3 = Color3.new(1, 1, 1),
                    Text = tag, TextSize = 12, FontFace = S.Font, ZIndex = 10 }, ui.laneLayer)
            end
        end
    end
    refresh()
end

local function select(id)
    map = id and loadMap(id) or nil
    if id and not map then lib:Notify("Could not read the snapshot of " .. id) end
    build()
end
Picker.select = select

------------------------------------------------------------------ clicking
local function nearestCell(x, z)
    local step = map.step
    local ix, iz = math.floor(x / step + 0.5), math.floor(z / step + 0.5)
    local best, bd = nil, SNAP * SNAP
    local r = math.ceil(SNAP / step)
    for dx = -r, r do
        for dz = -r, r do
            local c = map.hash[(ix + dx) * 100003 + iz + dz]
            if c then
                local d = (c[1] - x) ^ 2 + (c[2] - z) ^ 2
                if d < bd then best, bd = c, d end
            end
        end
    end
    return best
end

-- Click a free cell: the next copy of the selected slot's unit goes there. Click a spot of that unit again: it is removed.
local function clickAt(x, z)
    if not map then return end
    local id = unitOf(sel)
    if not id then return lib:Notify(("Slot %d has no unit"):format(sel)) end
    local c = nearestCell(x, z)
    if not c then return lib:Notify("No placeable ground there") end
    local list = spotsOf(id, true)
    for i, p in list do
        if math.abs(p[1] - c[1]) < 1 and math.abs(p[3] - c[2]) < 1 then
            table.remove(list, i)
            Core.save_config()
            return refresh()
        end
    end
    if #list >= MAX_SPOTS then return lib:Notify(("This unit already has %d spots"):format(MAX_SPOTS)) end
    table.insert(list, { c[1], 0, c[2] })
    Core.save_config()
    if cfg.use_learned == false then lib:Notify("Use Map Picker Spots is off: Auto Play ignores these spots until you turn it on (Advanced > Position).") end
    refresh()
end

------------------------------------------------------------------ UI
local box = Tabs.AutoPlay:AddLeftGroupbox("Map Picker", "map-pin")
local startId
do
    local ok, k = pcall(function() return Hub.AutoPlay and Hub.AutoPlay.mapKey and Hub.AutoPlay.mapKey() end)
    startId = ok and k and idLabel[(tostring(k):gsub("%W", "_"))] and (tostring(k):gsub("%W", "_")) or nil
end
ui.drop = box:AddDropdown("MP_Map", { Text = "Map", Tooltip = "Maps this machine has saved (each one the first time Auto Play ran on it). Spots are per map, every mode that uses the map shares them.",
    Values = labels, Default = startId and idLabel[startId] or nil, Callback = function(v) select(byLabel[v]) end })
box:AddLabel("Pick a unit, then click the map to add its next spot. Click a spot again to remove it. Grey dots are other units' spots.", true)

local slotRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), VerticalAlignment = Enum.VerticalAlignment.Center }, slotRow)
ui.slotBtn = {}
for i = 1, 6 do
    local b = new("TextButton", { Size = UDim2.new(1 / 6, -4, 1, 0), Text = tostring(i), TextSize = 14, FontFace = S.Font, TextColor3 = Color3.new(0, 0, 0), AutoButtonColor = false,
        BackgroundColor3 = COLORS[i], LayoutOrder = i, BorderSizePixel = 0 }, slotRow)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
    local line = new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
    b.MouseButton1Click:Connect(function() sel = i paintSlots() paintSpots() paintStatus() end)
    ui.slotBtn[i] = { btn = b, line = line }
end
box:AddUIPassthrough("MP_Slots", { Instance = slotRow, Height = 30 })

local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
local plot = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(14, 14, 22),
    BorderSizePixel = 0, ClipsDescendants = true }, holder)
new("UIAspectRatioConstraint", { AspectType = Enum.AspectType.FitWithinMaxSize, DominantAxis = Enum.DominantAxis.Width }, plot)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, plot)
new("UIStroke", { Color = S.OutlineColor, Thickness = 1 }, plot)
ui.cellLayer = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 1 }, plot)
ui.laneLayer = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, plot)
ui.spotLayer = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 20 }, plot)
local hit = new("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.fromScale(1, 1), ZIndex = 100 }, plot)
hit.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    if not map then return end
    -- input.Position leaves out the top bar; a ScreenGui that ignores the inset measures from the very top
    local pos = Vector2.new(input.Position.X, input.Position.Y)
    local sg = hit:FindFirstAncestorWhichIsA("ScreenGui")
    if sg and sg.IgnoreGuiInset then pos += GuiService:GetGuiInset() end
    local a, s = hit.AbsolutePosition, hit.AbsoluteSize
    if s.X <= 0 or s.Y <= 0 then return end
    local ok, err = pcall(clickAt, map.cx + ((pos.X - a.X) / s.X - 0.5) * map.side, map.cz + ((pos.Y - a.Y) / s.Y - 0.5) * map.side)
    if not ok then Core.log("ERROR mappicker click:", err) end
end)
box:AddUIPassthrough("MP_Plot", { Instance = holder, Height = 340 })
ui.status = box:AddLabel("-", true)
box:AddLabel("Colours: green = ground any unit can stand on (the game's own placement rule), brown = hill ground (hill units), purple = ground hidden under scenery (not usable), dark = nothing placeable found, or outside the scan (48 studs around the route). White dots = the enemy route, S = spawn, B = your base.", true)

box:AddButton({ Text = "Undo Last Spot (this unit)", Func = function()
    local list = spotsOf(unitOf(sel))
    if #list > 0 then table.remove(list) Core.save_config() refresh() end
end })
box:AddButton({ Text = "Clear This Unit's Spots", Func = function()
    local id = unitOf(sel)
    if map and id and cfg.learned[map.key] then cfg.learned[map.key][id] = nil Core.save_config() refresh() end
end })
box:AddButton({ Text = "Clear Whole Map (every unit) (double-click)", Risky = true, DoubleClick = true, Func = function()
    if map then cfg.learned[map.key] = nil Core.save_config() refresh() end
end })
box:AddButton({ Text = "Rescan This Map (needs a match on it)", Tooltip = "Scans the map you are playing again, wider than the first scans, and records why a nearby spot is not placeable.", Func = function()
    local ap = Hub.AutoPlay
    local ok, cur = pcall(function() return ap and ap.mapKey and ap.mapKey() end)
    if not (map and ap and ap.rescan and ok and cur == map.key) then return lib:Notify("Join a match on this map first, then press this again") end
    local done, res = pcall(ap.rescan)
    if done and res then
        lib:Notify("Rescanned " .. map.key)
        select(map.id)
    else
        lib:Notify("Could not rescan yet (the route is not loaded), try again in a few seconds")
    end
end })
box:AddButton({ Text = "Refresh Map List", Tooltip = "Picks up maps saved since the hub started.", Func = function()
    scan()
    ui.drop:SetValues(labels)
    paintStatus()
end })

if startId then select(startId) elseif labels[1] then ui.drop:SetValue(labels[1]) else build() end

-- The hotbar changes with the team: repaint the buttons and spots when the six unit ids differ.
task.spawn(function()
    local shown
    while Hub == getgenv().ZenoHub and not lib.Unloaded do
        local ids = {}
        for i = 1, 6 do ids[i] = unitOf(i) or "-" end
        local sig = table.concat(ids, ",")
        if sig ~= shown then
            shown = sig
            local ok, err = pcall(refresh)
            if not ok then Core.log("ERROR mappicker refresh:", err) end
        end
        task.wait(2)
    end
end)

-- exposed for checks from the executor
Picker.state = function() return { map = map and map.id, key = map and map.key, sel = sel, side = map and map.side, cx = map and map.cx, cz = map and map.cz, cells = map and #map.cells } end
Picker.click = function(x, z) clickAt(x, z) end
Picker.setSlot = function(i) sel = i refresh() end
Picker.refresh = refresh
return Picker
