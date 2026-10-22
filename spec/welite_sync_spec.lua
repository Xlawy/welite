package.path='./?.lua;'..package.path
local job,requests,fp=nil,{},'one'
package.preload['weread.lib.worker_settings']=function() return {
 fingerprint=function() return fp end,capture=function() return function() end end,merge=function() end} end
package.preload['weread.lib.background_worker']=function() return {new=function() return {
 start=function(_,value) job=value;return true end} end} end
package.preload['ui/uimanager']=function() return {close=function(_,v) v.welite_closed=true end} end
local position_syncs=0
package.preload['weread.ui.welite.reading_sync']=function() return {queue=function(_,ids) assert(ids['1'] or next(ids)==nil);position_syncs=position_syncs+1 end} end
local Sync=require('weread.ui.welite.sync')
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
-- Home orchestration uses the real ledger adapter, even when launch fails
-- synchronously or a credential change invalidates display updates.
local Ledger=require('weread.lib.reading_time_ledger')
local function with_time()
 local plugin,view=fixture()
 local values,clock={},0
 local ledger=Ledger.new({get=function(_,k,d) return values[k] or d end,
  set=function(_,k,value) values[k]=value end,flush=function() end},function() return clock end)
 ledger:start('one','1');clock=17;ledger:stop()
 plugin.read_report={time_ledger=ledger,_auth_fingerprint=function() return fp end,
  _context_fingerprint=function() return 'book' end,_renewal_allowed=function() return false end,
  _child_report=function(_,id,renew,position,seconds,cloud)
   assert(id=='1' and seconds==17 and cloud and position==nil)
   requests[#requests+1]='time';return {accepted=true,time_report_sent=true}
  end,_apply_job_outcome=function() end}
 return plugin,view,ledger
end
local ledger
p,v,ledger=with_time();requests={};Sync.refresh(p,v,{});complete()
assert(requests[1]=='shelf' and requests[2]=='time' and requests[3]=='monthly')
assert(ledger:status('one','1').acknowledged==17 and p.welite_shelf_status=='数据已刷新')
p,v,ledger=with_time();Sync.refresh(p,v,{});job.on_done{ok=false,cancelled=true}
assert(ledger:status('one','1').uncertain==17 and not p.books)
p,v,ledger=with_time();Sync.refresh(p,v,{});fp='two';complete()
assert(ledger:status('one','1').acknowledged==17 and not p.books,'old-account receipt settles only its own ledger')
fp='one'
local worker=require('weread.lib.background_worker');local original_new=worker.new
worker.new=function() return {start=function(_,options) options.on_done{ok=false,error='low_memory'};return false end} end
p,v,ledger=with_time();assert(not Sync.refresh(p,v,{}))
assert(ledger:status('one','1').pending==17 and ledger:status('one','1').uncertain==0)
worker.new=original_new
print('welite_sync_spec: catch-up ordering, cancellation, stale account receipts and synchronous launch failure passed')

p,v,ledger=with_time()
local flush=ledger.settings.flush
ledger.settings.flush=function() error('synthetic disk full') end
Sync.refresh(p,v,{});complete()
assert(p.welite_shelf_status=='同步未完成')
assert(p.message:find('synthetic disk full',1,true),'preserve the actual local storage failure for diagnosis')
ledger.settings.flush=flush;ledger:recover('one')
assert(ledger:status('one','1').pending==17,'failed reservation must retain all elapsed time')
print('welite_sync_spec: local storage errors retain pending time and expose the actual failure')
