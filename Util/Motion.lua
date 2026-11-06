local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end

-- Small, optional UI animations. Every helper checks the "Animations"
-- setting (Settings > Appearance) and does nothing when it is off or when the
-- frame API is missing, so callers never need their own guard.
local Motion = {}

Motion.FADE_DURATION = 0.15
Motion.SLIDE_DURATION = 0.12

function Motion.Enabled()
  local db = _G.SusurrusDB
  local settings = type(db) == "table" and db.settings or nil
  return not (type(settings) == "table" and settings.animationsEnabled == false)
end

-- Fades a frame in from transparent. The animation group is built once per
-- frame and restarted, so repeated calls never stack groups.
function Motion.FadeIn(frame, duration)
  if not Motion.Enabled() or type(frame) ~= "table" or type(frame.CreateAnimationGroup) ~= "function" then
    return false
  end
  local group = frame._wmFadeIn
  if group == nil then
    group = frame:CreateAnimationGroup()
    local alpha = group:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0)
    alpha:SetToAlpha(1)
    alpha:SetOrder(1)
    group._wmAlpha = alpha
    frame._wmFadeIn = group
  end
  group._wmAlpha:SetDuration(duration or Motion.FADE_DURATION)
  group:Stop()
  group:Play()
  return true
end

-- Cubic ease-out: fast start, soft landing.
function Motion.EaseOut(progress)
  local remaining = 1 - progress
  return 1 - remaining * remaining * remaining
end

Motion.WINDOW_FADE_IN = 0.22
Motion.WINDOW_FADE_OUT = 0.18

local function inCombat()
  local lockdown = _G.InCombatLockdown
  return type(lockdown) == "function" and lockdown() == true
end

-- Window fade. The window's opacity is "base * factor": the base comes from
-- the opacity settings (AlphaController writes frame._wmBaseAlpha), the
-- factor from here (frame._wmFadeFactor, 1 when idle). Keeping both in one
-- place stops the alpha ticker from fighting the fade.
--
-- Show fades in. Hide is wrapped: it fades out first and hides for real when
-- done. While fading out the frame reports itself hidden (IsShown/IsVisible),
-- so toggles and keybinds act on what the player sees, and Show() during a
-- fade-out turns it around. Hiding in combat, in restricted content or with
-- animations off stays instant.
function Motion.AttachWindowFade(frame)
  if type(frame) ~= "table" or frame._wmFade ~= nil or type(frame.Hide) ~= "function" or type(frame.Show) ~= "function" then
    return false
  end
  local createFrame = _G.CreateFrame
  if type(createFrame) ~= "function" then
    return false
  end

  local origHide, origShow, origIsShown, origIsVisible = frame.Hide, frame.Show, frame.IsShown, frame.IsVisible
  local driver = createFrame("Frame", nil, frame)
  local t = 1 -- fade progress: 0 transparent, 1 fully shown
  local target = 1
  local hiding = false
  local hasBeenShown = false

  local function apply()
    local factor = target >= t and Motion.EaseOut(t) or t
    frame._wmFadeFactor = factor
    frame:SetAlpha((frame._wmBaseAlpha or 1) * factor)
  end

  local function settle()
    t, target, hiding = 1, 1, false
    frame._wmFadingOut = false
    driver:SetScript("OnUpdate", nil)
    frame._wmFadeFactor = 1
    -- Only once the opacity settings have set a base: before that the frame
    -- still has the alpha it was built with.
    if frame._wmBaseAlpha then
      frame:SetAlpha(frame._wmBaseAlpha)
    end
  end

  local function finishHide(...)
    settle()
    return origHide(frame, ...)
  end

  local function run()
    driver:SetScript("OnUpdate", function(_, elapsed)
      local duration = target >= t and Motion.WINDOW_FADE_IN or Motion.WINDOW_FADE_OUT
      local step = (elapsed or 0) / duration
      if target >= t then
        t = math.min(target, t + step)
      else
        t = math.max(target, t - step)
      end
      apply()
      if t == target then
        driver:SetScript("OnUpdate", nil)
        if hiding then
          finishHide()
        end
      end
    end)
  end

  local function mustBeInstant()
    return not Motion.Enabled() or inCombat() or _G._wmSuspended == true
  end

  frame.Hide = function(self, ...)
    if hiding then
      if mustBeInstant() then
        return finishHide(...)
      end
      return
    end
    if not hasBeenShown or mustBeInstant() or not origIsShown(self) then
      settle()
      return origHide(self, ...)
    end
    hiding = true
    frame._wmFadingOut = true
    target = 0
    run()
  end

  frame.Show = function(self, ...)
    if hiding then
      -- Still on screen: turn the fade around instead of re-showing.
      hiding = false
      frame._wmFadingOut = false
      target = 1
      run()
      return
    end
    hasBeenShown = true
    return origShow(self, ...)
  end

  frame.IsShown = function(self)
    if hiding then
      return false
    end
    return origIsShown(self)
  end

  if type(origIsVisible) == "function" then
    frame.IsVisible = function(self)
      if hiding then
        return false
      end
      return origIsVisible(self)
    end
  end

  frame._wmFade = {
    -- Call from OnShow, after the base opacity has been applied.
    shown = function()
      hasBeenShown = true
      hiding = false
      frame._wmFadingOut = false
      if not Motion.Enabled() then
        settle()
        return
      end
      t, target = 0, 1
      apply()
      run()
    end,
    -- Call from OnHide.
    hidden = function()
      settle()
    end,
  }
  return true
end

-- One line for "/susurrus fade": is the fade hooked into the window?
function Motion.Describe(frame)
  if type(frame) ~= "table" then
    return "Susurrus fade: no window yet."
  end
  return string.format(
    "Susurrus fade: attached=%s animations=%s hideWrapped=%s alpha=%.2f base=%s factor=%s fadingOut=%s",
    tostring(frame._wmFade ~= nil),
    tostring(Motion.Enabled()),
    tostring(rawget(frame, "Hide") ~= nil),
    type(frame.GetAlpha) == "function" and frame:GetAlpha() or 0,
    tostring(frame._wmBaseAlpha),
    tostring(frame._wmFadeFactor),
    tostring(frame._wmFadingOut == true)
  )
end

function Motion.WindowShown(frame)
  local fade = type(frame) == "table" and frame._wmFade or nil
  if fade then
    fade.shown()
  end
end

function Motion.WindowHidden(frame)
  local fade = type(frame) == "table" and frame._wmFade or nil
  if fade then
    fade.hidden()
  end
end

ns.Motion = Motion
return Motion
