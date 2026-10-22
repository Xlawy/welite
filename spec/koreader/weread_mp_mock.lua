-- Actual installed plugin, MP Client HTTP, disk cache and native HTML reader.
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
local reader,opened= nil,0
plugin.ui.openFile=function(_,path)
    opened=opened+1
    reader=require('apps/reader/readerui'):new{dimen=require('device').screen:getSize(),
        document=assert(require('document/documentregistry'):openDocument(path))}
    UI:show(reader)
end
local book={bookId='MP_WXS_fixture',title='合成公众号',author='合成作者'}
plugin.shelf_mp={book}
plugin:showMPShelfPage()
plugin._mp_session.view._item_buttons[1].callback()
local session=assert(plugin._mp_session)
pump(function() return session.worker==nil end)
assert(session.view.items[1].title=='公众号合成文章')
session.view._batch_buttons[1].callback();pump(function() return session.worker==nil end)
assert(session.offset==1 and #session.view.items==0 and not session.next_offset)
session.view._batch_buttons[1].callback();pump(function() return session.worker==nil end)
assert(session.offset==0 and session.view.items[1].title=='公众号合成文章')
UI:forceRePaint();require('device').screen.bb:writePNG(home..'/../evidence/mp-list.png')
control{match='/web/mp/articles',status=503,times=-1}
session.view._action_button.callback();pump(function() return session.worker==nil end)
assert(session.view._retry_button)
control{match='',times=0,delay=0}
session.view._retry_button.callback();pump(function() return session.worker==nil end)
local delayed=control().delayed_requests
control{match='/web/mp/content',delay=2}
session.view._item_buttons[1].callback()
local worker=assert(session.worker)
pump(function() return control().delayed_requests>delayed end)
session.view:onClose()
pump(function() return worker.job==nil end)
assert(opened==0 and session.closed)
local article=plugin:getCachedMPArticles(book.bookId)[1]
assert(not require('welite.lib.content').mp_article_cached_path(plugin.settings,book,article))
control{match='',delay=0,times=0}
plugin:showMPAccount(book);session=plugin._mp_session
assert(not session.worker,'cached list should not fetch')
session.view._item_buttons[1].callback()
pump(function() return reader~=nil end)
assert(session.closed and not plugin._mp_session)
assert(reader.document:getPageCount()>0)
UI:forceRePaint();require('device').screen.bb:writePNG(home..'/../evidence/mp-reader.png')
reader:onClose();reader=nil
local function content_count()
    local count=0
    for _,request in ipairs(control().requests) do if request.path=='/web/mp/content' then count=count+1 end end
    return count
end
local before=content_count()
plugin:showMPAccount(book);session=plugin._mp_session
session.view._item_buttons[1].callback()
assert(opened==2 and content_count()==before,'cached article must open without network')
reader:onClose();plugin:closeWeReadUI()
print('PASS: MP account selection, HTTP list, 503 retry, running download cancellation, HTML reader and offline cache')
