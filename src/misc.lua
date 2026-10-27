-- Misc and Settings tabs (docs/features/misc-settings.md): Teleport to Lobby if Players Join, Walk Around,
-- UI control, failsafe (auto rejoin, ping freeze), script config export / import / reset, themes, information.
-- Options live in Core.config.misc (hub.json).
local Hub = ...
local Core = Hub.Core
local env = getgenv()
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local LP = Players.LocalPlayer
local LOBBY_PLACE = 8304191830
local MATCH = Hub.mode == "match"

local cfg = Core.config.misc or {}
Core.config.misc = cfg
local defaults = { lobby_on_join = false, walk = false, ui_key = "RightControl", ui_button = false, auto_rejoin = true, ping_freeze = false }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

local function alive() return env.ZenoHub == Hub end
local Misc = {}

local UI = Hub.UI
if not UI then return Misc end
local Library, Tabs = UI.Library, UI.Tabs
local function set(key) return function(v) cfg[key] = v Core.save_config() end end
local function notify(text) pcall(Library.Notify, Library, { Title = "Zeno Hub", Description = text, Time = 5 }) end

-- Leave for the lobby place. TeleportService works whatever state the server is in (same call as the loading failsafe).
local leaving = false
function Misc.rejoin(reason)
    if leaving then return end
    leaving = true
    Core.log("rejoin:", reason)
    Core.save_config()
    task.spawn(function()
        for _ = 1, 10 do
            if not alive() then return end
            pcall(TeleportService.Teleport, TeleportService, LOBBY_PLACE, LP)
            task.wait(10)
        end
        leaving = false
    end)
end

-- Misc > Players
local players = Tabs.Misc:AddRightGroupbox("Players", "users")
players:AddToggle("LobbyOnJoin", { Text = "Teleport to Lobby if Players Join", Tooltip = "Match only: returns to the lobby when another player is in your server. Players listed in Joiner > Party Player are ignored.", Default = cfg.lobby_on_join, Callback = set("lobby_on_join") })

local function exempt(p)
    local names = (Core.config.party and Core.config.party.names) or ""
    local n, d = p.Name:lower(), p.DisplayName:lower()
    for token in names:gmatch("[^,;%s]+") do
        token = token:lower()
        if n == token or d == token or n:sub(1, #token) == token or d:sub(1, #token) == token then return true end
    end
    return false
end

if MATCH then
    task.spawn(function()
        while alive() do
            task.wait(2)
            if cfg.lobby_on_join and not leaving then
                for _, p in Players:GetPlayers() do
                    if p ~= LP and not exempt(p) then
                        Misc.rejoin("player joined: " .. p.Name)
                        break
                    end
                end
            end
        end
    end)
end

-- Misc > Secure: Walk Around (the box is made by src/match.lua next to Anti-AFK)
local secure = Hub.SecureBox
if secure then
    secure:AddToggle("WalkAround", { Text = "Walk Around", Tooltip = "Match only: every 20 to 40 s the character walks to a spot a few studs away.", Default = cfg.walk, Callback = set("walk") })
end
if MATCH then
    task.spawn(function()
        while alive() do
            task.wait(math.random(20, 40))
            local char = LP.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if cfg.walk and hum and root and hum.Health > 0 then
                pcall(hum.MoveTo, hum, root.Position + Vector3.new(math.random(-10, 10), 0, math.random(-10, 10)))
            end
        end
    end)
end

-- Settings > Information
local info = Tabs.Settings:AddLeftGroupbox("Information", "info")
info:AddLabel("Zeno Hub | Anime Adventures", true)
info:AddLabel(("Version: %s"):format(Hub.version ~= "" and Hub.version or "hosted build"), true)
info:AddLabel("Auto Execute on Teleport: always on (the hub queues itself before every teleport).", true)

-- Settings > UI Control
local ui = Tabs.Settings:AddLeftGroupbox("UI Control", "mouse-pointer-2")
ui:AddLabel("Toggle UI"):AddKeyPicker("UIKey", { Default = cfg.ui_key, Mode = "Toggle", NoUI = true, Text = "Toggle UI", ChangedCallback = function(key)
    if typeof(key) == "EnumItem" then cfg.ui_key = key.Name Core.save_config() end
end })
Library.ToggleKeybind = Library.Options.UIKey
local button
local function showButton(v)
    if Library.IsMobile then return end -- Obsidian already makes its own on mobile
    if v and not button then button = Library:AddDraggableButton("Toggle", function() Library:Toggle() end, true) end
    if button then button.Button.Visible = v end
end
ui:AddToggle("UIButton", { Text = "Display Toggle UI Button", Tooltip = "A draggable on-screen button that shows or hides this window.", Default = cfg.ui_button, Callback = function(v) cfg.ui_button = v Core.save_config() showButton(v) end })
if cfg.ui_button then showButton(true) end

-- Settings > Failsafe
local fs = Tabs.Settings:AddLeftGroupbox("Failsafe", "life-buoy")
fs:AddToggle("AutoRejoin", { Text = "Auto Rejoin", Tooltip = "If you get kicked or disconnected, teleport back to the lobby. Only works while the script is running in the game; Roblox Account Manager (docs/features/relaunch.md) covers a closed client.", Default = cfg.auto_rejoin, Callback = set("auto_rejoin") })
fs:AddToggle("PingFreeze", { Text = "Rejoin Ping Freeze", Tooltip = "Rejoin if the server ping value has not changed for 2 minutes (the connection froze).", Default = cfg.ping_freeze, Callback = set("ping_freeze") })
table.insert(Hub.connections, GuiService.ErrorMessageChanged:Connect(function()
    local msg = GuiService:GetErrorMessage()
    if cfg.auto_rejoin and msg ~= "" then
        Core.log("error prompt:", msg)
        task.delay(3, Misc.rejoin, "error prompt: " .. msg)
    end
end))
task.spawn(function()
    local ok, item = pcall(function() return game:GetService("Stats").Network.ServerStatsItem["Data Ping"] end)
    if not ok then return Core.log("ping freeze: no Data Ping stat") end
    local last, since = nil, os.clock()
    while alive() do
        task.wait(5)
        local v = item:GetValue()
        if v ~= last then last, since = v, os.clock()
        elseif cfg.ping_freeze and os.clock() - since >= 120 then Misc.rejoin("ping frozen at " .. tostring(v)) end
    end
end)

-- Settings > Script Config. The file is hub.json (every module's options) without the webhook URL.
local cfgBox = Tabs.Settings:AddRightGroupbox("Script Config", "file-json")
local function exportText()
    local copy = HttpService:JSONDecode(HttpService:JSONEncode(Core.config))
    if copy.webhook then copy.webhook.url = nil end
    return HttpService:JSONEncode({ zeno_config = 1, config = copy })
end
local function swap(new)
    local keepUrl = Core.config.webhook and Core.config.webhook.url
    pcall(writefile, Core.paths.config .. "/hub.backup.json", HttpService:JSONEncode(Core.config))
    for k in Core.config do Core.config[k] = nil end
    for k, v in new do Core.config[k] = v end
    if keepUrl then Core.config.webhook = Core.config.webhook or {} Core.config.webhook.url = keepUrl end
    Core.save_config()
    notify("Config applied, reloading the hub.")
    task.delay(1, Hub.reload)
end
cfgBox:AddButton({ Text = "Copy Config to Clipboard", Tooltip = "Copies the config as JSON. The webhook URL is left out.", Func = function()
    if not setclipboard then return notify("This executor has no setclipboard.") end
    setclipboard(exportText())
    notify("Config copied.")
end })
cfgBox:AddButton({ Text = "Send Config via Webhook", Tooltip = "Sends the config as a .json file to your Discord webhook (Webhook tab). The webhook URL itself is not in the file.", Func = function()
    local url = Core.config.webhook and Core.config.webhook.url
    local request = request or http_request or (syn and syn.request)
    if type(url) ~= "string" or not (url:find("^https://discord%.com/api/webhooks/") or url:find("^https://discordapp%.com/api/webhooks/")) then return notify("Set a valid Webhook URL first.") end
    if not request then return notify("This executor has no request function.") end
    local b = "zeno" .. os.time()
    local body = "--" .. b .. "\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n"
        .. HttpService:JSONEncode({ username = "Zeno Hub", content = "Zeno Hub config" })
        .. "\r\n--" .. b .. "\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"zeno_config.json\"\r\nContent-Type: application/json\r\n\r\n"
        .. exportText() .. "\r\n--" .. b .. "--\r\n"
    local ok, res = pcall(request, { Url = url, Method = "POST", Headers = { ["Content-Type"] = "multipart/form-data; boundary=" .. b }, Body = body })
    local code = ok and res and res.StatusCode
    notify(code and code < 300 and "Config sent." or ("Send failed: " .. tostring(code or res)))
end })
cfgBox:AddInput("ImportConfig", { Text = "Import Config", Tooltip = "Paste the config JSON, or a raw / Discord attachment URL, then press Import Config.", Default = "", Placeholder = "JSON or URL" })
function Misc.import(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    Core.log("config import:", #text, "chars")
    if text:find("^https?://") then
        local ok, body = pcall(game.HttpGet, game, text)
        if not ok then return notify("Could not download that URL.") end
        text = body
    end
    local ok, t = pcall(HttpService.JSONDecode, HttpService, text)
    if not ok or type(t) ~= "table" or t.zeno_config ~= 1 or type(t.config) ~= "table" then return notify("That is not a Zeno Hub config.") end
    task.defer(swap, t.config)
end
cfgBox:AddButton({ Text = "Import Config", Tooltip = "Replaces your settings with the pasted config (a backup is kept in hub.backup.json) and reloads the hub. Your webhook URL stays.", DoubleClick = true, Func = function()
    Misc.import(Library.Options.ImportConfig.Value)
end })
function Misc.reset() task.defer(swap, {}) end
cfgBox:AddButton({ Text = "Reset Script Config", Tooltip = "Back to defaults (a backup is kept in hub.backup.json) and reload the hub. Your webhook URL stays.", DoubleClick = true, Func = Misc.reset })

-- Settings > Themes (Obsidian ThemeManager: presets, color editor, save / set as default)
local TM = UI.ThemeManager
if TM then
    local ok, err = pcall(function()
        TM:SetLibrary(Library)
        TM:SetFolder(Core.paths.root .. "/Themes")
        TM:ApplyToTab(Tabs.Settings)
    end)
    if not ok then Core.log("ERROR themes:", err) end
end

return Misc
