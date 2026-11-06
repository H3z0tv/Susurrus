local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end

local FlavorCompat = {}

local projectId = _G["WOW_PROJECT_ID"]
local MAINLINE = _G["WOW_PROJECT_MAINLINE"] or 1

FlavorCompat.isRetail = (projectId == MAINLINE)
FlavorCompat.isClassic = not FlavorCompat.isRetail

-- ponytail: no WOW_PROJECT_FOREVER exists; GetBuildInfo toc 16xxx is the only signal
local FOREVER_TOC_MIN = 16000
local FOREVER_TOC_MAX = 17000
local tocVersion = nil
if type(_G["GetBuildInfo"]) == "function" then
  tocVersion = select(4, _G["GetBuildInfo"]())
end
FlavorCompat.isForever = type(tocVersion) == "number" and tocVersion >= FOREVER_TOC_MIN and tocVersion < FOREVER_TOC_MAX

-- Readable name of the running game, for diagnostics and notes.
-- Titan Reforged reports 3.80.x (38xxx), TBC Anniversary 2.5.x (2xxxx).
local function flavorName()
  if FlavorCompat.isForever then
    return "forever"
  end
  if type(tocVersion) ~= "number" then
    return FlavorCompat.isRetail and "retail" or "classic"
  end
  if tocVersion >= 100000 then
    return "retail"
  elseif tocVersion >= 50000 then
    return "mists"
  elseif tocVersion >= 40000 then
    return "cata"
  elseif tocVersion >= 30000 then
    return "wrath"
  elseif tocVersion >= 20000 then
    return "tbc"
  end
  return "era"
end

FlavorCompat.tocVersion = tocVersion
FlavorCompat.name = flavorName()

-- Feature flags — true only on flavors that support the feature
FlavorCompat.hasMythicPlus = FlavorCompat.isRetail and not FlavorCompat.isForever

ns.FlavorCompat = FlavorCompat

return FlavorCompat
