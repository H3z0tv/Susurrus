local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end

local Theme = ns.Theme or require("Susurrus.UI.Theme")
local UIHelpers = ns.UIHelpers or require("Susurrus.UI.Helpers")
local SettingsControls = ns.SettingsControls or require("Susurrus.UI.Shared.SettingsControls")
local Localization = ns.Localization or require("Susurrus.Locale.Localization")
local PickerPopup = ns.PickerPopup or require("Susurrus.UI.Shared.PickerPopup")

-- One window for both directions of the history sync. Export shows the text
-- to copy (read only, already selected); Import has an empty box to paste
-- into and an Import button that reports what was merged.
local HistoryTransferDialog = {}

HistoryTransferDialog.FRAME_NAME = "SusurrusHistoryTransferDialog"

local WIDTH = 480
local PADDING = 18
local TITLE_SPACE = 30
local BOX_HEIGHT = 150
local BOX_INSET = 8
local BUTTON_WIDTH = 130
local BUTTON_GAP = 10
local TEXT_GAP = 8
local FRAME_RADIUS = 10
local INPUT_RADIUS = 6
local SCROLL_STEP = 40

local dialogs = setmetatable({}, { __mode = "k" })

local function createText(parent, font)
  local label = parent:CreateFontString(nil, "OVERLAY", font)
  label:SetJustifyH("LEFT")
  label:SetJustifyV("TOP")
  label:SetWordWrap(true)
  return label
end

local function createButton(factory, body)
  return UIHelpers.createOptionButton(factory, body, "", SettingsControls.OptionButtonColors(Theme), {
    height = Theme.LAYOUT.OPTION_BUTTON_HEIGHT,
    width = BUTTON_WIDTH,
  })
end

local function setStatus(dialog, message, isError)
  dialog.status:SetText(message or "")
  local colors = Theme.COLORS
  UIHelpers.setTextColor(dialog.status, isError and (colors.danger_text or colors.text_primary) or (colors.accent or colors.text_primary))
end

local function refreshImportButton(dialog)
  if dialog.mode ~= "import" then
    return
  end
  local text = dialog.box:GetText() or ""
  local ready = #text > 20
  dialog.actionButton:SetEnabled(ready)
  dialog.actionButton:SetAlpha(ready and 1 or 0.5)
end

local function build(factory)
  local dialog = factory.CreateFrame("Frame", HistoryTransferDialog.FRAME_NAME, _G.UIParent)
  dialog:SetFrameStrata("DIALOG")
  if dialog.SetToplevel then
    dialog:SetToplevel(true)
  end
  dialog:EnableMouse(true)
  dialog:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 80)

  dialog.background = UIHelpers.createRoundedBackground(dialog, FRAME_RADIUS)
  dialog.outline = UIHelpers.createBorderBox(dialog, Theme.COLORS.divider, 1, "BORDER")

  local body = factory.CreateFrame("Frame", nil, dialog)
  body:SetAllPoints(dialog)
  body:SetFrameLevel(dialog:GetFrameLevel() + 2)
  dialog.body = body

  dialog.title = createText(body, Theme.FONTS.icon_label)
  dialog.title:SetPoint("TOP", body, "TOP", 0, -PADDING)
  dialog.title:SetJustifyH("CENTER")

  dialog.instruction = createText(body, Theme.FONTS.system_text)
  dialog.instruction:SetPoint("TOPLEFT", body, "TOPLEFT", PADDING, -(PADDING + TITLE_SPACE))
  dialog.instruction:SetWidth(WIDTH - PADDING * 2)

  local boxFrame = factory.CreateFrame("Frame", nil, body)
  boxFrame:SetSize(WIDTH - PADDING * 2, BOX_HEIGHT)
  dialog.boxFrame = boxFrame
  boxFrame.background = UIHelpers.createRoundedBackground(boxFrame, INPUT_RADIUS)

  local scroll = factory.CreateFrame("ScrollFrame", nil, boxFrame)
  scroll:SetPoint("TOPLEFT", boxFrame, "TOPLEFT", BOX_INSET, -BOX_INSET)
  scroll:SetPoint("BOTTOMRIGHT", boxFrame, "BOTTOMRIGHT", -BOX_INSET, BOX_INSET)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    local nextValue = (self:GetVerticalScroll() or 0) - delta * SCROLL_STEP
    self:SetVerticalScroll(math.max(0, math.min(range, nextValue)))
  end)
  dialog.scroll = scroll

  local box = factory.CreateFrame("EditBox", nil, scroll)
  UIHelpers.setFontObject(box, Theme.FONTS.composer_input)
  box:SetMultiLine(true)
  box:SetAutoFocus(false)
  box:SetMaxLetters(0)
  box:SetWidth(WIDTH - PADDING * 2 - BOX_INSET * 2)
  box:SetHeight(BOX_HEIGHT - BOX_INSET * 2)
  scroll:SetScrollChild(box)
  dialog.box = box

  -- Keep the caret in view while typing or pasting.
  box:SetScript("OnCursorChanged", function(self, _, y, _, height)
    local parent = self:GetParent()
    local top = -(y or 0)
    local offset = parent:GetVerticalScroll() or 0
    if top < offset then
      parent:SetVerticalScroll(top)
    else
      local bottom = top + (height or 0)
      local visible = offset + parent:GetHeight()
      if bottom > visible then
        parent:SetVerticalScroll(bottom - parent:GetHeight())
      end
    end
  end)
  box:SetScript("OnTextChanged", function(self, userInput)
    if dialog.mode == "export" and userInput and dialog.lockedText then
      self:SetText(dialog.lockedText)
      self:HighlightText()
      return
    end
    if scroll.UpdateScrollChildRect then
      scroll:UpdateScrollChildRect()
    end
    refreshImportButton(dialog)
  end)
  box:SetScript("OnEscapePressed", function()
    dialog:Hide()
  end)
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function()
    box:SetFocus()
  end)

  dialog.status = createText(body, Theme.FONTS.contact_preview)
  dialog.status:SetWidth(WIDTH - PADDING * 2)

  dialog.actionButton = createButton(factory, body)
  dialog.closeButton = createButton(factory, body)
  dialog.closeButton:SetScript("OnClick", function()
    dialog:Hide()
  end)
  dialog.actionButton:SetScript("OnClick", function()
    local handler = dialog.onAction
    if type(handler) ~= "function" then
      return
    end
    local ok, message = handler(dialog.box:GetText() or "")
    setStatus(dialog, message, ok ~= true)
    if ok == true then
      dialog.actionButton:SetEnabled(false)
      dialog.actionButton:SetAlpha(0.5)
    end
  end)

  dialog:SetScript("OnHide", function()
    box:ClearFocus()
    box:SetText("")
    dialog.lockedText = nil
  end)

  PickerPopup.RegisterEscape(HistoryTransferDialog.FRAME_NAME, dialog)
  dialog:Hide()
  return dialog
end

local function paint(dialog)
  if dialog.background and dialog.background.setColor then
    dialog.background.setColor(Theme.COLORS.bg_primary)
  end
  UIHelpers.applyBorderBoxColor(dialog.outline, Theme.COLORS.divider)
  if dialog.boxFrame.background and dialog.boxFrame.background.setColor then
    dialog.boxFrame.background.setColor(Theme.COLORS.bg_input)
  end
  UIHelpers.setTextColor(dialog.title, Theme.COLORS.text_primary)
  UIHelpers.setTextColor(dialog.instruction, Theme.COLORS.text_secondary)
  UIHelpers.setTextColor(dialog.box, Theme.COLORS.text_primary)
end

local function layout(dialog, showAction)
  local body = dialog.body
  local instructionHeight = dialog.instruction:GetStringHeight() or 0
  dialog.boxFrame:ClearAllPoints()
  dialog.boxFrame:SetPoint("TOPLEFT", dialog.instruction, "BOTTOMLEFT", 0, -TEXT_GAP)
  dialog.status:ClearAllPoints()
  dialog.status:SetPoint("TOPLEFT", dialog.boxFrame, "BOTTOMLEFT", 0, -TEXT_GAP)

  dialog.actionButton:ClearAllPoints()
  dialog.closeButton:ClearAllPoints()
  if showAction then
    dialog.actionButton:Show()
    dialog.actionButton:SetPoint("BOTTOMRIGHT", body, "BOTTOM", -BUTTON_GAP / 2, PADDING)
    dialog.closeButton:SetPoint("BOTTOMLEFT", body, "BOTTOM", BUTTON_GAP / 2, PADDING)
  else
    dialog.actionButton:Hide()
    dialog.closeButton:SetPoint("BOTTOM", body, "BOTTOM", 0, PADDING)
  end

  local height = PADDING + TITLE_SPACE + instructionHeight + TEXT_GAP + BOX_HEIGHT + TEXT_GAP + 32 + TEXT_GAP + Theme.LAYOUT.OPTION_BUTTON_HEIGHT + PADDING
  dialog:SetSize(WIDTH, height)
end

-- spec fields:
--   mode         "export" or "import"
--   title, instruction, close (localized labels)
--   text         the text to copy (export)
--   action       label of the Import button (import)
--   onAction(text) -> ok, message (import)
--   notice       optional line shown under the box when it opens
--   noticeIsError  true to show the notice as an error
function HistoryTransferDialog.Show(factory, spec)
  local dialog = dialogs[factory]
  if dialog == nil then
    dialog = build(factory)
    dialogs[factory] = dialog
  end

  dialog.mode = spec.mode
  dialog.onAction = spec.onAction
  dialog.title:SetText(spec.title or "")
  dialog.instruction:SetText(spec.instruction or "")
  dialog.closeButton.label:SetText(spec.close or Localization.Text("Close"))
  dialog.actionButton.label:SetText(spec.action or "")
  setStatus(dialog, spec.notice, spec.noticeIsError == true)
  paint(dialog)
  layout(dialog, spec.mode == "import")
  dialog:Show()

  dialog.scroll:SetVerticalScroll(0)
  if spec.mode == "export" then
    dialog.lockedText = spec.text or ""
    dialog.box:SetText(dialog.lockedText)
    dialog.box:SetFocus()
    dialog.box:HighlightText()
  else
    dialog.lockedText = nil
    dialog.box:SetText("")
    dialog.box:SetFocus()
  end
  refreshImportButton(dialog)
  return dialog
end

ns.HistoryTransferDialog = HistoryTransferDialog
return HistoryTransferDialog
