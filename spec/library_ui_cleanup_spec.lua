-- Regression coverage for full-screen WeRead views left in UIManager's stack.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local closed = {}
package.preload["ui/uimanager"] = function()
    return {
        close = function(_self, view) closed[#closed + 1] = view end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end

for _, name in ipairs({
    "ui/widget/buttondialog",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
    "ui/widget/inputdialog",
    "ui/widget/progressbardialog",
    "ui/widget/textviewer",
}) do
    package.preload[name] = function() return {} end
end
package.preload["welite.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["welite.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["welite.ui.book_reviews_view"] = function() return {} end
package.preload["welite.lib.content"] = function()
    return { load_catalog_cache = function() return nil end }
end
package.preload["welite.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["welite.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end

local detail_data
local detail_view = { id = "detail" }
local chapter_view = { id = "chapters" }
package.preload["welite.ui.book_detail_view"] = function()
    return { show = function(data)
        detail_data=data
        expect(data.cover_path == "/fixture-cover.png", "detail receives only the cached cover path")
        return detail_view
    end }
end
package.preload["welite.ui.chapter_list_view"] = function()
    return { show = function() return chapter_view end }
end

local Library = require("welite.ui.library")
local books = {}
local opened
local host = {
    settings = {
        get = function(_self, key, default)
            if key == "books" then return books end
            return default
        end,
    },
    ui = {
        openFile = function(_self, path) opened = path end,
    },
    getShelfCoverCache = function() return {pathFor=function() return "/fixture-cover.png" end} end,
    getFullBookCachePath = function() return "/missing.epub" end,
    bookRecordHasDownload = function() return false end,
    safeCallback = function(_self, _label, callback) return callback end,
    showInfo = function() end,
    loadChapters = function(_self, _book, callback)
        callback({ { chapterUid = 1, title = "One", wordCount = 10 } })
    end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

local book = { book_id = "book", title = "Book", chapters = {} }
host:showBookMenu(book)
local reviewed
host.showBookReviews=function(_,chosen) reviewed=chosen end
detail_data.review_action.callback()
expect(reviewed==book,"book detail review action must open reviews for the selected book")
expect(host._book_detail_view == detail_view,
    "book detail view was not tracked")

host:showChapterList(book)
expect(host._chapter_list_view == chapter_view,
    "chapter list view was not tracked")

local shelf_view = { id = "shelf" }
host.shelf_view = shelf_view
host:openFile("/cache/book.epub")
expect(opened == "/cache/book.epub", "document was not opened")
expect(#closed == 3
        and closed[1] == chapter_view
        and closed[2] == detail_view
        and closed[3] == shelf_view,
    "WeRead views were not closed from topmost to bottommost")
expect(host._chapter_list_view == nil
        and host._book_detail_view == nil
        and host.shelf_view == nil,
    "closed WeRead view references were retained")

closed = {}
host.shelf_view = shelf_view
host:openFile(nil)
expect(#closed == 0 and host.shelf_view == shelf_view,
    "invalid open request unexpectedly closed the bookshelf")


local review_closed=false
host._time_review_session={close=function() review_closed=true end}
require("welite.ui.library").closeWeReadUI(host)
expect(review_closed,'closing plugin UI must close time review and its confirmation')
closed = {}
host.shelf_view = shelf_view
local settings_closed = 0
host.welite_settings_ui = {close=function() settings_closed=settings_closed+1 end}
expect(host:onCloseWidget() == nil, 'host teardown must propagate to native handlers')
expect(host.shelf_view == nil and closed[1] == shelf_view,
    'host teardown must release independent shelf window')
expect(settings_closed == 1, 'host teardown must close plugin settings')
host:onCloseWidget()
expect(#closed == 1, 'repeated host cleanup must not close stale shelf references')

print(("library_ui_cleanup_spec: %d checks"):format(checks))
