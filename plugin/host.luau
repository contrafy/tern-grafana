--!strict
-- Host entry: registers blocks and lenses. Decisions live in plugin/lib; adapters execute them.

require("./query_host").register()
require("./settings_host").register()
require("./dashboard_host").register()
require("./panel_host").register()
require("./alerts_host").register()
require("./silence_host").register()
require("./alerts_poll_host").start()
require("./ops_host").register()

local LensHost = require("./lens_host")
LensHost.define("promtool-query", require("./lib/lens/promtool_query").lens)
LensHost.define("promtool-check", require("./lib/lens/promtool_check").lens)
LensHost.define("curl", require("./lib/lens/curl").lens)
LensHost.define("amtool", require("./lib/lens/amtool").lens)
LensHost.define("logcli", require("./lib/lens/logcli").lens)

return nil
