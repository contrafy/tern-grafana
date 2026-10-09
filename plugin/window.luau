--!strict
-- Window entry: routes, palette commands and chrome. Decisions live in plugin/lib.

require("./links_window").register(tern)
require("./commands_window").register(tern)
require("./alerts_window").register(tern)

return nil
