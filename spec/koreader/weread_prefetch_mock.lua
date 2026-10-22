-- Actual WeLite settings -> upstream prefetch -> HTTP -> chapter EPUB/cache.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path='spec/front/unit/?.lua;'..package.path
require('commonrequire');disable_plugins()
G_reader_settings:saveSetting('language','zh_CN')
G_reader_settings:saveSetting('welite_preferences',{autostart=false})
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
load_plugin('welite.koplugin')
package.path=home..'/plugins/welite.koplugin/?.lua;'..package.path
local UI,Screen=require('ui/uimanager'),require('device').screen
local socket,util=require('socket'),require('ffi/util')
local settings=require('welite.lib.settings'):new()
assert(settings.mock_endpoint and settings.data_dir:match('/weread%-mock$'))
local http,json,ltn12=require('socket.http'),require('json'),require('ltn12')
local function control(values)
    local chunks,body={},values and json.encode(values)
    local _,status=http.request{url=settings.mock_endpoint..(values and '/__control' or '/__state'),
        method=values and 'POST' or 'GET',headers={['Content-Type']='application/json',['Content-Length']=body and #body or 0},
        source=body and ltn12.source.string(body),sink=ltn12.sink.table(chunks)}
    assert(status==200);return json.decode(table.concat(chunks))
end
UI:setRunForeverMode();UI:setInputTimeout(0)
local function pump(predicate)
    local deadline=socket.gettime()+30
    repeat UI:handleInput();if predicate() then return end;util.usleep(10000) until socket.gettime()>deadline
    error('prefetch UI did not complete')
end
local cache=settings:get('cache');cache.auto_prefetch_next_chapter=false;cache.prefetch_annotations=false
cache.show_annotations=false;settings:set('cache',cache)
settings:set('sync',{pull_on_open=false,upload_on_close=false})
local report=settings:get('read_report');report.enabled=false;settings:set('read_report',report)
local client=require('welite.lib.client'):new(settings)
local Content=require('welite.lib.content')
local book=client:get_book_info('900001')
Content.ensure_reader_state(client,book)
local chapters=Content.fetch_catalog(client,book)
Content.save_catalog_cache(client,settings,book,chapters)
local path=Content.fetch_chapter_epub(client,settings,book,chapters[1])
settings:set('books',{['900001']=book});settings:flush()
local reader,plugin
local function open(book_path)
    reader=require('apps/reader/readerui'):new{dimen=Screen:getSize(),document=require('document/documentregistry'):openDocument(book_path)}
    UI:show(reader);plugin=assert(reader.welite)
    pump(function() return plugin._current_weread_book_id=='900001' end)
end
open(path)
-- Enable this book's external annotations through the native chapter picker.
local picker=assert(plugin:chooseAnnotationChapters())
picker.layout[1][1].callback();pump(function() return picker.model.count==1 end)
picker.action_button.callback()
pump(function() return not plugin._external_annotation_sync and plugin:_annotationStore():get('900001','source_status','1')~=nil end)
local controller=require('welite.ui.welite.home').settings(plugin)
controller:show();controller.dialog.buttons[3][1].callback()
local tr=require('welite.lib.i18n').tr
local function select(label,confirm)
    local item
    for _,candidate in ipairs(controller.menu.item_table) do
        if candidate.text==tr(label) then item=candidate;break end
    end
    assert(item,'missing setting: '..label)
    controller.menu:onMenuSelect(item)
    if confirm then
        local popup=UI._window_stack[#UI._window_stack].widget
        assert(popup.ok_callback,'expected upstream confirmation')
        UI:close(popup);popup.ok_callback()
    end
end
select('Automatically prefetch next chapter',true)
select('Show prefetch notifications')
local function saved() return plugin.settings:get('books')['900001'] end
pump(function() return saved().cached_chapters['2'] and not plugin.downloader._active_job end)
assert(reader.document.file==path,'background prefetch must not switch the open chapter')
local second=saved().cached_chapters['2']
local file=assert(io.open(second,'rb'));assert(file:read(2)=='PK');file:close()
assert(not saved().cached_chapters['3'],'upstream prefetch must remain bounded to the next chapter')
-- Enabling annotation prefetch after the next EPUB is already cached must act.
select('Prefetch underlines and thoughts',true)
pump(function() return not plugin._external_annotation_sync and plugin:_annotationStore():get('900001','source_status','2')~=nil end)
UI:forceRePaint();Screen.bb:writePNG(home..'/../evidence/prefetch-settings.png')
controller:close();reader:onClose()
-- Next opening starts chapter 3; deliberately slow the content transport.
local delayed_before=control().delayed_requests
control{match='/web/book/chapter/e_0',delay=3,times=0}
open(second)
pump(function() return plugin.downloader:getActivePrefetch()~=nil and control().delayed_requests>delayed_before end)
controller=require('welite.ui.welite.home').settings(plugin);controller:show();controller.dialog.buttons[3][1].callback()
local started=socket.gettime();select('Automatically prefetch next chapter')
local cancellation_seconds=socket.gettime()-started
assert(cancellation_seconds<1,'turning prefetch off must not block on the network')
print(string.format('In-flight HTTP cancellation: %.3f seconds',cancellation_seconds))
pump(function() return plugin.downloader._active_job==nil end)
assert(not saved().cached_chapters['3'],'cancelled prefetch must not publish a late result')
control{match='',delay=0,times=0}
select('Automatically prefetch next chapter',true)
pump(function() return saved().cached_chapters['3'] and not plugin.downloader._active_job end)
assert(reader.document.file==second)
controller:close();reader:onClose()
print('PASS: native settings -> next chapter EPUB, cached-next annotation prefetch, bounded one-chapter scope, cancellation and restart')
