package.path='./?.lua;'..package.path
local Ledger=require('weread.lib.reading_time_ledger')
local values,clock,writes={},0,0
local settings={get=function(_,k,d) return values[k] or d end,set=function(_,k,v) values[k]=v end,
 flush=function() writes=writes+1 end}
local function new() return Ledger.new(settings,function() return clock end) end
local ledger=new();assert(ledger:start('one','book'))
clock=12;ledger:checkpoint();assert(ledger:status('one','book').pending==12)
clock=39;local batch=assert(ledger:begin(30));assert(batch.seconds==30)
assert(ledger:status('one','book').pending==9)
assert(ledger:settle(batch,'accepted'));assert(not ledger:settle(batch,'accepted'))
clock=45;ledger:stop();assert(ledger:status('one','book').pending==15)
clock=600;ledger=new();assert(ledger:start('one','book'))
assert(ledger:status('one','book').pending==15,'suspend/restart downtime counted')
batch=assert(ledger:begin());assert(batch.seconds==15)
assert(ledger:settle(batch,'retryable'));assert(ledger:status('one','book').pending==15)
batch=assert(ledger:begin());assert(ledger:settle(batch,'unknown'))
assert(ledger:status('one','book').uncertain==15 and ledger:status('one','book').pending==0)
clock=620;batch=assert(ledger:begin());assert(batch.seconds==20,'uncertain duration replayed')
local dead_batch={};for k,v in pairs(batch) do dead_batch[k]=v end
batch=nil;assert(batch==nil);collectgarbage('collect')
ledger=new();assert(ledger:start('one','book'))
assert(ledger:status('one','book').uncertain==35,'crashed attempt not isolated')
assert(not ledger:settle(dead_batch,'accepted'),'old callback consumed recovered attempt')
clock=630;ledger:start('two','book');clock=640;ledger:stop()
assert(ledger:status('one','book').pending==10 and ledger:status('two','book').pending==10)
assert(ledger:status('one','book').acknowledged==30)
assert(not ledger:start(nil,'book'))
-- Bounds never evict unreported data.
for i=1,Ledger.MAX_ENTRIES-2 do
 assert(ledger:start('one','other'..i));clock=clock+1;ledger:stop()
end
local ok,err=ledger:start('one','overflow');assert(not ok and err=='time_ledger_full')
assert(ledger:status('one','book').uncertain==35)
print('reading_time_ledger_spec: elapsed time, persistence, restart, uncertainty, duplicate callbacks, accounts and bounds passed')

-- A failed checkpoint keeps elapsed time in memory and stops the clock, so a
-- later retry cannot count suspension or add the same interval a second time.
values={};clock=0;ledger=new();assert(ledger:start('one','book'))
local flush=settings.flush
settings.flush=function() error('disk unavailable') end
clock=1.4;assert(not pcall(ledger.stop,ledger));assert(ledger.active==nil)
settings.flush=flush;clock=100;assert(ledger:start('one','book'))
clock=101.6;ledger:stop();assert(math.abs(ledger:status('one','book').pending-3)<0.00001)
clock=102;ledger:start('one','book')
settings.flush=function() error('reservation write failed') end
assert(not pcall(ledger.begin,ledger));assert(ledger:status('one','book').inflight==0)
settings.flush=flush
batch=assert(ledger:begin());assert(batch.seconds==3,'failed reservation lost or duplicated elapsed time')
print('reading_time_ledger_spec: fractional sessions and persistence failure recovery passed')

-- Closed books can be drained without starting a timer, opening a document,
-- or selecting a reading position. Reservations remain durable and bounded.
values={};clock=0;ledger=new()
assert(ledger:start('one','b'));clock=450;ledger:stop()
assert(ledger:start('one','a'));clock=460;ledger:stop()
assert(ledger:start('two','a'));clock=480;ledger:stop()
local books=ledger:pending_books('one',1)
assert(#books==1 and books[1]=='a')
assert(#ledger:pending_books('missing')==0 and #ledger:pending_books('one',0)==0)
batch=assert(ledger:begin_pending('one','b',300));assert(batch.seconds==300)
assert(ledger.active==nil,'backlog reservation must not start a reading timer')
assert(not ledger:begin_pending('one','b'),'duplicate in-flight reservation')
assert(#ledger:pending_books('one')==1,'in-flight book must not be queued twice')
local fresh=new()
assert(fresh:status('one','b').inflight==300,'reservation must persist before sending')
assert(fresh:settle(batch,'accepted'));assert(not ledger:settle(batch,'accepted'))
assert(ledger:status('one','b').pending==150)
batch=assert(ledger:begin_pending('one','b'));assert(batch.seconds==150)
assert(ledger:settle(batch,'unknown'))
assert(#ledger:pending_books('one')==1,'uncertain time must not become retryable')
batch=assert(ledger:begin_pending('one','a'));assert(batch.seconds==10)
assert(ledger:settle(batch,'retryable'))
assert(ledger:status('two','a').pending==20,'another account must remain untouched')
assert(ledger:start('one','a'))
local _,busy=ledger:begin_pending('one','a');assert(busy=='reading_time_active')
ledger:stop()
settings.flush=function() error('backlog reservation write failed') end
assert(not pcall(ledger.begin_pending,ledger,'one','a'))
assert(ledger:status('one','a').pending==10 and ledger:status('one','a').inflight==0)
settings.flush=flush
batch=assert(ledger:begin_pending('one','a'));assert(batch.seconds==10)
assert(ledger:settle(batch,'accepted'))
assert(#ledger:pending_books('one')==0 and #ledger:pending_books('two')==1)
print('reading_time_ledger_spec: closed-book batches, durable ownership, retry and account isolation passed')

values={};clock=0;ledger=new()
ledger:start('one','recover');clock=40;ledger:stop()
local live=assert(ledger:begin_pending('one','recover',30))
assert(new():recover('one')==0,'live request must retain ownership')
local old_id=live.id;live=nil;assert(live==nil);collectgarbage('collect')
local recovered=new()
assert(recovered:recover('other')==0 and recovered:recover('one')==1)
assert(recovered:recover('one')==0,'recovery must be idempotent')
assert(recovered:status('one','recover').pending==10 and recovered:status('one','recover').uncertain==30)
assert(not recovered:settle({id=old_id,account='one',book='recover'},'accepted'))
local item=recovered:unresolved('one')[1]
assert(item.book=='recover' and item.seconds==30)
assert(not recovered:resolve('other',item.book,30,'counted',item.revision))
assert(not recovered:resolve('one',item.book,29,'counted',item.revision))
assert(recovered:resolve('one',item.book,30,'counted',item.revision))
assert(recovered:status('one','recover').acknowledged==0,'manual review is not a server receipt')
assert(#recovered:unresolved('one')==0)
-- Same duration in a newer unknown batch cannot be consumed by an old dialog.
recovered:start('one','recover');clock=60;recovered:stop()
live=assert(recovered:begin_pending('one','recover',30));recovered:settle(live,'unknown')
assert(not recovered:resolve('one',item.book,30,'counted',item.revision))
item=recovered:unresolved('one')[1]
assert(recovered:resolve('one',item.book,item.seconds,'retry',item.revision))
assert(recovered:status('one','recover').pending==30 and #recovered:unresolved('one')==0)
assert(not recovered:resolve('one',item.book,item.seconds,'retry',item.revision))
print('reading_time_ledger_spec: orphan recovery, explicit review, revision guards and no false acknowledgements passed')

values={};clock=0;ledger=new()
ledger:start('one','book');clock=20;ledger:stop()
local home=assert(ledger:begin_pending('one','book'))
assert(new():has_pending_report('one','book'),'home catch-up is visible across handles')
assert(not new():has_pending_report('two','book') and not new():has_pending_report('one','other'))
assert(ledger:start('one','book'),'home reporting must not block a new reading clock')
clock=35;ledger:checkpoint()
assert(ledger:status('one','book').pending==15 and ledger:status('one','book').inflight==20)
assert(not ledger:begin() and not ledger:lock_position('one','book'))
assert(ledger:settle(home,'accepted'));ledger:stop()
assert(not new():has_pending_report('one','book'),'settlement releases the shared slot')
local lock=assert(ledger:lock_position('one','book'))
local before_poll=writes
assert(new():has_pending_report('one','book'),'position writes are visible before shelf reservation')
assert(writes==before_poll,'checking a live request must not write the ledger')
assert(not ledger:begin_pending('one','book'),'progress write must block home time write')
assert(new():recover('one')==0)
assert(not new():lock_position('one','book'),'another reader must share the same write slot')
local other=assert(ledger:lock_position('two','book'));ledger:unlock_position(other)
ledger:unlock_position(lock)
local newer=assert(ledger:lock_position('one','book'));ledger:unlock_position(lock)
assert(not ledger:begin_pending('one','book'),'late unlock must not release a newer write')
ledger:unlock_position(newer)
assert(not new():has_pending_report('one','book'),'unlock releases the shared slot')
batch=assert(ledger:begin_pending('one','book'));assert(batch.seconds==15)
ledger:settle(batch,'accepted');assert(ledger:status('one','book').acknowledged==35)
print('reading_time_ledger_spec: uninterrupted timer and shared per-book network ownership passed')

-- Independent storage handles must share failed writes for one profile. The
-- fake disk changes only on successful flush, matching SQLite transactions.
local durable,fail_disk,wall={},false,0
local function clone(v)
 if type(v)~='table' then return v end
 local result={};for k,field in pairs(v) do result[k]=clone(field) end;return result
end
local function handle()
 local staged,key
 local storage={get=function(_,k,d) return clone(durable[k] or d) end,
  set=function(_,k,v) key=k;staged=clone(v) end,
  flush=function() if fail_disk then error('synthetic disk full') end;durable[key]=clone(staged) end}
 local result=Ledger.new(storage,function() return wall end)
 result.storage_id='/synthetic/shared-time-recovery'
 return result
end
local first,second=handle(),handle()
first:start('one','a');wall=10;fail_disk=true
assert(not pcall(first.stop,first));fail_disk=false
assert(second:status('one','a').pending==10,'another handle lost the failed checkpoint')
second:start('one','b');wall=15;second:stop()
first:start('one','a');wall=20;first:stop()
assert(handle():status('one','a').pending==15 and handle():status('one','b').pending==5)
local accepted=assert(first:begin_pending('one','a',10));fail_disk=true
assert(not pcall(first.settle,first,accepted,'accepted'));fail_disk=false
second:start('two','c');wall=23;second:stop()
assert(not first:settle(accepted,'accepted'))
assert(handle():status('one','a').acknowledged==10)
assert(handle():status('one','b').pending==5 and handle():status('two','c').pending==3)
-- Recovery must retry an unsaved acknowledgement even when no orphan needs
-- converting; otherwise the home screen can report success with a dirty ledger.
accepted=assert(first:begin_pending('one','a'));fail_disk=true
assert(not pcall(first.settle,first,accepted,'accepted'))
assert(not pcall(second.recover,second,'one'),'persistent failure must not become silent success')
assert(not pcall(second.lock_position,second,'one','a'),'new position writes must wait for the dirty acknowledgement to persist')
fail_disk=false;second:recover('one')
assert(durable.welite_reading_time.accounts.one.a.acknowledged==15)
assert(handle():status('two','c').pending==3)
print('reading_time_ledger_spec: cross-handle disk failure recovery preserves checkpoints and acknowledgements')

values={};clock=0;ledger=new()
for i=1,Ledger.MAX_ENTRIES do
 local book=string.format('settled%03d',i)
 assert(ledger:start('one',book));clock=clock+1
 local sent=assert(ledger:begin());assert(ledger:settle(sent,'accepted'));ledger:stop()
end
assert(ledger:start('one','new-book'),'settled bookkeeping must not permanently block new books')
ledger:stop()
local count=0;for _,items in pairs(values.welite_reading_time.accounts) do for _ in pairs(items) do count=count+1 end end
assert(count==Ledger.MAX_ENTRIES,'retirement must preserve the working-set bound')
print('reading_time_ledger_spec: completed bookkeeping does not exhaust the bounded working set')

-- Retirement must not consume uncertain, in-flight, fractional or locked data.
values={};clock=0;ledger=new()
ledger:start('one','fraction');clock=0.25;ledger:stop()
ledger:start('two','unknown');clock=1.25;ledger:stop()
local ambiguous=assert(ledger:begin_pending('two','unknown'));ledger:settle(ambiguous,'unknown')
ledger:start('one','flight');clock=2.25;ledger:stop()
local flying=assert(ledger:begin_pending('one','flight'))
ledger:start('one','locked');ledger:stop()
local held=assert(ledger:lock_position('one','locked'))
for i=1,Ledger.MAX_ENTRIES-4 do
 ledger:start('one',string.format('done%03d',i));ledger:stop()
end
assert(ledger:start('three','new'));ledger:stop()
assert(ledger:status('one','fraction').pending==0.25)
assert(ledger:status('two','unknown').uncertain==1)
assert(ledger:status('one','flight').inflight==1)
assert(not ledger:lock_position('one','locked'))
ledger:unlock_position(held);ledger:settle(flying,'retryable')
assert(ledger:status('one','flight').pending==1)
print('reading_time_ledger_spec: capacity retirement preserves every unsettled balance and live write')
