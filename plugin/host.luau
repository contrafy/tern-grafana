--!strict
-- Host entry: registers blocks and lenses. Decisions live in plugin/lib; adapters execute them.

require("./query_host").register()
require("./settings_host").register()
require("./dashboard_host").register()
require("./panel_host").register()
require("./alerts_host").register()
require("./alerts_poll_host").start()
require("./lens_host").define("promtool-query", require("./lib/lens/promtool_query").lens)

return nil
