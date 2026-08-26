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

-- ---------------------------------------------------------------------------
-- Styles
--
-- "corner" keeps the client's own shape: a square icon in the corner it lays
-- that texture out in, drawn smaller and tighter than it draws its own -- 0.78
-- of the size it uses (17px in the default profile, so 13), flush horizontally
-- and 1px down, where it insets by 3,-2.
--
-- The two band styles instead run the icon down the whole left edge of the
-- health bar, a vertical strip from the top-left corner to just above the
-- power bar. The health bar is the right thing to measure against rather than
-- the frame: the client anchors it from the frame's top-left down to exactly
-- where the power bar starts, so its left edge already IS that span -- no
-- power-bar arithmetic here, and a profile with the power bar switched off
-- lengthens the band on its own.
--
-- "band" ends on a dark hairline, so it stays narrow enough to read as a
-- stripe. "bandFaded" instead dissolves rightward, and that is what pays for
-- its width: a tail that costs nothing visually can be twice as wide, wide
-- enough to read as the icon it actually is, and it washes UNDER the name
-- rather than pushing it aside.
--
-- These are whole pixels on purpose. The offsets are UI units, not device
-- pixels, so a fractional one lands mid-pixel and softens the icon's edge
-- instead of moving it -- there is no half step here worth having.
local ICON_SCALE = 0.78
local ICON_PAD_X = 0
local ICON_PAD_Y = 1

-- Where the name restarts when the band has taken the corner its anchor used
-- to hang off. Matches where the client itself leaves the name when it has no
-- role icon to show: its own 3px inset plus the 1px the hidden icon collapses
-- to.
local NAME_ORPHAN_X = 4

-- `width`       strip width, and the mark of a band style; absent means corner.
-- `side`        which edge of the health bar it runs down; LEFT when absent.
-- `edge`        finish with the dark hairline on the strip's inner side.
-- `fadeFrom`    gradient alpha at the strip's outer edge, fading to `fadeTo`
--               at its inner one. Absent means flat.
-- `nameGap`     px of daylight between the strip and the name, for a name the
--               client has hung off the role icon.
-- `nameRebase`  re-point that name anchor at the frame instead. Required
--               whenever the strip is not a small thing sitting to the name's
--               left: a right band would anchor the name's left edge past its
--               own right one, and a square-wide left band would drag the name
--               halfway across the frame. Leaving the anchor alone is what
--               INDENTS the name, not what leaves it be.
-- `pullRight`   px the right-hand text anchors come in by.
-- `statusShift` px the status text's left anchor moves out by.
--
-- Both faded styles wash under the text rather than moving it: the status text
-- is left exactly where the client put it, and the name is put back where the
-- client would put it with no icon beside it at all.
local STYLES = {
    corner = {},
    band = { width = 12, edge = true, nameGap = 4, statusShift = 4 },
    bandFaded = { width = 30, fadeFrom = 0.6, fadeTo = 0, nameRebase = true },
    bandRight = {
        width = 12, side = "RIGHT", edge = true,
        nameRebase = true, pullRight = 14,
    },
    bandRightFaded = {
        width = 30, side = "RIGHT", fadeFrom = 0.6, fadeTo = 0,
        nameRebase = true,
    },
}

-- Padding on whichever side the client padded. Its layouts inset from the
-- top-left by 3,-2 and from the top-right by -3,-2, so the sign of the offset
-- it chose is what says which way "into the frame" is.
local function PadLike(offset, pad)
    if offset > 0 then return pad end
    if offset < 0 then return -pad end
    return 0
end

-- Which style to draw, and whether this frame can even carry it. The band
-- needs a measurable health bar to span; without one there is nothing to
-- anchor a strip to, so that frame quietly keeps the corner.
local function StyleFor(frame)
    local db = WhoDoesWhat.db
    -- Same fallback the settings dropdown falls back to, so a missing saved
    -- value can never draw one style while the window ticks another.
    local key = db and db.profile.settings.raidFrameRoleIconStyle or "bandFaded"
    local style = STYLES[key]
    if not (style and style.width) then return "corner", STYLES.corner end
    local bar = frame.healthBar
    local height = bar and bar:GetHeight() or 0
    if height <= 0 then return "corner", STYLES.corner end
    return key, style, height
end

-- Show only the middle slice of the icon, as wide as the strip is relative to
-- its height: the art is square, so drawing it at the band's height would make
-- it the band's height WIDE too, and everything past the strip has to be
-- masked off rather than squashed in. Cropping the texcoords the texture
-- already carries -- rather than computing a rect from scratch -- is what
-- keeps this working for a custom role wearing a micro role ATLAS, whose
-- coordinates address a sub-rect of a shared sheet and not the whole file.
local function CapturePoints(region)
    local points = {}
    for i = 1, region:GetNumPoints() do
        local point, relativeTo, relativePoint, x, y = region:GetPoint(i)
        points[i] = { point, relativeTo or region:GetParent(), relativePoint, x, y }
    end
    return points
end

-- Re-apply one region's captured anchors under a style's text rules. A style
-- with no rules restores them verbatim, which is how both the faded styles and
-- the release path put everything back.
--
-- Anchors that name neither edge are left alone throughout -- that is what
-- keeps the centred name of the buffs-top layout centred rather than dragging
-- it sideways.
local function ApplyTextPoints(frame, key, region, points, style)
    local roleIcon = frame.roleIcon
    region:ClearAllPoints()
    for _, p in ipairs(points) do
        local point, relativeTo, relativePoint, x, y = p[1], p[2], p[3], p[4], p[5]
        local left = point:find("LEFT", 1, true)
        if key == "name" and left and relativeTo == roleIcon then
            -- The client hangs the name off the role icon's inner edge, so the
            -- name follows our strip whether we want it to or not. A narrow
            -- left band can ride that and just ask for a gap; anything else
            -- has to be cut loose -- a right band would anchor the name's LEFT
            -- edge past its own right one and collapse the string, and a
            -- square-wide band would shove the name halfway across the frame.
            if style.nameRebase then
                relativeTo, relativePoint, x = frame, point, NAME_ORPHAN_X
            elseif style.nameGap then
                x = x + style.nameGap
            end
        elseif key == "statusText" and left and style.statusShift then
            x = x + style.statusShift
        end
        if style.pullRight and point:find("RIGHT", 1, true) then
            x = x - style.pullRight
        end
        region:SetPoint(point, relativeTo, relativePoint, x, y)
    end
end

-- Lay the frame's text out for a style, or put it back. Only ever on a change:
-- in corner style this settles on the client's own anchors after one pass and
-- then costs a comparison.
local TEXT_REGIONS = { "name", "statusText" }

local function SetTextLayout(frame, h, key, style)
    if h.textStyle == key then return end
    -- Never touched, and not being asked to: a style with no text rules has no
    -- business reaching into the client's layout, so don't even capture it.
    if not (style.nameGap or style.nameRebase or style.pullRight
        or style.statusShift or h.textPoints) then
        h.textStyle = key
        return
    end
    h.textPoints = h.textPoints or {}
    for _, region_key in ipairs(TEXT_REGIONS) do
        local region = frame[region_key]
        if region and region.GetNumPoints and region:GetNumPoints() > 0 then
            h.textPoints[region_key] = h.textPoints[region_key]
                or CapturePoints(region)
            ApplyTextPoints(frame, region_key, region,
                h.textPoints[region_key], style)
        end
    end
    h.textStyle = key
end

-- ---------------------------------------------------------------------------
-- Band finishes: the hairline and the fade
-- ---------------------------------------------------------------------------

-- A dark hairline down the right side of the narrow band, so the art ends on a
-- line instead of bleeding into the health bar. The client's role icon is a
-- bare texture with no border of its own, so this is one we create -- kept in
-- a table of ours rather than stamped onto the frame, and reused and re-hidden
-- rather than made again, since these frames outlive any one raid.
--
-- OVERLAY, a layer above the icon it edges: same layer would leave which one
-- wins to draw order, and the point of the line is that nothing covers it.
local BAND_EDGE_WIDTH = 1
local BAND_EDGE_COLOR = { 0.15, 0.15, 0.15, 1 }
local edges = {}

local function SetBandEdge(frame, style)
    local edge = edges[frame]
    if not (style and style.width and style.edge) then
        if edge then edge:Hide() end
        return
    end
    if not edge then
        edge = frame:CreateTexture(nil, "OVERLAY")
        if edge.SetColorTexture then
            edge:SetColorTexture(unpack(BAND_EDGE_COLOR))
        else
            edge:SetTexture("Interface\\Buttons\\WHITE8X8")
            edge:SetVertexColor(unpack(BAND_EDGE_COLOR))
        end
        edges[frame] = edge
    end
    -- Always the strip's inner side, the one facing the middle of the frame.
    local mine, theirs = "LEFT", "RIGHT"
    if style.side == "RIGHT" then mine, theirs = "RIGHT", "LEFT" end
    edge:ClearAllPoints()
    edge:SetPoint("TOP" .. mine, frame.roleIcon, "TOP" .. theirs, 0, 0)
    edge:SetPoint("BOTTOM" .. mine, frame.roleIcon, "BOTTOM" .. theirs, 0, 0)
    edge:SetWidth(BAND_EDGE_WIDTH)
    edge:Show()
end

-- Fade the band out to the right, or flatten it back to plain opaque. Only on
-- a change, since a gradient sticks to the region until something replaces it.
-- Colour objects are cached rather than built per call: this runs per frame
-- per repaint, and fresh tables at that rate are exactly the litter the
-- repaint budget was cleaned up to avoid.
local colors = {}

local function Alpha(a)
    local color = colors[a]
    if not color then
        color = CreateColor(1, 1, 1, a)
        colors[a] = color
    end
    return color
end

local function SetFade(texture, h, style)
    local from = style.fadeFrom
    -- The gradient runs outer-edge-inward, so which end holds the solid alpha
    -- depends on the side the strip is on.
    local wanted = from and ((style.side or "LEFT") .. from) or false
    if h.fade == wanted then return end
    if not (texture.SetGradient and CreateColor) then return end
    if from then
        local outer, inner = Alpha(from), Alpha(style.fadeTo or 0)
        if style.side == "RIGHT" then outer, inner = inner, outer end
        texture:SetGradient("HORIZONTAL", outer, inner)
    else
        texture:SetGradient("HORIZONTAL", Alpha(1), Alpha(1))
    end
    h.fade = wanted
end

-- Ability icons carry a rounded bevel baked into the art, so a texture drawn
-- at its full coordinates shows that border instead of filling with the
-- symbol -- worse the smaller it is drawn, and a band is mostly border.
--
-- Trimmed by the same 7% the rest of the addon trims its icons by (Data.lua's
-- ApplyStatusCheckIcon, and every icon row under Views/), so these match the
-- icons in our own windows. That is the ~116% zoom rather than the 110% one:
-- the bevel really is about a fifteenth of the art per side, and 110% leaves a
-- sliver of it lit along the edge. ICON_TRIM is the knob -- 0.045 is 110%.
--
-- File icons only. A custom role wearing one of the client's micro role
-- ATLASES is already-trimmed art inside a shared sheet, and insetting that
-- eats the symbol rather than a border, so ask the texture what it actually
-- ended up holding rather than guessing from the role's icon id.
local ICON_TRIM = 0.07

local function TrimIconBorder(texture)
    if texture.GetAtlas and texture:GetAtlas() then return end
    local ulX, ulY, llX, llY, urX = texture:GetTexCoord()
    if not (ulX and urX) then return end
    local across, down = urX - ulX, llY - ulY
    texture:SetTexCoord(
        ulX + across * ICON_TRIM, urX - across * ICON_TRIM,
        ulY + down * ICON_TRIM, llY - down * ICON_TRIM)
end

-- Never called with a width past the height -- a band is clamped square, so
-- the widest it ever gets is the whole icon at its own aspect, uncropped.
local function MaskToWidth(texture, width, height)
    if width >= height then return end
    local ulX, ulY, llX, llY, urX = texture:GetTexCoord()
    if not (ulX and urX) then return end
    local middle = (ulX + urX) / 2
    local half = (urX - ulX) * (width / height) / 2
    texture:SetTexCoord(middle - half, middle + half, ulY, llY)
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
--
-- Only the anchor is conditional. Texture, size and mask are re-applied every
-- time, because the client's update runs immediately before this one and sets
-- a size of its own on every pass -- including the 1px-wide collapse, which
-- would otherwise eat the band.
local function Anchor(frame, h, key, style)
    local roleIcon = frame.roleIcon
    roleIcon:ClearAllPoints()
    if style.width then
        local corner = style.side == "RIGHT" and "TOPRIGHT" or "TOPLEFT"
        roleIcon:SetPoint(corner, frame.healthBar, corner, 0, 0)
        h.setPoint, h.setRelativeTo, h.setX, h.setY =
            corner, frame.healthBar, 0, 0
    else
        roleIcon:SetPoint(h.point, h.relativeTo, h.relativePoint,
            PadLike(h.x, ICON_PAD_X), PadLike(h.y, ICON_PAD_Y))
        h.setPoint, h.setRelativeTo = h.point, h.relativeTo
        h.setX, h.setY = PadLike(h.x, ICON_PAD_X), PadLike(h.y, ICON_PAD_Y)
    end
    h.setStyle = key
end

local function Draw(frame, icon)
    local roleIcon = frame.roleIcon
    local h = held[frame]
    if not h then
        h = { size = roleIcon:GetHeight() }
        held[frame] = h
    end
    local key, style, bandHeight = StyleFor(frame)
    -- Never wider than it is tall. A band past square would have to stretch
    -- the art sideways or crop it top and bottom, and both are worse than
    -- simply stopping at the whole icon.
    local width = style.width and math.min(style.width, bandHeight) or nil

    local point, relativeTo, relativePoint, x, y = roleIcon:GetPoint(1)
    local ours = point == h.setPoint and relativeTo == h.setRelativeTo
        and x == h.setX and y == h.setY
    if point and not ours then
        -- The client's own anchor, and the one we owe it back. Its layout
        -- moves the text with the icon, so a pass of its own has undone our
        -- shift too -- drop the record of it and let it be re-applied.
        h.point, h.relativeTo, h.relativePoint, h.x, h.y =
            point, relativeTo or frame, relativePoint, x, y
        h.textStyle = nil
    end
    if h.point and (not ours or h.setStyle ~= key) then
        Anchor(frame, h, key, style)
    end

    SetTextLayout(frame, h, key, style)
    SetFade(roleIcon, h, style)
    SetBandEdge(frame, style)
    WhoDoesWhat:SetRoleIconTexture(roleIcon, icon)
    -- Trim first, mask second: the mask narrows whatever rect it finds, so
    -- running it the other way round would crop the band out of the bevel.
    TrimIconBorder(roleIcon)
    if width then
        roleIcon:SetSize(width, bandHeight)
        MaskToWidth(roleIcon, width, bandHeight)
    else
        local size = math.floor(h.size * ICON_SCALE + 0.5)
        roleIcon:SetSize(size, size)
    end
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
    local roleIcon = frame.roleIcon
    SetTextLayout(frame, h, "corner", STYLES.corner)
    SetFade(roleIcon, h, STYLES.corner)
    SetBandEdge(frame, nil)
    held[frame] = nil
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
            -- The style counts as a change too. Comparing the icon alone meant
            -- switching style repainted nothing at all: the same player still
            -- resolves to the same icon, so every frame looked untouched and
            -- the new shape waited for the next unrelated board edit.
            local h = held[frame]
            if icon ~= applied[frame]
                or (icon and h and h.setStyle ~= StyleFor(frame)) then
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
