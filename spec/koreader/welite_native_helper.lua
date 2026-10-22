-- Preserve the host helper and preload the FFI binding before Busted snapshots
-- package.loaded. Lua modules can be unloaded between suites; FFI metatypes
-- cannot, so reloading SQLite would mix new connection tables with old methods.
dofile('spec/helper.lua')
require('lua-ljsqlite3/init')
