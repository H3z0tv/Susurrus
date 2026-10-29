local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end

local Loader = ns.Loader or require("Susurrus.Core.Loader")
local loadModule = Loader.LoadModule

local Bootstrap = {}
ns.Bootstrap = Bootstrap

function Bootstrap.Initialize(factory, options)
  options = options or {}

  local RuntimeFactory = loadModule("Susurrus.Core.Bootstrap.RuntimeFactory", "BootstrapRuntimeFactory")
  loadModule("Susurrus.Core.Bootstrap.EventBridge", "BootstrapEventBridge") -- registers on ns
  local RestrictedActions = loadModule("Susurrus.Core.Bootstrap.RestrictedActions", "BootstrapRestrictedActions")
  local ChatFilters = loadModule("Susurrus.Core.Bootstrap.ChatFilters", "BootstrapChatFilters")
  local ReplyKeyBinder = loadModule("Susurrus.Core.Bootstrap.ReplyKeyBinder", "BootstrapReplyKeyBinder")
  local MythicSuspendController = loadModule("Susurrus.Core.Bootstrap.MythicSuspendController", "BootstrapMythicSuspendController")
  local WindowRuntime = loadModule("Susurrus.Core.Bootstrap.WindowRuntime", "BootstrapWindowRuntime")
  local AutoOpenCoordinator = loadModule("Susurrus.Core.Bootstrap.AutoOpenCoordinator", "BootstrapAutoOpenCoordinator")
  local FirstRunTip = loadModule("Susurrus.Core.Bootstrap.FirstRunTip", "BootstrapFirstRunTip")
  local SavedState = loadModule("Susurrus.Persistence.SavedState", "SavedState")
  local Schema = loadModule("Susurrus.Persistence.Schema", "Schema")
  local SlashCommands = loadModule("Susurrus.Core.SlashCommands", "SlashCommands")
  local PresenceCache = loadModule("Susurrus.Model.PresenceCache", "PresenceCache")
  local ReplyToLast = loadModule("Susurrus.Core.SlashCommands.ReplyToLast", "SlashCommandsReplyToLast")
  local PerfCounters = loadModule("Susurrus.Util.PerfCounters", "PerfCounters")
  local ChatPrint = loadModule("Susurrus.Util.ChatPrint", "ChatPrint")

  local Fonts = loadModule("Susurrus.UI.Theme.Fonts", "ThemeFonts")
  local Theme = loadModule("Susurrus.UI.Theme", "Theme")
  local Hud = loadModule("Susurrus.UI.Theme.Hud", "Hud")
  local WindowScale = loadModule("Susurrus.UI.MessengerWindow.WindowScale", "MessengerWindowWindowScale")

  local uiFactory = factory or _G
  local localProfileId = RuntimeFactory.ResolveLocalProfileId(options)
  local accountState, characterState = SavedState.Initialize(options.accountState, options.characterState, localProfileId)
  local freshInstall = FirstRunTip.IsFreshInstall(accountState)
  accountState.settings = accountState.settings or {}
  accountState.settings.windowScale = WindowScale.Normalize(accountState.settings.windowScale)
  local defaultCharacterState = Schema.NewCharacterState()
  local runtime = RuntimeFactory.CreateRuntimeState(accountState, characterState, localProfileId, options)
  ns._channelMessageState = runtime.channelMessageStore
  runtime.messagingNotice = nil

  -- Record the current character's class tag under their profileId so
  -- group-chat rows originating from any character on this account can
  -- be tinted with the owner's class color (even after switching alts).
  if type(localProfileId) == "string" and localProfileId ~= "" and type(_G.UnitClass) == "function" then
    local ok, _, classTag = pcall(_G.UnitClass, "player")
    if ok and type(classTag) == "string" and classTag ~= "" then
      accountState.playerClasses = accountState.playerClasses or {}
      accountState.playerClasses[localProfileId] = classTag
    end
  end
  -- Initialize theme/font mode from saved settings
  -- Group-chat visibility toggle. First-run default is ON. We seed the
  -- value explicitly so SavedVariables always serializes the current
  -- choice (absence-treated-as-true is fragile if SavedVariables
  -- compaction ever drops nil-equivalent fields).
  if accountState.settings.showGroupChats == nil then
    accountState.settings.showGroupChats = true
  end
  -- Brand-new installs start on the default HUD and theme (Modern with
  -- Azeroth on Retail and Forever) with whispers hidden from default chat.
  -- Upgraders keep what they had.
  if freshInstall then
    accountState.settings.hideFromDefaultChat = true
    accountState.settings.hudStyle = Hud.DefaultStyle()
    accountState.settings.themePreset = Hud.DefaultPreset()
  end
  -- hudStyle replaces the old nativeChrome flag, which stays saved for
  -- older addon versions after a downgrade.
  if accountState.settings.hudStyle == nil then
    accountState.settings.hudStyle = accountState.settings.nativeChrome == true and "classic" or "off"
  end
  Hud.Configure(accountState.settings.hudStyle)
  FirstRunTip.Announce(accountState)
  if Fonts.Initialize then
    Fonts.Initialize(accountState.settings.fontFamily or "default")
  end
  if Fonts.SetFontSize then
    Fonts.SetFontSize(accountState.settings.fontSize or 12)
  end
  if Fonts.SetOutline then
    Fonts.SetOutline(accountState.settings.fontOutline or "NONE")
  end
  if Fonts.SetFontColor then
    Fonts.SetFontColor(accountState.settings.fontColor or "default")
  end
  local themePresetKey = accountState.settings.themePreset or (Theme.DEFAULT_PRESET or "wow_default")
  if Theme.ResolvePreset then
    local resolvedKey = Theme.ResolvePreset(themePresetKey)
    themePresetKey = resolvedKey or themePresetKey
  end
  accountState.settings.themePreset = themePresetKey
  if Theme.SetBubblePreset then
    Theme.SetBubblePreset(accountState.settings.bubbleColorPreset or "default")
  end
  -- Initialize time format/source from saved settings
  local TimeFormat = loadModule("Susurrus.Util.TimeFormat", "TimeFormat")
  if TimeFormat.Configure then
    TimeFormat.Configure({
      timeFormat = accountState.settings.timeFormat or "12h",
      timeSource = accountState.settings.timeSource or "local",
    })
  end
  local Localization = loadModule("Susurrus.Locale.Localization", "Localization")
  if Localization.Configure then
    Localization.Configure({
      language = accountState.settings.interfaceLanguage or "auto",
    })
  end
  if Fonts.SetLanguage then
    Fonts.SetLanguage(accountState.settings.interfaceLanguage or "auto")
  end
  local DisplayName = loadModule("Susurrus.Util.DisplayName", "DisplayName")
  DisplayName.Configure({
    hideBattleTagNumbers = accountState.settings.hideBattleTagNumbers ~= false,
    showPlayerLevels = accountState.settings.showPlayerLevels == true,
  })
  -- Initialize guild/community presence cache
  local presenceTTL = (accountState.settings and accountState.settings.presenceRefreshInterval) or 30
  PresenceCache.Initialize(options.clubApi or _G["C_Club"], {
    ttl = presenceTTL,
    now = options.now,
  })

  local windowRuntime = WindowRuntime.Create({
    runtime = runtime,
    accountState = accountState,
    characterState = characterState,
    defaultCharacterState = defaultCharacterState,
    uiFactory = uiFactory,
    uiParent = _G.UIParent,
    bootstrap = Bootstrap,
  })
  -- Building the contact list fills DisplayName's BattleTag clash set, so
  -- chat alerts before the first window or icon refresh name the right friend.
  if windowRuntime.buildContacts then
    windowRuntime.buildContacts()
  end

  -- 12.0+ authoritative restriction cache, populated from
  -- ADDON_RESTRICTION_STATE_CHANGED payload. On pre-12.0 clients the
  -- instance exists but never receives events — isCompetitive falls back
  -- to the legacy flag model below.
  runtime.restrictedActions = RestrictedActions.New()
  -- Seam for the lockdown catcher; nil until one is installed.
  runtime.lockdownCatcher = Bootstrap._lockdownCatcher

  runtime.isChatLocked = function()
    return runtime.restrictedActions.isChatLocked()
  end

  -- A chat lock behaves exactly like restricted content.
  runtime.isCompetitiveContent = function()
    if runtime.restrictedActions and runtime.restrictedActions.isCompetitive() then
      return true
    end
    if runtime.isChatLocked() then
      return true
    end
    return Bootstrap._inCompetitiveContent == true or Bootstrap._inEncounter == true
  end

  runtime.isMythicLockdown = function()
    if runtime.restrictedActions and runtime.restrictedActions.isMythic() then
      return true
    end
    return Bootstrap._inMythicContent == true
  end

  local SeenLevelEvents = loadModule("Susurrus.Core.SeenLevelEvents", "SeenLevelEvents")
  SeenLevelEvents.Init(runtime)
  runtime.seenLevelEvents = SeenLevelEvents
  SeenLevelEvents.SetEnabled(accountState.settings.showPlayerLevels == true)
  local WhoLookup = loadModule("Susurrus.Transport.WhoLookup", "WhoLookup")
  WhoLookup.Init(runtime)

  -- Channel chats pause wherever chat may carry secret values.
  runtime.isChannelIngestSuspended = function()
    return runtime.isMythicLockdown() or runtime.isCompetitiveContent()
  end

  Bootstrap.onCompetitiveStateChanged = function(isActive)
    local ic = windowRuntime.getIcon()
    if ic and ic.setCompetitiveContent then
      ic.setCompetitiveContent(isActive)
    end
  end

  AutoOpenCoordinator.Attach({
    runtime = runtime,
    accountState = accountState,
    windowRuntime = windowRuntime,
  })

  -- Register addon-message prefixes before live events begin routing.
  local AddonComm = loadModule("Susurrus.Transport.AddonComm", "AddonComm")
  AddonComm.RegisterPrefix(_G.C_ChatInfo, AddonComm.PREFIX_QUEST_LINK)
  AddonComm.RegisterPrefix(_G.C_ChatInfo, AddonComm.PREFIX_REACTION)
  -- Suppress whisper messages from the default chat frame (and their sound).
  -- Our addon provides its own messenger UI for whispers.
  -- We must preserve /r reply targets since the default handler won't run.
  -- Setting hideFromDefaultChat = false lets whispers appear in both places.
  --
  -- IMPORTANT: Any addon code running inside a ChatFrame filter taints
  -- Blizzard's chat processing context. Filters are only registered when
  -- they should suppress (hideFromDefaultChat=true, not in competitive
  -- content or mythic). syncChatFilters manages this dynamically.
  ChatFilters.Configure(Bootstrap, accountState, runtime)
  Bootstrap.syncChatFilters()

  runtime.syncChatFilters = Bootstrap.syncChatFilters

  -- Option B: when hideFromDefaultChat is on, override R to fire /wr
  -- through a SecureActionButton so Blizzard's tainted ReplyTell never runs.
  local replyKeyBinder = ReplyKeyBinder.New({
    getSettings = function()
      return accountState.settings
    end,
    isMythic = function()
      return runtime.isMythicLockdown and runtime.isMythicLockdown() or false
    end,
  })
  runtime.syncReplyKey = replyKeyBinder.sync
  replyKeyBinder.sync()

  SlashCommands.Register({
    toggle = runtime.toggle,
    replyToLast = ReplyToLast.Create({ runtime = runtime, windowRuntime = windowRuntime }),
    perf = function()
      for _, line in ipairs(PerfCounters.Lines(addonName)) do
        ChatPrint.Print(line)
      end
    end,
  })

  MythicSuspendController.Attach(runtime, {
    Bootstrap = Bootstrap,
    isWindowVisible = windowRuntime.isWindowVisible,
    setWindowVisible = runtime.setWindowVisible,
    refreshWindow = runtime.refreshWindow,
  })

  return runtime
end

local function initializeRuntime()
  if Bootstrap.runtime ~= nil then
    return Bootstrap.runtime
  end

  Bootstrap.runtime = Bootstrap.Initialize(_G, {
    accountState = _G.SusurrusDB,
    characterState = _G.SusurrusCharacterDB,
  })
  _G.SusurrusDB = Bootstrap.runtime.accountState
  _G.SusurrusCharacterDB = Bootstrap.runtime.characterState
  loadModule("Susurrus.Core.PublicApi", "PublicApi").Publish(Bootstrap.runtime)

  return Bootstrap.runtime
end

if type(_G.CreateFrame) == "function" then
  local AddonEventFrame = loadModule("Susurrus.Core.Bootstrap.AddonEventFrame", "BootstrapAddonEventFrame")
  AddonEventFrame.Install({
    addonName = addonName,
    Bootstrap = Bootstrap,
    initializeRuntime = initializeRuntime,
    loadModule = loadModule,
  })
end

return Bootstrap
