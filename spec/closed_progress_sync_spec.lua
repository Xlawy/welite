package.path='./?.lua;'..package.path
local fingerprint='one'
package.preload['weread.lib.worker_settings']=function() return {
 fingerprint=function() return fingerprint end,capture=function() return function() return {} end end,
 merge=function() end} end
package.preload['apps/reader/readerui']=function() return {} end
local job
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
print('closed_progress_sync_spec: baseline comparison, readback, newer snapshot, account isolation and timeout passed')
