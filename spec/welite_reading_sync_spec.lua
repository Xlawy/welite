package.path='./?.lua;'..package.path
local queue,calls,flushes={},0,0
local Reader={}
package.preload['apps/reader/readerui']=function() return Reader end
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,fn) queue[#queue+1]=fn end} end
local values={account={user_vid='one'}}
local settings={get=function(_,k,d) return values[k] or d end,
 set=function(_,k,v) values[k]=v end,flush=function() flushes=flushes+1 end}
local state={state='waiting'}
local id='a'
local plugin={settings=settings,ui={document={file='/a.epub'}},detectWeReadBook=function() return id end,
 progress_sync={status=function() return state end},onWeReadSyncProgress=function() calls=calls+1;return true end}
Reader.instance=plugin.ui
local Bridge=require('weread.ui.welite.reading_sync')
local function step() local fn=table.remove(queue,1);assert(fn);fn() end
Bridge.queue(plugin,{a=true,b=true})
assert(calls==0 and #queue==0,'refresh must not open reader, compare or show dialogs')
id='other';Bridge.onReaderReady(plugin);assert(#queue==0,'only the matching book triggers a check')
id='a';Bridge.onReaderReady(plugin);step()
assert(calls==0 and #queue==1,'wait for upstream initialization')
state.state='unverified';step();assert(calls==1 and #queue==0,'do not poll after starting upstream sync')
assert(values.welite_pending_progress_sync.books.a,'starting a request is not completion')
assert(not Bridge.complete(plugin,'a','another'),'another account cannot consume a marker')
assert(Bridge.complete(plugin,'a','one'),'completion can arrive arbitrarily later')
assert(not values.welite_pending_progress_sync.books.a and values.welite_pending_progress_sync.books.b)
local saved_flushes=flushes
assert(not Bridge.complete(plugin,'a','one') and flushes==saved_flushes,'duplicate completion avoids writes')
Bridge.onReaderReady(plugin);assert(#queue==0,'consumed marker does not repeat')
plugin.ui={document={file='/b.epub'}};Reader.instance=plugin.ui;id='b'
Bridge.onReaderReady(plugin);Reader.instance=nil;step()
assert(calls==1 and values.welite_pending_progress_sync.books.b,'closed reader leaves marker for next open')
Reader.instance=plugin.ui;Bridge.onReaderReady(plugin);values.account={user_vid='two'};step()
assert(calls==1,'account switch discards stale callback')
assert(not Bridge.complete(plugin,'b','one'),'old completion cannot consume after switching accounts')
Bridge.onReaderReady(plugin);assert(#queue==0,'another account cannot use old marker')
Bridge.queue(plugin,{b=true})
for _,status in ipairs({{state='awaiting_choice'},{state='pulling',pulling=true},
 {state='uploading',uploading=true},{state='offline'},{state='error'},
 {state='unverified',verified_reason='choice_cancelled'},
 {state='verified',verified=true,verified_reason='remote_selected'},
 {state='verified',verified=true,verified_reason='remote_chapter_applied'},
 {state='verified',verified=true,verified_reason='local_selected'}}) do
 state=status;Bridge.onReaderReady(plugin);step()
 assert(calls==1 and #queue==0 and values.welite_pending_progress_sync.books.b,
  'upstream ownership, failure, cancel or local selection must neither restart nor consume')
end
state={state='verified',verified=true,verified_reason='positions_match'}
Bridge.onReaderReady(plugin);step()
assert(not values.welite_pending_progress_sync.books.b,'already completed automatic verification is consumed')
Bridge.queue(plugin,{b=true});state={state='waiting'};Bridge.onReaderReady(plugin)
local count=0;while #queue>0 do step();count=count+1;assert(count<=30) end
assert(count==30 and values.welite_pending_progress_sync.books.b,'initialization wait has a fixed upper bound')
assert(Bridge.complete(plugin,'b','two'),'late successful manual retry still completes after initialization timeout')
print('welite_reading_sync_spec: deferred initialization, event completion, persistence, cancellation and account isolation passed')
