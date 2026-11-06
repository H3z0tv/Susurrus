local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end
local Theme = ns.Theme or require("Susurrus.UI.Theme")
local UIHelpers = ns.UIHelpers or require("Susurrus.UI.Helpers")
local captureFramePosition = UIHelpers.captureFramePosition
local applyVertexColor = UIHelpers.applyVertexColor
local Badge = ns.Badge or require("Susurrus.UI.Badge")
local CompetitiveIndicator = ns.CompetitiveIndicator or require("Susurrus.UI.ToggleIcon.CompetitiveIndicator")
local IncomingPreview = ns.ToggleIconIncomingPreview or require("Susurrus.UI.ToggleIcon.IncomingPreview")
local PulseGlow = ns.ToggleIconPulseGlow or require("Susurrus.UI.ToggleIcon.PulseGlow")
local PulseState = ns.ToggleIconPulseState or require("Susurrus.UI.ToggleIcon.PulseState")
local Desaturation = ns.ToggleIconDesaturation or require("Susurrus.UI.ToggleIcon.Desaturation")
local IconClick = ns.ToggleIconIconClick or require("Susurrus.UI.ToggleIcon.IconClick")

local Localization = ns.Localization or require("Susurrus.Locale.Localization")
local KeybindHints = ns.KeybindHints or require("Susurrus.UI.Shared.KeybindHints")
local UnreadSummary = ns.UnreadSummary or require("Susurrus.UI.Shared.UnreadSummary")
local ADDON_ICON_TEXTURE = "Interface\\AddOns\\Susurrus\\Media\\widget_icon.png"

local CHAT_ICON_RATIO = 0.9 -- chat icon scale factor vs ICON_SIZE
local BORDERLESS_ICON_RATIO = 1.0 -- no background: the icon fills the widget
local GLOW_TEXTURE = "Interface\\AddOns\\Susurrus\\Media\\inner-glow.png"
local GLOW_PAD_RATIO = 0.3 -- how far the accent halo reaches past the icon
local GLOW_PULSE_SECONDS = 0.9
local HOVER_ICON_COLOR = { 1, 1, 1, 0.65 }
local HOVER_ICON_COLOR_BORDERLESS = { 1, 1, 1, 0.8 }
local WHITE = { 1, 1, 1, 1 }
local LOCK_GLYPH_RATIO = 0.45 -- lock indicator size vs ICON_SIZE
local LOCK_GLYPH_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK"
local BADGE_LEVEL_OFFSET = 10 -- above the pulse glow (parent + 5)

local ToggleIcon = {}

function ToggleIcon.Create(factory, options)
  options = options or {}

  local parent = options.parent or _G.UIParent
  local state = options.state or {}
  local anchorPoint = state.anchorPoint or "CENTER"
  local relativePoint = state.relativePoint or anchorPoint
  local x = state.x or 0
  local y = state.y or 0

  local ICON_SIZE = options.iconSize or Theme.LAYOUT.ICON_SIZE
  local currentSize = ICON_SIZE

  -- "Show icon background": the round background and ring. Off (the default)
  -- shows just the icon.
  local getShowIconBackground = options.getShowIconBackground
  local function showBackground()
    return type(getShowIconBackground) == "function" and getShowIconBackground() == true
  end

  local frame = factory.CreateFrame("Button", "SusurrusToggleIcon", parent)
  frame:SetSize(ICON_SIZE, ICON_SIZE)
  frame:SetPoint(anchorPoint, parent, relativePoint, x, y)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  -- Float above action bars and bags, same as the minimap icon.
  if frame.SetFrameStrata then
    frame:SetFrameStrata("HIGH")
  end

  -- Circular background: use the circle texture directly, tinted to desired color
  local CIRCLE_TEX = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
  local RING_TEX = "Interface\\COMMON\\RingBorder"

  local function resolveBgColor()
    return Theme.COLORS.toggle_icon_bg
  end
  local function resolveRingColor()
    local c = Theme.COLORS.toggle_icon_ring
    if c then
      return c
    end
    local a = Theme.COLORS.accent or { 1, 1, 1, 1 }
    return { a[1], a[2], a[3], 0.3 }
  end
  local function resolveGlyphColor()
    if not showBackground() then
      -- The artwork keeps its own colours; the glyph tint is for the ring look.
      return WHITE
    end
    return Theme.COLORS.toggle_icon_glyph or Theme.COLORS.text_primary
  end

  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(frame)
  background:SetTexture(CIRCLE_TEX)
  applyVertexColor(background, resolveBgColor())

  -- Circular border ring: the generic `COMMON\RingBorder` hoop, which
  -- paints cleanly with any vertex-color tint from the preset palette.
  local border = frame:CreateTexture(nil, "BORDER")
  border:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
  border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
  border:SetTexture(RING_TEX)
  applyVertexColor(border, resolveRingColor())

  -- Chat icon (speech bubble) instead of text label
  local chatIcon = frame:CreateTexture(nil, "ARTWORK")
  chatIcon:SetSize(ICON_SIZE * CHAT_ICON_RATIO, ICON_SIZE * CHAT_ICON_RATIO)
  chatIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
  chatIcon:SetTexture(ADDON_ICON_TEXTURE)
  applyVertexColor(chatIcon, resolveGlyphColor())

  local label = chatIcon -- reference kept for return table

  -- Accent halo behind the icon while whispers are unread.
  local backGlow = frame:CreateTexture(nil, "BACKGROUND")
  backGlow:SetTexture(GLOW_TEXTURE)
  if backGlow.SetBlendMode then
    backGlow:SetBlendMode("ADD")
  end
  local function paintBackGlow()
    local accent = Theme.COLORS.accent or { 1, 1, 1, 1 }
    applyVertexColor(backGlow, { accent[1], accent[2], accent[3], 0.9 })
  end
  paintBackGlow()
  backGlow:Hide()

  local backGlowAnim = nil
  if backGlow.CreateAnimationGroup then
    backGlowAnim = backGlow:CreateAnimationGroup()
    backGlowAnim:SetLooping("BOUNCE")
    local fade = backGlowAnim:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.45)
    fade:SetDuration(GLOW_PULSE_SECONDS)
    fade:SetOrder(1)
  end

  local function setBackGlow(active, animate)
    if not active then
      if backGlowAnim then
        backGlowAnim:Stop()
      end
      backGlow:Hide()
      return
    end
    backGlow:Show()
    if backGlowAnim then
      if animate then
        if not backGlowAnim:IsPlaying() then
          backGlowAnim:Play()
        end
      else
        backGlowAnim:Stop()
      end
    end
  end

  -- Icon and halo sizes follow the widget size and the background setting.
  local function layoutIcon(size)
    local ratio = showBackground() and CHAT_ICON_RATIO or BORDERLESS_ICON_RATIO
    chatIcon:SetSize(math.floor(size * ratio), math.floor(size * ratio))
    local pad = math.floor(size * GLOW_PAD_RATIO)
    backGlow:ClearAllPoints()
    backGlow:SetPoint("TOPLEFT", frame, "TOPLEFT", -pad, pad)
    backGlow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", pad, -pad)
  end
  layoutIcon(ICON_SIZE)

  -- Glow pulse for unread messages (CraftScan-style looping animation)
  local pulseGlow = PulseGlow.Create(factory, frame, {
    theme = Theme,
    accent = Theme.COLORS.accent,
  })

  -- Unread badge, outlined so it reads where it overlaps the ring
  local badgeResult = Badge.Create(factory, frame, { outline = true })
  local badge = badgeResult.frame
  local badgeBackground = badgeResult.background
  local badgeOutline = badgeResult.outline
  local badgeLabel = badgeResult.label
  local innerSetUnreadCount = badgeResult.setCount
  badge:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 6, 6)
  badge:SetFrameLevel(frame:GetFrameLevel() + BADGE_LEVEL_OFFSET)

  -- Competitive content indicator via CompetitiveIndicator submodule
  local competitiveResult = CompetitiveIndicator.Create(factory, frame)
  local innerSetCompetitiveActive = competitiveResult.setActive
  local isCompetitiveActive = false

  local function setCompetitiveContent(active)
    isCompetitiveActive = active == true
    innerSetCompetitiveActive(isCompetitiveActive)
  end

  local pulseState
  local incomingPreview = IncomingPreview.Create(factory, frame, {
    theme = Theme,
    getPreviewPosition = options.getPreviewPosition,
    getPreviewAutoDismissSeconds = options.getPreviewAutoDismissSeconds,
    onDismissPreview = options.onDismissPreview,
    onOpenPreview = options.onOpenPreview,
    onExternalChanged = function()
      pulseState.refresh()
    end,
  })
  pulseState = PulseState.New({
    start = pulseGlow.start,
    stop = pulseGlow.stop,
    getBadgePulse = options.getBadgePulse,
    isExternalShown = incomingPreview.isExternalShown,
  })
  local previewFrame = incomingPreview.frame
  local previewSenderLabel = incomingPreview.senderLabel
  local previewMessageLabel = incomingPreview.messageLabel
  local previewDismissButton = incomingPreview.dismissButton
  local previewDismissLabel = incomingPreview.dismissLabel
  local previewClassIcon = incomingPreview.classIcon
  local previewClassIconFrame = incomingPreview.classIconFrame
  local setIncomingPreview = incomingPreview.setIncomingPreview

  local getShowUnreadBadge = options.getShowUnreadBadge
  local getBadgePulse = options.getBadgePulse
  local getIconDesaturated = options.getIconDesaturated
  local getIsLocked = options.getIsLocked
  local getWidgetTransparency = options.getWidgetTransparency

  local function isLocked()
    return type(getIsLocked) == "function" and getIsLocked() == true
  end

  -- Lock glyph overlay: small padlock texture pinned to the bottom-right of
  -- the icon. Hidden by default; shown only while the icon is locked AND the
  -- cursor is hovering it, so the indicator stays out of sight otherwise.
  local lockGlyph = frame:CreateTexture(nil, "OVERLAY")
  local function applyLockGlyphLayout(size)
    local s = math.max(8, math.floor((tonumber(size) or ICON_SIZE) * LOCK_GLYPH_RATIO))
    lockGlyph:SetSize(s, s)
    if lockGlyph.ClearAllPoints then
      lockGlyph:ClearAllPoints()
    end
    lockGlyph:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
  end
  applyLockGlyphLayout(ICON_SIZE)
  lockGlyph:SetTexture(LOCK_GLYPH_TEXTURE)
  if lockGlyph.Hide then
    lockGlyph:Hide()
  end

  local isHoveringIcon = false

  local function resolveWidgetTransparency()
    local value = type(getWidgetTransparency) == "function" and tonumber(getWidgetTransparency()) or nil
    if value == nil or value ~= value then
      return 0
    end
    return math.min(1, math.max(0, value))
  end

  local function refreshTransparency()
    if frame.SetAlpha then
      local alpha = not isHoveringIcon and (1 - resolveWidgetTransparency()) or 1
      frame:SetAlpha(alpha)
    end
  end

  local function syncLockGlyphVisibility()
    local show = isHoveringIcon and isLocked()
    if show then
      if lockGlyph.Show then
        lockGlyph:Show()
      end
    else
      if lockGlyph.Hide then
        lockGlyph:Hide()
      end
    end
  end

  local function refreshLockGlyph()
    if frame.SetMovable then
      frame:SetMovable(not isLocked())
    end
    syncLockGlyphVisibility()
  end

  local desaturation = Desaturation.Create({
    textures = { chatIcon = chatIcon, background = background, border = border },
    getDesatIconColor = function()
      -- Borderless: a plain grey icon, readable on its own.
      if not showBackground() then
        return { 0.85, 0.85, 0.85, 1 }
      end
      return nil
    end,
    resolveColors = {
      chatIcon = resolveGlyphColor,
      background = resolveBgColor,
      border = resolveRingColor,
    },
    getIconDesaturated = getIconDesaturated,
    applyVertexColor = applyVertexColor,
  })

  -- count is the number shown; pulseCount (default count) starts the glow.
  local unreadSummary = ""
  local function setUnreadCount(count, pulseCount)
    unreadSummary = UnreadSummary.Format(UnreadSummary.Split(count, pulseCount))
    local showBadge = not getShowUnreadBadge or getShowUnreadBadge()
    local allowPulse = not getBadgePulse or getBadgePulse()
    local unreadCount = tonumber(count) or 0
    if showBadge then
      innerSetUnreadCount(count)
    else
      innerSetUnreadCount(0)
    end

    pulseState.setUnreadWants((tonumber(pulseCount or count) or 0) > 0 and allowPulse and showBadge)

    desaturation.update(unreadCount)
    setBackGlow(unreadCount > 0, allowPulse)
  end

  -- Hover glow effect
  if frame.SetScript then
    frame:SetScript("OnEnter", function()
      isHoveringIcon = true
      syncLockGlyphVisibility()
      refreshTransparency()
      if not desaturation.isActive() then
        applyVertexColor(background, Theme.COLORS.send_button_hover)
        applyVertexColor(chatIcon, showBackground() and HOVER_ICON_COLOR or HOVER_ICON_COLOR_BORDERLESS)
      end
      if _G.GameTooltip and _G.GameTooltip.SetOwner then
        _G.GameTooltip:SetOwner(frame, "ANCHOR_BOTTOM")
        local unreadText = badge:IsShown() and " — " .. unreadSummary or ""
        local competitiveText = ""
        if isCompetitiveActive then
          competitiveText = "\n" .. Localization.Text("Paused in M+")
        end
        local lockedText = ""
        if isLocked() then
          lockedText = "\n" .. Localization.Text("Locked")
        end
        _G.GameTooltip:SetText("Susurrus Chat" .. unreadText .. competitiveText .. lockedText)
        KeybindHints.AddToTooltip(_G.GameTooltip, type(options.getHideFromDefaultChat) == "function" and options.getHideFromDefaultChat() == true)
        KeybindHints.AddClickHint(_G.GameTooltip)
        _G.GameTooltip:Show()
      end
    end)

    frame:SetScript("OnLeave", function()
      isHoveringIcon = false
      syncLockGlyphVisibility()
      refreshTransparency()
      local isDesat = desaturation.isActive()
      applyVertexColor(background, isDesat and desaturation.DESAT_BG or resolveBgColor())
      if not isDesat then
        applyVertexColor(chatIcon, resolveGlyphColor())
      end
      if _G.GameTooltip and _G.GameTooltip.Hide then
        _G.GameTooltip:Hide()
      end
    end)

    frame:SetScript("OnClick", IconClick.Create(options))

    frame:SetScript("OnDragStart", function(self)
      if isLocked() then
        return
      end
      if self.IsMovable == nil or self:IsMovable() then
        self:StartMoving()
      end
    end)

    frame:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      local nextState = captureFramePosition(self)

      if options.onPositionChanged then
        options.onPositionChanged(nextState)
      end
    end)
  end

  local refreshDesaturation = desaturation.refresh

  -- Applies the "Show icon background" setting.
  local function refreshBackground()
    local on = showBackground()
    background:SetShown(on)
    border:SetShown(on)
    layoutIcon(currentSize)
    desaturation.refreshOriginalColors()
    desaturation.refresh()
  end

  local function refreshTheme()
    paintBackGlow()
    badgeResult.paint()
    desaturation.refreshOriginalColors()
    pulseGlow.applyTheme(Theme)
    incomingPreview.applyTheme(Theme)
    refreshDesaturation()
  end

  local function applyIconSize(newSize)
    newSize = tonumber(newSize) or ICON_SIZE
    currentSize = newSize
    frame:SetSize(newSize, newSize)
    layoutIcon(newSize)
    if border.SetPoint and border.ClearAllPoints then
      border:ClearAllPoints()
      border:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
      border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
    end
    applyLockGlyphLayout(newSize)
  end

  refreshBackground()
  setUnreadCount(options.unreadCount)
  setIncomingPreview(options.previewSenderName, options.previewMessageText, options.previewClassTag)
  refreshTheme()
  refreshLockGlyph()
  refreshTransparency()

  return {
    frame = frame,
    background = background,
    border = border,
    label = label,
    badge = badge,
    badgeBackground = badgeBackground,
    badgeOutline = badgeOutline,
    badgeLabel = badgeLabel,
    previewFrame = previewFrame,
    previewSenderLabel = previewSenderLabel,
    previewMessageLabel = previewMessageLabel,
    previewDetailLabel = incomingPreview.detailLabel,
    previewDismissButton = previewDismissButton,
    previewDismissLabel = previewDismissLabel,
    previewClassIcon = previewClassIcon,
    previewClassIconFrame = previewClassIconFrame,
    setUnreadCount = setUnreadCount,
    setCompetitiveContent = setCompetitiveContent,
    setIncomingPreview = setIncomingPreview,
    setExternalPreview = incomingPreview.setExternalPreview,
    isExternalPreviewShown = incomingPreview.isExternalShown,
    setExternalPulse = pulseState.setExternal,
    applyPreviewPosition = incomingPreview.applyPreviewPosition,
    applyIconSize = applyIconSize,
    refreshDesaturation = refreshDesaturation,
    refreshBackground = refreshBackground,
    refreshTheme = refreshTheme,
    lockGlyph = lockGlyph,
    refreshLockGlyph = refreshLockGlyph,
    refreshTransparency = refreshTransparency,
  }
end

ns.ToggleIcon = ToggleIcon
return ToggleIcon
