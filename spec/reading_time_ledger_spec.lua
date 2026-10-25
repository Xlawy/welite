package.path='./?.lua;'..package.path
local Ledger=require('welite.lib.reading_time_ledger')
local function reserve(ledger,account,book,limit)
 local ok,err=ledger:start(account,book)
 if not ok then return nil,err end
 local batch,reason=ledger:begin(limit)
 ledger:stop()
 return batch,reason
end
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
assert(ledger:settle(batch,'accepted'));ledger:stop()
print('reading_time_ledger_spec: fractional sessions and persistence failure recovery passed')

-- Explicit online checkpoints survive a conservative pause; unobserved
-- disconnected time never becomes an uploadable balance.
values={};clock=0;ledger=new();ledger:start('one','book')
clock=10;ledger:checkpoint();clock=20;ledger:pause()
clock=600;ledger:checkpoint();assert(ledger:status('one','book').pending==10)
ledger:start('one','book');clock=610;batch=assert(ledger:begin())
assert(batch.seconds==20);ledger:settle(batch,'accepted');ledger:stop()
assert(ledger:status('one','book').acknowledged==20)
local lock=assert(ledger:lock_position('one','book'))
assert(new():has_pending_report('one','book'));assert(not new():lock_position('one','book'))
ledger:unlock_position(lock)
assert(not new():has_pending_report('one','book'))
print('reading_time_ledger_spec: online pause and shared position ownership passed')

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
local accepted=assert(reserve(first,'one','a',10));fail_disk=true
assert(not pcall(first.settle,first,accepted,'accepted'));fail_disk=false
second:start('two','c');wall=23;second:stop()
assert(not first:settle(accepted,'accepted'))
assert(handle():status('one','a').acknowledged==10)
assert(handle():status('one','b').pending==5 and handle():status('two','c').pending==3)
-- Recovery must retry an unsaved acknowledgement even when no orphan needs
-- converting; otherwise the home screen can report success with a dirty ledger.
accepted=assert(reserve(first,'one','a'));fail_disk=true
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
local ambiguous=assert(reserve(ledger,'two','unknown'));ledger:settle(ambiguous,'unknown')
ledger:start('one','flight');clock=2.25;ledger:stop()
local flying=assert(reserve(ledger,'one','flight'))
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
