-- Actual shelf search entry -> input -> Client HTTP -> result -> book detail.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path='spec/front/unit/?.lua;'..package.path
require('commonrequire');disable_plugins()
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('welite_preferences',{autostart=false})
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
load_plugin('welite.koplugin')
package.path=home..'/plugins/welite.koplugin/?.lua;'..package.path
local UI=require('ui/uimanager')
local socket,util=require('socket'),require('ffi/util')
local Plugin=dofile(home..'/plugins/welite.koplugin/main.lua')
local plugin=Plugin:new{ui={menu={registerToMainMenu=function() end}}}
assert(plugin.settings.mock_endpoint and plugin.settings.data_dir:match('/weread%-mock$'))
local http,json,ltn12=require('socket.http'),require('json'),require('ltn12')
local function control(values)
    local chunks,body={},values and json.encode(values)
    local _,status=http.request{url=plugin.settings.mock_endpoint..(values and '/__control' or '/__state'),
        method=values and 'POST' or 'GET',headers={['Content-Type']='application/json',['Content-Length']=body and #body or 0},
        source=body and ltn12.source.string(body),sink=ltn12.sink.table(chunks)}
    assert(status==200);return json.decode(table.concat(chunks))
end
UI:setRunForeverMode();UI:setInputTimeout(0)
local function pump(predicate)
    local deadline=socket.gettime()+20
    repeat UI:handleInput();if predicate() then return end;util.usleep(10000) until socket.gettime()>deadline
    error('search UI did not complete')
end
local function input(query)
    local dialog
    for _,window in ipairs(UI._window_stack) do
        if getmetatable(window.widget)==require('ui/widget/inputdialog') then dialog=window.widget end
    end
    assert(dialog,'search entry must open a query dialog')
    dialog:setInputText(query)
    dialog.button_table:getButtonById('search').callback()
    return assert(plugin._book_search_session)
end
local shelf=plugin.client:get_shelf()
plugin.settings:set('shelf',{view_mode='cover',sort_order='default'})
plugin:applyShelfSnapshot(shelf.books,shelf.archive)
plugin:showShelfView('books')
local homeview=plugin.shelf_view
assert(homeview.search_button and homeview.filter_button)
UI:forceRePaint();require("device").screen.bb:writePNG(home.."/../evidence/search-home.png")
homeview.search_button.callback()
local session=input('山谷')
pump(function() return not session.worker end)
assert(#session.view.items>0 and #session.view.items<=10)
assert(UI:getTopmostVisibleWidget()==session.view,"background shelf updates must not cover search results")
local expected=session.view.items[1].title
UI:forceRePaint();require('device').screen.bb:writePNG(home..'/../evidence/search-results.png')
session.view._item_buttons[1].callback()
pump(function() return plugin._book_detail_view~=nil end)
local detail=plugin._book_detail_view
assert(detail.data.title==expected,'result selection must open the correct book')
local info_session=assert(plugin._book_info_session,'uncached details must load in background')
pump(function() return info_session.closed end)
assert(plugin._book_detail_view==detail,'completion must update the existing detail modal')
local selected=session.view.items[1]
local saved=plugin.settings:get('books')[tostring(selected.book_id or selected.bookId)]
assert(saved and saved.detail_updated_at,'HTTP detail refresh must persist metadata')
detail:onClose()
assert(not session.view.closed,'return from detail must keep search results')
session.view._action_button.callback();session=input('不存在的合成书名')
pump(function() return not session.worker end)
assert(#session.view.items==0 and session.view.status==nil)
control{match='/store/search',status=503,times=-1}
session.view._action_button.callback();session=input('山谷')
pump(function() return not session.worker end)
assert(session.view._retry_button)
control{match='',times=0,delay=0}
session.view._retry_button.callback();pump(function() return not session.worker end)
assert(#session.view.items>0 and session.view.status==nil)
session.view:onClose()
assert(not homeview.welite_closed,'closing search must preserve home shelf')
plugin:closeWeReadUI()
print('PASS: shelf search, real query input, HTTP results, correct details, back navigation, empty results and HTTP 503 retry')
