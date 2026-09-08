local WhoDoesWhat = LibStub("AceAddon-3.0"):GetAddon("WhoDoesWhat")

-- Shared chrome for all WhoDoesWhat windows so every view gets the same look
-- and the same title-bar / close / drag / Escape behaviour.

WhoDoesWhat.TITLEBAR_H = 22

-- Every bar and window ends its tooltip with the same gold "modifier-click:
-- what it does" list. Those hints are reference material rather than the
-- answer the tooltip was opened for, so they are drawn a point below the body
-- font and let the content above them lead. Blizzard's own small tooltip font
-- is two sizes down and reads as fine print, so the hint font is derived from
-- the body's instead, which also keeps it following the player's tooltip font
-- scale.
local HINT_FONT = CreateFont("WhoDoesWhatTooltipHintFont")
do
    local path, size, flags = GameTooltipText:GetFont()
    HINT_FONT:SetFont(path, (size or 12) - 1, flags)
end

-- A tooltip pools its font strings across every tooltip it draws, so a shrunk
-- line has to be put back before the next content inherits it. Keyed by
-- tooltip: the value is the last line we shrank, and nil means we have not
-- hooked that tooltip's clear yet.
local hintLines = {}

local function RestoreHintFonts(tooltip)
    local name = tooltip:GetName()
    -- Line 1 is the header, in its own larger font, and never a hint.
    for i = 2, hintLines[tooltip] or 0 do
        local left = _G[name .. "TextLeft" .. i]
        local right = _G[name .. "TextRight" .. i]
        if left then left:SetFontObject(GameTooltipText) end
        if right then right:SetFontObject(GameTooltipText) end
    end
    hintLines[tooltip] = 0
end

-- One shortcut hint: "Alt-Drag:" on the left, what it does on the right.
-- SetFontObject brings the font's own colour with it, so the line's colours
-- are re-applied after the shrink rather than before it. An unnamed tooltip
-- has no reachable font strings; it just keeps the body size.
function WhoDoesWhat:AddTooltipHint(tooltip, shortcut, action, r, g, b)
    tooltip = tooltip or GameTooltip
    r, g, b = r or 1, g or 1, b or 1
    tooltip:AddDoubleLine(shortcut, action, 1, 0.82, 0, r, g, b)
    local name = tooltip:GetName()
    if not name then return end
    if hintLines[tooltip] == nil then
        hintLines[tooltip] = 0
        tooltip:HookScript("OnTooltipCleared", RestoreHintFonts)
    end
    local i = tooltip:NumLines()
    local left = _G[name .. "TextLeft" .. i]
    local right = _G[name .. "TextRight" .. i]
    if left then
        left:SetFontObject(HINT_FONT)
        left:SetTextColor(1, 0.82, 0)
    end
    if right then
        right:SetFontObject(HINT_FONT)
        right:SetTextColor(r, g, b)
    end
    if i > hintLines[tooltip] then hintLines[tooltip] = i end
end

-- Apply the addon's compact treatment to Blizzard's legacy dropdown chrome.
-- Its three housing textures are 64px tall (with transparent padding) around
-- a 24px arrow. Trim and position that housing without scaling any click
-- target or menu content, then place its label and arrow independently.
function WhoDoesWhat:StyleDropdown(dd, leftAlign)
    local name = dd:GetName()
    if not name then return end

    if not dd.wdwHousingStyled then
        for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
            local texture = _G[name .. suffix]
            if texture then texture:SetHeight(57) end
        end
        local left = _G[name .. "Left"]
        local button = _G[name .. "Button"]
        local label = _G[name .. "Text"]
        -- Middle and Right are chained from Left, so moving Left shifts the
        -- entire housing. Its dependent arrow/text anchors follow it; leave
        -- the arrow 0.5px and text 2.8px lower, then nudge the arrow right.
        if left then left:AdjustPointsOffset(0, -3) end
        if button then button:AdjustPointsOffset(2, 2.5) end
        if label then label:AdjustPointsOffset(0, 0.2) end
        dd.wdwHousingStyled = true
    end

    if leftAlign and not dd.wdwTextAligned then
        local label = _G[name .. "Text"]
        if label then
            label:SetJustifyH("LEFT")
            label:SetWidth(label:GetWidth() + 5)
            label:AdjustPointsOffset(0, -1)
        end
        dd.wdwTextAligned = true
    end
end

-- Create a standard WDW window frame: solid black backdrop, a title bar with
-- text, a close button, draggable, closes on Escape. Returns the frame; the
-- caller anchors its own content below the title bar (offset f.titleBarHeight).
-- `globalName` must be unique per window (used for the Escape-close registry).
function WhoDoesWhat:CreateWindowFrame(globalName, width, height, titleText)
    WhoDoesWhat:LogUiBuilding("Creating window frame: " .. globalName)

    local f = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)

    -- Solid black background with a thin border
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4)

    -- Draggable by the whole frame
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Close with Escape
    tinsert(UISpecialFrames, globalName)

    -- Title bar strip
    local titlebar = f:CreateTexture(nil, "ARTWORK")
    titlebar:SetColorTexture(0.12, 0.12, 0.15, 1)
    titlebar:SetPoint("TOPLEFT", 5, -5)
    titlebar:SetPoint("TOPRIGHT", -5, -5)
    titlebar:SetHeight(WhoDoesWhat.TITLEBAR_H)
    f.titleBarTexture = titlebar

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titlebar, "LEFT", 10, 0)
    title:SetText(titleText or "")
    f.titleText = title

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() f:Hide() end)
    f.closeButton = close

    f.titleBarHeight = WhoDoesWhat.TITLEBAR_H
    f:Hide()
    return f
end
