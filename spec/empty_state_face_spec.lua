-- Regression coverage for full-screen views whose empty states use TextWidget.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Widget = {}
Widget.__index = Widget

function Widget:extend(defaults)
    defaults = defaults or {}
    defaults.__index = defaults
    return setmetatable(defaults, { __index = self })
end

function Widget:new(values)
    values = values or {}
    setmetatable(values, { __index = self })
    if values.init then values:init() end
    return values
end

function Widget:getSize()
    local dimen = self.dimen or {}
    return { w = self.width or dimen.w or 100, h = self.height or dimen.h or 20 }
end

function Widget:getHeight()
    return self:getSize().h
end
function Widget:free() end

local function widget_module()
    return Widget:extend{}
end

local shown = {}
local has_keys = false
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY = 2,
        gray = function() return 2 end,
        new = function(width, height, btype)
            return { blitFrom = function() end, paintRect = function() end,
                free = function() end, getType = function() return btype end }
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["device"] = function()
    return {
        input = { group = { Back = "back" } },
        hasKeys = function() return has_keys end,
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
        },
    }
end
package.preload["ui/font"] = function()
    return { getFace = function(_self, name, size) return { name = name, size = size } end }
end
package.preload["ui/geometry"] = function()
    return {
        new = function(_self, values)
            values.copy = function(source)
                local copy = {}
                for key, value in pairs(source) do copy[key] = value end
                return copy
            end
            return values
        end,
    }
end
package.preload["ui/size"] = function()
    return {
        border = { thin = 1, window = 2 },
        padding = { small = 2, default = 4, large = 8 },
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function() end,
        nextTick = function(_self, callback) callback() end,
        setDirty = function() end,
    }
end
package.preload["ui/widget/textwidget"] = function()
    local TextWidget = widget_module()
    function TextWidget:new(values)
        expect(values.face ~= nil, "TextWidget empty state must provide a font face")
        return Widget.new(self, values)
    end
    return TextWidget
end
package.preload["ui/widget/focusmanager"] = function()
    local FocusManager = widget_module()
    FocusManager.FOCUS_ONLY_ON_NT = 0
    FocusManager.NOT_UNFOCUS = 1
    FocusManager.key_events = {}
    FocusManager.ges_events = {}
    function FocusManager:moveFocusTo() return true end
    function FocusManager.onFocusMove() return true end
    return FocusManager
end

for _, name in ipairs({
    "ui/gesturerange",
    "ui/widget/button",
    "ui/widget/container/centercontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/textboxwidget",
    "ui/widget/container/framecontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/container/scrollablecontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/imagewidget",
    "ui/widget/iconwidget",
    "ui/widget/linewidget",
    "ui/widget/overlapgroup",
    "ui/widget/titlebar",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/widget",
}) do
    package.preload[name] = widget_module
end
package.preload["ui/widget/button"] = function()
    local Button = Widget:extend{}
    function Button:init()
        self.label_widget = Widget:new{}
        self.label_container = { self.label_widget }
        self.frame = Widget:new{}
        self.dimen = {w=self.width or 100,h=self.height or 20}
    end
    return Button
end

package.preload["welite.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["welite.lib.book_reviews"] = function()
    return {
        format_date = function() return "" end,
        format_rating = tostring,
        preview = function(text) return text end,
    }
end

-- Optional geometry probe against KOReader's actual layout containers and Button.
-- Font rasterization, framebuffer, screen and event loop remain test doubles.
local native_widgets = os.getenv("KOREADER_WIDGET_DIR")
if native_widgets then
    package.preload["ui/bidi"] = function() return { mirroredUILayout = function() return false end } end
    package.preload["util"] = function() return {} end
    package.preload["gettext"] = function() return function(value) return value end end
    package.preload["logger"] = function() return { dbg = function() end } end
    package.preload["dbg"] = function() return { dassert = assert } end
    package.preload["ui/widget/iconwidget"] = widget_module
    package.preload["ui/widget/textboxwidget"] = widget_module
    G_defaults = { readSetting = function() return 24 end }
    function Widget:isTruncated() return false end
    function Widget:free() end
    local size = require("ui/size")
    size.border.button, size.padding.button = 1, 4
    for _, name in ipairs({
        "ui/widget/container/widgetcontainer", "ui/widget/container/framecontainer",
        "ui/widget/container/centercontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/textboxwidget", "ui/widget/container/leftcontainer",
        "ui/widget/horizontalgroup", "ui/widget/verticalgroup",
        "ui/widget/horizontalspan", "ui/widget/verticalspan", "ui/widget/button",
    }) do
        package.preload[name] = function() return dofile(native_widgets .. "/frontend/" .. name .. ".lua") end
    end
end

local LibraryView = require("welite.ui.library_view")
has_keys = true
local empty_paged_view
local ok, error_message = pcall(function()
    empty_paged_view = LibraryView.show({
        mode = "books", books = {}, accounts = {},
        paged = true, page = 9, page_size = 10,
    }, {})
end)
expect(ok, "empty bookshelf failed to build: " .. tostring(error_message))
expect(empty_paged_view.page == 1 and empty_paged_view.page_count == 1,
    "empty paged bookshelf did not initialize safe page metadata")
ok, error_message = pcall(function()
    empty_paged_view:onNextPage()
    empty_paged_view:onPrevPage()
end)
expect(ok, "empty paged bookshelf key navigation failed: " .. tostring(error_message))
has_keys = false

local books = {}
for index = 1, 25 do
    books[index] = { bookId = tostring(index), title = "Book " .. tostring(index) }
end
local changed_page
local paged_view = LibraryView.show({
    mode = "books", books = books, accounts = {},
    paged = true, page = 2, page_size = 10,
}, {
    on_page_changed = function(page) changed_page = page end,
})
expect(paged_view.page == 2 and paged_view.page_count == 3,
    "bookshelf page metadata was wrong")
expect(#paged_view._item_rows == 10,
    "paged bookshelf created rows outside the current page")
expect(#paged_view._page_buttons == 3,
    "paged bookshelf did not create navigation controls")
expect(paged_view._page_buttons[2].text == "2/3 pages",
    "bookshelf page indicator did not use compact current/total text")
expect((paged_view._page_buttons[1].height or 0) >= 54
        and (paged_view._page_buttons[3].height or 0) >= 54,
    "bookshelf page buttons lost their enlarged tap targets")
changed_page = nil
paged_view._page_buttons[1].callback()
expect(changed_page == 1, "previous-page button returned the wrong page")
changed_page = nil
paged_view._page_buttons[3].callback()
expect(changed_page == 3, "next-page button returned the wrong page")

local clamped_view = LibraryView.show({
    mode = "books", books = books, accounts = {},
    paged = true, page = 99, page_size = 10,
}, {})
expect(clamped_view.page == 3 and #clamped_view._item_rows == 5,
    "last bookshelf page was not clamped and sliced correctly")

local single_page_view = LibraryView.show({
    mode = "books", books = { books[1], books[2], books[3] }, accounts = {},
    paged = true, page = 1, page_size = 10,
}, {})
expect(single_page_view.page_count == 1
        and #single_page_view._item_rows == 3
        and single_page_view._page_buttons == nil,
    "single-page bookshelf created unnecessary navigation controls")

local exact_page_change
local exact_page_view = LibraryView.show({
    mode = "books", books = books, accounts = {},
    paged = true, page = 99, page_size = 5,
}, {
    on_page_changed = function(page) exact_page_change = page end,
})
expect(exact_page_view.page == 5 and exact_page_view.page_count == 5
        and #exact_page_view._item_rows == 5,
    "exact page-size multiple produced the wrong last page")
exact_page_view._page_buttons[3].callback()
expect(exact_page_change == nil,
    "next-page button advanced beyond the last exact page")

local continuous_view = LibraryView.show({
    mode = "books", books = books, accounts = {}, paged = false,
}, {})
expect(#continuous_view._item_rows == #books
        and continuous_view._page_buttons == nil,
    "continuous bookshelf did not retain the complete result list")

local accounts = {}
for index = 1, 12 do
    accounts[index] = { bookId = "mp-" .. tostring(index), title = "Account " .. tostring(index) }
end
local account_view = LibraryView.show({
    mode = "public_account", books = books, accounts = accounts,
    paged = true, page = 2, page_size = 10,
}, {})
expect(account_view.page_count == 2 and #account_view._item_rows == 2
        and account_view._item_rows[1].text == "Account 11",
    "public-account pagination used the wrong source or slice")

local account_cover_paths = { [accounts[1]] = "/covers/account.jpg" }
local account_cover_view = LibraryView.show({
    mode = "public_account", books = books, accounts = accounts,
    paged = true, page = 1, page_size = 6,
    cover_mode = true, cover_columns = 3, cover_paths = account_cover_paths,
}, {})
expect(account_cover_view.page_count == 2 and #account_cover_view._item_rows == 6
        and #account_cover_view._focus_item_rows == 2
        and account_cover_view._item_rows[1]._has_cover == true
        and account_cover_view._item_rows[1]._cover_fit == "contain"
        and account_cover_view._item_rows[1]._has_download_status == false,
    "public-account cover mode did not reuse the book-cover grid safely")

local large_shelf = {}
for index = 1, 1000 do
    large_shelf[index] = { bookId = tostring(index), title = "Book " .. tostring(index) }
end
local large_view = LibraryView.show({
    mode = "books", books = large_shelf, accounts = {},
    paged = true, page = 50, page_size = 10,
}, {})
expect(large_view.page_count == 100 and #large_view._item_rows == 10,
    "large bookshelf created more than one page of row widgets")

books[1]._cached = true
books[1].finishReading = "1"
books[1].secret = "1"
local cover_paths = { [books[1]] = "/covers/one.jpg" }
local cover_view = LibraryView.show({
    mode = "books", books = books, accounts = {},
    paged = true, page = 1, page_size = 6,
    cover_mode = true, cover_columns = 3, cover_paths = cover_paths,
}, {})
expect(cover_view.page_count == 5 and #cover_view._item_rows == 6,
    "cover bookshelf created more than the current six-item page")
expect(#cover_view._focus_item_rows == 2
        and #cover_view._focus_item_rows[1] == 3
        and #cover_view._focus_item_rows[2] == 3,
    "cover bookshelf did not build a three-by-two focus grid")
expect(cover_view._item_rows[1]._has_cover == true
        and cover_view._item_rows[2]._has_cover == false,
    "cover bookshelf did not distinguish cached covers from placeholders")
expect(cover_view._item_rows[1].status == nil,
    "cover bookshelf retained date or cache status metadata")
expect(cover_view._item_rows[1]._has_download_status == true
        and cover_view._item_rows[1]._download_status_checked == true
        and cover_view._item_rows[2]._has_download_status == false
        and cover_view._item_rows[2]._download_status_checked == false,
    "cover bookshelf download status did not follow download state")
expect(cover_view._item_rows[1]._has_finished_badge == true
        and cover_view._item_rows[2]._has_finished_badge == false,
    "cover bookshelf finished badge did not follow shelf completion state")
expect(cover_view._item_rows[1]._has_private_badge == true
        and cover_view._item_rows[1]._private_badge_size == 24
        and cover_view._item_rows[2]._has_private_badge == false,
    "cover bookshelf private badge did not follow the private-reading state")

-- Plain Widget wrappers must release their owned content on CloseWidget,
-- without consuming the event before sibling cards can be closed.
local closed_wrappers = 0
local function check_cover_close(widget)
    local owned = rawget(widget, "inner") or rawget(widget, "label") or rawget(widget, "content")
    if owned then
        local original_free, freed = owned.free, 0
        owned.free = function() freed = freed + 1 end
        expect(type(widget.onCloseWidget) == "function", "cover wrapper has no close handler")
        expect(not widget:onCloseWidget(), "cover wrapper consumed the close event")
        expect(freed == 1, "closing a cover wrapper did not release its content")
        owned.free = original_free
        closed_wrappers = closed_wrappers + 1
    end
    for _, child in ipairs(widget) do check_cover_close(child) end
end
check_cover_close(cover_view._item_rows[1])
expect(closed_wrappers == 3, "close regression missed the cover, finished badge or title")

-- The private-reading glyph must stay inside the pennant triangle at every
-- size the shelf can produce; small masks used to spill white pixels onto
-- the cover artwork beside the pennant's diagonal edge.
local private_badge = cover_view._item_rows[1]._private_badge
expect(private_badge and private_badge.size == 24, "private badge fixture missing")
local painted = {}
local paint_bb = { paintRect = function(_self, px, py, pw, ph, color)
    for yy = py, py + ph - 1 do
        painted[yy] = painted[yy] or {}
        for xx = px, px + pw - 1 do painted[yy][xx] = color end
    end
end }
private_badge:paintTo(paint_bb, 0, 0)
local spilled, glyph_pixels = 0, 0
for yy, row in pairs(painted) do
    for xx, color in pairs(row) do
        if color == 0 then glyph_pixels = glyph_pixels + 1 end
        if xx > yy then spilled = spilled + 1 end
    end
end
expect(glyph_pixels > 0, "private badge painted no glyph")
expect(spilled == 0, "private badge glyph spilled outside its pennant: " .. spilled .. " px")

-- Cover preparation must scale through KOReader's C (MuPDF) path instead of
-- the per-pixel Lua scaler, and a coverless card must keep its placeholder
-- centered like the pre-grid layout did.
local scale_calls, lua_scale_calls = 0, 0
local function fake_image(w, h)
    return {
        getWidth = function() return w end,
        getHeight = function() return h end,
        getType = function() return "fake-color8" end,
        free = function() end,
        scale = function(_self, nw, nh)
            lua_scale_calls = lua_scale_calls + 1
            return fake_image(nw, nh)
        end,
    }
end
package.preload["ui/renderimage"] = function()
    return {
        renderImageFile = function() return fake_image(300, 450) end,
        scaleBlitBuffer = function(_self, _bb, w, h)
            scale_calls = scale_calls + 1
            return fake_image(w, h)
        end,
    }
end
local scaled_books = { { bookId = "scaled", title = "Scaled" } }
local scaled_view = LibraryView.show({
    mode = "books", books = scaled_books, accounts = {},
    paged = true, page = 1, page_size = 6,
    cover_mode = true, cover_columns = 3,
    cover_paths = { [scaled_books[1]] = "/covers/scaled.jpg" },
}, {})
expect(scaled_view._item_rows[1]._has_cover == true,
    "mocked cover pipeline did not produce a cover widget")
expect(scale_calls > 0 and lua_scale_calls == 0,
    "cover preparation used the per-pixel Lua scaler: lua=" .. lua_scale_calls
        .. " c=" .. scale_calls)
local mp_accounts = { { bookId = "MP_WXS_scaled", title = "Account",
    cover = "http://wx.qlogo.cn/avatar" } }
local mp_scale_before = scale_calls
LibraryView.show({
    mode = "public_account", books = {}, accounts = mp_accounts,
    paged = true, page = 1, page_size = 6,
    cover_mode = true, cover_columns = 3,
    cover_paths = { [mp_accounts[1]] = "/covers/mp.jpg" },
}, {})
expect(scale_calls > mp_scale_before,
    "contained avatar preparation used the per-pixel Lua scaler")
expect(cover_view._item_rows[2]._placeholder_centered == true,
    "coverless card did not center its placeholder text")
expect(cover_view._item_rows[1].width == 200
        and cover_view._item_rows[3].width == 200,
    "cover bookshelf columns did not fill the complete screen width")
expect(cover_view._item_rows[1].height == cover_view.cover_cell_height
        and cover_view._item_rows[4].height
            == cover_view.cover_content_height - cover_view.cover_cell_height,
    "cover bookshelf rows did not fill the available content height")

local invalid_page_size_view = LibraryView.show({
    mode = "books", books = books, accounts = {},
    paged = true, page = 2, page_size = 0,
}, {})
expect(invalid_page_size_view.page_size == 1
        and invalid_page_size_view.page_count == #books
        and #invalid_page_size_view._item_rows == 1,
    "invalid page size was not clamped to a safe positive value")

local BookReviewsView = require("welite.ui.book_reviews_view")
ok, error_message = pcall(function()
    BookReviewsView.show({
        book_title = "Book",
        mode = "recommended",
        result = { items = {} },
    }, {})
end)
expect(ok, "empty review list failed to build: " .. tostring(error_message))
expect(#shown == 14, "all bookshelf and empty-state views should be shown")

expect(#paged_view._header_buttons == 5 and paged_view._tab_buttons == nil
        and paged_view._action_primary == nil, "shelf retained its permanent tabs or toolbars")
local width = 0
for _, button in ipairs(paged_view._header_buttons) do width = width + button:getSize().w end
expect(width <= 600, "compact header controls escaped the screen width")
expect(paged_view._header_buttons[2].width == nil and paged_view._header_buttons[2].max_width == 312,
    "source button must size its feedback to the label, with a screen-width cap")
changed_page = nil
expect(paged_view:onShelfSwipe(nil, { direction = "west" }) and changed_page == 3,
    "left swipe did not use the same next page as the button")
expect(not paged_view:onShelfSwipe(nil, { direction = "north" }), "shelf captured vertical scrolling")
expect(not continuous_view:onShelfSwipe(nil, { direction = "west" })
        and continuous_view.ges_events.ShelfSwipe == nil, "continuous list acquired a page swipe handler")

local function dialog_module()
    local Dialog = Widget:extend{}
    function Dialog:init()
        self[1] = { radius = 20 }
        self.movable = { { radius = 20 } }
        self.page_info = {}
        if self.items_per_page then
            self.inner_dimen = { h = self.height - 4 }
            self.item_dimen = {}
            self:_recalculateDimen()
        end
    end
    function Dialog:_recalculateDimen() end
    return Dialog
end
package.preload["ui/widget/menu"] = dialog_module
package.preload["ui/widget/buttondialog"] = dialog_module
local chosen_group, changed_type, display_key, display_value
local selector_view = LibraryView.show({
    mode = "books", books = books, accounts = {}, paged = true,
    group_key = "archive:1", group_label = "A long group name", total_books = 100,
    groups = { { key = "archive:1", label = "A long group name", books = books } },
}, {
    on_select_group = function(key) chosen_group = key end,
    on_switch = function(mode) changed_type = mode end,
    on_display_change = function(key, value) display_key, display_value = key, value end,
})
selector_view._header_buttons[2].callback()
local selector = shown[#shown]
expect(selector.items_per_page == 2 and #selector.item_table == 2 and selector.height < 400,
    "group chooser did not reuse a paginated native menu")
expect(selector.custom_title_bar[1].height == selector_view._header_buttons[2].height,
    "content switcher is shorter than the bookshelf header")
expect(selector.page_info.handleEvent and not selector.page_info:handleEvent({})
        and selector.item_dimen.h * selector.items_per_page == selector.available_height,
    "single-page picker retained footer controls or wasted row space")
selector.layout, selector.selected = { { {} } }, { y = 1 }
selector:mergeTitleBarIntoLayout()
expect(selector.selected.y == 3 and selector.layout[1][1] == selector.custom_title_bar[1]
        and selector.layout[2][1] == selector.custom_title_bar[2],
    "content tabs are not reachable using vertical five-way navigation")
selector.item_table[2].callback()
expect(chosen_group == "archive:1", "group picker used position instead of stable server ID")
selector.custom_title_bar[2].callback()
expect(changed_type == "public_account", "content picker lost the public-account action")
selector_view:showOptions()
local options_dialog = shown[#shown]
expect(#options_dialog.buttons == 2, "shelf options should only expose sort and filter")
expect(display_key == nil and display_value == nil, "opening options must not change the view")
selector_view.groups = {}
for i = 1, 11 do selector_view.groups[i] = { key = tostring(i), label = tostring(i), books = {} } end
selector_view:showSourceMenu()
local fitting_selector = shown[#shown]
expect(fitting_selector.items_per_page == 12 and fitting_selector.page_info.paintTo ~= nil,
    "picker paginated groups that still fit on one screen")
for i = 12, 25 do selector_view.groups[i] = { key = tostring(i), label = tostring(i), books = {} } end
selector_view:showSourceMenu()
local long_selector = shown[#shown]
expect(long_selector.items_per_page < #long_selector.item_table and long_selector.height <= 800
        and long_selector.page_info.handleEvent == nil,
    "overflowing picker lost pagination or exceeded the screen")
if native_widgets then
    local layout = LibraryView.getLayout(true, 100)
    expect(layout.rows == 3 and layout.page_size == 9, "compact 600x800 shelf did not reclaim a third cover row")
    local native_view = LibraryView.show({
        mode = "books", books = books, accounts = {}, paged = true,
        cover_mode = true, cover_columns = layout.columns, cover_rows = layout.rows,
        page_size = layout.page_size,
    }, {})
    expect(native_view[1][1]:getSize().h == 800, "native header, viewport and pager exceed the screen height")
    expect(native_view[1][1][1]:getSize().h == 73, "native header is taller than a single button row")
    expect(native_view[1][1][3]:getSize().h == 54, "native pager padding escaped its reserved height")
    local list_layout = LibraryView.getLayout(false, 100)
    local native_list = LibraryView.show({
        mode = "books", books = books, accounts = {}, paged = true, page_size = list_layout.page_size,
    }, {})
    expect(native_list.scroll[1]:getSize().h <= native_list.scroll.dimen.h,
        "native list rows require scrolling in page mode")
    print("native bookshelf geometry: real KOReader Button and layout containers passed")
end

print(("empty_state_face_spec: %d checks"):format(checks))
