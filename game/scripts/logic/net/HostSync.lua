--
-- Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
-- Licensed under the MIT license. See LICENSE file in the project root for details.
--

-- HostSync: streams the remote (player 2) unit state from host to client.
--
--   Host  : on each tick, reads player 2's hero/unit and sends a StateSnapshot.
--   Client: registers a StateSnapshot handler that applies the remote unit's
--           transform / animation / health to its local representation.
--
-- The host-authoritative model (docs/online-coop-architecture.md section 2)
-- means only the host simulates; the client's player-2 unit is a view driven by
-- these snapshots.
--
-- Engine accessors that are NOT already proven present elsewhere in the mod are
-- isolated behind clearly named locals with a TODO and are listed in the design
-- doc's implemented-vs-stubbed section. Proven calls used here: GetLocation{Id}
-- (logic/saveHandlers/SinglePlayerHeroSaveHandler.lua), Teleport{Id,
-- DestinationId} (logic/CoopPlayers.lua and others) and the hero.Health field.

---@type CoopPlayers
local CoopPlayers = ModRequire "../CoopPlayers.lua"
---@type NetSession
local NetSession = ModRequire "NetSession.lua"
---@type NetProtocol
local NetProtocol = ModRequire "NetProtocol.lua"

---@class HostSync
local HostSync = {}

-- The networked remote player id. Player 1 is local on the host; player 2 is the
-- client's avatar, simulated by the host and mirrored on the client.
local REMOTE_PLAYER_ID = 2

-- ---------------------------------------------------------------------------
-- Engine accessor stubs (NOT proven present; see design doc stubbed section).
-- Each returns a safe default so review and offline runs never crash. When the
-- real engine symbol is confirmed, replace the body and move the row to the
-- implemented section of the design doc.
-- ---------------------------------------------------------------------------

---TODO(online-coop): no proven numeric position getter exists. GetLocation{Id}
---is proven present but its return shape is not verified to expose x/y here, so
---we read it defensively and fall back to 0.
---@param unitId integer
---@return number x, number y
local function ReadUnitPosition(unitId)
    local ok, loc = pcall(GetLocation, { Id = unitId })
    if ok and type(loc) == "table" then
        return loc.X or loc.x or 0, loc.Y or loc.y or 0
    end
    return 0, 0
end

---TODO(online-coop): no proven facing/angle getter exists in the Lua layer.
---@param unitId integer
---@return number angle
local function ReadUnitAngle(unitId)
    return 0
end

---TODO(online-coop): no proven current-animation getter exists in the Lua
---layer; animation streaming is not wired yet.
---@param unitId integer
---@return string animId
local function ReadUnitAnimation(unitId)
    return ""
end

---TODO(online-coop): no proven coordinate-teleport is confirmed. Teleport with a
---DestinationId is proven present, but teleporting to explicit x/y is not, so
---client-side position apply is isolated here and currently a no-op placeholder.
---@param unitId integer
---@param x number
---@param y number
local function ApplyUnitPosition(unitId, x, y)
    -- TODO(online-coop): call the confirmed coordinate teleport / move here, e.g.
    -- Teleport { Id = unitId, OffsetX = x, OffsetY = y } once the engine contract
    -- for absolute-vs-relative placement is verified.
end

---TODO(online-coop): animation apply on the client is not wired (no proven
---SetAnimation-style call in the Lua layer).
---@param unitId integer
---@param animId string
local function ApplyUnitAnimation(unitId, animId)
end

-- ---------------------------------------------------------------------------

---Build a snapshot of the remote player's unit, or nil if it is not available.
---@return table?
function HostSync.BuildRemoteSnapshot()
    local hero = CoopPlayers.GetHero(REMOTE_PLAYER_ID)
    if not hero or not hero.ObjectId then
        return nil
    end

    local unitId = hero.ObjectId
    local x, y = ReadUnitPosition(unitId)

    return {
        units = {
            {
                unitId = unitId,
                x = x,
                y = y,
                angle = ReadUnitAngle(unitId),
                animId = ReadUnitAnimation(unitId),
                health = hero.Health or 0,
            },
        },
    }
end

---Host tick handler: send the remote-player snapshot while connected.
function HostSync.OnTick()
    if not NetSession.IsHost() or not NetSession.IsConnected() then
        return
    end

    local snapshot = HostSync.BuildRemoteSnapshot()
    if snapshot then
        NetSession.Send(NetProtocol.EncodeSnapshot(snapshot))
    end
end

---Client handler: apply an incoming authoritative snapshot to the local
---representation of the remote player's unit.
---@param msg table decoded StateSnapshot message
function HostSync.OnSnapshot(msg)
    local hero = CoopPlayers.GetHero(REMOTE_PLAYER_ID)
    if not hero then
        return
    end

    for _, u in ipairs(msg.units or {}) do
        -- Apply to the local player-2 unit. We key on the local hero's current
        -- ObjectId rather than the host's unit id, since unit ids are not shared
        -- across processes; the snapshot carries a single remote unit today.
        local localUnitId = hero.ObjectId
        if localUnitId then
            ApplyUnitPosition(localUnitId, u.x, u.y)
            ApplyUnitAnimation(localUnitId, u.animId)
            -- Health is a proven hero field used throughout the mod. Clamp the
            -- wire value before applying so a malformed/zero/overflowing
            -- snapshot cannot drive the local display out of range: floor at 0
            -- and cap at hero.MaxHealth when the mod exposes it.
            local health = tonumber(u.health) or 0
            if health < 0 then
                health = 0
            end
            local maxHealth = tonumber(hero.MaxHealth)
            if maxHealth and health > maxHealth then
                health = maxHealth
            end
            hero.Health = health
        end
    end
end

---Register tick/message hooks. Called from GamemodeInit on the online path.
---@param Events Events
function HostSync.Init(Events)
    if NetSession.IsHost() then
        Events.engine:on("tick", HostSync.OnTick)
    elseif NetSession.IsClient() then
        NetSession.On("StateSnapshot", HostSync.OnSnapshot)
    end
end

return HostSync
