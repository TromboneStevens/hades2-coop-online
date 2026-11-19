--
-- Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
-- Licensed under the MIT license. See LICENSE file in the project root for details.
--

-- NetProtocol: dependency-free (de)serialization for the online-coop message
-- kinds described in docs/online-coop-architecture.md section 3. It only uses
-- the Lua standard library (string.format / tonumber / string.find / gmatch),
-- so it can be reviewed and reasoned about without the engine being present.
--
-- Wire format: each message is a single string whose first character is a kind
-- tag, followed by fields joined by the unit separator FS. Snapshots pack a
-- variable number of units; each unit's fields are joined by GS and units are
-- joined by RS. These separators are control characters that never appear in
-- the small set of values we send (control names, integers, formatted floats).

---@class NetProtocol
local NetProtocol = {}

-- Protocol version, checked during the Hello / Welcome handshake.
NetProtocol.VERSION = 1

-- Kind tags (single characters so Decode can branch on string.sub(str, 1, 1)).
NetProtocol.Kind = {
    Hello = "H",
    Welcome = "W",
    InputEvent = "I",
    StateSnapshot = "S",
    Heartbeat = "B",
}

-- Field separator (between the top-level fields of one message).
local FS = "\31" -- ASCII Unit Separator
-- Group separator (between the fields of a single unit inside a snapshot).
local GS = "\30" -- ASCII Record Separator fields
-- Record separator (between units inside a snapshot).
local RS = "\29" -- ASCII Group Separator

---@param n number
---@return string
local function num(n)
    -- %.4g keeps transforms compact while preserving enough precision for
    -- position/angle; integer ids round-trip exactly through tonumber.
    return string.format("%.4g", n or 0)
end

---Split a string on a single-character separator. Returns a plain array.
---Empty trailing/leading pieces are preserved so field positions stay stable.
---@param str string
---@param sep string
---@return string[]
local function split(str, sep)
    local out = {}
    local start = 1
    while true do
        local idx = string.find(str, sep, start, true)
        if not idx then
            out[#out + 1] = string.sub(str, start)
            break
        end
        out[#out + 1] = string.sub(str, start, idx - 1)
        start = idx + 1
    end
    return out
end

--- Encoders -----------------------------------------------------------------

---@param clientName string?
---@return string
function NetProtocol.EncodeHello(clientName)
    return NetProtocol.Kind.Hello .. FS .. num(NetProtocol.VERSION) .. FS .. (clientName or "")
end

---@param assignedPlayerId integer
---@return string
function NetProtocol.EncodeWelcome(assignedPlayerId)
    return NetProtocol.Kind.Welcome .. FS .. num(NetProtocol.VERSION) .. FS .. num(assignedPlayerId or 2)
end

---@param input { playerId: integer, controlName: string, dx: number?, dy: number?, pressed: boolean? }
---@return string
function NetProtocol.EncodeInput(input)
    return table.concat({
        NetProtocol.Kind.InputEvent,
        num(input.playerId or 2),
        input.controlName or "",
        num(input.dx or 0),
        num(input.dy or 0),
        input.pressed and "1" or "0",
    }, FS)
end

---@param snapshot { units: { unitId: integer, x: number?, y: number?, angle: number?, animId: (string|number)?, health: number? }[] }
---@return string
function NetProtocol.EncodeSnapshot(snapshot)
    local units = snapshot.units or {}
    local parts = {}
    for i = 1, #units do
        local u = units[i]
        parts[i] = table.concat({
            num(u.unitId or 0),
            num(u.x or 0),
            num(u.y or 0),
            num(u.angle or 0),
            tostring(u.animId or ""),
            num(u.health or 0),
        }, GS)
    end
    return NetProtocol.Kind.StateSnapshot .. FS .. table.concat(parts, RS)
end

---@param timestamp number?
---@return string
function NetProtocol.EncodeHeartbeat(timestamp)
    return NetProtocol.Kind.Heartbeat .. FS .. num(timestamp or 0)
end

--- Decoder ------------------------------------------------------------------

---Decode a wire string back into a message table tagged with `kind`.
---Returns nil for an empty or unrecognised message so callers can skip it.
---@param str string
---@return table?
function NetProtocol.Decode(str)
    if not str or str == "" then
        return nil
    end

    local kind = string.sub(str, 1, 1)
    local body = string.sub(str, 3) -- skip the kind tag and the first FS
    local f = split(body, FS)

    if kind == NetProtocol.Kind.Hello then
        return { kind = "Hello", version = tonumber(f[1]) or 0, clientName = f[2] or "" }
    elseif kind == NetProtocol.Kind.Welcome then
        return { kind = "Welcome", version = tonumber(f[1]) or 0, playerId = tonumber(f[2]) or 2 }
    elseif kind == NetProtocol.Kind.InputEvent then
        return {
            kind = "InputEvent",
            playerId = tonumber(f[1]) or 2,
            controlName = f[2] or "",
            dx = tonumber(f[3]) or 0,
            dy = tonumber(f[4]) or 0,
            pressed = f[5] == "1",
        }
    elseif kind == NetProtocol.Kind.StateSnapshot then
        local units = {}
        local packed = f[1] or ""
        if packed ~= "" then
            local records = split(packed, RS)
            for i = 1, #records do
                local g = split(records[i], GS)
                units[i] = {
                    unitId = tonumber(g[1]) or 0,
                    x = tonumber(g[2]) or 0,
                    y = tonumber(g[3]) or 0,
                    angle = tonumber(g[4]) or 0,
                    -- animId may be a name or an id; keep the raw string and
                    -- let the consumer coerce it when it knows the engine type.
                    animId = g[5] or "",
                    health = tonumber(g[6]) or 0,
                }
            end
        end
        return { kind = "StateSnapshot", units = units }
    elseif kind == NetProtocol.Kind.Heartbeat then
        return { kind = "Heartbeat", timestamp = tonumber(f[1]) or 0 }
    end

    return nil
end

return NetProtocol
