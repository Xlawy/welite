-- Explicit, bounded summary refresh. No requests on paint, paging, or filtering.
local M = {}
function M.ensure(plugin, view)
    if not plugin.settings:is_api_configured() then return false end
    local now=os.time()
    if plugin.welite_stats_attempt and now-plugin.welite_stats_attempt<3600 then return false end
    plugin.welite_stats_attempt=now
    return M.refresh(plugin,view,true)
end
function M.refresh(plugin, view, quiet)
    if plugin.welite_stats_worker and plugin.welite_stats_worker:busy() then return false end
    if not plugin:requireLogin(false, true) then return false end
    local account=plugin.settings:get('account',{}).user_vid
    local WorkerSettings=require('welite.lib.worker_settings')
    local fingerprint=WorkerSettings.fingerprint(plugin.settings)
    local worker=plugin.welite_stats_worker
    if not worker then
        worker=require('welite.lib.background_worker'):new{
            temp_dir=plugin.settings.data_dir..'/workers',timeout=35}
        plugin.welite_stats_worker=worker
    end
    return worker:start{task=function(context)
        local capture=WorkerSettings.capture(plugin.settings)
        local overview={}
        for _,mode in ipairs({'monthly','weekly'}) do
            context.checkCancelled()
            local raw=plugin.client:get_read_stats(mode)
            local data,err=require('welite.ui.welite.reading').summary(raw,mode)
            if not data then error('[welite.statistics.'..mode..'] '..tostring(err.kind)) end
            data.updated=os.time();overview[mode]=data
        end
        return {overview=overview,auth=capture()}
    end,on_done=function(result)
        if plugin.settings:get('account',{}).user_vid~=account then return end
        if WorkerSettings.fingerprint(plugin.settings)~=fingerprint then return end
        if not result.ok then
            if not quiet and not result.cancelled then plugin:showInfo('[welite.statistics] '..tostring(result.error)) end
            return
        end
        WorkerSettings.merge(plugin.settings,fingerprint,result.value.auth)
        plugin.welite_overview=result.value.overview
        local current=plugin.shelf_view
        if current and not current.welite_closed then
            current.overview=plugin.welite_overview
            current:redraw()
        end
    end}
end
return M
