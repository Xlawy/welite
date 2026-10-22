package.path='./?.lua;'..package.path
local job,launches,busy=nil,0,false
local worker={busy=function() return busy end,cancel=function() busy=false end,
    start=function(_,options) job=options;launches=launches+1;busy=true;return true end}
package.preload['weread.lib.background_worker']=function() return {new=function() return worker end} end
local fingerprint='one'
package.preload['weread.lib.worker_settings']=function() return {
    fingerprint=function() return fingerprint end,capture=function() return function() end end,merge=function() end,
} end
local calls,paint=0,0
local plugin={settings={data_dir='/tmp',is_api_configured=function() return true end,
    get=function(_,key) if key=='books' then local books={};for i=1,18 do books[tostring(i)]={cached_file='fixture.epub'} end;return books end;return {user_vid='one'} end},client={get_progress=function(_,id)
        calls=calls+1;return {book={progress=tonumber(id)}} end}}
local function view(page)
    local v={mode='books',page=page,page_size=6,items={},redraw=function() paint=paint+1 end}
    for i=1,18 do v.items[i]={kind='book',id=tostring(i)} end
    return v
end
local P=require('weread.ui.welite.progress')
local current=view(1);plugin.shelf_view=current
assert(P.ensure(plugin,current));assert(calls==0,'no requests in UI callback')
local result=job.task{checkCancelled=function() end}
assert(calls==6,'only current six books')
busy=false;job.on_done{ok=true,value=result}
assert(current.items[1].percent==1 and current.items[6].percent==6)
assert(current.items[7].percent==nil and launches==1,'no whole-shelf prefetch')
current=view(1);plugin.shelf_view=current
P.ensure(plugin,current)
assert(current.items[1].percent==1 and launches==1,'cached progress appears without requests')
current=view(2);plugin.shelf_view=current
P.ensure(plugin,current)
assert(launches==2)
plugin.client.get_progress=function() error('timeout') end
assert(not pcall(job.task,{checkCancelled=function() end}))
busy=false;job.on_done{ok=false,error='timeout'}
assert(launches==2 and current.items[7].percent==nil,'failure remains unknown with no retry loop')
local old=job
fingerprint='another-account'
old.on_done{ok=true,value={values={['7']=99}}}
assert(current.items[7].percent==nil,'old auth results discarded')
-- Paging during a running batch only starts the latest visible page after completion.
fingerprint='one';plugin.welite_progress=nil
plugin.client.get_progress=function(_,id) calls=calls+1;return {book={progress=0}} end
current=view(1);plugin.shelf_view=current;P.ensure(plugin,current)
result=job.task{checkCancelled=function() end}
current=view(3);plugin.shelf_view=current;P.ensure(plugin,current)
local before=launches
busy=false;job.on_done{ok=true,value=result}
assert(launches==before+1)
result=job.task{checkCancelled=function() end};busy=false;job.on_done{ok=true,value=result}
assert(current.items[13].percent==0,'zero is real progress, not missing')
print('welite_progress_spec: bounded visible-page requests, cache, failures, account isolation and page changes passed')

plugin.welite_progress=nil
plugin.settings.get=function(_,key) return key=='account' and {user_vid='one'} or {} end
current=view(1);plugin.shelf_view=current
local before=launches
P.ensure(plugin,current)
assert(launches==before,'unread cloud-only pages must not launch progress requests')
