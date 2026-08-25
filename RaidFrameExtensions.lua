local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Draws a raider's WDW spec icon in the top-left corner of Blizzard's compact
-- raid (and raid-style party) frames, where the client otherwise draws the
-- group icon -- the main-tank / main-assist marker, or the tank/healer/damager
-- group-role symbol.
--
-- Display only, and deliberately quiet: a player whose spec has neither been
-- chosen on the board nor scanned from their talents gets nothing from us, and
-- the client's own icon is left exactly as it drew it. Same while the setting
-- is off.
--
-- We repaint Blizzard's own `roleIcon` texture rather than adding one of our
-- own. The client re-runs CompactUnitFrame_UpdateRoleIcon on every event that
-- can change that corner -- roster changes, role flags, a frame being reused
-- for a different unit -- so hooking it is what keeps us on top of it without
-- a ticker; borrowing the texture also starts us from its exact position and
-- size, which is what our scale and corner offset are measured against. When
-- our icon goes away we hand the corner back -- size, anchor and all -- and
-- let the client redraw whatever it would have drawn on its own.
--
-- What we do NOT inherit is the raid profile's own show/hide of that corner:
-- a known spec draws even where the profile has role icons switched off, and
-- over the vehicle icon. Our setting is the switch for this, and a feature
-- that silently drew nothing because of a checkbox in a different window
-- would just read as broken.

-- Drawn smaller and tighter into the corner than the client draws its own:
-- 0.78 of the size it lays that corner out at (17px in the default profile,
-- so 13), flush horizontally and 1px down, where it insets by 3,-2. All of it
-- is undone again the moment we hand the corner back.
--
-- These are whole pixels on purpose. The offsets are UI units, not device
-- pixels, so a fractional one lands mid-pixel and softens the icon's edge
-- instead of moving it -- there is no half step here worth having.
local ICON_SCALE = 0.78
local ICON_PAD_X = 0
local ICON_PAD_Y = 1

-- Padding on whichever side the client padded. Its layouts inset from the
-- top-left by 3,-2 and from the top-right by -3,-2, so the sign of the offset
-- it chose is what says which way "into the frame" is.
local function PadLike(offset, pad)
    if offset > 0 then return pad end
    if offset < 0 then return -pad end
    return 0
end

local frames = {}  -- every compact frame our hook has run for
local applied = {} -- frame -> the role icon we last drew there, nil when none

-- What the client had in this corner before we took it over -- the size it
-- laid the texture out at and its own anchor -- plus the anchor we put in its
-- place, so we can tell our own handiwork from a fresh layout of its. A record
-- here means our icon is in that corner, and it is the ONLY thing our size is
-- ever derived from. The
-- client's update reads the size back off the texture and carries it forward,
-- so measuring what we last drew and taking another tenth off it would walk
-- the icon down to nothing over a handful of repaints.
local held = {}

-- Both switches, asked together because every draw decision needs both. The
-- combat one is not a restriction we are working around -- a texture carries
-- no protected state, and the client repaints this same corner mid-fight
-- itself -- it is a preference about how busy the frames get during a pull.
local function Enabled()
    local db = WhoDoesWhat.db
    if not db then return false end
    local settings = db.profile.settings
    if settings.raidFrameRoleIcons == false then return false end
    if settings.raidFrameRoleIconsInCombat == false and InCombatLockdown() then
        return false
    end
    return true
end

-- Same "Name" / "Name-Realm" keying db.profile.assignments uses.
local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- The role icon for a frame's unit, or nil when we have nothing to say about
-- them: no unit, not a player, no role, or a saved role id that no longer
-- resolves. Auto-assignment writes a scanned spec into the same store a hand
-- pick uses (TalentScanning.lua), so both arrive here as one lookup.
local function RoleIconFor(unit)
    if not (unit and UnitExists(unit) and UnitIsPlayer(unit)) then return nil end
    local key = UnitKey(unit)
    local roleId = key and WhoDoesWhat:GetAssignedRole(key)
    if not roleId then return nil end
    local _, role = WhoDoesWhat:FindRoleById(roleId)
    return role and role.icon or nil
end

-- SetRoleIconTexture rather than SetTexture: a custom role may wear one of the
-- client's micro role ATLASES, which SetTexture renders blank (see Data.lua).
--
-- Sizing this ourselves is not optional even without the scale. Everything the
-- client draws here is an atlas, and when it has nothing to draw it hides the
-- texture AND narrows it to 1px -- the name string is anchored to its right
-- edge, so the corner has to collapse or every icon-less frame would carry an
-- indent. It widens it back to a square whenever it does draw, and so must we,
-- or our icon is a sliver on exactly the players it had nothing to say about.
--
-- The anchor is re-read rather than trusted, because a raid-profile change
-- re-runs the client's layout and puts its own anchor back underneath us.
-- Anything that isn't the anchor we ourselves last set is therefore the
-- client's, and worth saving to hand back -- an exact comparison rather than a
-- guess from the offsets, since ours are only a couple of pixels off its own.
-- It also means a layout that moved this corner from the left to the right
-- carries us with it instead of pinning the icon to the wrong side.
local function Draw(frame, icon)
    local roleIcon = frame.roleIcon
    local h = held[frame]
    if not h then
        h = { size = roleIcon:GetHeight() }
        held[frame] = h
    end
    local point, relativeTo, relativePoint, x, y = roleIcon:GetPoint(1)
    if point and (point ~= h.setPoint or x ~= h.setX or y ~= h.setY) then
        h.point, h.relativeTo, h.relativePoint, h.x, h.y =
            point, relativeTo or frame, relativePoint, x, y
        h.setPoint, h.setX, h.setY =
            point, PadLike(x, ICON_PAD_X), PadLike(y, ICON_PAD_Y)
        roleIcon:ClearAllPoints()
        roleIcon:SetPoint(point, h.relativeTo, relativePoint, h.setX, h.setY)
    end
    local size = math.floor(h.size * ICON_SCALE + 0.5)
    WhoDoesWhat:SetRoleIconTexture(roleIcon, icon)
    roleIcon:SetSize(size, size)
    roleIcon:Show()
    applied[frame] = icon
end

-- Give the corner back exactly as we found it. The client has already redrawn
-- its own icon by the time this runs -- it just did so at OUR size, since that
-- is the height it found on the texture -- so the size it would have set is
-- put back by hand here: square while it is showing something, collapsed to
-- 1px wide while it is not. Calling its update again instead would recurse,
-- because this runs inside the hook on it.
local function Release(frame)
    local h = held[frame]
    if not h then return end
    held[frame] = nil
    local roleIcon = frame.roleIcon
    if h.point then
        roleIcon:ClearAllPoints()
        roleIcon:SetPoint(h.point, h.relativeTo, h.relativePoint, h.x, h.y)
    end
    roleIcon:SetSize(roleIcon:IsShown() and h.size or 1, h.size)
end

-- Runs right after the client has finished drawing that corner, so it always
-- redraws -- whatever we had there a moment ago has just been overwritten.
local function OnUpdateRoleIcon(frame)
    if not (frame and frame.roleIcon) then return end
    frames[frame] = true
    applied[frame] = nil
    local icon = Enabled() and RoleIconFor(frame.unit)
    if icon then
        Draw(frame, icon)
    else
        Release(frame)
    end
end

-- ---------------------------------------------------------------------------
-- Board-driven repaints
--
-- Nothing on Blizzard's side moves when OUR board does, so a role edit, an
-- arriving talent scan or a sync has to push. Leading edge, like
-- RequestFullRefresh: the first push after a quiet spell lands immediately and
-- everything inside the interval collapses into one catch-up -- this hangs off
-- RefreshBoardViews, which live buff tracking fires at up to 10Hz. Frames
-- whose icon hasn't changed cost a table lookup and nothing else.
-- ---------------------------------------------------------------------------

local REFRESH_INTERVAL = 0.2
local pending, lastRefresh = false, 0

local function Sweep()
    lastRefresh = GetTime()
    local enabled = Enabled()
    for frame in pairs(frames) do
        if frame.roleIcon and frame.unit and frame:IsVisible() then
            local icon = enabled and RoleIconFor(frame.unit) or nil
            if icon ~= applied[frame] then
                if icon then
                    Draw(frame, icon)
                else
                    -- Nothing of ours to show any more: let the client redraw
                    -- its own corner. That re-enters the hook above, which is
                    -- what clears our record of the frame.
                    CompactUnitFrame_UpdateRoleIcon(frame)
                end
            end
        end
    end
end

function WhoDoesWhat:RefreshRaidFrameRoleIcons()
    if pending or not next(frames) then return end
    local elapsed = GetTime() - lastRefresh
    if elapsed >= REFRESH_INTERVAL then
        Sweep()
        return
    end
    pending = true
    C_Timer.After(REFRESH_INTERVAL - elapsed, function()
        pending = false
        Sweep()
    end)
end

-- The two edges of a fight are just another reason to sweep, for the raiders
-- whose corner the combat setting hands back and forth. Registered even when
-- the hook below never installs: the sweep has nothing to walk then and costs
-- a table lookup.
local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function()
    WhoDoesWhat:RefreshRaidFrameRoleIcons()
end)

-- The compact frames live in the Blizzard_UnitFrame addon rather than in
-- FrameXML, so the function is normally already there when we load but isn't
-- guaranteed to be -- hence the second look at login. A client that never
-- provides it has no such corner to draw in, and the refresh above then has
-- nothing registered and stays a no-op.
local function InstallHook()
    if type(CompactUnitFrame_UpdateRoleIcon) ~= "function" then return false end
    hooksecurefunc("CompactUnitFrame_UpdateRoleIcon", OnUpdateRoleIcon)
    return true
end

if not InstallHook() then
    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("PLAYER_LOGIN")
    waiter:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        if not InstallHook() then
            WhoDoesWhat:LogUiBuilding("Raid frame role icons: this client has "
                .. "no CompactUnitFrame_UpdateRoleIcon; nothing to draw on.")
        end
    end)
end
