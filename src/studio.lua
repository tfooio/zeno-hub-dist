-- Macro Studio (docs/features/macro-studio-research.md): a second window for macros, in Zeno Hub's own look (Obsidian's scheme: soft dark panels, pink accent,
-- flat outlined cards). Own ScreenGui, not an Obsidian tab. Pages: Run (now playing, activity), Macros (local library with unit pictures).
-- It only drives what the Macro tab already has (Core.config.macro, Library.Options / Toggles), so the Obsidian tab stays the fallback.
-- Cut on purpose (2026-11-21): Catalog (no backend), Team page, play settings, favorites / filters / search. See docs/features/macro-studio-research.md.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local TS = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local LP = game:GetService("Players").LocalPlayer
local env = getgenv()

local Studio = {}
local mcfg = Core.config.macro or {}
Core.config.macro = mcfg
local lib = Hub.UI and Hub.UI.Library

------------------------------------------------------------------ style kit (Zeno Hub's Obsidian scheme)
local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
local Scheme = lib and lib.Scheme
local function scheme(key, default) return Scheme and Scheme[key] or default end
local C = {
    bg = scheme("BackgroundColor", rgb(16, 16, 24)), main = scheme("MainColor", rgb(26, 26, 38)), line = scheme("OutlineColor", rgb(46, 46, 64)),
    accent = scheme("AccentColor", rgb(240, 143, 181)), text = scheme("FontColor", rgb(255, 255, 255)),
    sub = rgb(190, 190, 205), dim = rgb(130, 130, 152), dark = rgb(16, 16, 24),
    green = rgb(90, 210, 130), red = rgb(240, 110, 125), amber = rgb(250, 180, 80),
}
local BASE = scheme("Font", Font.fromEnum(Enum.Font.GothamMedium))
local F = { body = BASE, bold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold) }

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in props do o[k] = v end
    o.Parent = parent
    return o
end
local function corner(o, r) return new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
local function stroke(o, th, color, tr) return new("UIStroke", { Thickness = th, Color = color, Transparency = tr or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end
local function tw(o, t, props) TS:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play() end
local function label(parent, props)
    props.BackgroundTransparency = props.BackgroundTransparency or 1
    props.FontFace = props.FontFace or F.body
    props.TextColor3 = props.TextColor3 or C.text
    props.TextSize = props.TextSize or 14
    return new("TextLabel", props, parent)
end
local function lift(c, k) return c:Lerp(Color3.new(1, 1, 1), k) end

-- Icons from Obsidian's Lucide set when it is loaded; a text glyph otherwise. Returns the object and the property that colors it.
local function icon(name, size, parent, color, glyph)
    local ic = lib and pcall(lib.GetIcon, lib, name) and lib:GetIcon(name)
    if ic then
        local ok, o = pcall(lib.CreateIcon, lib, ic, { Size = UDim2.fromOffset(size, size), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ImageColor3 = color or C.text, BackgroundTransparency = 1 })
        if ok and o then o.Parent = parent return o, (o:IsA("ImageLabel") or o:IsA("ImageButton")) and "ImageColor3" or "TextColor3" end
    end
    return label(parent, { Size = UDim2.fromScale(1, 1), Text = glyph or "?", TextSize = size, FontFace = F.bold, TextColor3 = color or C.text }), "TextColor3"
end

-- Flat button: accent fill (primary), outlined (ghost), or green. Hover lightens it.
local FILL = { primary = "accent", ghost = "main", good = "green" }
local function button(parent, text, size, kind, props)
    local fill = C[FILL[kind or "ghost"]]
    local b = new("TextButton", { Size = size, BackgroundColor3 = fill, Text = "", AutoButtonColor = false }, parent)
    for k, v in props or {} do b[k] = v end
    corner(b, 8)
    local line = stroke(b, 1, kind == "primary" and C.accent or (kind == "good" and C.green or C.line))
    local t = label(b, { Size = UDim2.fromScale(1, 1), Text = text, FontFace = F.bold, TextSize = 13, TextColor3 = (kind == "primary" or kind == "good") and C.dark or C.text })
    b.MouseEnter:Connect(function() tw(b, 0.1, { BackgroundColor3 = lift(fill, 0.12) }) end)
    b.MouseLeave:Connect(function() tw(b, 0.1, { BackgroundColor3 = fill }) end)
    return b, t, line
end
local function restyle(b, t, line, kind) -- change a button's kind (Start <-> Stop)
    local fill = C[FILL[kind]]
    b.BackgroundColor3 = fill
    t.TextColor3 = (kind == "primary" or kind == "good") and C.dark or C.text
    line.Color = kind == "primary" and C.accent or (kind == "good" and C.green or C.line)
end

-- Flat outlined panel (Obsidian groupbox look). `accent` true = accent outline.
local function card(parent, size, accent, class)
    local f = new(class or "Frame", { Size = size, BackgroundColor3 = C.main, AutoButtonColor = class and false or nil, Text = class and "" or nil }, parent)
    corner(f, 8)
    local s = stroke(f, accent and 1.5 or 1, accent and C.accent or C.line)
    return f, s
end

local function pill(parent, text, color, props)
    local p = label(parent, { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 20), BackgroundTransparency = 0, BackgroundColor3 = C.bg, Text = text, TextSize = 11,
        FontFace = F.bold, TextColor3 = color or C.sub })
    for k, v in props or {} do p[k] = v end
    corner(p, 10)
    stroke(p, 1, color or C.line, 0.4)
    new("UIPadding", { PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9) }, p)
    return p
end

------------------------------------------------------------------ data: macros, assignments, units
local function path(name) return ("%s/%s.json"):format(Core.paths.macro, name) end
local function macroNames()
    local ok, list = pcall(function() return Hub.Macro and Hub.Macro.list() or {} end)
    return ok and list or {}
end

local defs
local function unitName(id)
    if not defs then local ok, d = pcall(Game.data, "Units") defs = ok and d or {} end
    return defs[id] and defs[id].name or id
end

local infoCache = {}
local function infoOf(name)
    local i = infoCache[name]
    if i then return i end
    i = { steps = 0, team = {} }
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path(name))) end)
    if ok and type(data) == "table" then
        local list = {}
        for k, s in data do list[#list + 1] = { n = tonumber(k) or 0, s = s } end
        table.sort(list, function(a, b) return a.n < b.n end)
        i.steps = #list
        local seen = {}
        for _, e in list do
            local id = e.s.UnitId
            if e.s.Type == "spawn_unit" and id and not seen[id] and #i.team < 7 then seen[id] = true i.team[#i.team + 1] = id end
        end
    end
    infoCache[name] = i
    return i
end

local function assignments(name) -- { mode, map } this macro is assigned to
    local out = {}
    for mode, maps in mcfg.stage or {} do
        for map, m in maps do if m == name then out[#out + 1] = { mode = mode, map = map } end end
    end
    table.sort(out, function(a, b) return a.mode .. a.map < b.mode .. b.map end)
    return out
end

local function viaOption(opt, value) -- through Obsidian's own control so its callback (save, start) runs and the Macro tab stays in step
    local o = lib and (lib.Toggles[opt] or lib.Options[opt])
    if o and o.SetValue then o:SetValue(value) return true end
    return false
end
local function syncDropdowns()
    if not lib then return end
    local names = macroNames()
    local a, b = lib.Options.MacroRecordFile, lib.Options.MacroStageMacro
    if a and a.SetValues then pcall(a.SetValues, a, names) end
    if b and b.SetValues then local n = table.clone(names) table.insert(n, 1, "None") pcall(b.SetValues, b, n) end
end
local function selectMacro(name)
    if not viaOption("MacroRecordFile", name) then mcfg.file = name Core.save_config() end
end
local function notify(text) if lib then lib:Notify(text, 4) end end

-- Unit pictures: the game's own unit frame (as the Units tab), a saved PNG, or letters.
local GUI
local pics = {} -- id -> template frame | false
local function keepIdentity(fn, ...)
    local ident = getthreadidentity and getthreadidentity() or 8
    local res = table.pack(pcall(fn, ...))
    if setthreadidentity then pcall(setthreadidentity, math.max(ident, 8)) end
    return table.unpack(res, 1, res.n)
end
local function picture(id)
    if pics[id] ~= nil then return pics[id] and pics[id]:Clone() end
    pics[id] = false
    if not GUI then keepIdentity(function() GUI = Game.loader().load_client_service(script, "GUIService") end) end
    if GUI then
        local ok, f = keepIdentity(GUI.make_unit_frame, id, 0, nil, {}, true, { hide_extra_info = true, _from_moving_ui = true })
        if ok and typeof(f) == "Instance" then
            for _, k in f:GetChildren() do if k:IsA("UIScale") or k:IsA("UIAspectRatioConstraint") then k:Destroy() end end
            for _, n in { "TradeIcon", "BlackedOut", "EquippedList", "LockIcon", "Cost", "SellIcon", "FuseIcon", "EvolveArrow", "NEW", "name" } do
                local o = f:FindFirstChild(n)
                if o then o.Visible = false end
            end
            for _, c in f:GetChildren() do if c:IsA("TextLabel") then c.Visible = false end end
            f.AutoButtonColor, f.Active = false, false
            local view = f:FindFirstChild("View", true)
            local wm = view and view:FindFirstChildWhichIsA("WorldModel")
            local model = wm and wm:FindFirstChildWhichIsA("Model")
            if model and model.Name ~= "unselected_unit" then pics[id] = f return f:Clone() end
            f:Destroy()
        end
    end
    local ok, p = pcall(function()
        local file = Core.paths.data .. "/unit_icons/" .. id .. ".png"
        return isfile(file) and getcustomasset(file)
    end)
    if ok and p then
        local img = new("ImageLabel", { Image = p, BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit })
        pics[id] = img
        return img:Clone()
    end
    return nil
end
local function unitIcon(parent, id, size, props)
    local slot = new("Frame", { Size = UDim2.fromOffset(size, size), BackgroundColor3 = C.bg, ClipsDescendants = true }, parent)
    for k, v in props or {} do slot[k] = v end
    corner(slot, size > 40 and 8 or 6)
    stroke(slot, 1, C.line)
    local pic = id and picture(id)
    if pic then
        pic.Size, pic.Position, pic.AnchorPoint = UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero
        pic.Parent = slot
    else
        label(slot, { Size = UDim2.fromScale(1, 1), Text = id and unitName(id):sub(1, 2):upper() or "", FontFace = F.bold, TextSize = math.floor(size * 0.38), TextColor3 = C.dim })
    end
    return slot
end

------------------------------------------------------------------ window
local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
local stale = parentGui:FindFirstChild("ZenoStudio") -- a copy from an earlier load of this module
if stale then stale:Destroy() end
local gui = new("ScreenGui", { Name = "ZenoStudio", ResetOnSpawn = false, DisplayOrder = 80, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false })
if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end
gui.Parent = parentGui
table.insert(Hub.connections, { Disconnect = function() gui:Destroy() end })

local W, H = 1014, 600
local PW, PH = 830, 540 -- page area
local win = new("Frame", { Name = "Window", Size = UDim2.fromOffset(W, H), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = C.bg }, gui)
corner(win, 12)
stroke(win, 1.5, C.line)
local uiscale = new("UIScale", {}, win)
local function fit()
    local cam = workspace.CurrentCamera
    local v = cam and cam.ViewportSize or Vector2.new(1280, 720)
    uiscale.Scale = math.clamp(math.min((v.X - 40) / W, (v.Y - 40) / H), 0.4, 1.15)
end
fit()
if workspace.CurrentCamera then table.insert(Hub.connections, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)) end
local body = win -- popups and modals go on the window itself

------------------------------------------------------------------ title bar
local top = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1 }, win)
label(top, { Size = UDim2.fromOffset(170, 22), Position = UDim2.fromOffset(18, 7), Text = "Macro Studio", FontFace = F.bold, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left })
local statusRow = new("Frame", { Size = UDim2.fromOffset(190, 16), Position = UDim2.fromOffset(19, 29), BackgroundTransparency = 1 }, top)
local dot = new("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(0, 4), BackgroundColor3 = C.dim }, statusRow)
corner(dot, 4)
local statusText = label(statusRow, { Size = UDim2.new(1, -14, 1, 0), Position = UDim2.fromOffset(14, 0), Text = "Off", TextSize = 12, TextColor3 = C.sub, TextXAlignment = Enum.TextXAlignment.Left })
new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BackgroundColor3 = C.line, BorderSizePixel = 0 }, top)

-- Window drag by the title bar.
do
    local dragging, startMouse, startPos
    top.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startMouse, startPos = true, i.Position, win.Position
        end
    end)
    table.insert(Hub.connections, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startMouse
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    table.insert(Hub.connections, UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
end

-- Popup list (macro picker): a click-catcher behind it closes it.
local function popup(anchor, options, current, onPick)
    local catcher = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 40 }, body)
    local rows = math.min(#options, 8)
    local box = card(catcher, UDim2.fromOffset(anchor.AbsoluteSize.X / uiscale.Scale, rows * 30 + 14), true)
    box.ZIndex = 41
    local pos = (anchor.AbsolutePosition - body.AbsolutePosition) / uiscale.Scale
    box.Position = UDim2.fromOffset(pos.X, pos.Y + anchor.AbsoluteSize.Y / uiscale.Scale + 4)
    local scroll = new("ScrollingFrame", { Size = UDim2.new(1, -12, 1, -12), Position = UDim2.fromOffset(6, 6), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 42 }, box)
    new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
    for i, o in options do
        local r = new("TextButton", { Size = UDim2.new(1, -4, 0, 28), BackgroundColor3 = C.line, BackgroundTransparency = o == current and 0.5 or 1, Text = "", AutoButtonColor = false, LayoutOrder = i, ZIndex = 43 }, scroll)
        corner(r, 6)
        label(r, { Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(10, 0), Text = o, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
            TextColor3 = o == current and C.accent or C.text, ZIndex = 44 })
        r.MouseEnter:Connect(function() r.BackgroundTransparency = 0.6 end)
        r.MouseLeave:Connect(function() r.BackgroundTransparency = o == current and 0.5 or 1 end)
        r.MouseButton1Click:Connect(function() catcher:Destroy() onPick(o) end)
    end
    catcher.MouseButton1Click:Connect(function() catcher:Destroy() end)
end

local picker = card(top, UDim2.fromOffset(236, 36), false, "TextButton")
picker.Position = UDim2.new(0.5, -170, 0, 8)
local pickerName = label(picker, { Size = UDim2.new(1, -40, 0, 17), Position = UDim2.fromOffset(12, 3), Text = "-", FontFace = F.bold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
label(picker, { Size = UDim2.new(1, -40, 0, 13), Position = UDim2.fromOffset(12, 19), Text = "Select Macro", TextSize = 10, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left })
do
    local arrow = new("Frame", { Size = UDim2.fromOffset(20, 20), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), BackgroundTransparency = 1 }, picker)
    icon("chevron-down", 16, arrow, C.sub, "v")
end
picker.MouseButton1Click:Connect(function()
    local names = macroNames()
    if #names == 0 then notify("No macros yet: make one on the Macros page") return end
    popup(picker, names, mcfg.file, function(n) selectMacro(n) Studio.refresh() end)
end)

local startBtn, startText, startLine = button(top, "Start", UDim2.fromOffset(96, 36), "primary")
startBtn.Position = UDim2.new(0.5, 74, 0, 8)

-- Session / Runs box.
local sess = card(top, UDim2.fromOffset(190, 36))
sess.AnchorPoint, sess.Position = Vector2.new(1, 0), UDim2.new(1, -62, 0, 8)
label(sess, { Size = UDim2.fromOffset(80, 12), Position = UDim2.fromOffset(12, 3), Text = "Session", TextSize = 10, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left })
local sessTime = label(sess, { Size = UDim2.fromOffset(80, 18), Position = UDim2.fromOffset(12, 15), Text = "--:--", FontFace = F.bold, TextSize = 15, TextColor3 = C.accent, TextXAlignment = Enum.TextXAlignment.Left })
label(sess, { Size = UDim2.fromOffset(60, 12), Position = UDim2.fromOffset(112, 3), Text = "Runs", TextSize = 10, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left })
local runsText = label(sess, { Size = UDim2.fromOffset(60, 18), Position = UDim2.fromOffset(112, 15), Text = "0", FontFace = F.bold, TextSize = 15, TextColor3 = C.accent, TextXAlignment = Enum.TextXAlignment.Left })

local close = button(top, "", UDim2.fromOffset(36, 36), "ghost")
close.AnchorPoint, close.Position = Vector2.new(1, 0), UDim2.new(1, -12, 0, 8)
do
    local holder = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, close)
    icon("x", 16, holder, C.sub, "x")
end
close.MouseButton1Click:Connect(function() Studio.close() end)

------------------------------------------------------------------ sidebar and pages
local side = new("Frame", { Size = UDim2.fromOffset(160, 532), Position = UDim2.fromOffset(8, 60), BackgroundTransparency = 1 }, win)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, side)
local pagesHolder = new("Frame", { Size = UDim2.fromOffset(PW, PH), Position = UDim2.fromOffset(176, 60), BackgroundTransparency = 1 }, win)
new("Frame", { Size = UDim2.fromOffset(1, 524), Position = UDim2.fromOffset(170, 64), BackgroundColor3 = C.line, BorderSizePixel = 0 }, win)

local pages, railBtns, order = {}, {}, {}
local current
local function showPage(name)
    current = name
    for n, p in pages do p.frame.Visible = n == name end
    for n, r in railBtns do
        local on = n == name
        tw(r.bg, 0.12, { BackgroundTransparency = on and 0 or 1 })
        r.bar.Visible = on
        r.label.TextColor3 = on and C.text or C.sub
        r.icon[r.prop] = on and C.accent or C.dim
    end
    if pages[name].refresh then pages[name].refresh() end
end
local function addPage(name, iconName, glyph, build)
    local frame = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, pagesHolder)
    local page = { frame = frame }
    pages[name] = page
    order[#order + 1] = name
    local b = new("TextButton", { Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, LayoutOrder = #order }, side)
    local bg = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.main, BackgroundTransparency = 1 }, b)
    corner(bg, 8)
    local bar = new("Frame", { Size = UDim2.fromOffset(3, 18), Position = UDim2.new(0, 0, 0.5, -9), BackgroundColor3 = C.accent, Visible = false }, bg)
    corner(bar, 2)
    local holder = new("Frame", { Size = UDim2.fromOffset(20, 20), Position = UDim2.new(0, 14, 0.5, -10), BackgroundTransparency = 1 }, b)
    local ic, prop = icon(iconName, 17, holder, C.dim, glyph)
    local lb = label(b, { Size = UDim2.new(1, -48, 1, 0), Position = UDim2.fromOffset(42, 0), Text = name, TextSize = 14, TextColor3 = C.sub, TextXAlignment = Enum.TextXAlignment.Left })
    railBtns[name] = { bg = bg, bar = bar, label = lb, icon = ic, prop = prop }
    b.MouseEnter:Connect(function() if current ~= name then tw(bg, 0.1, { BackgroundTransparency = 0.6 }) end end)
    b.MouseLeave:Connect(function() if current ~= name then tw(bg, 0.1, { BackgroundTransparency = 1 }) end end)
    b.MouseButton1Click:Connect(function() showPage(name) end)
    build(page, frame)
    return page
end

local function pageTitle(parent, text)
    return label(parent, { Size = UDim2.fromOffset(300, 30), Position = UDim2.fromOffset(2, 2), Text = text, FontFace = F.bold, TextSize = 20, TextXAlignment = Enum.TextXAlignment.Left })
end

-- Card grid and the macro card builder.
-- it = { name, author, meta, desc, team, accent (bool), useText, useKind, onUse, onDelete, tag, tagColor }
local CW, CH = 402, 130 -- two cards plus the gap and the scrollbar fit in the 830 px page
local function makeGrid(parent, size, pos)
    local sf = new("ScrollingFrame", { Size = size, Position = pos, BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = C.accent,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y }, parent)
    new("UIGridLayout", { CellSize = UDim2.fromOffset(CW, CH), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
    new("UIPadding", { PaddingLeft = UDim.new(0, 1), PaddingTop = UDim.new(0, 1), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, sf)
    return sf
end
local function cardFor(grid, it, order)
    local c, cs = card(grid, UDim2.fromOffset(CW, CH), it.accent, "TextButton")
    c.LayoutOrder = order
    c.MouseEnter:Connect(function() if not it.accent then cs.Color = lift(C.line, 0.25) end end)
    c.MouseLeave:Connect(function() if not it.accent then cs.Color = C.line end end)
    label(c, { Size = UDim2.new(1, -170, 0, 20), Position = UDim2.fromOffset(16, 10), Text = it.name, FontFace = F.bold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
    local who = it.author and ('<font color="#f08fb5">%s</font> <font color="#82829a">·</font> '):format(it.author) or ""
    label(c, { Size = UDim2.new(1, -32, 0, 16), Position = UDim2.fromOffset(16, 33), RichText = true, Text = who .. (it.meta or ""), TextSize = 12, TextColor3 = C.sub,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
    label(c, { Size = UDim2.new(1, -32, 0, 16), Position = UDim2.fromOffset(16, 53), Text = it.desc or "", TextSize = 12, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
    if it.tag then
        local p = pill(c, it.tag, it.tagColor or C.sub)
        p.AnchorPoint, p.Position = Vector2.new(1, 0), UDim2.new(1, it.onDelete and -46 or -12, 0, 10)
    end
    local row = new("Frame", { Size = UDim2.fromOffset(240, 28), Position = UDim2.fromOffset(16, 88), BackgroundTransparency = 1 }, c)
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, row)
    for i = 1, 7 do
        local id = it.team and it.team[i]
        local slot = unitIcon(row, id, 28, { LayoutOrder = i })
        if not id then slot.BackgroundTransparency = 0.5 end
    end
    local use = button(c, it.useText or "Use", UDim2.fromOffset(64, 30), it.useKind or "primary")
    use.AnchorPoint, use.Position = Vector2.new(1, 0), UDim2.new(1, -12, 0, 86)
    use.MouseButton1Click:Connect(function() if it.onUse then it.onUse() end end)
    if it.onDelete then
        local del = new("TextButton", { Size = UDim2.fromOffset(26, 22), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 9), Text = "", AutoButtonColor = false, BackgroundColor3 = C.bg }, c)
        corner(del, 6)
        local ds = stroke(del, 1, C.line)
        local di = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, del)
        local ic, prop = icon("trash-2", 14, di, C.dim, "x")
        local armed
        del.MouseButton1Click:Connect(function()
            if armed then it.onDelete() return end
            armed = true
            ds.Color = C.red
            ic[prop] = C.red
            task.delay(2.5, function() if del.Parent then armed = false ds.Color = C.line ic[prop] = C.dim end end)
        end)
    end
    c.MouseButton1Click:Connect(function() if it.onClick then it.onClick() end end)
    return c
end
local function emptyState(parent, headline, text)
    local f = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, parent)
    label(f, { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0.5, -40), Text = headline, FontFace = F.bold, TextSize = 18, TextColor3 = C.sub })
    label(f, { Size = UDim2.new(0.7, 0, 0, 60), Position = UDim2.new(0.15, 0, 0.5, -6), Text = text, TextSize = 13, TextColor3 = C.dim, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    return f
end

------------------------------------------------------------------ page: Run
local runRefresh
local current_ -- (page name is `current`, declared above)
local activity = {} -- newest first: { win, text, at }
table.insert(Hub.connections, { Disconnect = Core.on("run_finished", function(rec)
    table.insert(activity, 1, { win = rec.victory and true or false, text = ("%s · wave %s"):format(tostring(rec.level or "?"), tostring(rec.waves or "?")), at = os.date("%H:%M") })
    if #activity > 6 then table.remove(activity) end
    if current == "Run" and runRefresh then pcall(runRefresh) end
end) })
addPage("Run", "play", ">", function(page, f)
    pageTitle(f, "Run")
    local now = card(f, UDim2.fromOffset(PW, 196), true)
    now.Position = UDim2.fromOffset(0, 40)
    local nowName = label(now, { Size = UDim2.new(1, -32, 0, 30), Position = UDim2.fromOffset(16, 12), Text = "-", FontFace = F.bold, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
    local nowSub = label(now, { Size = UDim2.new(1, -32, 0, 16), Position = UDim2.fromOffset(16, 44), Text = "", TextSize = 12, TextColor3 = C.sub, TextXAlignment = Enum.TextXAlignment.Left, RichText = true })
    local function stat(y, title)
        label(now, { Size = UDim2.fromOffset(110, 18), Position = UDim2.fromOffset(16, y), Text = title, TextSize = 12, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left })
        return label(now, { Size = UDim2.new(1, -150, 0, 18), Position = UDim2.fromOffset(130, y), Text = "-", FontFace = F.bold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
    end
    local sStage, sAssigned, sSteps = stat(78, "This match"), stat(100, "Stage macro"), stat(122, "Steps")
    local teamRow = new("Frame", { Size = UDim2.fromOffset(240, 28), Position = UDim2.fromOffset(16, 152), BackgroundTransparency = 1 }, now)
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, teamRow)
    -- Activity: this session's finished runs
    local act = card(f, UDim2.fromOffset(PW, 240))
    act.Position = UDim2.fromOffset(0, 250)
    label(act, { Size = UDim2.new(1, -32, 0, 22), Position = UDim2.fromOffset(16, 10), Text = "Activity", FontFace = F.bold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left })
    local actRows = new("Frame", { Size = UDim2.new(1, -32, 1, -46), Position = UDim2.fromOffset(16, 38), BackgroundTransparency = 1 }, act)
    new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, actRows)
    function runRefresh()
        local name = mcfg.file
        nowName.Text = name or "No macro selected"
        local info = name and infoOf(name)
        nowSub.Text = name and ('<font color="#f08fb5">%s</font> <font color="#82829a">·</font> %d steps'):format(LP.Name, info.steps) or "Pick one in the bar above or on the Macros page"
        local ld = Hub.mode == "match" and Game.loader().LevelData
        local mode, map
        if ld and Hub.Macro and Hub.Macro.stageOf then pcall(function() mode, map = Hub.Macro.stageOf(ld) end) end
        sStage.Text = mode and ("%s: %s"):format(tostring(mode), tostring(map)) or "Not in a match"
        local own = mode and map and mcfg.stage and mcfg.stage[mode] and mcfg.stage[mode][map]
        sAssigned.Text = own or "None (Select Macro plays)"
        sSteps.Text = info and tostring(info.steps) or "-"
        for _, c in teamRow:GetChildren() do if c:IsA("GuiObject") then c:Destroy() end end
        for i = 1, 7 do
            local id = info and info.team[i]
            local s = unitIcon(teamRow, id, 28, { LayoutOrder = i })
            if not id then s.BackgroundTransparency = 0.5 end
        end
        for _, c in actRows:GetChildren() do if c:IsA("GuiObject") then c:Destroy() end end
        if #activity == 0 then
            label(actRows, { Size = UDim2.new(1, 0, 0, 22), Text = "No runs yet this session", TextSize = 12, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left })
        end
        for i, a in activity do
            local r = new("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = C.bg, LayoutOrder = i }, actRows)
            corner(r, 6)
            local d = new("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 10, 0.5, -4), BackgroundColor3 = a.win and C.green or C.red }, r)
            corner(d, 4)
            label(r, { Size = UDim2.new(1, -90, 1, 0), Position = UDim2.fromOffset(26, 0), Text = (a.win and "Win" or "Loss") .. " · " .. a.text, FontFace = F.bold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
            label(r, { Size = UDim2.fromOffset(50, 28), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Text = a.at, TextSize = 11, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Right })
        end
    end
    page.refresh = runRefresh
end)

------------------------------------------------------------------ page: Macros (local library)
local function macroItems(onChange)
    local out = {}
    for _, name in macroNames() do
        local info = infoOf(name)
        local asg = assignments(name)
        local selected = mcfg.file == name
        do
            local meta = #asg > 0 and ("%s: %s"):format(asg[1].mode, asg[1].map) .. (#asg > 1 and (" +%d"):format(#asg - 1) or "") or "Not assigned to a stage"
            local names = {}
            for i = 1, math.min(#info.team, 3) do names[i] = unitName(info.team[i]) end
            out[#out + 1] = {
                name = name, author = LP.Name, meta = meta .. (' <font color="#82829a">·</font> %d steps'):format(info.steps),
                desc = #info.team > 0 and ("Places %s%s"):format(table.concat(names, ", "), #info.team > 3 and (" +%d"):format(#info.team - 3) or "") or (info.steps == 0 and "Empty: record it in a match" or ""),
                team = info.team, accent = selected,
                tag = selected and "In use" or (#asg > 0 and ("%d stage%s"):format(#asg, #asg > 1 and "s" or "") or nil), tagColor = selected and C.accent or C.sub,
                useText = selected and "Using" or "Use", useKind = selected and "good" or "primary",
                onUse = function() selectMacro(name) onChange() end,
                onDelete = function()
                    pcall(delfile, path(name))
                    for _, maps in mcfg.stage or {} do for map, m in maps do if m == name then maps[map] = nil end end end
                    if mcfg.file == name then viaOption("MacroRecordFile", nil) mcfg.file = nil end
                    Core.save_config()
                    infoCache[name] = nil
                    syncDropdowns()
                    onChange()
                end,
            }
        end
    end
    return out
end

local function newMacroModal(onDone)
    local catcher = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Text = "", AutoButtonColor = false, ZIndex = 50 }, body)
    corner(catcher, 12)
    local m = card(catcher, UDim2.fromOffset(360, 160), true)
    m.AnchorPoint, m.Position, m.ZIndex = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), 51
    label(m, { Size = UDim2.new(1, -40, 0, 26), Position = UDim2.fromOffset(20, 14), Text = "New macro", FontFace = F.bold, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 52 })
    local box = new("TextBox", { Size = UDim2.new(1, -40, 0, 36), Position = UDim2.fromOffset(20, 50), BackgroundColor3 = C.bg, Text = "", PlaceholderText = "name (up to 26 characters)", PlaceholderColor3 = C.dim,
        TextColor3 = C.text, FontFace = F.body, TextSize = 13, ClearTextOnFocus = false, ZIndex = 52 }, m)
    corner(box, 8)
    stroke(box, 1, C.line)
    local create = button(m, "Create", UDim2.fromOffset(110, 34), "primary", { ZIndex = 52 })
    create.Position = UDim2.new(1, -130, 1, -48)
    local cancel = button(m, "Cancel", UDim2.fromOffset(90, 34), "ghost", { ZIndex = 52 })
    cancel.Position = UDim2.new(1, -228, 1, -48)
    for _, b in { create, cancel } do for _, d in b:GetDescendants() do if d:IsA("GuiObject") then d.ZIndex = 53 end end end
    cancel.MouseButton1Click:Connect(function() catcher:Destroy() end)
    local function go()
        local n = (box.Text or ""):gsub("[\\/:*?\"<>|]", ""):match("^%s*(.-)%s*$")
        if n == "" or #n > 26 then notify("Name must be 1 to 26 characters") return end
        if isfile(path(n)) then notify(n .. " already exists") return end
        writefile(path(n), "{}")
        syncDropdowns()
        selectMacro(n)
        catcher:Destroy()
        onDone()
    end
    create.MouseButton1Click:Connect(go)
    box.FocusLost:Connect(function(enter) if enter then go() end end)
    box:CaptureFocus()
end

addPage("Macros", "scroll-text", "M", function(page, f)
    pageTitle(f, "Macros")
    local grid = makeGrid(f, UDim2.fromOffset(PW, 456), UDim2.fromOffset(0, 44))
    local count = label(f, { Size = UDim2.fromOffset(500, 18), Position = UDim2.fromOffset(2, 512), Text = "", TextSize = 12, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left })
    local function rebuild()
        for _, c in grid:GetChildren() do if c:IsA("GuiObject") then c:Destroy() end end
        local items = macroItems(function() Studio.refresh() end)
        for i, it in items do cardFor(grid, it, i) end
        count.Text = ("%d macros"):format(#items)
        if #items == 0 then
            local e = emptyState(grid, "Nothing here yet", "Press New to make a macro, then record into it from a match.")
            e.Size = UDim2.fromOffset(PW - 20, 300)
        end
    end
    local new_ = button(f, "New", UDim2.fromOffset(100, 32), "primary")
    new_.Position = UDim2.fromOffset(PW - 212, 0)
    new_.MouseButton1Click:Connect(function() newMacroModal(function() Studio.refresh() end) end)
    local refresh = button(f, "Refresh", UDim2.fromOffset(100, 32), "ghost")
    refresh.Position = UDim2.fromOffset(PW - 106, 0)
    refresh.MouseButton1Click:Connect(function() infoCache = {} syncDropdowns() Studio.refresh() end)
    page.refresh = function() rebuild() end
end)

------------------------------------------------------------------ live state
local runs, sessionAt = 0, nil
table.insert(Hub.connections, { Disconnect = Core.on("game_finished", function() runs += 1 runsText.Text = tostring(runs) end) })

local function playing() return mcfg.play and true or false end
local function paintState()
    local on = playing()
    local inMatch = Hub.mode == "match"
    statusText.Text = not on and "Off" or (inMatch and "Playing" or "Armed: plays in the next match")
    dot.BackgroundColor3 = not on and C.dim or (inMatch and C.green or C.amber)
    startText.Text = on and "Stop" or "Start"
    restyle(startBtn, startText, startLine, on and "ghost" or "primary")
    pickerName.Text = mcfg.file or "No macro"
    if on and not sessionAt then sessionAt = os.clock() elseif not on then sessionAt = nil end
    sessTime.Text = sessionAt and ("%02d:%02d"):format(math.floor((os.clock() - sessionAt) / 60), math.floor(os.clock() - sessionAt) % 60) or "--:--"
end
startBtn.MouseButton1Click:Connect(function()
    local on = not playing()
    if not viaOption("MacroPlay", on) then
        mcfg.play = on
        Core.save_config()
        if on and Hub.Macro and Hub.Macro.start then Hub.Macro.start() elseif Hub.Macro and Hub.Macro.stop then Hub.Macro.stop() end
    end
    paintState()
end)
task.spawn(function()
    while env.ZenoHub == Hub and gui.Parent do
        if gui.Enabled then pcall(paintState) end
        task.wait(1)
    end
end)

function Studio.refresh()
    pcall(paintState)
    if current and pages[current] and pages[current].refresh then pcall(pages[current].refresh) end
end
function Studio.open(page)
    gui.Enabled = true
    win.Position = UDim2.fromScale(0.5, 0.5)
    showPage(page or current or "Run")
    Studio.refresh()
end
function Studio.close() gui.Enabled = false end
function Studio.toggle() if gui.Enabled then Studio.close() else Studio.open() end end

-- Hub.StudioLatest keeps the button pointing at the newest module when it is re-required on a live hub.
Hub.StudioLatest = Studio
if Hub.UI and Hub.UI.Tabs and Hub.UI.Tabs.Macro and not Hub.StudioBox then
    local box = Hub.UI.Tabs.Macro:AddLeftGroupbox("Studio", "sparkles")
    Hub.StudioBox = box
    box:AddButton({ Text = "Open Macro Studio", Func = function() Hub.StudioLatest.toggle() end, Tooltip = "Your macros as cards with unit pictures, and what is playing now." })
    box:AddLabel("Your macros with unit pictures.", true)
end

showPage("Run")
return Studio
