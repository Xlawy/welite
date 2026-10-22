-- Real installed plugin, detail button, background Client HTTP and review UI.
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
local socket=require('socket')
local util=require('ffi/util')
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
    error('review UI did not complete')
end
local function count()
    local n=0;for _,request in ipairs(control().requests) do if request.api=='/review/list' then n=n+1 end end
    return n
end
local books=plugin.client:get_shelf().books
plugin:showBookMenu(books[1])
local detail=plugin._book_detail_view
assert(detail._action_buttons[1].text=='书评')
detail._action_buttons[1].callback()
local session=assert(plugin._book_reviews_session)
pump(function() return session.worker==nil end)
assert(session.view.result.items[1].content:match('^推荐书评：'))
local start=count()
session.view._tab_buttons[2].callback()
pump(function() return session.worker==nil end)
assert(session.view.result.items[1].content:match('^最新书评：'))
assert(count()==start+1)
session.view._tab_buttons[1].callback()
assert(count()==start+1,'cached tab must not request again')
UI:forceRePaint()
require('device').screen.bb:writePNG(home..'/../evidence/reviews-list.png')
session.view._review_buttons[1].callback()
assert(session.detail and session.detail.heading=='书评')
UI:forceRePaint()
require('device').screen.bb:writePNG(home..'/../evidence/reviews-detail.png')
session.detail:onClose()
assert(not session.view.closed,'closing review text must keep list available')
session.view:onClose()
assert(not detail.closed,'closing list must return to book details')
control{match='/review/list',status=503,times=-1}
detail._action_buttons[1].callback();session=assert(plugin._book_reviews_session)
pump(function() return session.worker==nil end)
assert(session.view._retry_button,'failed request must show retry')
control{match='',times=0,delay=0}
session.view._retry_button.callback();pump(function() return session.worker==nil end)
assert(session.view.result and not session.view.status)
plugin:closeWeReadUI()
assert(session.closed and detail.closed)
print('PASS: detail entry, HTTP recommended/latest, cache, full review, back navigation, HTTP 503 retry and cleanup')
