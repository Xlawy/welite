-- Run with KOREADER_WIDGET_DIR=/path/to/koreader luajit spec/koreader/shelf_picker_geometry.lua
-- Uses native Menu, Button and layout containers; fonts, screen and events are test doubles.
dofile('spec/empty_state_face_spec.lua')
local native = assert(os.getenv('KOREADER_WIDGET_DIR'))
local Device = require('device')
for _, name in ipairs({'hasKeyboard', 'hasFewKeys', 'hasScreenKB', 'hasDPad', 'hasSymKey'}) do Device[name] = function() return false end end
local Size = require('ui/size')
Size.line = { medium = 1 }
Size.span = { horizontal_default = 8, horizontal_small = 4, vertical_default = 8 }
Size.padding.fullscreen = 8
Size.border.default = 1
local BD = require('ui/bidi')
BD.rtlUIText = function() return false end
BD.ltr = function(text) return text end
G_reader_settings = { readSetting = function() end, isTrue = function() return false end }
local Font = require('ui/font')
Font.getFace = function(_, name, size) return { name = name, size = size, orig_size = size, orig_font = name } end
local FocusManager = require('ui/widget/focusmanager')
FocusManager.selected = { x = 1, y = 1 }
FocusManager.ges_events = {}
require('ui/widget/textboxwidget').getFontSizeToFitHeight = function() return 20 end
require('ui/widget/textwidget').getWidth = function(self) return self:getSize().w end
require('ui/widget/textwidget').setText = function(self, text) self.text = text end
package.preload.optmath = function() return { round = function(n) return math.floor(n + 0.5) end } end
for _, name in ipairs({'bottomcontainer', 'rightcontainer', 'underlinecontainer'}) do
    package.preload['ui/widget/container/' .. name] = function() return dofile(native .. '/frontend/ui/widget/container/' .. name .. '.lua') end
end
local Menu = dofile(native .. '/frontend/ui/widget/menu.lua')
package.loaded['ui/widget/menu'] = Menu
local shown
require('ui/uimanager').show = function(_, widget) shown = widget end
local LibraryView = require('welite.ui.library_view')
for _, count in ipairs({1, 8, 12, 13, 14, 26}) do
    local groups = {}
    for i = 2, count do groups[#groups + 1] = { key = tostring(i), label = 'Group ' .. i, books = {} } end
    local view = LibraryView.show({mode = 'books', books = {}, accounts = {}, groups = groups}, {})
    view:showSourceMenu()
    local dialog = shown
    assert(dialog.custom_title_bar:getSize().h == view._header_buttons[2]:getSize().h)
    assert(dialog.height <= 800)
    assert(dialog.item_group:getSize().h + dialog.custom_title_bar:getSize().h <= dialog.inner_dimen.h)
    if count <= 13 then
        assert(dialog.page_num == 1 and dialog.item_dimen.h == 54)
        assert(rawget(dialog.page_info, 'handleEvent') and not dialog.page_info:handleEvent({}))
        assert(dialog.height == 72 + count * 54 + 4)
    else
        assert(dialog.page_num > 1 and not rawget(dialog.page_info, 'handleEvent'))
        dialog:onNextPage()
        assert(dialog.page == 2)
    end
    print('Native source picker: ' .. count .. ' entries; ' .. dialog.page_num .. ' pages; ' .. dialog.height .. ' px')
end
