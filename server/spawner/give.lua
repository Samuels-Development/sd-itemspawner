---@type table sd-itemspawner config root (configs/config.lua).
local config = require 'configs.config'
---@type table Console log helper (shared.log): tagged colour-coded prints.
local log = require 'shared.log'
---@type table Audit trail (server.spawner.audit): ox_lib logger + console lines.
local audit = require 'server.spawner.audit'

---@type table Server-only security policy (configs/server/security.lua).
local SEC = config.Security

---@type table Give module; the table returned at end of file.
local give = {}

---Server ids of everyone currently connected, as numbers. GetPlayers() hands back strings.
---@return number[] ids
local function onlineIds()
    local raw = GetPlayers()
    local ids = {}

    for i = 1, #raw do
        local id = tonumber(raw[i])
        if id then
            ids[#ids + 1] = id
        end
    end

    return ids
end

---Everyone within config.Security.NearbyRadius of the acting admin, the admin included.
---Coordinates are read from server-side entity state rather than anything the client sent, so
---an admin cannot claim to be standing somewhere they are not in order to reach other players.
---@param src number acting admin's server id
---@return number[] ids
local function nearbyIds(src)
    local origin = GetEntityCoords(GetPlayerPed(src))
    local radius = SEC.NearbyRadius
    local ids = {}

    for _, id in ipairs(onlineIds()) do
        local ped = GetPlayerPed(id)

        -- A player still loading in has no ped yet; skip rather than treating them as at 0,0,0.
        if ped and ped ~= 0 then
            if #(origin - GetEntityCoords(ped)) <= radius then
                ids[#ids + 1] = id
            end
        end
    end

    return ids
end

---Resolve a validated target descriptor into the concrete list of recipients.
---@param src number acting admin's server id
---@param target table validated { mode, playerId }
---@return number[] ids
local function recipients(src, target)
    if target.mode == 'self' then return { src } end
    if target.mode == 'player' then return { target.playerId } end
    if target.mode == 'all' then return onlineIds() end
    return nearbyIds(src)
end

---Hand one row to one player. CanCarryItem is checked first so a full inventory is reported as
---a clean per-recipient failure instead of an opaque AddItem false - the difference between
---"they had no room" and "something broke" matters when you are spawning to twenty people.
---@param playerId number recipient server id
---@param row table validated { name, count, metadata, label }
---@return boolean ok
---@return string|nil reason locale key when it failed
local function deliver(playerId, row)
    if not exports.ox_inventory:CanCarryItem(playerId, row.name, row.count, row.metadata) then
        return false, 'err.no_room'
    end

    local ok = exports.ox_inventory:AddItem(playerId, row.name, row.count, row.metadata)
    if not ok then return false, 'err.add_failed' end

    return true
end

---Execute a validated spawn: every row to every recipient, with a per-recipient result.
---Partial success is a real outcome here (one player full, the rest fine) and is reported as
---such rather than collapsed into a single pass/fail.
---@param src number acting admin's server id
---@param rows table[] validated rows from validate.selection
---@param target table validated target from validate.target
---@return table result { delivered, recipients, failures }
function give.execute(src, rows, target)
    local ids = recipients(src, target)
    local delivered, failures = 0, {}

    for _, playerId in ipairs(ids) do
        -- Re-tested per recipient because 'all'/'nearby' resolve a list that can go stale
        -- between resolution and delivery if someone disconnects mid-loop.
        if GetPlayerName(playerId) then
            for i = 1, #rows do
                local row = rows[i]
                local ok, reason = deliver(playerId, row)

                if ok then
                    delivered = delivered + 1
                else
                    failures[#failures + 1] = {
                        playerId = playerId,
                        playerName = GetPlayerName(playerId),
                        item = row.label,
                        reason = reason,
                    }
                end
            end
        end
    end

    audit.give(src, rows, target, ids, delivered, failures)

    log.debug('give', 'src=%d mode=%s recipients=%d delivered=%d failed=%d',
        src, target.mode, #ids, delivered, #failures)

    return { delivered = delivered, recipients = #ids, failures = failures }
end

return give
