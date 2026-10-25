package.path='./?.lua;'..package.path
local job,requests,fp=nil,{},'one'
package.preload['welite.lib.worker_settings']=function() return {
 fingerprint=function() return fp end,capture=function() return function() end end,merge=function() end} end
package.preload['welite.lib.background_worker']=function() return {new=function() return {
 start=function(_,value) job=value;return true end} end} end
package.preload['ui/uimanager']=function() return {close=function(_,v) v.welite_closed=true end} end
local position_syncs=0
package.preload['welite.ui.welite.reading_sync']=function() return {queue=function(_,ids) assert(ids['1'] or next(ids)==nil);position_syncs=position_syncs+1 end} end
local Sync=require('welite.ui.welite.sync')
local function fixture(fail)
 local view={keyword='',setRefreshing=function(self,v) self.refreshing=v end,
 setSyncStatus=function(self,v) self.status=v end,redraw=function() end}
 local p={settings={data_dir='/tmp',get=function() return {user_vid='one'} end},shelf_view=view,
 requireLogin=function() return true end,client={
 get_shelf=function() requests[#requests+1]='shelf';if fail=='shelf' then error('fixture') end
 return {books={{bookId='1',progress=10,readUpdateTime=100},{bookId='2'},{bookId='MP_WXS_1'}}} end,
 get_progress=function(_,id) requests[#requests+1]='progress:'..id
 if fail=='progress' then error('fixture') end;return {book={progress=42}} end,
 get_read_stats=function(_,mode) requests[#requests+1]=mode
 if fail=='stats' then error('fixture') end;return {totalReadTime=120} end},
 showInfo=function(self,message) self.message=message end,
 applyShelfSnapshot=function(self,books) self.books=books end,
 showShelfView=function(self) self.shown=true;self.shelf_view=view;view.welite_closed=false end}
 return p,view
end
local function complete()
 job.on_done{ok=true,value=job.task{checkCancelled=function() end}}
end
local p,v=fixture();requests={}
assert(Sync.refresh(p,v,{}));assert(#requests==0 and v.refreshing,'UI callback does not do network IO')
assert(not Sync.refresh(p,v,{}),'duplicate sync suppressed')
complete()
assert(#requests==4,'shelf and statistics are complete; only recent progress is queried')
assert(p.books[2].progress==nil,'unselected books stay in the full bookshelf')
assert(p.books[1].progress==42 and p.welite_overview.weekly.total_seconds==120)
assert(p.welite_shelf_status=='数据已刷新' and not p.shelf_refreshing and p.shown)
assert(position_syncs==1,'shelf sync queues progress checks without opening a book')
for _,failure in ipairs({'shelf','stats','progress'}) do
 p,v=fixture(failure);Sync.refresh(p,v,{});complete()
 assert(p.welite_shelf_status=='同步未完成' and p.message,'partial failure cannot claim success')
 if failure=='shelf' then assert(p.welite_overview.monthly.total_seconds==120) end
 if failure=='stats' then assert(p.books[1].progress==42) end
end
p,v=fixture();Sync.refresh(p,v,{});fp='two';complete()
assert(not p.books and not p.welite_overview,'account switch discards stale results')
fp='one';p,v=fixture();Sync.refresh(p,v,{});job.on_done{ok=false}
assert(p.welite_shelf_status=='同步失败' and not p.shelf_refreshing)
p,v=fixture();Sync.refresh(p,v,{});v.welite_closed=true;complete()
assert(not p.shown,'closing shelf must not reopen it on completion')
-- A timeout after a completed six-book batch preserves that batch and stats.
p,v=fixture();Sync.refresh(p,v,{})
local saved={data={shelf={books={{bookId='1',progress=42}}},overview={monthly={total_seconds=120}},
    failed={},pending={['阅读进度']=true},progress_books={['1']=true}}}
job.on_progress{value=saved}
job.on_done{ok=false,error='worker_timeout'}
assert(p.books[1].progress==42 and p.welite_overview.monthly.total_seconds==120)
assert(p.welite_shelf_status=='同步未完成' and p.message:find('阅读进度'))
-- Explicit cancellation/account changes must not apply checkpoint data.
p,v=fixture();Sync.refresh(p,v,{});job.on_progress{value=saved};job.on_done{ok=false,cancelled=true}
assert(not p.books and p.welite_shelf_status=='同步失败')
-- Checkpoint count is bounded by batches, not one disk write per book.
p,v=fixture();p.client.get_shelf=function()
 local books={};for i=1,120 do books[i]={bookId=tostring(i),readUpdateTime=i} end;return {books=books}
end
Sync.refresh(p,v,{})
local emits=0
local result=job.task{checkCancelled=function() end,emit=function() emits=emits+1 end}
assert(emits==3 and next(result.data.pending)==nil,'only ten recent books: two initial checkpoints plus one six-book batch')
assert(#result.data.shelf.books==120 and result.data.progress_books['120'] and not result.data.progress_books['1'])
print('welite_sync_spec: upstream calls, forced progress refresh, partial failure, duplicate suppression and stale account passed')
-- Shelf refresh must not inspect or upload historical reading time.
for _, pending in ipairs({0,5338.75091}) do
 p,v=fixture();requests={}
 p.read_report={time_ledger=setmetatable({}, {__index=function() error('shelf touched reading-time ledger') end}),
  _child_report=function() error('shelf attempted time upload') end}
 p.historical_time=pending
 assert(Sync.refresh(p,v,{}));complete()
 assert(p.welite_shelf_status=='数据已刷新' and not p.message)
 assert(#requests==4 and p.historical_time==pending,'refresh must only read shelf, stats and progress')
end
local worker=require('welite.lib.background_worker');local original_new=worker.new
worker.new=function() return {start=function(_,options) options.on_done{ok=false,error='low_memory'};return false end} end
p,v=fixture();assert(not Sync.refresh(p,v,{}));assert(p.welite_shelf_status=='同步失败')
worker.new=original_new
print('welite_sync_spec: legacy time is ignored and shelf failures remain visible')

-- Current cloud records are authoritative; foreign local-only records are not.
p,v=fixture();requests={}
local shared={cached_file='retained-shared.epub',home_remote_position={account='old',position={percent=17}}}
local retained={['1']=shared,stale={readUpdateTime=999999,home_remote_position={account='old'}},
    legacy={cached_file='legacy.epub'},own={cached_file='own.epub',last_local_position={account_id='one'}}}
p.settings.get=function(_,key,default)
    if key=='account' then return {user_vid='one'} end
    if key=='books' then return retained end
    return default
end
p.settings.set=function(_,key,value) assert(key=='books');retained=value end
p.settings.flush=function() end
p.client.get_progress=function(_,id)
    requests[#requests+1]='progress:'..id
    assert(id=='1' or id=='own','foreign/legacy book was queried')
    return {book={progress=42,chapterUid=1,chapterOffset=42}}
end
for _=1,2 do
    assert(Sync.refresh(p,v,{}));complete()
    assert(p.welite_shelf_status=='数据已刷新')
    assert(shared.home_remote_position.account=='old' and shared.home_remote_position.position.percent==17,
        'shared cloud book overwrote the other account local reading state')
    assert(retained.stale and retained.legacy.cached_file=='legacy.epub','old caches were removed')
    assert(retained.own.home_remote_position.account=='one','same-account local-only progress was not saved')
end
p.client.get_progress=function() return {book={recordReadingTime=0}} end
assert(Sync.refresh(p,v,{}));complete()
assert(p.welite_shelf_status=='同步未完成' and p.message:find('阅读进度'),
    'missing current-account progress must remain a failure, not be hidden by the filter')
print('welite_sync_spec: retained foreign caches, shared-book write isolation, repeated sync and genuine failures passed')

-- The close-sync callback must carry book details through the shelf worker.
local closed=require('welite.lib.closed_progress_sync')
local original_start=closed.start
closed.start=function(_,done)
 done(false,{conflicts={count=7,books={{id='1',title='冲突书 🌿\n第二行'},{id='missing'}}},
  pending={count=1,books={{id='retry',title='网络失败书'}}}})
end
p,v=fixture();assert(Sync.refresh(p,v,{}));complete()
assert(p.message:find('《冲突书 🌿 第二行》',1,true) and p.message:find('书籍 ID：missing',1,true))
assert(p.message:find('另有 5 本未列出。',1,true) and p.message:find('《网络失败书》',1,true))
assert(p.message:find('有冲突',1,true) and p.message:find('尚未上传',1,true))
closed.start=function(_,done)
 done(false,{conflicts={count=0,books={}},pending={count=1,books={{id='1',title=string.rep('长🌿',200)}}}})
end
p,v=fixture();assert(Sync.refresh(p,v,{}));complete()
assert(not p.message:find('冲突',1,true) and p.message:find(string.rep('长🌿',30)..'…',1,true),
 'generic upload failure stays retryable and long Unicode titles are bounded')
closed.start=function(_,done) done(false) end
p,v=fixture();assert(Sync.refresh(p,v,{}));complete()
assert(p.message:find('仍有本地进度未上传',1,true) and not p.message:find('冲突',1,true))
closed.start=original_start
print('welite_sync_spec: conflict book names, ID fallback, omission count, bounded Unicode and failure-specific guidance passed')
