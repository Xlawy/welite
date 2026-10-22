package.path='./?.lua;'..package.path
local task, launches= nil,0
local worker={busy=function() return false end,start=function(_,options) task=options;launches=launches+1;return true end}
package.preload['welite.lib.background_worker']=function() return {new=function() return worker end} end
local fingerprint='a'
package.preload['welite.lib.worker_settings']=function() return {
    fingerprint=function() return fingerprint end,capture=function() return function() end end,merge=function() end,
} end
local account='one'
local calls=0
local plugin={settings={data_dir='/tmp',get=function() return {user_vid=account} end},
    requireLogin=function() return true end,
    client={get_read_stats=function(_,mode) calls=calls+1;return {totalReadTime=3600,readTimes={}} end},
    showInfo=function(self,error) self.error=error end,
    showShelfView=function(self) self.rebuilt=true end}
local view={mode='books',page=2,redraw=function() plugin.rebuilt=true end};plugin.shelf_view=view
local Stats=require('welite.ui.welite.statistics')
assert(Stats.refresh(plugin,view));assert(calls==0,'UI callback must not make requests')
local result=task.task{checkCancelled=function() end}
assert(calls==2,'exactly monthly and weekly; no progress/shelf requests')
task.on_done{ok=true,value=result}
assert(plugin.welite_overview.monthly.total_seconds==3600 and plugin.rebuilt)
plugin.rebuilt=nil;account='two';task.on_done{ok=true,value=result};assert(not plugin.rebuilt)
account='one';fingerprint='changed';task.on_done{ok=true,value=result};assert(not plugin.rebuilt)
fingerprint='a';task.on_done{ok=false,error='timeout'};assert(plugin.error:find('timeout'))
assert(plugin.welite_overview.monthly.total_seconds==3600,'failure retains cached data')
worker.busy=function() return true end
assert(Stats.refresh(plugin,view)==false and launches==1,'no stacked jobs or retries')
print('welite_statistics_spec: bounded requests, failure, stale account/auth and busy passed')
-- Read failures never replace the last successful summary or trigger retry.
for _,reason in ipairs({'timeout','disconnected','authentication_expired','rate_limited'}) do
    local attempts=0
    plugin.client.get_read_stats=function() attempts=attempts+1;error(reason) end
    local ok=pcall(task.task,{checkCancelled=function() end})
    assert(not ok and attempts==1,'read failure must stop this task: '..reason)
    task.on_done{ok=false,error=reason}
    assert(plugin.welite_overview.monthly.total_seconds==3600)
end
plugin.client.get_read_stats=function() return {} end
assert(not pcall(task.task,{checkCancelled=function() end}),'missing total is unknown, not zero')

plugin.settings.is_api_configured=function() return true end
plugin.welite_stats_attempt=os.time()
local before=launches
assert(Stats.ensure(plugin,view)==false and launches==before,'page redraw must not refetch statistics')

worker.busy=function() return false end
plugin.welite_stats_attempt=nil
assert(Stats.ensure(plugin,view)==true and launches==before+1,'first home visit fetches summary automatically')
assert(Stats.ensure(plugin,view)==false and launches==before+1,'automatic load is bounded across rebuilds')
