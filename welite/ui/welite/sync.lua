-- UI orchestration only: all data comes from the existing WeRead client.
local M={}
local Reading=require('welite.ui.welite.reading')
local Auth=require('welite.lib.worker_settings')
local TimeSync=require('welite.lib.reading_time_sync')
local Scope=require('welite.lib.progress_scope')

function M.refresh(plugin,view,options,closed_ok)
    if plugin.shelf_refreshing or not plugin:requireLogin(false,true) then return false end
    if closed_ok==nil then
        plugin.shelf_refreshing=true;view:setRefreshing(true)
        local started=true
        require('welite.lib.closed_progress_sync').start(plugin,function(ok)
            plugin.shelf_refreshing=nil
            if plugin.shelf_view and not plugin.shelf_view.welite_closed then
                started=M.refresh(plugin,plugin.shelf_view,options,ok)
            end
        end)
        return started
    end
    local fingerprint=Auth.fingerprint(plugin.settings)
    local account=plugin.settings:get('account',{}).user_vid
    for _,worker in pairs({plugin.welite_stats_worker,
        plugin.welite_progress and plugin.welite_progress.worker}) do
        worker:cancel(nil,'manual_sync')
    end
    plugin.welite_progress=nil
    plugin.shelf_cover_generation=(plugin.shelf_cover_generation or 0)+1
    plugin.shelf_cover_pending=nil
    plugin.shelf_refreshing=true
    view:setRefreshing(true)
    local worker=require('welite.lib.background_worker'):new{
        temp_dir=plugin.settings.data_dir..'/workers',timeout=180}
    plugin.welite_sync_worker=worker
    local function finish(status)
        plugin.shelf_refreshing=nil
        plugin.welite_shelf_status=status
        local current=plugin.shelf_view
        if current and not current.welite_closed then
            current:setSyncStatus(status)
            current:setRefreshing(false)
        end
    end
    local time_task=TimeSync.prepare(plugin.read_report,account)
    local checkpoint
    local launch_returned=false
    local started=worker:start{task=function(context)
        local capture=Auth.capture(plugin.settings)
        local result={overview={},failed={},progress_books={},remote_positions={},pending={['阅读时间']=true,['阅读进度']=true}}
        local function publish()
            if context.emit then context.emit{value={data=result,auth=capture()}} end
        end
        local function fetch(name,fn)
            context.checkCancelled()
            local ok,value=pcall(fn)
            if ok and value then return value end
            result.failed[name]=true
        end
        result.shelf=fetch('书架',function()
            local shelf=plugin.client:get_shelf()
            assert(type(shelf)=='table' and type(shelf.books)=='table')
            return shelf
        end)
        publish()
        result.time_receipts=TimeSync.run(time_task,context,function(receipts)
            result.time_receipts=receipts;publish()
        end)
        -- Fetch even when the shelf fails so independent statistics can refresh.
        for _,mode in ipairs({'monthly','weekly'}) do
            result.overview[mode]=fetch('阅读时间',function()
                local summary=assert(Reading.summary(plugin.client:get_read_stats(mode),mode))
                summary.updated=os.time()
                return summary
            end)
        end
        result.pending['阅读时间']=nil
        publish()
        local completed=0
        local targets=Scope.select(
            result.shelf and result.shelf.books or {},plugin.settings:get('books',{}),account)
        for _,book in ipairs(targets) do
            local id=tostring(book.bookId or book.book_id or '')
            if id~='' and id:sub(1,7)~='MP_WXS_' then
                local progress=fetch('阅读进度',function()
                    local raw=plugin.client:get_progress(id)
                    local data=assert(Reading.progress(raw))
                    local position=require('welite.lib.position_mapper').normalize_remote(raw,id,'gateway')
                    if position and position.has_chapter_offset then
                        book.home_remote_position={account=account,position=position}
                        result.remote_positions[id]=book.home_remote_position
                    end
                    assert(data.percent~=nil)
                    return data
                end)
                if progress then
                    book.progress=progress.percent
                    result.progress_books[id]=true
                end
                completed=completed+1
                -- Checkpoint once per six books, never on every UI repaint.
                if completed%6==0 then publish() end
            end
        end
        result.pending['阅读进度']=nil
        if not result.shelf then result.failed['阅读进度']=true end
        return {data=result,auth=capture()}
    end,on_progress=function(progress)
        if plugin.welite_sync_worker==worker then
            checkpoint=progress.value
            TimeSync.apply(time_task,checkpoint and checkpoint.data.time_receipts,
                plugin.settings:get('account',{}).user_vid==account
                and Auth.fingerprint(plugin.settings)==fingerprint)
        end
    end,on_done=function(outcome)
        local value=outcome.ok and outcome.value or checkpoint
        TimeSync.apply(time_task,value and value.data.time_receipts,
            plugin.settings:get('account',{}).user_vid==account
            and Auth.fingerprint(plugin.settings)==fingerprint)
        local time_ok=TimeSync.finish(time_task,not launch_returned)
        if plugin.welite_sync_worker~=worker then return end
        plugin.welite_sync_worker=nil
        if plugin.settings:get('account',{}).user_vid~=account
            or Auth.fingerprint(plugin.settings)~=fingerprint then
            finish('未同步');return
        end
        if not value or outcome.cancelled then finish('同步失败');return end
        Auth.merge(plugin.settings,fingerprint,value.auth)
        local result=value.data
        if not time_ok then result.failed['阅读时间']=true end
        if not closed_ok then result.failed['阅读进度']=true end
        for name in pairs(result.pending or {}) do result.failed[name]=true end
        plugin.welite_overview=plugin.welite_overview or {}
        for mode,summary in pairs(result.overview) do plugin.welite_overview[mode]=summary end
        plugin.welite_stats_attempt=os.time()
        local failed={}
        for _,name in ipairs({'书架','阅读进度','阅读时间'}) do
            if result.failed[name] then failed[#failed+1]=name end
        end
        finish(#failed==0 and '数据已刷新' or '同步未完成')
        if result.shelf then
            local books,archives=result.shelf.books,result.shelf.archive or {}
            local stored=plugin.settings:get('books',{})
            local changed=false
            for id,position in pairs(result.remote_positions or {}) do
                local owner=Scope.record_account(stored[id])
                if stored[id] and (owner==nil or owner==tostring(account)) then
                    stored[id].home_remote_position=position;changed=true
                end
            end
            if changed then plugin.settings:set('books',stored);plugin.settings:flush() end
            if plugin.library_db then plugin.library_db:cacheShelf(books,archives) end
            local group=plugin.shelf_group_key
            plugin:applyShelfSnapshot(books,archives)
            local next_options={}
            for key,option_value in pairs(options or {}) do next_options[key]=option_value end
            next_options.prepared_shelf=nil
            if group~=plugin.shelf_group_key then next_options.page=1 end
            local current=plugin.shelf_view
            if current and not current.welite_closed then
                require('ui/uimanager'):close(current)
                plugin:showShelfView(plugin.shelf_view_mode or 'books',current.keyword,nil,next_options)
            end
        elseif plugin.shelf_view and not plugin.shelf_view.welite_closed then
            plugin.shelf_view.overview=plugin.welite_overview
            plugin.shelf_view:redraw()
        end
        require('welite.ui.welite.reading_sync').queue(plugin,result.progress_books)
        if #failed>0 then
            local message='未能完成：'..table.concat(failed,'、')..'。请重试同步。'
            if not closed_ok then message=message..'\n仍有本地进度未上传；云端也有变化时，请打开对应书籍选择进度。' end
            if time_task.error then
                message=message..'\n本地阅读时间记录处理失败：'..tostring(time_task.error):sub(1,300)
            end
            if (time_task.uncertain_seconds or 0)>0 then
                message=message..'\n另有 '..math.floor(time_task.uncertain_seconds)..' 秒阅读时间回执不明；请在阅读上报菜单的“待核对阅读时间”中处理，重复同步不会重报这些记录。'
            end
            plugin:showInfo(message)
        end
    end}
    launch_returned=true
    if not started then TimeSync.finish(time_task,true);plugin.welite_sync_worker=nil;finish('同步失败') end
    return started
end
return M
