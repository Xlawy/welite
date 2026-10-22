package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

local calls = {}
package.preload["logger"] = function()
    local function capture(level, ...)
        calls[#calls + 1] = {
            level = level,
            args = { ... },
        }
    end
    return {
        dbg = function(...) capture("dbg", ...) end,
        info = function(...) capture("info", ...) end,
        warn = function(...) capture("warn", ...) end,
        err = function(...) capture("err", ...) end,
    }
end

local logger = require("welite.lib.logger")
logger.info("default message", "value")
logger.scoped("HTTP").err("scoped message")

expect(#calls == 2, "logger did not forward both calls")
expect(calls[1].level == "info", "default logger changed the level")
expect(calls[1].args[1] == "[WeLite]", "default logger omitted the prefix")
expect(calls[1].args[2] == "default message"
    and calls[1].args[3] == "value", "default logger changed arguments")
expect(calls[2].level == "err", "scoped logger changed the level")
expect(calls[2].args[1] == "[WeLite][HTTP]",
    "scoped logger omitted the scoped prefix")
expect(calls[2].args[2] == "scoped message",
    "scoped logger changed arguments")

-- Opening diagnostics must include waiting time, not just Lua CPU time.
local wall_now = require("ffi").new("int64_t", 1000000)
package.preload["ui/time"] = function() return { now = function() return wall_now end } end
package.preload["welite.lib.i18n"] = function() return { tr = function(s) return s end } end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
local perf = require("welite.lib.plugin_util").reader_open_perf
local started = perf("context_begin", nil)
wall_now = wall_now + 29000000
perf("chapter_source_cache", started, "book_id=", "fixture")
local args = calls[#calls].args
expect(args[2] == "reader_open_perf" and args[4] == "chapter_source_cache",
    "opening stage is not identifiable in the log")
expect(args[5] == "wall_ms=" and args[6] == "29000.0",
    "opening diagnostics omitted the 29-second wall-clock wait")
expect(args[7] == "book_id=" and args[8] == "fixture",
    "opening diagnostics lost book correlation")

print(("logger_spec: %d checks"):format(checks))
