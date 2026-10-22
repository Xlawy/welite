package.path='./?.lua;'..package.path
local fingerprint='one'
package.preload['weread.lib.worker_settings']=function() return {
 fingerprint=function() return fingerprint end,capture=function() return function() return {} end end,
 merge=function() end} end
package.preload['apps/reader/readerui']=function() return {} end
local job
local queue={}
package.preload['ui/uimanager']=function() return {
 scheduleIn=function(_,delay,fn) assert(delay>0);queue[#queue+1]=fn end,
 unschedule=function(_,fn) for i=#queue,1,-1 do if queue[i]==fn then table.remove(queue,i) end end end,
} end
package.preload['weread.lib.background_worker']=function() return {new=function() return {
 start=function(_,value) job=value;return true end} end} end
local Sync=require('weread.lib.closed_progress_sync')
local function position(offset) return {account_id='one',book_id='b',percent=offset/10,
 chapter_uid=1,chapter_idx=1,chapter_offset=offset,position_basis='source_utf16'} end
local sent,locks,unlocks=0,0,0
local cloud=100
local books={}
local settings={data_dir='/tmp',get=function(_,k,d)
 if k=='books' then return books elseif k=='account' then return {user_vid='one'} end;return d end,
 set=function(_,k,v) if k=='books' then books=v end end,flush=function() end}
local p={settings=settings,client={get_progress=function() return {book={progress=cloud/10,chapterUid=1,chapterOffset=cloud}} end},
 read_report={time_ledger={lock_position=function() locks=locks+1;return {} end,
 unlock_position=function(_,lock) if lock then unlocks=unlocks+1 end end},
 _renewal_allowed=function() return false end,
 _child_report=function(_,id,renew,pos,seconds)
 assert(id=='b' and seconds==0);sent=sent+1;cloud=pos.chapter_offset;return {accepted=true} end}}
local pending=position(500);pending.sync_base=position(100)
assert(Sync.reconcile(p,'b',pending).accepted and sent==1 and cloud==500)
pending.percent=50.9
assert(Sync.reconcile(p,'b',pending).accepted and sent==1,'rounded cloud percent at the same source offset must not resend')
cloud=700
assert(Sync.reconcile(p,'b',pending).conflict and sent==1,'changed cloud must not be overwritten')
pending.sync_base=nil;cloud=100
assert(Sync.reconcile(p,'b',pending).conflict,'unknown baseline needs a user choice')
books.b={last_reported_position={account='one',position=position(100)}}
assert(Sync.reconcile(p,'b',pending).accepted,'own acknowledged timer report is a valid cloud baseline')
cloud=100;books.b.last_reported_position.account='two'
assert(Sync.reconcile(p,'b',pending).conflict,'another account report cannot authorize upload')
local function prepare()
 pending=position(500);pending.sync_base=position(100);books={b={pending_upload_position=pending}}
 local result
 Sync.start(p,function(ok) result=ok end)
 return function() return result end
end
local result=prepare()
-- A real child receives an independent address space; build its result explicitly.
job.on_done{ok=true,value={receipts={b={accepted=true,position=position(500)}}}}
assert(result()==true and not books.b.pending_upload_position and unlocks==locks)
result=prepare();books.b.pending_upload_position=position(600)
job.on_done{ok=true,value={receipts={b={accepted=true,position=position(500)}}}}
assert(result()==false and books.b.pending_upload_position.chapter_offset==600,'newer close snapshot survives old receipt')
result=prepare();fingerprint='two'
job.on_done{ok=true,value={receipts={b={accepted=true,position=position(500)}}}}
assert(result()==false and books.b.pending_upload_position and unlocks==locks,'account switch discards data and releases locks')
fingerprint='one';result=prepare();job.on_done{ok=false,error='timeout'}
assert(result()==false and books.b.pending_upload_position and unlocks==locks,'unknown writes remain pending for readback')
local busy=true
p.read_report.time_ledger.has_pending_report=function() return busy end
job=nil;result=prepare()
assert(not job and result()==nil and #queue==1,'busy close upload must wait without starting a competing worker')
local held_locks=locks
for _=1,3 do table.remove(queue,1)() end
assert(locks==held_locks and result()==nil and #queue==1,'waiting polls only memory without taking locks')
-- The already-running close upload commits while the shelf waits.
books.b.pending_upload_position=nil;books.b.last_uploaded_position=position(500);busy=false
table.remove(queue,1)()
assert(result()==true and not job and #queue==0,'completed close upload requires no second position write')

busy=true;job=nil;result=prepare()
busy=false;books.b.pending_upload_position=position(600)
table.remove(queue,1)()
assert(job and result()==nil,'a failed close upload is reconciled using its current snapshot')
job.on_done{ok=true,value={receipts={b={accepted=true,position=position(600)}}}}
assert(result()==true and books.b.last_uploaded_position.chapter_offset==600)

busy=true;job=nil;result=prepare()
for _=1,Sync.MAX_WAIT_CHECKS do table.remove(queue,1)() end
assert(result()==false and not job and #queue==0 and books.b.pending_upload_position,'bounded waiting never discards unsent progress or reports success')

result=prepare();p.welite_closed_progress_worker:cancel()
assert(result()==false and #queue==0,'canceling the wait removes the scheduled callback')
result=prepare();fingerprint='two';table.remove(queue,1)()
assert(result()==false and #queue==0 and books.b.pending_upload_position,'account change cancels before acquiring any lock')
fingerprint='one';busy=false
print('closed_progress_sync_spec: baseline comparison, readback, newer snapshot, account isolation and timeout passed')
