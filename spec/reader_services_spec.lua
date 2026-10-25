package.path='./?.lua;'..package.path
local scheduled={}
package.preload['ui/uimanager']=function() return {
 scheduleIn=function(_,delay,fn) scheduled[#scheduled+1]={delay,fn} end} end
package.preload['ui/event']=function() return {new=function(_,name,arg) return {name,arg} end} end
package.preload['welite.lib.plugin_util']=function() return {tr=function(s) return s end} end
local readers={}
package.preload['apps/reader/readerui']=function() return readers end
local document={file='/book.epub'}
local book={title='Book'}
local online=false
local plugin={settings={data_dir='/tmp',get=function(_,_,d) return d end,get_book=function(_,id)
 assert(id=='book');return book end},client={},ui={document=document,view={view_mode='page'}},
 detectWeReadBook=function() return 'book' end,isNetworkConnected=function() return online end,
 ensureChaptersLoaded=function(_,value) assert(value==book);return {{chapterUid=1}} end}
require('welite.lib.reader_services').attach(plugin)
assert(plugin.read_report.get_document()==document and plugin.progress_sync.get_document()==document)
assert(plugin.read_report.detect_book()=='book' and plugin.progress_sync.get_book('book')==book)
assert(not plugin.read_report.is_online() and not plugin.progress_sync.is_online())
online=true;assert(plugin.read_report.is_online() and plugin.progress_sync.is_online())
assert(plugin.progress_sync.can_finish_close_upload())
readers.instance={};assert(not plugin.progress_sync.can_finish_close_upload())
readers.instance=plugin.ui;assert(plugin.progress_sync.can_finish_close_upload())
readers.instance=nil
local events={}
plugin.ui.handleEvent=function(_,event) events[#events+1]=event end
assert(plugin.progress_sync.goto_fraction(0.1234))
assert(events[1][1]=='GotoPercent' and math.abs(events[1][2]-12.34)<1e-8)
local position,reason,required=plugin.read_report.position_provider('book')
assert(not position and reason=='progress_unverified' and required,'reporting must use progress verification gate')
assert(#scheduled==0,'composition must not schedule work or perform network I/O')
local Lifecycle=require('welite.lib.reader_lifecycle')
local connected,disconnected=0,0
plugin.read_report.on_network_connected=function() connected=connected+1 end
plugin.read_report.on_network_disconnected=function() disconnected=disconnected+1 end
Lifecycle.onNetworkConnected(plugin);Lifecycle.onNetworkDisconnected(plugin)
assert(connected==1 and disconnected==1,'host connectivity events reach the online clock')
print('reader_services_spec: service ownership, host navigation, connectivity and progress gate passed')
