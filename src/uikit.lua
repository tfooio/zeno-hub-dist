-- Shared visual widgets for the Obsidian UI (docs/features/ui-kit.md).
-- Kit.rankList: a ranked list with a number badge, an icon, the name, an optional counter and up / down arrows.
local Hub = ...
local Kit = {}

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in props do o[k] = v end
    o.Parent = parent
    return o
end

-- Icons come from Obsidian's Lucide set (lib:GetIcon); a missing name just leaves the row without a picture.
local function icon(lib, name, size, parent, x)
    local ic = name and lib:GetIcon(name)
    if not ic then return nil end
    local o = lib:CreateIcon(ic, { Size = UDim2.fromOffset(size, size), Position = UDim2.new(0, x, 0.5, -size / 2), ImageColor3 = lib.Scheme.AccentColor })
    o.Parent = parent
    return o
end

-- o.items   = { { key, text, icon (Lucide name) } ... } (every row that can exist)
-- o.get()   -> keys in priority order (first = top); keys missing from it are appended in item order
-- o.set(keys)
-- o.counter = optional { min, max, get(key), set(key, v), prefix } shown as  - N +  on every row
function Kit.rankList(lib, box, id, o)
    local S = lib.Scheme
    local byKey = {}
    for _, it in o.items do byKey[it.key] = it end
    local frame = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
    new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, frame)
    local rows, L = {}, {}

    local function order()
        local out, seen = {}, {}
        for _, k in o.get() or {} do if byKey[k] and not seen[k] then seen[k] = true out[#out + 1] = k end end
        for _, it in o.items do if not seen[it.key] then out[#out + 1] = it.key end end
        return out
    end
    local function small(parent, text, x)
        return new("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(18, 18), Text = text, TextSize = 14,
            FontFace = S.Font, TextColor3 = S.FontColor, BackgroundColor3 = S.OutlineColor, AutoButtonColor = false, BorderSizePixel = 0 }, parent)
    end
    local function arrow(name, fallback, x, parent)
        local props = { Size = UDim2.fromOffset(22, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0) }
        local ic = lib:GetIcon(name)
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

    -- Move the row at k to position to (the rows in between shift by one).
    local function moveTo(k, to)
        local keys = order()
        to = math.clamp(math.floor(to), 1, #keys)
        if to == k then return L.refresh() end
        table.insert(keys, to, table.remove(keys, k))
        o.set(keys)
        L.refresh()
    end
    -- Arrow: one step; Shift: five; Ctrl: straight to the top / bottom (a 40-row list is slow one step at a time).
    local UIS = game:GetService("UserInputService")
    local function move(k, dir)
        local step = 1
        if UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift) then step = 5 end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl) then step = 1e6 end
        moveTo(k, k + dir * step)
    end
    local reserve = 60 + (o.counter and 76 or 0)
    for k, it in o.items do
        local r = { k = k }
        r.frame = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = S.MainColor, LayoutOrder = k }, frame)
        new("UICorner", { CornerRadius = UDim.new(0, 8) }, r.frame)
        -- The number is a box: type where the card should go and press Enter (it jumps there, the rows in between shift).
        r.num = new("TextBox", { Size = UDim2.fromOffset(22, 22), Position = UDim2.new(0, 5, 0.5, -11), BackgroundColor3 = S.OutlineColor, TextColor3 = S.FontColor, TextSize = 13, FontFace = S.Font,
            ClearTextOnFocus = true, PlaceholderText = "", BorderSizePixel = 0 }, r.frame)
        new("UICorner", { CornerRadius = UDim.new(0, 6) }, r.num)
        r.num.FocusLost:Connect(function()
            local n = tonumber(r.num.Text)
            if n and r.k and rows[r.k] == r then moveTo(r.k, n) else L.refresh() end
        end)
        r.pic = icon(lib, it.icon, 18, r.frame, 33)
        local nameX = r.pic and 56 or 36
        r.name = new("TextLabel", { Position = UDim2.fromOffset(nameX, 0), Size = UDim2.new(1, -(nameX + reserve), 1, 0), BackgroundTransparency = 1, Text = it.text, TextColor3 = S.FontColor,
            TextSize = 14, TextScaled = true, FontFace = S.Font, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, r.frame)
        -- a narrow window shrinks the name (down to 9) before it is cut short
        new("UITextSizeConstraint", { MaxTextSize = 14, MinTextSize = 9 }, r.name)
        r.up, r.down = arrow("chevron-up", "^", -30, r.frame), arrow("chevron-down", "v", -6, r.frame)
        if o.counter then
            local c = o.counter
            r.minus, r.plus = small(r.frame, "-", -92), small(r.frame, "+", -54)
            new("UICorner", { CornerRadius = UDim.new(0, 5) }, r.minus)
            new("UICorner", { CornerRadius = UDim.new(0, 5) }, r.plus)
            r.val = new("TextLabel", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -74, 0.5, 0), Size = UDim2.fromOffset(18, 18), BackgroundTransparency = 1, TextColor3 = S.FontColor, TextSize = 13, FontFace = S.Font }, r.frame)
            r.minus.MouseButton1Click:Connect(function() c.set(r.key, math.max(c.min, c.get(r.key) - 1)) L.refresh() end)
            r.plus.MouseButton1Click:Connect(function() c.set(r.key, math.min(c.max, c.get(r.key) + 1)) L.refresh() end)
        end
        r.up.MouseButton1Click:Connect(function() move(r.k, -1) end)
        r.down.MouseButton1Click:Connect(function() move(r.k, 1) end)
        rows[k] = r
    end
    function L.refresh()
        local keys = order()
        local n = #keys
        for i, key in keys do
            local r, it = rows[i], byKey[key]
            r.key = key
            r.num.Text = tostring(i)
            r.name.Text = it.text
            if r.pic then
                local ic = it.icon and lib:GetIcon(it.icon)
                if ic then lib:ApplyIcon(r.pic, ic) end
            end
            r.up.Visible, r.down.Visible = i > 1, i < n
            if r.val then r.val.Text = tostring(o.counter.get(key)) end
        end
    end
    box:AddUIPassthrough(id, { Instance = frame, Height = #o.items * 34 })
    L.refresh()
    return L
end

return Kit
