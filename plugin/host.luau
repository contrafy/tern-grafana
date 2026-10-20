--!strict
-- Host entry: registers blocks and lenses. Decisions live in plugin/lib; adapters execute them.

require("./query_host").register()
require("./settings_host").register()
require("./dashboard_host").register()
require("./panel_host").register()
require("./alerts_host").register()
require("./silence_host").register()
require("./alerts_poll_host").start()
require("./watches_poll_host").start()
require("./ops_host").register()
require("./logs_host").register()
require("./trace_host").register()
require("./investigate_host").register()
require("./annotations_host").register()
require("./impact_host").register()
require("./compat_host").register()
require("./irm_host").register()
require("./irm_poll_host").start()

local LensHost = require("./lens_host")
LensHost.define("promtool-query", require("./lib/lens/promtool_query").lens)
LensHost.define("promtool-check", require("./lib/lens/promtool_check").lens)
LensHost.define("curl", require("./lib/lens/curl").lens)
LensHost.define("amtool", require("./lib/lens/amtool").lens)
LensHost.define("logcli", require("./lib/lens/logcli").lens)

return nil
