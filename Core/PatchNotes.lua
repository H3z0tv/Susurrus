local addonName, ns = ...
if type(ns) ~= "table" then
  ns = {}
end

local PatchNotes = {
  version = "0.2.6",
  date = "2026-11-06",
  lines = {
    "Susurrus is now All Rights Reserved. The LICENSE file, the README and the addon info are updated. Nothing changes in how the addon works.",
  },
}

ns.PatchNotes = PatchNotes

return PatchNotes
