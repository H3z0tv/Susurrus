-- Test harness resolves this module through ./?/init.lua.

return {
  IgnoreList = require("Susurrus.Model.Filters.IgnoreList"),
  KeywordRules = require("Susurrus.Model.Filters.KeywordRules"),
  RulePresets = require("Susurrus.Model.Filters.RulePresets"),
  DuplicateCollapse = require("Susurrus.Model.Filters.DuplicateCollapse"),
}
