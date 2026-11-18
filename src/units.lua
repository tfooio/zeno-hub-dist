-- Units tab (docs/features/units-tab.md): a grid of unit pictures on the left; the selected unit's page on the right with a header (picture, name,
-- tagline, whether the account owns it), what its special ability does (text) and its options. Other modules put their controls on a unit's page
-- with Hub.Units.box(id). To add a unit: one entry in ENTRIES (its page appears at once; the module that owns the feature adds the controls).
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local Units = {}

local UI = Hub.UI
if not (UI and UI.Tabs.Units) then return Units end -- safe mode (no window): Units.box returns nil and callers use their old box

local defs = Game.data("Units")
local lib = UI.Library
local S = lib.Scheme

-- id = the game's unit id (the picture comes from it), title = page name when the game's name is not the one to show, tag = the line under the name,
-- status = replaces the owned / not owned line (for a unit nobody owns: it only exists in a match), look = the unit whose picture is shown instead.
local BUFF = "Casts a team damage buff on a long cooldown. Smart Auto Ability casts four placed copies as a chain, exactly on cooldown, so the buff is up about 94% of the time (measured on the Commander chain: +25% damage, 30 s). Nothing is cast with fewer than 4 copies placed."
local ENTRIES = {
    { id = "erwin", tag = "Buff chain", text = BUFF },
    { id = "wendy", tag = "Buff chain", text = "Same buff chain as the Commander: four placed copies are cast in turn so the buff stays up." },
    { id = "leafa_evolved", tag = "Buff chain", text = "Same buff chain as the Commander (her buff is a magic damage buff): four placed copies are cast in turn so the buff stays up. Cursed (+SPA) copies reach the cooldown ceiling of about 94% uptime." },
    { id = "kisuke_evolved", tag = "Team buff", text = "Up to three copies. His active ability (Kannonbiraki Benihime Aratame) unlocks at upgrade 6 and buffs all your units for 30 s: +20% range and 10% faster attacks. Cooldown 90 s at max upgrade, so three copies can keep it up all the time. A cast while the buff is on is ignored, so Smart Auto Ability casts a ready copy right after the buff ends, while enemies are alive." },
    { id = "homura_evolved", tag = "Time stop", text = "Stops time. Smart Auto Ability takes turns between her copies, one cast every max(cooldown / copies, Min Gap) seconds, and only while an enemy is in range, so a stop never lands on enemies that cannot be stopped again yet. Min Gap 12 = her 4 s stop + 8 s immunity; lower it to stop more often." },
    { id = "rukia_bankai_evolved", tag = "Freeze meter", text = "Freezes enemies while she is on; a meter drains (about 5 per second on) and refills (about 2.5 per second off). Smart Auto Ability keeps one copy on at a time and hands over to the fullest idle copy before the meter runs out, only while enemies are in range. About 92% uptime with three copies (measured); 100% is not reachable." },
    { id = "vegito", look = "goku_ssj3_evolved", title = "Vegito (Fusion)", tag = "Fusion", status ="Made in a match by fusing Carrot and Vego", text = "Carrot (Ultra) and Vego (Mage II) fuse into Vegito at upgrade 7. With both on the hotbar, Auto Fuse upgrades them to level 7, casts the fusion on the better one (stat potentials, level, relic), then upgrades the Fused Hero to its maximum. Needs Auto Play." },
    { id = "marco_evolved", tag = "Reincarnation", text = "Reincarnation: selling Phoenix (Mythic Flames) at max upgrade gives +50% damage to every Phoenix placed after that sale (only the first sale counts). The hub sells the first one at max, then all your other Phoenixes one at a time, lowest upgrade first; Auto Play places them again and upgrades them. A sale refunds about 25% of what the unit cost, so the money is gone. Needs Auto Play, Phoenix on the hotbar and his Upgrade Cap at max." },
}

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in props do o[k] = v end
    o.Parent = parent
    return o
end
local function nameOf(e) return e.title or (defs[e.id] and defs[e.id].name) or e.id end
local function shortName(e) return (nameOf(e):gsub("%s*%b()", "")) end

local tab = UI.Tabs.Units
local gridBox = tab:AddLeftGroupbox("Units", "users")
local picked = gridBox:AddLabel("Pick a unit.", true)

-- Identity: calls into the game's GUIService code lower this thread's identity (every Obsidian call after it failed with "lacking capability Plugin",
-- 2026-11-17), so every such call is wrapped.
local function keepIdentity(fn, ...)
    local ident = getthreadidentity and getthreadidentity() or 8
    local res = table.pack(pcall(fn, ...))
    if setthreadidentity then pcall(setthreadidentity, math.max(ident, 8)) end
    return table.unpack(res, 1, res.n)
end

local GUI
keepIdentity(function() GUI = Game.loader().load_client_service(script, "GUIService") end)

-- Which unit ids the account owns (the game only has the models of those on the client).
local owned = {}
local function refreshOwned()
    local col
    local pd = Game.profile()
    col = pd and pd.collection
    if not col then keepIdentity(function() col = GUI.session.collection.collection_profile_data end) end
    if not col then return end
    local out = {}
    for _, u in col.owned_units do out[u.unit_id] = true end
    owned = out
end
pcall(refreshOwned)

-- A scrolling frame: the number of columns depends on the window width and the list grows with every unit added.
local holder = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 4, ScrollBarImageColor3 = S.AccentColor })
local COLS, GAP = 3, 10
local layout = new("UIGridLayout", { CellSize = UDim2.fromOffset(76, 76), CellPadding = UDim2.fromOffset(GAP, GAP), SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center }, holder)
new("UIPadding", { PaddingRight = UDim.new(0, 4), PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4) }, holder)

local pages, cells, heroes, selected = {}, {}, {}, nil

-- The game's own unit picture widget (GUIService.make_unit_frame: ImageButton with a ViewportFrame and the rarity frame), stripped of its extras.
-- Returns the button and whether it is the game's gray "unselected_unit" placeholder (no model on the client).
local function buildPicture(e)
    if not GUI then -- in a match GUIService is not there yet right after the hub loads: look again
        keepIdentity(function() GUI = Game.loader().load_client_service(script, "GUIService") end)
        if not GUI then return nil, true end
    end
    local ok, f = keepIdentity(GUI.make_unit_frame, e.look or e.id, 0, nil, {}, true, { hide_extra_info = true, _from_moving_ui = true })
    if not (ok and typeof(f) == "Instance") then return nil, true end
    for _, k in f:GetChildren() do
        if k:IsA("UIScale") or k:IsA("UIAspectRatioConstraint") then k:Destroy() end
    end
    for _, n in { "TradeIcon", "BlackedOut", "EquippedList", "LockIcon", "Cost", "SellIcon", "FuseIcon", "EvolveArrow", "NEW", "name" } do
        local o = f:FindFirstChild(n)
        if o then o.Visible = false end
    end
    f.AutoButtonColor = false
    local view = f:FindFirstChild("View", true)
    local wm = view and view:FindFirstChildWhichIsA("WorldModel")
    local model = wm and wm:FindFirstChildWhichIsA("Model")
    return f, not model or model.Name == "unselected_unit"
end

-- Saved pictures (Data/unit_icons/<unit>.png, cropped from a screenshot on an account that owns the unit): shown where the game cannot draw the unit
-- (a unit this account does not own, or a match that has not loaded the model yet).
local ICONS = Core.paths.data .. "/unit_icons/"
local iconAssets = {}
local function iconButton(e)
    local id = e.look or e.id
    if iconAssets[id] == nil then
        iconAssets[id] = false
        pcall(function()
            local path = ICONS .. id .. ".png"
            if isfile(path) then iconAssets[id] = getcustomasset(path) end
        end)
    end
    if not iconAssets[id] then return nil end
    local b = new("ImageButton", { Image = iconAssets[id], ScaleType = Enum.ScaleType.Fit, BackgroundColor3 = S.MainColor, AutoButtonColor = false })
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
    return b
end

-- Grid cell: picture, name bar, outline that lights up on hover and stays lit when selected.
local placeholders = {} -- id -> true while the cell still shows the placeholder (or a saved picture) instead of the game's own
local function paint(id)
    local line = cells[id]
    if line then line.Thickness, line.Color = id == selected and 3 or 2, id == selected and S.AccentColor or S.OutlineColor end
end
local function makeCell(e, order, built, builtPlaceholder)
    local f, placeholder = built, builtPlaceholder
    if not built then f, placeholder = buildPicture(e) end
    if not f or placeholder then
        local ic = iconButton(e)
        if ic then
            if f then f:Destroy() end
            f = ic
        end
    end
    if not f then
        f = new("TextButton", { Text = "", BackgroundColor3 = S.MainColor })
        new("UICorner", { CornerRadius = UDim.new(0, 8) }, f)
    end
    f.Name, f.LayoutOrder = e.id, order
    new("TextLabel", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 22), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.3,
        BorderSizePixel = 0, Text = shortName(e), TextWrapped = true, TextSize = 12, FontFace = S.Font, TextColor3 = Color3.new(1, 1, 1), ZIndex = 20 }, f)
    cells[e.id] = new("UIStroke", { Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = S.OutlineColor }, f)
    f.MouseButton1Click:Connect(function() Units.select(e.id) end)
    f.MouseEnter:Connect(function() if e.id ~= selected then cells[e.id].Color = S.AccentColor cells[e.id].Transparency = 0.45 end end)
    f.MouseLeave:Connect(function() cells[e.id].Transparency = 0 paint(e.id) end)
    f.Parent = holder
    placeholders[e.id] = placeholder or nil
    paint(e.id)
    return f
end

-- Page header: a bigger picture, the name, the tagline, and whether the account owns the unit.
local function statusText(e)
    if e.status then return e.status, S.FontColor end
    if owned[e.id] then return "In your collection", S.AccentColor end
    return "Not in your collection: no picture, its model is not loaded", S.FontColor
end
local function makeHero(e)
    local frame = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
    local slot = new("Frame", { BackgroundColor3 = S.MainColor, Size = UDim2.fromOffset(76, 76), Position = UDim2.fromOffset(0, 4), ClipsDescendants = true }, frame)
    new("UICorner", { CornerRadius = UDim.new(0, 10) }, slot)
    new("UIStroke", { Thickness = 2, Color = S.OutlineColor }, slot)
    new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(90, 4), Size = UDim2.new(1, -90, 0, 24), Text = nameOf(e), TextSize = 18, FontFace = S.Font,
        TextColor3 = S.FontColor, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, frame)
    new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(90, 30), Size = UDim2.new(1, -90, 0, 16), Text = e.tag or "", TextSize = 13, FontFace = S.Font,
        TextColor3 = S.AccentColor, TextXAlignment = Enum.TextXAlignment.Left }, frame)
    local state = new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(90, 50), Size = UDim2.new(1, -90, 0, 32), TextSize = 11, FontFace = S.Font,
        TextTransparency = 0.25, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "" }, frame)
    heroes[e.id] = { slot = slot, state = state, e = e }
    return frame
end
-- The big picture is built when its page is first opened (a viewport costs rendering), and again when the model turns up.
local function fillHero(id, force)
    local h = heroes[id]
    if not h then return end
    local text, color = statusText(h.e)
    h.state.Text, h.state.TextColor3 = text, color
    if h.built and not force then return end
    if h.pic then h.pic:Destroy() h.pic = nil end
    local f, placeholder = buildPicture(h.e)
    if not f or placeholder then
        local ic = iconButton(h.e)
        if ic then
            if f then f:Destroy() end
            f = ic
        end
    end
    if f then
        f.Size, f.Position, f.AnchorPoint, f.Active = UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero, false
        for _, c in f:GetChildren() do if c:IsA("TextLabel") then c.Visible = false end end
        f.Parent = h.slot
    end
    h.pic, h.built = f, f ~= nil -- a failed build is tried again at the next refresh (this used to store `true` and then crashed on :Destroy())
end

function Units.select(id)
    local prev = selected
    selected = id
    for _, e in ENTRIES do
        if pages[e.id] and pages[e.id].SetVisible then pages[e.id]:SetVisible(e.id == id) end
        if e.id == id then picked:SetText(nameOf(e)) end
    end
    if prev then paint(prev) end
    paint(id)
    fillHero(id)
end

-- The groupbox of a unit's page: modules add its controls there.
function Units.box(id) return pages[id] end

for i, e in ENTRIES do
    makeCell(e, i)
    local page = tab:AddRightGroupbox(shortName(e), "user")
    page:AddUIPassthrough("UnitHero_" .. e.id, { Instance = makeHero(e), Height = 86 })
    page:AddLabel(e.text, true)
    pages[e.id] = page
end
-- Three columns, centered; the cell size follows the box width (the window can be resized) and the box height follows the cells, up to 4 rows
-- (more units scroll).
local gridHeight = 260
local pass = gridBox:AddUIPassthrough("UnitsGrid", { Instance = holder, Height = gridHeight })
local function fit()
    if holder.AbsoluteSize.Y <= 0 or holder.AbsoluteSize.X <= 0 then return end
    local sc = holder.AbsoluteSize.Y / gridHeight -- the window's UI scale (the passthrough is gridHeight layout units high)
    local cell = math.clamp(math.floor((holder.AbsoluteSize.X / sc - 8 - (COLS - 1) * GAP) / COLS), 56, 120)
    layout.CellSize = UDim2.fromOffset(cell, cell)
    local rows = math.min(math.ceil(#ENTRIES / COLS), 4)
    local want = rows * cell + (rows - 1) * GAP + 8
    if math.abs(want - gridHeight) > 1 and pass and pass.SetHeight then
        gridHeight = want
        pass:SetHeight(want)
    end
end
holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
task.defer(fit)
Units.select(ENTRIES[1].id)

-- Every 3 s for the first minute (a match loads the unit models seconds after the hub), then every 10 s: the owned list is read again, and a cell
-- that is not the game's own picture is tried again (the model arrives when the account owns the unit or it is placed in a match). Every step is
-- protected: one error used to end this loop and leave the cells blank for the rest of the match.
task.spawn(function()
    local started = os.clock()
    while not lib.Unloaded do
        task.wait(os.clock() - started < 60 and 3 or 10)
        pcall(refreshOwned)
        for i, e in ENTRIES do
            local ok, err = pcall(function()
                if placeholders[e.id] then
                    local f, placeholder = buildPicture(e)
                    if f and not placeholder then
                        local old = holder:FindFirstChild(e.id)
                        if old then old:Destroy() end
                        makeCell(e, i, f, false)
                        if heroes[e.id] and heroes[e.id].built then fillHero(e.id, true) end
                    elseif f then
                        f:Destroy()
                    end
                end
            end)
            if not ok then Core.log("ERROR units picture", e.id, err) end
        end
        local ok, err = pcall(function() if selected then fillHero(selected) end end)
        if not ok then Core.log("ERROR units hero", err) end
    end
end)

return Units
