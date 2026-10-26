-- Macro player (Macro tab) + status overlay. Plays Nousigi-format JSON (docs/macro-format.md).
-- Options live in Core.config.macro (hub.json) so playback resumes after every teleport.
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local HttpService = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local LP = game:GetService("Players").LocalPlayer
local env = getgenv()

local cfg = Core.config.macro or {}
Core.config.macro = cfg
local defaults = { play = false, retries = 10, overlay = true, maps = {}, ignore_timing = false, sell_timing = true }
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end

local Macro = {}
local TOLERANCE = 3 -- studs (XZ) when matching a step's Pos to a placed unit
local function alive() return env.ZenoHub == Hub end

-- Nousigi step names -> ours (older Zeno recordings use the right-hand names).
local ALIAS = { sell_unit_ingame = "sell_unit", change_priority = "set_target", use_active_attack = "use_ability" }

-- Parse: steps sorted by numeric key (JSON key order is not kept), Time = "<wave> <seconds into wave>".
function Macro.list()
    local names = {}
    for _, f in listfiles(Core.paths.macro) do
        local n = f:match("([^/\\]+)%.json$")
        if n then table.insert(names, n) end
    end
    table.sort(names)
    return names
end

function Macro.load(name)
    local data = HttpService:JSONDecode(readfile(("%s/%s.json"):format(Core.paths.macro, name)))
    local steps = {}
    for k, s in data do
        local w, t = tostring(s.Time or "0 0"):match("(%S+)%s+(%S+)")
        local nums = s.Pos and tostring(s.Pos):split(",")
        for i, v in nums or {} do nums[i] = tonumber(v) end
        table.insert(steps, {
            n = tonumber(k), type = ALIAS[s.Type] or s.Type, unit = s.Unit, id = s.UnitId, key = s.UnitKey,
            priority = s.Prio or s.Priority, value = s.Value, upgrade = tonumber(s.Upgrade),
            wave = tonumber(w) or 0, time = tonumber(t) or 0,
            cf = nums and #nums == 12 and CFrame.new(table.unpack(nums)) or nil,
        })
    end
    table.sort(steps, function(a, b) return a.n < b.n end)
    return steps
end

-- Status overlay: Last / Next / Waiting. Draggable, position saved in cfg.overlay_pos.
local overlay = {}
do
    local gui = Instance.new("ScreenGui")
    gui.Name = "ZenoMacroStatus"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 50
    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(300, 62)
    local p = cfg.overlay_pos
    frame.Position = p and UDim2.fromOffset(p[1], p[2]) or UDim2.new(0.5, -150, 0, 8)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
    frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
    local pad = Instance.new("UIPadding", frame)
    pad.PaddingLeft, pad.PaddingTop = UDim.new(0, 8), UDim.new(0, 4)
    for i, key in { "last", "next", "wait" } do
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, -8, 0, 18)
        l.Position = UDim2.fromOffset(0, (i - 1) * 18)
        l.BackgroundTransparency = 1
        l.Font = Enum.Font.Code
        l.TextSize = 13
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.TextColor3 = i == 3 and Color3.fromRGB(255, 200, 90) or Color3.fromRGB(230, 230, 230)
        l.Parent = frame
        overlay[key] = l
    end
    local dragging, start, origin
    frame.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, start, origin = true, i.Position, frame.AbsolutePosition
        end
    end)
    table.insert(Hub.connections, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - start
            frame.Position = UDim2.fromOffset(origin.X + d.X, origin.Y + d.Y)
        end
    end))
    table.insert(Hub.connections, UIS.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            cfg.overlay_pos = { frame.Position.X.Offset, frame.Position.Y.Offset }
            Core.save_config()
        end
    end))
    gui.Enabled = cfg.overlay
    gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
    overlay.gui = gui
    table.insert(Hub.connections, { Disconnect = function() gui:Destroy() end })
end

local function status(key, text) overlay[key].Text = (key == "wait" and "Waiting: " or key == "last" and "Last: " or "Next: ") .. text end
status("last", "-") status("next", "-") status("wait", Hub.mode == "match" and "idle" or "lobby")

-- UI
local Tabs = Hub.UI and Hub.UI.Tabs
-- LevelData is set a moment after the match loads.
local level
for _ = 1, 30 do
    level = Hub.mode == "match" and Game.loader().LevelData
    if level or Hub.mode ~= "match" then break end
    task.wait(1)
end
local levelId = level and level.id

-- Stage macros, Nousigi layout: cfg.stage[mode][map name] = macro name.
local Worlds, Maps = Game.data("Worlds"), Game.data("Maps")
local function worldNames(kind)
    local out = {}
    for _, id in Game.worlds(kind) do if not table.find(out, Worlds[id].name) then table.insert(out, Worlds[id].name) end end
    return out
end
local function allMaps()
    local out = {}
    for _, m in Maps do if m.name and not table.find(out, m.name) then table.insert(out, m.name) end end
    table.sort(out)
    return out
end
-- shortcut: Infinity Mansion and Daily list every map (no pool data found); narrow if the lists get unwieldy.
local SECTIONS = {
    { mode = "Story", maps = worldNames("story") },
    { mode = "Legend", maps = worldNames("legend") },
    { mode = "Raid", maps = worldNames("raid") },
    { mode = "Infinity Mansion", maps = allMaps() },
    { mode = "Challenge", maps = worldNames("story") },
    { mode = "Daily Challenge", maps = allMaps() },
}
cfg.stage = cfg.stage or {}
for _, sec in SECTIONS do cfg.stage[sec.mode] = cfg.stage[sec.mode] or {} end

-- Mode + map of a match (Game.stage); Infinite story stages use the Story section.
local function stageOf(ld)
    local mode, map = Game.stage(ld)
    return mode == "Infinite" and "Story" or mode, map
end
Macro.stageOf = stageOf

-- One-time move of the old per-level-id choices (cfg.maps) into Story / Legend / Raid by world name.
if cfg.maps then
    local Levels = Game.data("Levels")
    for id, name in cfg.maps do
        local mode, map = stageOf(Levels[id])
        if mode and map and cfg.stage[mode] then cfg.stage[mode][map] = name end
    end
    cfg.maps = nil
    Core.save_config()
end

local options = { stage = {} }
if Tabs then
    local lib = Hub.UI.Library
    local function set(key) return function(v) cfg[key] = v Core.save_config() end end
    local function withNone()
        local n = Macro.list()
        table.insert(n, 1, "None")
        return n
    end
    local function refresh()
        options.file:SetValues(Macro.list())
        local n = withNone()
        for _, d in options.stage do d:SetValues(n) end
    end

    local manage = Tabs.Macro:AddLeftGroupbox("Manage", "folder")
    options.file = manage:AddDropdown("MacroRecordFile", { Text = "Select Macro", Values = Macro.list(), AllowNull = true })
    manage:AddInput("MacroNewName", { Text = "Create Macro", Default = "", Placeholder = "name, then Enter", Finished = true, Callback = function(v)
        local n = (v or ""):gsub("[\\/:*?\"<>|]", ""):match("^%s*(.-)%s*$")
        if n == "" then return end
        if #n > 26 then lib:Notify("Name must be 1 to 26 characters") return end
        local path = ("%s/%s.json"):format(Core.paths.macro, n)
        if isfile(path) then lib:Notify(n .. " already exists") else writefile(path, "{}") end
        refresh()
        options.file:SetValue(n)
    end })
    manage:AddButton({ Text = "Delete Selected Macro", DoubleClick = true, Func = function()
        local n = options.file.Value
        if not n then lib:Notify("Select a macro first") return end
        delfile(("%s/%s.json"):format(Core.paths.macro, n))
        for _, maps in cfg.stage do for map, m in maps do if m == n then maps[map] = nil end end end
        Core.save_config()
        options.file:SetValue(nil)
        refresh()
        lib:Notify("Deleted " .. n)
    end })
    manage:AddButton("Refresh list", refresh)

    local main = Tabs.Macro:AddLeftGroupbox("Macro", "play")
    main:AddToggle("MacroPlay", { Text = "Play Macro", Default = cfg.play, Callback = function(v)
        set("play")(v)
        if v and Macro.start then Macro.start() end
    end })
    options.record = main:AddToggle("MacroRecord", { Text = "Record Macro", Default = false, Callback = function(v)
        if Macro.record then Macro.record(v) elseif v then lib:Notify("Record inside a match") end
    end })
    main:AddLabel("Records into Select Macro: place, upgrade, sell, target, ability, wave skip. Stops and saves at match end.", true)

    local conf = Tabs.Macro:AddRightGroupbox("Play Macro Config", "sliders-horizontal")
    conf:AddToggle("MacroIgnoreTiming", { Text = "Ignore Macro Timing", Tooltip = "Run each step as soon as its wave is reached and it is affordable; recorded wave skips are not sent.", Default = cfg.ignore_timing, Callback = set("ignore_timing") })
    conf:AddToggle("MacroSellTiming", { Text = "No Ignore Sell Timing", Tooltip = "Keep the recorded seconds for sell steps even with Ignore Macro Timing on.", Default = cfg.sell_timing, Callback = set("sell_timing") })
    conf:AddSlider("MacroRetries", { Text = "Macro Retry Limit", Tooltip = "Failed tries before a step is skipped. 0 = never skip.", Default = cfg.retries, Min = 0, Max = 100, Rounding = 0, Callback = set("retries") })
    conf:AddToggle("MacroOverlay", { Text = "Show status bar", Default = cfg.overlay, Callback = function(v)
        set("overlay")(v)
        overlay.gui.Enabled = v
    end })

    local info = Tabs.Macro:AddRightGroupbox("Information", "info")
    local cur = Hub.mode == "match" and { stageOf(level) } or {}
    info:AddLabel(cur[1] and ("This match: %s, %s"):format(cur[1], tostring(cur[2])) or "Pick a macro per map below; it plays whenever that mode and map loads.", true)
    local names = withNone()
    for _, sec in SECTIONS do
        local box = Tabs.Macro:AddRightGroupbox(("Select %s Macro"):format(sec.mode), "map")
        local mine, drops = cfg.stage[sec.mode], {}
        for _, map in sec.maps do
            local key = ("Stage_%s_%s"):format(sec.mode, map):gsub("%W", "_")
            local d = box:AddDropdown(key, { Text = map, Values = names, Default = mine[map] or "None", Callback = function(v)
                mine[map] = v ~= "None" and v or nil
                Core.save_config()
            end })
            table.insert(options.stage, d)
            table.insert(drops, d)
        end
        box:AddButton(("Clear %s Macros"):format(sec.mode), function()
            for _, d in drops do d:SetValue("None") end
        end)
    end
end

if Hub.mode ~= "match" then return Macro end

-- Wave clock: Nousigi times are seconds since the wave started. Loaded mid-wave, the clock starts at load.
local waveVal = workspace:WaitForChild("_wave_num")
local waveStart = os.clock()
table.insert(Hub.connections, waveVal.Changed:Connect(function() waveStart = os.clock() end))

local defs = Game.data("Units")
local function hotbar()
    local gs = Game.loader().load_client_service(script, "GUIService")
    local col = gs.session.collection.collection_profile_data
    local byName = {}
    for _, uuid in col.equipped_units do
        local u = col.owned_units[uuid]
        local d = u and defs[u.unit_id]
        if d then byName[d.name] = { uuid = uuid, id = u.unit_id, def = d } byName[u.unit_id] = byName[d.name] end
    end
    return byName
end

local function costScale()
    local m = workspace:FindFirstChild("_DATA") and workspace._DATA:FindFirstChild("LevelModifiers")
    local v = m and m:FindFirstChild("player_cost_scale")
    return v and v.Value or 1
end

local function unitAt(cf, tol, id)
    local best, bestD
    for _, u in workspace._UNITS:GetChildren() do
        local s = u:FindFirstChild("_stats")
        if s and s:FindFirstChild("player") and s.player.Value == LP and (not id or s.id.Value == id) then
            local p = u:GetPivot().Position
            local d = Vector2.new(p.X - cf.X, p.Z - cf.Z).Magnitude
            if d <= (tol or TOLERANCE) and (not bestD or d < bestD) then best, bestD = u, d end
        end
    end
    return best
end

local function describe(s)
    if not s then return "done" end
    return ("#%d %s%s (w%d %.0fs)"):format(s.n, s.type, s.unit and (" " .. s.unit) or "", s.wave, s.time)
end

-- One attempt. Returns "ok", "skip" (cannot ever succeed) or "fail"; waits for money itself.
local actions = {}
local function waitMoney(cost, run)
    while run.live() do
        local money = LP._stats.resource.Value
        if money >= cost then return true end
        status("wait", ("money %d / %d"):format(money, cost))
        task.wait(0.25)
    end
end
-- The unit a step acts on: the model its UnitKey's spawn step placed, else ours nearest Pos (same id if known).
local function target(s, run)
    local u = s.key and run.keys[s.key]
    if u and u.Parent == workspace._UNITS then return u end
    return s.cf and unitAt(s.cf, nil, s.id)
end
function actions.spawn_unit(s, run)
    local h = run.hotbar[s.id or ""] or run.hotbar[s.unit or ""]
    if not h then return "skip", "unit not on hotbar" end
    if not s.cf then return "skip", "no Pos" end
    -- Already standing there (hub reloaded or started mid-match): take it over instead of placing again.
    local here = unitAt(s.cf, 1.5, h.id)
    if here and not table.find(run.taken, here) then
        table.insert(run.taken, here)
        if s.key then run.keys[s.key] = here end
        return "ok"
    end
    if not waitMoney(h.def.cost * costScale(), run) then return "fail" end
    if Game.invoke("spawn_unit", h.uuid, s.cf) ~= true then return "fail" end
    if s.key then
        for _ = 1, 10 do
            local u = unitAt(s.cf, 0.5, h.id)
            if u then run.keys[s.key] = u table.insert(run.taken, u) break end
            task.wait(0.1)
        end
    end
    return "ok"
end
function actions.upgrade_unit_ingame(s, run)
    local u = target(s, run)
    if not u then return "fail", "no unit at Pos" end
    local st = u._stats
    if s.upgrade and st.upgrade.Value >= s.upgrade then return "ok" end -- already at the recorded level
    if st.upgrade.Value >= st.max_upgrade.Value then return "skip", "already max" end
    local up = defs[st.id.Value] and defs[st.id.Value].upgrade
    local nextUp = up and up[st.upgrade.Value + 1]
    if nextUp and not waitMoney(nextUp.cost * costScale(), run) then return "fail" end
    return Game.invoke("upgrade_unit_ingame", u) == true and "ok" or "fail"
end
function actions.sell_unit(s, run)
    local u = target(s, run)
    if not u then return "fail", "no unit at Pos" end
    local d = defs[u._stats.id.Value]
    if d and d.unsellable then return "skip", "unsellable" end
    return Game.invoke("sell_unit_ingame", u) == true and "ok" or "fail"
end
function actions.set_target(s, run)
    local u = target(s, run)
    if not u then return "fail", "no unit at Pos" end
    if not s.priority then return "skip", "no Priority" end
    Game.invoke("change_priority", u, s.priority)
    return u._stats.priority.Value == s.priority and "ok" or "fail"
end
function actions.use_ability(s, run)
    local u = target(s, run)
    if not u then return "fail", "no unit at Pos" end
    if Hub.Abilities and Hub.Abilities.handles(u) then return "ok" end -- Smart Auto Ability casts this unit
    -- Like money, a cooldown is a wait, not a failure. last_active_cast is on the tick() clock (verified).
    local st = u._stats
    local last, cd = st:FindFirstChild("last_active_cast"), st:FindFirstChild("active_attack_cooldown")
    while last and cd and run.live() and u.Parent == workspace._UNITS and tick() < last.Value + cd.Value do
        status("wait", ("ability cooldown %.0fs"):format(last.Value + cd.Value - tick()))
        task.wait(0.25)
    end
    return Game.invoke("use_active_attack", u) == true and "ok" or "fail"
end
-- Our extension: the auto loop in Macro.start casts for units whose toggle is on (setting the attribute does not).
function actions.toggle_auto_ability(s, run)
    local u = target(s, run)
    if not u then return "fail", "no unit at Pos" end
    if Hub.Abilities and Hub.Abilities.handles(u) then return "ok" end -- Smart Auto Ability casts this unit
    run.auto[u] = s.value == true or nil
    return "ok"
end
function actions.vote_wave_skip()
    Game.invoke("vote_wave_skip")
    return "ok"
end

local runId = 0
function Macro.stop() runId += 1 status("wait", "stopped") end

function Macro.start()
    local mode, map = stageOf(level)
    local name = mode and cfg.stage[mode] and cfg.stage[mode][map]
    if not name then status("wait", ("no macro for %s, %s"):format(tostring(mode), tostring(map))) return end
    runId += 1
    local myId = runId
    local run = { keys = {}, dead = {}, auto = {}, taken = {}, live = function() return alive() and cfg.play and runId == myId end }
    task.spawn(function()
        local ok, steps = pcall(Macro.load, name)
        if not ok then Core.log("ERROR macro load", name, steps) status("wait", "cannot read " .. name) return end
        -- The GUIService session appears a few seconds after the match loads.
        local hok, hb
        for _ = 1, 30 do
            hok, hb = pcall(hotbar)
            if hok or not run.live() then break end
            status("wait", "hotbar")
            task.wait(1)
        end
        if not hok then Core.log("ERROR macro hotbar", hb) status("wait", "hotbar unreadable") return end
        run.hotbar = hb
        Core.log("macro start", name, #steps, "steps", mode, map)
        task.spawn(function()
            while run.live() do
                for u in run.auto do
                    local st = u.Parent == workspace._UNITS and u._stats
                    local last, cd = st and st:FindFirstChild("last_active_cast"), st and st:FindFirstChild("active_attack_cooldown")
                    if not st then run.auto[u] = nil
                    elseif last and cd and tick() >= last.Value + cd.Value then pcall(Game.invoke, "use_active_attack", u) end
                end
                task.wait(0.5)
            end
        end)
        local i = 1
        while run.live() and i <= #steps do
            local s = steps[i]
            status("next", describe(s))
            local wave = waveVal.Value
            local timed = not cfg.ignore_timing or (s.type == "sell_unit" and cfg.sell_timing)
            if cfg.ignore_timing and s.type == "vote_wave_skip" then
                -- Nousigi does not replay recorded wave skips with timing ignored.
                i += 1
                continue
            end
            if wave < s.wave or (timed and wave == s.wave and os.clock() - waveStart < s.time) then
                status("wait", timed and ("wave %d %.0fs -> %d %.0fs"):format(wave, os.clock() - waveStart, s.wave, s.time)
                    or ("wave %d -> %d"):format(wave, s.wave))
                task.wait(0.2)
                continue
            end
            local fn = actions[s.type]
            local res, why, tries = nil, nil, 0
            if not fn then res, why = "skip", "unknown type" end
            if s.type ~= "spawn_unit" and s.key and run.dead[s.key] then res, why = "skip", "its spawn step was skipped" end
            while not res and run.live() do
                local pok, r, w = pcall(fn, s, run)
                if not pok then r, w = "fail", r end
                if r ~= "fail" then res, why = r, w break end
                tries += 1
                local limit = cfg.retries == 0 and math.huge or cfg.retries
                if tries >= limit then res, why = "skip", ("failed %d times%s"):format(tries, w and (": " .. tostring(w)) or "") break end
                status("wait", ("retry %d%s"):format(tries, w and (" (" .. tostring(w) .. ")") or ""))
                task.wait(1)
            end
            if not res then break end
            if res == "skip" then
                Core.log("macro skip", describe(s), why)
                if s.type == "spawn_unit" and s.key then run.dead[s.key] = true end
            end
            status("last", describe(s) .. (res == "skip" and " SKIPPED" or ""))
            i += 1
            task.wait(0.2) -- Nousigi's minimum gap between steps
        end
        if run.live() then status("next", "done") status("wait", "-") Core.log("macro finished", name) end
    end)
end

-- Recorder: hooks the game's own InvokeServer calls (checkcaller() is false for them), so only the
-- player's clicks are recorded, not the hub's auto wave skip or playback. Each step is saved as it lands.
local recording -- { name, steps, keys = {[model] = "p<n>"}, n, t0, hotbar, conns }
local function save()
    local out = {}
    for i, s in recording.steps do out[tostring(i)] = s end
    writefile(("%s/%s.json"):format(Core.paths.macro, recording.name), HttpService:JSONEncode(out))
end
-- `at` is the moment of the click (taken before the handler waits for confirmation).
local function now()
    return { time = ("%d %s"):format(waveVal.Value, tostring(os.clock() - waveStart)), elapsed = os.clock() - recording.t0 }
end
local function addStep(s, at)
    if not recording then return end
    at = at or now()
    s.Time, s.Elapsed, s.Clock = at.time, at.elapsed, "Wave"
    table.insert(recording.steps, s)
    pcall(save)
    status("last", ("rec #%d %s%s"):format(#recording.steps, s.Type, s.Unit and (" " .. s.Unit) or ""))
end
local function mine(u) return typeof(u) == "Instance" and u:FindFirstChild("_stats") and u._stats:FindFirstChild("player") and u._stats.player.Value == LP end

-- Nousigi step for a placed unit. UnitKey = p1, p2 ... in the order units are first seen by this recording.
local unitStep
local function keyOf(u)
    local k = recording.keys[u]
    if k then return k end
    recording.n += 1
    k = "p" .. recording.n
    recording.keys[u] = k
    -- In-game auto ability: one toggle step instead of every automatic cast (attribute set by the game's panel).
    table.insert(recording.conns, u:GetAttributeChangedSignal("_auto_active"):Connect(function()
        if recording and u.Parent == workspace._UNITS then
            addStep(unitStep(u, "toggle_auto_ability", { Value = u:GetAttribute("_auto_active") == true }))
        end
    end))
    return k
end
function unitStep(u, type, extra)
    local id = u._stats.id.Value
    local s = { Type = type, Unit = defs[id] and defs[id].name or id, UnitId = id, UnitKey = keyOf(u), Pos = tostring(u:GetPivot()) }
    for k, v in extra or {} do s[k] = v end
    return s
end

-- Each handler gets the call args and confirms the action took effect before recording it.
local recorders = {}
function recorders.spawn_unit(at, uuid, cf)
    if typeof(cf) ~= "CFrame" then return end
    for _ = 1, 20 do
        task.wait(0.1)
        local u = unitAt(cf, 0.5)
        if u and u._stats.upgrade.Value == 0 and not recording.keys[u] then
            return addStep(unitStep(u, "spawn_unit", { Pos = tostring(cf) }), at)
        end
    end
end
function recorders.upgrade_unit_ingame(at, u)
    if not mine(u) then return end
    local before = u._stats.upgrade.Value
    for _ = 1, 20 do
        task.wait(0.1)
        local lvl = u._stats.upgrade.Value
        if lvl > before then
            -- Spam clicks: pending handlers share level changes; one step per level gained, each level once.
            local from = math.max(recording.levels[u] or before, before)
            recording.levels[u] = math.max(lvl, recording.levels[u] or 0)
            for l = from + 1, lvl do addStep(unitStep(u, "upgrade_unit_ingame", { Upgrade = l }), at) end
            return
        end
    end
end
function recorders.sell_unit_ingame(at, u)
    if not mine(u) then return end
    local step = unitStep(u, "sell_unit_ingame")
    for _ = 1, 20 do
        task.wait(0.1)
        if u.Parent ~= workspace._UNITS then return addStep(step, at) end
    end
end
function recorders.change_priority(at, u, priority)
    if not mine(u) then return end
    task.wait(0.5)
    if u._stats.priority.Value == priority then addStep(unitStep(u, "change_priority", { Prio = priority }), at) end
end
function recorders.use_active_attack(at, u)
    if not mine(u) or u:GetAttribute("_auto_active") then return end -- automatic casts come from the toggle step
    local st = u._stats
    local last = st:FindFirstChild("last_active_cast")
    local before = last and last.Value
    for _ = 1, 10 do
        task.wait(0.1)
        -- Only casts that happened (a click on cooldown does nothing).
        if not last or last.Value ~= before then
            local aid = st:FindFirstChild("active_attack")
            return addStep(unitStep(u, "use_active_attack", { ActiveId = aid and aid.Value or nil }), at)
        end
    end
end
function recorders.vote_wave_skip(at) addStep({ Type = "vote_wave_skip" }, at) end

local c2s = game:GetService("ReplicatedStorage"):WaitForChild("endpoints"):WaitForChild("client_to_server")
local watched = {}
for name in recorders do watched[c2s:WaitForChild(name, 10) or name] = name end

-- The current hub's handler; the hook below calls it and outlives reloads.
env.ZenoRecordHandler = function(self, ...)
    if not (recording and alive() and watched[self]) then return end
    local fn, args, at = recorders[watched[self]], table.pack(...), now()
    task.spawn(function()
        -- The hook runs on the game's thread (identity 2), which cannot touch some instances; raise it.
        setthreadidentity(8)
        local ok, err = pcall(fn, at, table.unpack(args, 1, args.n))
        if not ok then Core.log("ERROR macro record", watched[self], err) end
    end)
end
-- Installed once per server, on the first Record. Installed at match load (before the game's client
-- starts) a plain Lua hook broke the game's own InvokeServer returns, so it is a cclosure and lazy.
local function installHook()
    if env.ZenoRecordHook then return end
    env.ZenoRecordHook = true
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if not checkcaller() and getnamecallmethod() == "InvokeServer" and env.ZenoRecordHandler then
            pcall(env.ZenoRecordHandler, self, ...)
        end
        return old(self, ...)
    end))
end

function Macro.record(on)
    if not on then
        if recording then
            pcall(save)
            for _, c in recording.conns do c:Disconnect() end
            Core.log("macro recorded", recording.name, #recording.steps, "steps")
            status("wait", ("recorded %d steps into %s"):format(#recording.steps, recording.name))
            recording = nil
        end
        return
    end
    local name = options.file and options.file.Value
    local lib = Hub.UI.Library
    if not name then lib:Notify("Pick or create a macro first") options.record:SetValue(false) return end
    -- Overwrite warning: a non-empty file needs a second toggle within 10 s.
    local ok, steps = pcall(Macro.load, name)
    if ok and #steps > 0 and Macro.confirm ~= name then
        Macro.confirm = name
        task.delay(10, function() if Macro.confirm == name then Macro.confirm = nil end end)
        lib:Notify(("%s has %d steps. Toggle Record again within 10 s to overwrite."):format(name, #steps), 8)
        options.record:SetValue(false)
        return
    end
    Macro.confirm = nil
    local hok, hb = pcall(hotbar)
    if not hok then lib:Notify("Cannot read the hotbar") options.record:SetValue(false) return end
    installHook()
    recording = { name = name, steps = {}, keys = {}, levels = {}, n = 0, t0 = os.clock(), hotbar = hb, conns = {} }
    pcall(save)
    local placed = 0
    for _, u in workspace._UNITS:GetChildren() do if mine(u) then placed += 1 end end
    if placed > 0 then lib:Notify(("%d units were placed before recording: their steps replay by position only."):format(placed), 8) end
    Core.log("macro record start", name, levelId)
    status("wait", "recording into " .. name)
end

-- Stop at match end; start once the hub is loaded in a match with a macro set for this map.
table.insert(Hub.connections, game:GetService("ReplicatedStorage"):WaitForChild("endpoints")
    :WaitForChild("server_to_client"):WaitForChild("game_finished").OnClientEvent:Connect(function()
        Macro.stop()
        if recording then Macro.record(false) if options.record then options.record:SetValue(false) end end
    end))
if cfg.play then Macro.start() end

return Macro
