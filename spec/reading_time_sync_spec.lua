package.path='./?.lua;'..package.path
local Ledger=require('weread.lib.reading_time_ledger')
local Sync=require('weread.lib.reading_time_sync')
local function fixture()
 local values,now={},0
 local store={get=function(_,k,d) return values[k] or d end,set=function(_,k,v) values[k]=v end,flush=function() end}
 local ledger=Ledger.new(store,function() return now end)
 for i=1,8 do ledger:start('one',tostring(i));now=now+20;ledger:stop() end
 ledger:start('two','1');now=now+10;ledger:stop()
 local calls=0
 local report={time_ledger=ledger,_auth_fingerprint=function() return 'auth' end,
 _context_fingerprint=function(_,id) return id end,_renewal_allowed=function() return false end,
 _child_report=function(_,id,renewal,position,seconds,cloud)
  assert(position==nil and seconds==20 and cloud and not renewal);calls=calls+1
  return {accepted=true,time_report_sent=true}
 end,_apply_job_outcome=function() end}
 return ledger,report,function() return calls end
end
local ledger,report,calls=fixture()
local task=Sync.prepare(report,'one');assert(#task.batches==6 and calls()==0)
local emitted=0
local receipts=Sync.run(task,{checkCancelled=function() end},function(value)
 emitted=emitted+1;Sync.apply(task,value,true)
end)
assert(calls()==6 and emitted==6 and ledger:status('one','1').acknowledged==20)
Sync.apply(task,receipts,true);assert(ledger:status('one','1').acknowledged==20)
assert(not Sync.finish(task),'remaining backlog must not be reported as completely synchronized')
assert(ledger:status('two','1').pending==10)
for _,case in ipairs({{'retryable',{accepted=false,time_report_sent=false}},
 {'retryable',{accepted=false,time_report_sent=true,time_rejected=true}},
 {'unknown',{accepted=false,time_report_sent=true}}}) do
 ledger,report=fixture();task=Sync.prepare(report,'one')
 local b=task.batches[1];Sync.apply(task,{[tostring(b.id)]=case[2]},false)
 assert(not Sync.finish(task))
 local status=ledger:status('one',b.book)
 assert((case[1]=='retryable' and status.pending==20) or (case[1]=='unknown' and status.uncertain==20))
 assert(ledger:status('one','2').uncertain==20,'interrupted unsolved batch must not be blindly retried')
end
ledger,report=fixture();task=Sync.prepare(report,'one');Sync.finish(task,true)
assert(ledger:status('one','1').pending==20 and ledger:status('one','1').uncertain==0)
assert(Sync.finish(Sync.prepare(nil,'one')))
print('reading_time_sync_spec: bounded closed-book batches, parent settlement, duplicates, cancellation and account isolation passed')
