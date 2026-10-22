-- From the KOReader directory: ./luajit /path/to/probe/spec/koreader/annotation_cancel.lua /path/to/probe
-- Probe contains this file, annotation_sync_controller_spec + its SQLite helper,
-- and the changed controller/pipeline. Uses real Trapper/fork/pipes, dummy HTTP,
-- test databases and inert widgets; never touches accounts or the open reader.
local probe_root = assert(arg[1], "probe directory required")
dofile("setupkoenv.lua")
package.path = probe_root .. "/?.lua;plugins/welite.koplugin/?.lua;" .. package.path
-- Keep the native FFI module loaded once: reloading its C declarations after
-- the fixture replaces package.loaded would redefine platform structs.
local FFIUtil = require("ffi/util")
package.loaded["ffi/util"] = {}
dofile(probe_root .. "/spec/annotation_sync_controller_spec.lua")
package.loaded["ffi/util"] = FFIUtil
package.loaded["ui/trapper"], package.preload["ui/trapper"] = nil, nil
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/trapwidget"] = function() return {} end
package.preload.gettext = function() return function(text) return text end end
require("logger").dbg = function() end
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local socket = require("socket")
local tasks, guards, killed, writes = {}, 0, 0, 0
UIManager.preventStandby = function() guards = guards + 1 end
UIManager.allowStandby = function() guards = guards - 1 end
UIManager.scheduleIn = function(_self, delay, callback)
    tasks[#tasks + 1] = { at = socket.gettime() + delay, callback = callback }
end
UIManager.unschedule = function(_self, callback)
    for index = #tasks, 1, -1 do
        if tasks[index].callback == callback then table.remove(tasks, index) end
    end
end
local Guard = require("weread.lib.standby_guard")
Guard.acquire = function() UIManager:preventStandby(); return {} end
Guard.release = function() UIManager:allowStandby() end
local terminate = FFIUtil.terminateSubProcess
FFIUtil.terminateSubProcess = function(pid)
    killed = killed + 1
    return terminate(pid)
end
local function pump()
    local deadline = socket.gettime() + 12
    while #tasks > 0 do
        assert(socket.gettime() < deadline, "native worker did not settle")
        table.sort(tasks, function(a, b) return a.at < b.at end)
        if tasks[1].at <= socket.gettime() then table.remove(tasks, 1).callback()
        else FFIUtil.usleep(10000) end
    end
end
local flush = function() error("child flushed parent settings") end
local host = setmetatable({
    settings = { get = function(_self, _key, default) return default end, flush = flush },
    _reader_session_gen = 1,
    ui = { document = { file = "probe.epub" } },
    client = {
        build_chapter_review_batches = function() return { { "0-1" } } end,
        get_chapter_reviews_batch = function()
            FFIUtil.usleep(5000000)
            return true, { reviews = {} }
        end,
    },
    isNetworkConnected = function() return true end,
    showInfo = function(_self, message) error(message) end,
    showTransientInfo = function() end,
}, { __index = require("weread.ui.annotation_sync_controller") })
local context = { path = "probe.epub", book_id = "probe", binding = { title = "Probe" },
    chapters = { { chapterUid = "1" } }, ranges = {}, statuses = {}, document_key = "probe",
    store = {
        get = function(_self, _book, kind)
            if kind == "download" then return { revision = "1", next_batch = 1,
                underlines = { { range = "0-1", markText = "a" } } } end
        end,
        write = function() writes = writes + 1 end,
    },
}
host._annotation_context = context
host:_runAnnotationJob(context, {})
local request = host._external_annotation_sync
local elapsed
local function await_request()
    if not request.progress.dismiss_callback then
        UIManager:scheduleIn(0.01, await_request)
        return
    end
    assert(request.progress.current_title:find("Downloading thoughts", 1, true))
    local started = socket.gettime()
    UIManager:scheduleIn(0.1, function()
        request.progress.buttons[1][1].callback()
        elapsed = socket.gettime() - started
    end)
end
UIManager:scheduleIn(0.01, await_request)
pump()
assert(elapsed and elapsed < 1, "cancel waited for the slow HTTP request")
assert(killed == 1 and guards == 0 and writes == 0 and not host._external_annotation_sync)
assert(host.settings.flush == flush and not request.progress.dismiss_callback)
print(string.format("Native annotation cancel: %.3fs including 100ms input delay; child killed/reaped; no late writes; standby balanced", elapsed))

-- Check real pipe serialization preserves holes and binary text on success.
local success = { trapper = Trapper, progress = {} }
host._external_annotation_sync = success
local values
Trapper:wrap(function()
    values = host:_runAnnotationNetwork(success, function() return false, nil, "reason\0text" end)
end)
pump()
assert(values[1] == false and values[2] == nil and values[3] == "reason\0text")
assert(not success.progress.dismiss_callback and guards == 0 and host.settings.flush == flush)
print("Native annotation response: false/nil/binary payload preserved; settings isolated")

-- Use KOReader's real JSON codec, not the SQLite fixture codec above. JSON
-- null is a function in LuaJSON and cannot cross Trapper's table serializer.
package.loaded.json, package.preload.json = nil, nil
local Json = require("json")
local null = Json.decode("null")
local payload = string.rep("thought\0\255text", 100000)
local response_ok, response
Trapper:wrap(function()
    response_ok, response = pcall(host._runAnnotationNetwork, host, success, function()
        local data = Json.decode('{"optional":null,"nested":[null,{"value":null}]}')
        data.content = payload
        return true, data
    end)
end)
pump()
assert(response_ok, tostring(response))
assert(response[1] == true and response[2].optional == null
    and response[2].nested[1] == null and response[2].nested[2].value == null
    and response[2].content == payload and response[3] == nil)
Trapper:wrap(function()
    response_ok, response = pcall(host._runAnnotationNetwork, host, success, function()
        error("fixture child failure")
    end)
end)
pump()
assert(not response_ok and tostring(response):find("fixture child failure", 1, true))
print("Native annotation response: nested JSON null, large binary text and child errors preserved")
