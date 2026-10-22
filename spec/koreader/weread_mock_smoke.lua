-- Standalone real-KOReader smoke. See docs/mock-weread.md for the command.
-- luacheck: globals fastforward_ui_events
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
package.path = "spec/front/unit/?.lua;" .. package.path
require("commonrequire")
disable_plugins()
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("extra_plugin_paths", { home .. "/plugins" })
load_plugin("welite.koplugin")
-- PluginLoader restores package.path after loading; later lazy requires in
-- this standalone test need the same installed candidate directory.
package.path = home .. "/plugins/welite.koplugin/?.lua;" .. package.path

local Settings = require("welite.lib.settings")
local Client = require("welite.lib.client")
local Content = require("welite.lib.content")
local settings = Settings:new()
assert(settings.mock_endpoint and settings.data_dir:match("/weread%-mock$"), "isolated mock environment")
local client = Client:new(settings)
-- A configured Internet proxy must not intercept local mock traffic or probes.
local http = require("socket.http")
http.PROXY = "http://127.0.0.1:1"
assert(client:test_mock_connection(require("welite.lib.mock_environment").active()) == settings.mock_endpoint)
local shelf = client:get_shelf()
assert(#shelf.books == 26 and #shelf.archive == 3, "shelf contract")
assert(http.PROXY == "http://127.0.0.1:1", "mock changed the global HTTP proxy")
local book = client:get_book_info("900001")
Content.ensure_reader_state(client, book)
local chapters = Content.fetch_catalog(client, book)
assert(#chapters == 6, "catalog contract")
assert(Content.save_catalog_cache(client, settings, book, chapters))
local path = Content.fetch_chapter_epub(client, settings, book, chapters[1])
settings:set("books", { [book.bookId] = book })
settings:flush()
local ok, marks = client:get_chapter_underlines(book.bookId, 1)
assert(ok and #marks.underlines == 1, "underlines contract")
local reviews_ok, thoughts = client:get_chapter_reviews(book.bookId, 1, { marks.underlines[1].range })
assert(reviews_ok and #thoughts.reviews == 1, "thoughts contract")
local denied, code = client:request({ url = "https://example.invalid/never-contact-upstream" })
assert(code == 501 and denied:find("Unimplemented mock route", 1, true), "HTTP must fail closed")

local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local reader = require("apps/reader/readerui"):new{
    dimen = Screen:getSize(),
    document = require("document/documentregistry"):openDocument(path),
}
assert(reader.welite, "real plugin instance")
UIManager:show(reader)
fastforward_ui_events()
assert(reader.document:getPageCount() > 1, "real downloaded EPUB must paginate")
reader.rolling:onGotoPage(1)
fastforward_ui_events()
Screen:shot(home .. "/../evidence/mock-page-1.png")
reader.rolling:onGotoPage(2)
fastforward_ui_events()
assert(reader:getCurrentPage() == 2, "real page turn")
Screen:shot(home .. "/../evidence/mock-page-2.png")
-- Exercise cancellation through the actual dialog, then resume the same workspace.
local socket, util = require("socket"), require("ffi/util")
local json, ltn12 = require("json"), require("ltn12")
local function control(values)
    local body, chunks = values and json.encode(values), {}
    local proxy = http.PROXY
    http.PROXY = nil
    local _, status = http.request{
        url = settings.mock_endpoint .. (values and "/__control" or "/__state"),
        method = values and "POST" or "GET",
        headers = { ["Content-Type"] = "application/json", ["Content-Length"] = body and #body or 0 },
        source = body and ltn12.source.string(body), sink = ltn12.sink.table(chunks),
    }
    http.PROXY = proxy
    assert(status == 200, "mock control failed")
    return json.decode(table.concat(chunks))
end
UIManager:setRunForeverMode()
UIManager:setInputTimeout(0)
local function pump(predicate)
    local deadline = socket.gettime() + 45
    repeat
        UIManager:handleInput()
        if predicate() then return end
        util.usleep(10000)
    until socket.gettime() > deadline
    error("download UI did not finish before deadline")
end
control{match="/web/book/chapter/e_0", delay=0.3, times=0}
local downloader = reader.welite.downloader
local cancelled, cancel_reason
assert(downloader:start(book, chapters, "full", {
    offer_read=false, silent_completion=true,
    on_complete=function(success, reason) cancelled=not success;cancel_reason=reason end,
}))
pump(function()
    local job = downloader._active_job
    return job and job.completed_count >= 1 and job.completed_count < #chapters and job.progress_dialog
end)
local interrupted = downloader._active_job
local saved_count = interrupted.completed_count
local started = socket.gettime()
interrupted.progress_dialog.buttons[1][1].callback()
assert(socket.gettime()-started < 1, "cancel button blocked the UI")
pump(function() return cancelled ~= nil and not downloader._active_job end)
assert(cancelled and cancel_reason == "cancelled", "cancel must not report success")
local preserved = 0
for index, chapter in ipairs(chapters) do
    if Content.full_download_chapter_exists(interrupted.workspace, chapter, index) then
        preserved = preserved + 1
    end
end
assert(preserved >= saved_count and preserved < #chapters, "completed chapters must survive cancellation")
assert(reader.document.file == path, "cancel must not switch the reader")
control{match="", delay=0, times=0}
local first_chapter_key
local function first_chapter_requests()
    local count = 0
    for _, request in ipairs(control().requests) do
        if request.path == "/web/book/chapter/e_0" then
            first_chapter_key = first_chapter_key or request.encoded_chapter
            if request.encoded_chapter == first_chapter_key then count = count + 1 end
        end
    end
    return count
end
local first_chapter_before = first_chapter_requests()
assert(first_chapter_key and first_chapter_before > 0)
local completed, full_path, download_error
assert(downloader:start(book, chapters, "full", {
    offer_read=false, silent_completion=true,
    on_complete=function(success, value)
        completed=success
        if success then full_path=value else download_error=tostring(value) end
    end,
}))
pump(function() return completed ~= nil and not downloader._active_job end)
assert(completed and full_path, download_error or "resumed download did not complete")
assert(first_chapter_requests() == first_chapter_before, "resume must not download the completed first chapter again")
print("PASS: real full-download cancel button preserves partial workspace and resumes without refetching completed chapter")
local file = assert(io.open(full_path, "rb"))
assert(file:read(2) == "PK", "full download must produce an EPUB ZIP")
file:close()
reader:onClose()
UIManager:quit()
print("PASS: mock HTTP -> real Client/Content/Downloader -> EPUB with image/footnote -> ReaderUI -> page 2")
print("EPUB: " .. path)
print("FULL EPUB: " .. full_path)
