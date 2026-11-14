-- Misc and Settings tabs (docs/features/misc-settings.md): Teleport to Lobby if Players Join, Walk To Units,
-- UI control, failsafe (auto rejoin), script config export / import / reset, themes, information.
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
local defaults = { lobby_on_join = false, walk_units = false, ui_key = "RightControl", ui_button = false, auto_rejoin = true,
    leave_idle = false, idle_secs = 120, leave_weak = false, weak_dmg = 0, weak_wave = 24 }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end
-- Walk Around and Rejoin Ping Freeze were removed 2026-11-10 (Walk To Units covers the first, the second never fired in the logs).
cfg.walk, cfg.ping_freeze = nil, nil

local function alive() return env.ZenoHub == Hub end
local Misc = {}

-- Safe mode: when the UI library did not load, this file used to stop here, before the rejoin, the error-prompt rejoin and the ping-freeze check
-- (so a UI failure also removed every recovery path, and the watchdog's Hub.Misc.rejoin was nil). Without a UI every Add* call below lands on a
-- stub that swallows it, and the code in between still runs.
local UI = Hub.UI
local stub
stub = setmetatable({}, { __index = function() return stub end, __call = function() return stub end })
local Library, Tabs = UI and UI.Library or stub, UI and UI.Tabs or stub
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

-- A name token matches a player by (the start of) their user name or display name.
local function matches(p, token)
    token = token:lower()
    return p.Name:lower():sub(1, #token) == token or p.DisplayName:lower():sub(1, #token) == token
end
local function exempt(p)
    local names = (Core.config.party and Core.config.party.names) or ""
    for token in names:gmatch("[^,;%s]+") do
        if matches(p, token) then return true end
    end
    return false
end

-- Player protection (competitor parity, 2026-11-10): the first listed name that is not in this server yet, or nil.
-- Lobby.hold (src/lobby.lua) holds the joiners and the Summer Hunt while this returns one.
function Misc.missing_players()
    for token in (cfg.wait_names or ""):gmatch("[^,;%s]+") do
        local here = false
        for _, p in Players:GetPlayers() do
            if p ~= LP and matches(p, token) then here = true break end
        end
        if not here then return token end
    end
end
players:AddInput("WaitNames", { Text = "Hold Joins until Here", Tooltip = "Names (separated by commas) of players who must be in your lobby server before any joiner runs. Empty = off. The start of a name is enough.", Default = cfg.wait_names or "", Placeholder = "name1, name2", Callback = function(v) cfg.wait_names = v Core.save_config() end })

-- Hide Other Players: only on your screen. Their characters are made invisible again every 2 s (accessories load late); off shows them at once.
players:AddToggle("HideOthers", { Text = "Hide Other Players", Tooltip = "Only on your screen. Turn off to show them again.", Default = cfg.hide_others, Callback = set("hide_others") })
local function hideChar(char, on)
    for _, d in char:GetDescendants() do
        if d:IsA("BasePart") then d.LocalTransparencyModifier = on and 1 or 0 end
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then hum.DisplayDistanceType = on and Enum.HumanoidDisplayDistanceType.None or Enum.HumanoidDisplayDistanceType.Viewer end
end
task.spawn(function()
    local was = false
    while alive() do
        if cfg.hide_others or was then
            for _, p in Players:GetPlayers() do
                if p ~= LP and p.Character then pcall(hideChar, p.Character, cfg.hide_others) end
            end
            was = cfg.hide_others
        end
        task.wait(2)
    end
end)

-- Leave if I Deal No Damage / Leave on Weak Teammates (competitor parity, 2026-11-10). Every player carries a `_stats.damage_dealt`
-- NumberValue (checked live on our own player, lobby; other players' copies UNVERIFIED). The level check of the competitor is not built.
if MATCH then
    task.spawn(function()
        local lastDmg, lastMove = nil, os.clock()
        while alive() do
            task.wait(2)
            local data = workspace:FindFirstChild("_DATA")
            local started, fin = data and data:FindFirstChild("GameStarted"), data and data:FindFirstChild("GameFinished")
            local wave = workspace:FindFirstChild("_wave_num")
            if leaving or not (started and fin and wave) then continue end
            local mine = LP:FindFirstChild("_stats") and LP._stats:FindFirstChild("damage_dealt")
            if not (started.Value and not fin.Value and wave.Value >= 1 and mine) then
                lastMove = os.clock() -- the clock starts at wave 1
            else
                if mine.Value ~= lastDmg then lastDmg, lastMove = mine.Value, os.clock() end
                if cfg.leave_idle and os.clock() - lastMove >= cfg.idle_secs then
                    Misc.rejoin(("no damage for %d s"):format(cfg.idle_secs))
                elseif cfg.leave_weak and wave.Value >= cfg.weak_wave then
                    for _, p in Players:GetPlayers() do
                        local d = p ~= LP and not exempt(p) and p:FindFirstChild("_stats") and p._stats:FindFirstChild("damage_dealt")
                        if d and d.Value <= cfg.weak_dmg then
                            Misc.rejoin(("%s dealt %d damage by wave %d"):format(p.Name, d.Value, wave.Value))
                            break
                        end
                    end
                end
            end
        end
    end)
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

-- Misc > Secure: Walk To Units (the box is made by src/match.lua next to Anti-AFK)
local secure = Hub.SecureBox
-- Walk To Units (user, 2026-11-03): Auto Play calls Misc.walkTo(position) after it places or upgrades a unit; the character walks next to it.
function Misc.walkTo(pos)
    if not (MATCH and cfg.walk_units) then return end
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if not (hum and hum.Health > 0) then return end
    pcall(hum.MoveTo, hum, pos + Vector3.new(3, 0, 3))
end
if secure then
    secure:AddToggle("WalkToUnits", { Text = "Walk To Units", Tooltip = "Match only: the character walks to the unit Auto Play just placed or upgraded.", Default = cfg.walk_units, Callback = set("walk_units") })
    local idleSecs, weakDmg, weakWave
    local function showIdle(on) if idleSecs then idleSecs:SetVisible(on) end end
    local function showWeak(on) if weakDmg then weakDmg:SetVisible(on) weakWave:SetVisible(on) end end
    secure:AddToggle("LeaveIdle", { Text = "Leave if I Deal No Damage", Tooltip = "Match only. Goes back to the lobby when your units have dealt no damage for the time below (counted from wave 1), so an idle account is not banned for being idle. Leave it off for teams that only farm or buff.", Default = cfg.leave_idle, Callback = function(v) cfg.leave_idle = v Core.save_config() showIdle(v) end })
    idleSecs = secure:AddSlider("IdleSecs", { Text = "No Damage for (s)", Default = cfg.idle_secs, Min = 30, Max = 600, Rounding = 0, Callback = set("idle_secs") })
    secure:AddToggle("LeaveWeak", { Text = "Leave on Weak Teammates", Tooltip = "Match only, other players only. Goes back to the lobby when a teammate (not one listed in Joiner > Party Player) has dealt no more than the damage below by the wave below.", Default = cfg.leave_weak, Callback = function(v) cfg.leave_weak = v Core.save_config() showWeak(v) end })
    weakDmg = secure:AddSlider("WeakDmg", { Text = "Teammate Damage at most", Default = cfg.weak_dmg, Min = 0, Max = 100000, Rounding = 0, Callback = set("weak_dmg") })
    weakWave = secure:AddSlider("WeakWave", { Text = "Check from Wave", Default = cfg.weak_wave, Min = 1, Max = 100, Rounding = 0, Callback = set("weak_wave") })
    showIdle(cfg.leave_idle)
    showWeak(cfg.leave_weak)
end

-- Settings > Information
local info = Tabs.Settings:AddLeftGroupbox("Information", "info")
info:AddLabel("Zeno Hub | Anime Adventures", true)
info:AddLabel(("Version: %s"):format(Hub.version ~= "" and Hub.version or "hosted build"), true)
info:AddLabel("Auto Execute on Teleport: always on (the hub queues itself before every teleport).", true)
info:AddLabel(("Log files: workspace/%s"):format(tostring(Core.paths.logs)), true)

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
ui:AddButton({ Text = "Unload Hub (double-click)", Risky = true, Tooltip = "Stops every loop and removes this window until the next teleport or run.", DoubleClick = true, Func = function() Hub.unload() end })

-- Settings > Failsafe
local fs = Tabs.Settings:AddLeftGroupbox("Failsafe", "life-buoy")
fs:AddToggle("AutoRejoin", { Text = "Auto Rejoin", Tooltip = "If you get kicked or disconnected, teleport back to the lobby. Only works while the script is running in the game; it cannot reopen a closed Roblox client.", Default = cfg.auto_rejoin, Callback = set("auto_rejoin") })
table.insert(Hub.connections, GuiService.ErrorMessageChanged:Connect(function()
    local msg = GuiService:GetErrorMessage()
    if cfg.auto_rejoin and msg ~= "" then
        Core.log("error prompt:", msg)
        task.delay(3, Misc.rejoin, "error prompt: " .. msg)
    end
end))

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
cfgBox:AddButton({ Text = "Import Config (double-click)", Risky = true, Tooltip = "Replaces your settings with the pasted config (a backup is kept in hub.backup.json) and reloads the hub. Your webhook URL stays.", DoubleClick = true, Func = function()
    Misc.import(Library.Options.ImportConfig.Value)
end })
function Misc.reset() task.defer(swap, {}) end
cfgBox:AddButton({ Text = "Reset Script Config (double-click)", Risky = true, Tooltip = "Back to defaults (a backup is kept in hub.backup.json) and reload the hub. Your webhook URL stays.", DoubleClick = true, Func = Misc.reset })

-- Settings > Themes (Obsidian ThemeManager: presets, color editor, save / set as default)
local TM = UI and UI.ThemeManager
if TM then
    local ok, err = pcall(function()
        TM:SetLibrary(Library)
        TM:SetFolder(Core.paths.root .. "/Themes")
        TM:ApplyToTab(Tabs.Settings)
    end)
    if not ok then Core.log("ERROR themes:", err) end
end

return Misc
