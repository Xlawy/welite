local I18n = require("welite.lib.i18n")
local logger = require("welite.lib.logger")
local time = require("ui/time")
local T = require("ffi/util").template

local PluginUtil = {
    T = T,
    unpack_args = unpack or table.unpack,
}

function PluginUtil.tr(text)
    return I18n.tr(text)
end

function PluginUtil.log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

function PluginUtil.display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

function PluginUtil.file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

function PluginUtil.thought_perf(stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.dbg("thought_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed), ...)
end

-- KOReader's monotonic clock includes I/O and time spent yielding to the UI.
function PluginUtil.reader_open_perf(stage, started, ...)
    local now = time.now()
    logger.info("reader_open_perf", "stage=", stage,
        "wall_ms=", string.format("%.1f", started and tonumber(now - started) / 1000 or 0), ...)
    return now
end

return PluginUtil
