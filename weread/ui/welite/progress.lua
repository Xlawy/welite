-- Bounded current-page progress enrichment; no network calls in paint callbacks.
local M={}
local Reading=require('weread.ui.welite.reading')
local Auth=require('weread.lib.worker_settings')
function M.ensure(plugin,view)
    if view.mode~='books' or not view.items or not plugin.settings:is_api_configured() then return end
    local account=plugin.settings:get('account',{}).user_vid
    local fingerprint=Auth.fingerprint(plugin.settings)
    local state=plugin.welite_progress
    if not state or state.fingerprint~=fingerprint or state.account~=account then
        if state and state.worker then state.worker:cancel(nil,'account_changed') end
        state={fingerprint=fingerprint,account=account,values={},order={}}
        plugin.welite_progress=state
    end
    local _,eligible=require('weread.lib.progress_scope').select(
        plugin.shelf_regular or {},plugin.settings:get('books',{}),account)
    local pending={}
    local changed=false
    local first=((view.page or 1)-1)*(view.page_size or 6)+1
    for index=first,math.min(#view.items,first+math.min(view.page_size or 6,6)-1) do
        local item=view.items[index]
        if item.kind=='book' and item.id~='' then
            local cached=state.values[item.id]
            if cached and item.percent~=cached.percent then item.percent=cached.percent;changed=true end
            if eligible[item.id] and not cached and not Reading.number(item.percent,100) then pending[#pending+1]=item.id end
        end
    end
    if changed then view:redraw() end
    if #pending==0 then return end
    if state.worker and state.worker:busy() then return end
    state.worker=state.worker or require('weread.lib.background_worker'):new{
        temp_dir=plugin.settings.data_dir..'/workers',timeout=60}
    -- Reserve attempts before starting: failures do not trigger automatic retry loops.
    for _,id in ipairs(pending) do
        state.values[id]={};state.order[#state.order+1]=id
        if #state.order>128 then state.values[table.remove(state.order,1)]=nil end
    end
    return state.worker:start{task=function(context)
        local capture=Auth.capture(plugin.settings)
        local result={}
        for _,id in ipairs(pending) do
            context.checkCancelled()
            local data,err=Reading.progress(plugin.client:get_progress(id))
            if not data then error('[welite.progress] '..tostring(err.kind)) end
            result[id]=data.percent
        end
        return {values=result,auth=capture()}
    end,on_done=function(result)
        if plugin.welite_progress~=state or plugin.settings:get('account',{}).user_vid~=account
            or Auth.fingerprint(plugin.settings)~=fingerprint then return end
        if result.ok then
            Auth.merge(plugin.settings,fingerprint,result.value.auth)
            for id,percent in pairs(result.value.values) do
                if state.values[id] then state.values[id].percent=percent end
            end
        end
        local current=plugin.shelf_view
        if current and not current.welite_closed then
            for _,item in ipairs(current.items or {}) do
                local cached=state.values[item.id]
                if cached and item.percent~=cached.percent then item.percent=cached.percent end
            end
            current:redraw()
            -- A page selected while the worker was busy gets its own bounded batch.
            M.ensure(plugin,current)
        end
    end}
end
return M
