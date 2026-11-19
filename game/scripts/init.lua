--
-- Copyright (c) Uladzislau Nikalayevich <thenormalnij@gmail.com>. All rights reserved.
-- Licensed under the MIT license. See LICENSE file in the project root for details.
--

-- Load menu and add gamemode button
ModRequire "mainmenu/CoopMenu.lua"

-- Get current gamemode
local _, data = GetTempRuntimeData("Gamemode")
if data ~= "Coop" then
    return
end

-- Disable the gamemode for the next run
SetTempRuntimeData("Gamemode", nil)

-- Load gamemode hooks

-- Keep the existing local CoopCreatePlayer flow for both Local and Online.
-- Online note: a Client does not spawn a locally-controlled second hero the same
-- way the host does. The host owns the authoritative player-2 simulation; on the
-- client the player-2 roster slot is a networked view driven by HostSync
-- snapshots (see docs/online-coop-architecture.md). We still create the roster
-- slot here so snapshot apply has a local hero/unit to target, so there is no
-- divergence to gate at this point. Any future client-only change to this spawn
-- must be gated behind NetSession.IsClient().
if not CoopHasPlayer(2) then
    CoopCreatePlayer()
end

(ModRequire "GamemodeInit.lua").Start()
