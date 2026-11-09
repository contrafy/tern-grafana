--!strict
-- Prints plugin/dynamictext.css (the stylesheet lib/panels/html_style
-- compiles inline styles against):
--   .tools/bin/luau scripts/gen-dynamictext-css.luau > plugin/dynamictext.css
local HtmlStyle = require("../plugin/lib/panels/html_style")
print((string.gsub(HtmlStyle.stylesheet(), "\n$", "")))
