-- Phoenix (Mythic Flames, `marco_evolved`) Reincarnation: selling him at max upgrade gives +50% attack on units placed after the sale (docs/features/phoenix.md).
-- This module only sells; Auto Play places him again and upgrades him to max. The first sale (a Phoenix at max upgrade) unlocks the bonus (a second
-- sale gives none, user-confirmed); then every other Phoenix is sold one at a time so it is placed again with the bonus.
-- Our own re-placing on the exact spot was tried and dropped (the server refused the unit's pivot position, 2026-11-17).
local Hub = ...
local Core, Game = Hub.Core, Hub.Game
local LP = game:GetService("Players").LocalPlayer
local env = getgenv()

local cfg = Core.config.phoenix or {}
Core.config.phoenix = cfg
if cfg.enable == nil then cfg.enable = false end
cfg.max, cfg.others, cfg.others_max = nil, nil, nil -- sliders / toggles of earlier builds

local Phoenix = {}
local ID = "marco_evolved"
local function alive() return env.ZenoHub == Hub end

local Tabs = Hub.UI and Hub.UI.Tabs
if Tabs then
    local box = (Hub.Units and Hub.Units.box(ID)) or Tabs.Game:AddRightGroupbox("Phoenix", "flame") -- his page in the Units tab (docs/features/units-tab.md)
    box:AddToggle("PhoenixReincarnate", { Text = "Sell Phoenix at Max", Tooltip = "Sells a Phoenix (Mythic Flames) when he is fully upgraded: his Reincarnation gives +50% attack to every Phoenix placed after that sale. Then sells all your other Phoenixes one at a time (lowest upgrade first), so each comes back with the bonus. A sale refunds about 25% of what the unit cost, so the money is gone. Auto Play places them again and upgrades them (Auto Play on, Phoenix on the hotbar, his Upgrade Cap at max). Not while a stage macro plays.", Default = cfg.enable, Callback = function(v) cfg.enable = v Core.save_config() end })
end

if Hub.mode ~= "match" then return Phoenix end

-- One line of what decides his damage. `_buffs` lists every buff the game knows (a NumberValue each, 0 = off), so only non-zero ones are named;
-- `marco_reincarnate` is the Reincarnation counter (1 on a unit placed after the first sale, verified 2026-11-17).
local STATS = { "damage", "base_damage", "damage_multiplier", "buff_damage_multiplier", "buff_multiplier" }
local function snap(u)
    local st, parts, active = u._stats, {}, {}
    for _, name in STATS do local v = st:FindFirstChild(name) parts[#parts + 1] = ("%s %s"):format(name, v and tostring(v.Value) or "-") end
    local b = u:FindFirstChild("_buffs") or st:FindFirstChild("_buffs")
    for _, v in b and b:GetChildren() or {} do
        if v:IsA("ValueBase") and v.Value ~= 0 and v.Value ~= false and v.Value ~= "" and v.Name ~= "marco_reincarnate" then active[#active + 1] = v.Name .. "=" .. tostring(v.Value) end
    end
    local rc = b and b:FindFirstChild("marco_reincarnate")
    return ("up %s/%s | %s | reincarnate %s | active [%s]"):format(st.upgrade.Value, st.max_upgrade.Value, table.concat(parts, ", "), rc and tostring(rc.Value) or "-", table.concat(active, ", "))
end
local function log(...) Core.log("phoenix", ...) end

local sold, seen, blocked, pendingCount, pendingAt = 0, {}, false, nil, 0
table.insert(Hub.connections, { Disconnect = Core.on("game_finished", function() sold, seen, blocked, pendingCount = 0, {}, false, nil end) })

local function mine()
    local out, folder = {}, workspace:FindFirstChild("_UNITS")
    for _, u in folder and folder:GetChildren() or {} do
        local st = u:FindFirstChild("_stats")
        local owner = st and st:FindFirstChild("player")
        if owner and owner.Value == LP and st:FindFirstChild("id") and st.id.Value == ID then table.insert(out, u) end
    end
    return out
end

local function reinc(u) -- Reincarnation counter (0 = placed before the first sale)
    local b = u:FindFirstChild("_buffs") and u._buffs:FindFirstChild("marco_reincarnate")
    return b and b.Value or 0
end

local function readyToSell()
    if not cfg.enable or blocked then return false end
    local ap = Core.config.autoplay
    if not (ap and ap.enable) or (Hub.AutoPlay and Hub.AutoPlay.macroOwns()) then return false end -- nobody would place him again
    local finished = workspace:FindFirstChild("_DATA") and workspace._DATA:FindFirstChild("GameFinished")
    if finished and finished.Value then return false end
    local last = workspace:FindFirstChild("_is_last_wave")
    return not (last and last.Value) -- a sale on the last wave only loses the unit
end

task.spawn(function()
    while alive() do
        local ok, err = pcall(function()
            local list, bonus, pick = mine(), false, nil
            for _, u in list do
                if not seen[u] then -- a Phoenix we have not looked at yet: log it once its stats settled
                    seen[u] = true
                    task.delay(2, function() if u.Parent then log(("new after %d sales | wave %d | %s"):format(sold, workspace._wave_num.Value, snap(u))) end end)
                end
                local st = u._stats
                local lvl, max = st.upgrade.Value, st.max_upgrade.Value
                if reinc(u) > 0 then bonus = true
                elseif sold == 0 then -- the first sale has to be a Phoenix at max upgrade: it unlocks the bonus for the ones placed after it
                    if max > 0 and lvl >= max then pick = u end
                elseif not pick or lvl < pick._stats.upgrade.Value then pick = u end -- then all the others, lowest upgrade first (cheapest to lose)
            end
            -- After a sale wait until Auto Play has placed him again (or 30 s): selling the next one earlier could leave the team without Phoenix.
            local waiting = pendingCount and #list < pendingCount
            if waiting and os.clock() - pendingAt >= 30 then blocked, waiting = true, false log("Auto Play did not place him again in 30 s: stopping") end
            if not waiting then pendingCount = nil end
            if pick and not waiting and (sold == 0 or bonus) and readyToSell() then
                local st = pick._stats
                local before, money = snap(pick), LP._stats.resource.Value
                local res = Game.invoke("sell_unit_ingame", pick)
                if res == true then
                    sold += 1
                    pendingCount, pendingAt = #list, os.clock()
                    log(("sold #%d | wave %d | money %.0f | spent %s | %s"):format(sold, workspace._wave_num.Value, money, tostring(st.total_spent and st.total_spent.Value), before))
                else
                    blocked = true -- refused (unsellable, bad state): do not hammer the server, try again next match
                    log("sell refused:", tostring(res))
                end
            end
        end)
        if not ok then Core.log("ERROR phoenix", err) task.wait(3) end
        task.wait(0.5)
    end
end)

return Phoenix
