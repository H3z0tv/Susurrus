local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end

local PatchNotes = {
  version = "0.2.0",
  date = "2026-10-29",
  lines = {
    "New Susurrus Chat look, name and icon.",
    "Whispering someone from the friends list, a chat name or a menu opens Susurrus Chat, for character friends and Battle.net friends.",
    "New minimap button with an unread badge.",
    "New minimize button in the title bar: tucks the window away to the minimap button.",
    "Every option in Settings > Whispers is now on by default.",
  },
}

ns.PatchNotes = PatchNotes

return PatchNotes
