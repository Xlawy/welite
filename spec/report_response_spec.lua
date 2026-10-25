package.path='./?.lua;'..package.path
local R=require('welite.lib.report_response')
assert(R.accepted({succ=1},200))
assert(R.accepted({data={synckey='receipt'}},'200'))
for _,status in ipairs({302,401,429,500,503}) do
    assert(not R.accepted({succ=1},status),'HTTP failure cannot acknowledge time')
end
for _,value in ipairs({{errCode=-1,data={succ=1}}, {succ=1,errcode=-2},
    {data={synckey='old',succ=0}}, {succ='0'}}) do
    assert(not R.accepted(value,200) and R.rejected(value),'explicit rejection wins')
end
for _,value in ipairs({{},'timeout',{data={}}, {succ='maybe'}}) do
    assert(not R.accepted(value,200) and not R.rejected(value),'unknown receipt stays unknown')
end
local summary=R.summary(nil,{succ=0,token='private',body=string.rep('secret',10000)},500)
assert(#summary<200 and not summary:find('private') and not summary:find('secret'))

assert(R.accepted({succ='1'},200),'string success flag remains compatible')
assert(not R.accepted({errorCode='invalid',result={succ=1}},200) and not R.rejected({errorCode='invalid'}),'ambiguous error cannot authorize replay')

assert(R.settlement(nil)=='unknown' and R.settlement({accepted='yes'})=='unknown')
assert(R.settlement({accepted=true})=='accepted')
assert(R.settlement({time_report_sent=false})=='retryable')
assert(R.settlement({time_rejected=true})=='retryable')
assert(R.settlement({time_report_sent=true})=='unknown')
print('report_response_spec: HTTP/business precedence, settlement, ambiguous receipts and bounded private diagnostics passed')
