-- Icons: export the game's flat currency images as small transparent PNGs (Data/icons/zh_<name>.png) to upload to
-- Discord as custom emoji. Roblox serves these assets to nobody but the game (thumbnail API: private image, download: 403),
-- so the pixels are read from the client with EditableImage. Loaded only by the Webhook tab's export button.
local Hub = ...
local Game = Hub.Game
local Icons = {}

local SIZE = 128
local DIR = Hub.Core.paths.data .. "/icons"

local crcTable = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do c = c % 2 == 1 and bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) or bit32.rshift(c, 1) end
    crcTable[i] = c
end
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, s:byte(i)), 0xFF)], bit32.rshift(c, 8)) end
    return bit32.bxor(c, 0xFFFFFFFF)
end
local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521 b = (b + a) % 65521 end
    return b * 65536 + a
end
local function chunk(kind, body) return string.pack(">I4", #body) .. kind .. body .. string.pack(">I4", crc32(kind .. body)) end

-- RGBA buffer (size x size) to PNG bytes. shortcut: zlib "stored" blocks (no compression), 64 KB per icon is fine for emoji.
function Icons.png(rgba, size)
    local rows = {}
    for y = 0, size - 1 do rows[#rows + 1] = "\0" .. buffer.readstring(rgba, y * size * 4, size * 4) end
    local raw = table.concat(rows)
    local z = { "\x78\x01" }
    for i = 1, #raw, 65535 do
        local part = raw:sub(i, i + 65534)
        z[#z + 1] = string.pack("<BI2I2", i + 65534 >= #raw and 1 or 0, #part, 65535 - #part) .. part
    end
    z[#z + 1] = string.pack(">I4", adler32(raw))
    return "\137PNG\r\n\26\n" .. chunk("IHDR", string.pack(">I4I4BBBBB", size, size, 8, 6, 0, 0, 0))
        .. chunk("IDAT", table.concat(z)) .. chunk("IEND", "")
end

-- A non-square image is centred on a transparent square first, so it is not stretched.
local function square(src, w, h)
    if w == h then return src, w end
    local s = math.max(w, h)
    local out = buffer.create(s * s * 4)
    local dx, dy = (s - w) // 2, (s - h) // 2
    for y = 0, h - 1 do buffer.copy(out, ((y + dy) * s + dx) * 4, src, y * w * 4, w * 4) end
    return out, s
end

-- Box filter on premultiplied colour, so transparent edges do not turn dark.
local function downscale(src, w, size)
    local out = buffer.create(size * size * 4)
    for oy = 0, size - 1 do
        local y0 = oy * w // size
        local y1 = math.max(y0 + 1, (oy + 1) * w // size)
        for ox = 0, size - 1 do
            local x0 = ox * w // size
            local x1 = math.max(x0 + 1, (ox + 1) * w // size)
            local r, g, b, a, n = 0, 0, 0, 0, 0
            for y = y0, y1 - 1 do
                for x = x0, x1 - 1 do
                    local i = (y * w + x) * 4
                    local al = buffer.readu8(src, i + 3)
                    r += buffer.readu8(src, i) * al
                    g += buffer.readu8(src, i + 1) * al
                    b += buffer.readu8(src, i + 2) * al
                    a += al
                    n += 1
                end
            end
            if a > 0 then
                local o = (oy * size + ox) * 4
                buffer.writeu8(out, o, math.floor(r / a + 0.5))
                buffer.writeu8(out, o + 1, math.floor(g / a + 0.5))
                buffer.writeu8(out, o + 2, math.floor(b / a + 0.5))
                buffer.writeu8(out, o + 3, math.floor(a / n + 0.5))
            end
        end
        if oy % 8 == 7 then task.wait() end
    end
    return out
end

-- The game's resource icons (Loader assets gui._Resource.<Name>.Icon.Image); names starting with "_" (battle pass etc.) are skipped.
-- Returns the emoji names written and a list of problems.
function Icons.export()
    if not isfolder(DIR) then makefolder(DIR) end
    local folder = Game.loader().get_assets_path().gui._Resource
    local AssetService = game:GetService("AssetService")
    local done, failed = {}, {}
    for _, res in folder:GetChildren() do
        local icon = res:FindFirstChild("Icon")
        local name = "zh_" .. (res.Name == "_Trait" and "trait" or res.Name:lower())
        -- the other "_" resources (battle pass, event tokens) are not shown in embeds
        if (res.Name:sub(1, 1) == "_" and res.Name ~= "_Trait") or res.Name == "TestResource" or not icon then continue end
        local ok, err = pcall(function()
            local img = AssetService:CreateEditableImageAsync(Content.fromUri(icon.Image))
            local px = img:ReadPixelsBuffer(Vector2.zero, img.Size)
            local sq, side = square(px, img.Size.X, img.Size.Y)
            img:Destroy()
            writefile(("%s/%s.png"):format(DIR, name), Icons.png(downscale(sq, side, SIZE), SIZE))
        end)
        if ok then done[#done + 1] = name else failed[#failed + 1] = name .. ": " .. tostring(err) end
    end
    return done, failed, DIR
end

return Icons
