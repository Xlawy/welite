-- Reconcile closed-book snapshots before home data refresh. The existing
-- ReadReport pipeline owns every write; a changed cloud baseline is deferred.
local M={MAX_BOOKS=6,MAX_DETAIL_BOOKS=5,WAIT_INTERVAL=0.25,MAX_WAIT_CHECKS=120}
local BookStore=require('welite.lib.book_store')
local Auth=require('welite.lib.worker_settings')
local Mapper=require('welite.lib.position_mapper')
local function details()
    return {conflicts={count=0,books={}},pending={count=0,books={}}}
end
local function add_detail(summary,kind,id,book)
    local group=summary[kind]
    group.count=group.count+1
    if #group.books<M.MAX_DETAIL_BOOKS then
        group.books[#group.books+1]={id=tostring(id),title=book.title or book.name}
    end
end
local function pending_details(entries)
    local summary=details()
    for _,entry in ipairs(entries) do add_detail(summary,'pending',entry.id,entry) end
    return summary
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function exact(a,b)
    return type(a)=='table' and type(b)=='table' and a.chapter_uid~=nil
        and b.chapter_uid~=nil and a.chapter_offset~=nil and b.chapter_offset~=nil
        and tostring(a.chapter_uid)==tostring(b.chapter_uid)
        and tonumber(a.chapter_offset)==tonumber(b.chapter_offset)
end
function M.reconcile(plugin,id,position)
    local remote=assert(Mapper.normalize_remote(plugin.client:get_progress(id),id,'gateway'))
    assert(remote.has_chapter_offset,'cloud source offset unavailable')
    if position.position_basis~='source_utf16' and position.position_basis~='confirmed_remote_offset' then
        assert(position.source_snapshot,'closed reader source snapshot unavailable')
        local book=assert(BookStore.get(plugin.settings,id))
        local chapter={chapterUid=position.chapter_uid,chapterIdx=position.chapter_idx}
        local Store=require('welite.lib.annotation_store')
        local spans=Store:new(plugin.settings):get(id,'original',tostring(position.chapter_uid),true)
        local Source=require('welite.lib.source_position')
        local map=Source.new(spans)
        if not map then
            local html,plain=require('welite.lib.content').fetch_chapter_xhtml(
                plugin.client,plugin.settings,book,chapter,{no_source_cache=true})
            assert(#(plain or html)<=Source.MAX_BYTES,'source_limit')
            local Index=require('welite.lib.annotation_source')
            map=assert(Source.new(plain and Index.plain(plain) or Index.index(html)))
        end
        local offset,err,summary=map:capture_snapshot(position.source_snapshot)
        assert(offset,err)
        position.chapter_offset,position.position_basis,position.summary=offset,'source_utf16',summary
        position.source_snapshot=nil
    end
    if exact(position,remote) then return {accepted=true,position=position} end
    local reported=(BookStore.get(plugin.settings,id) or {}).last_reported_position
    local own_report=reported and reported.account==position.account_id and reported.position
    if not exact(position.sync_base,remote) and not exact(own_report,remote) then return {conflict=true} end
    local outcome=plugin.read_report:_child_report(id,plugin.read_report:_renewal_allowed(),position,0)
    return {accepted=outcome.accepted==true,position=position,outcome=outcome}
end
function M.start(plugin,done,wait_checks)
    if not plugin.read_report or not plugin.read_report.time_ledger then done(true);return end
    local account=plugin.settings:get('account',{}).user_vid
    local fingerprint=Auth.fingerprint(plugin.settings)
    local entries={}
    for id,book in pairs(plugin.settings:get('books',{})) do
        local p=type(book)=="table" and book.pending_upload_position
        if type(p)=='table' and p.account_id==account
            and #entries<M.MAX_BOOKS then
            entries[#entries+1]={id=tostring(id),position=p,title=book.title or book.name}
        end
    end
    if #entries==0 then done(true);return end
    local reader=require('apps/reader/readerui').instance
    local active=reader and reader.welite and reader.welite:detectWeReadBook()
    for i=#entries,1,-1 do if entries[i].id==tostring(active) then table.remove(entries,i) end end
    if #entries==0 then done(true);return end
    if plugin.isNetworkConnected and not plugin:isNetworkConnected() then done(false,pending_details(entries));return end
    local ledger=plugin.read_report.time_ledger
    local function busy()
        for _,entry in ipairs(entries) do
            if require('welite.lib.progress_sync').has_pending_upload(plugin.settings,entry.id)
                or (ledger.has_pending_report and ledger:has_pending_report(account,entry.id)) then
                return true
            end
        end
        return false
    end
    if busy() then
        -- Join the existing close upload before taking a new position snapshot. Poll memory only: no network, disk scans or extra writes.
        local ui=require('ui/uimanager')
        local waiting={}
        local check
        local remaining=wait_checks or M.MAX_WAIT_CHECKS
        plugin.welite_closed_progress_worker=waiting
        function waiting:cancel()
            ui:unschedule(check)
            if plugin.welite_closed_progress_worker==waiting then
                plugin.welite_closed_progress_worker=nil
                local same_account=Auth.fingerprint(plugin.settings)==fingerprint
                    and plugin.settings:get('account',{}).user_vid==account
                done(false,same_account and pending_details(entries) or nil)
            end
        end
        check=function()
            if plugin.welite_closed_progress_worker~=waiting then return end
            if Auth.fingerprint(plugin.settings)~=fingerprint
                or plugin.settings:get('account',{}).user_vid~=account then
                waiting:cancel();return
            end
            if not busy() then
                plugin.welite_closed_progress_worker=nil
                -- The close job may have cleared or remapped its pending
                -- snapshot; reconcile the latest saved data, never the old copy.
                M.start(plugin,done,remaining);return
            end
            remaining=remaining-1
            if remaining<=0 then waiting:cancel();return end
            ui:scheduleIn(M.WAIT_INTERVAL,check)
        end
        ui:scheduleIn(M.WAIT_INTERVAL,check)
        return
    end
    for _,entry in ipairs(entries) do
        local ok,lock=pcall(ledger.lock_position,ledger,account,entry.id)
        if ok then entry.lock=lock end
    end
    local worker=require('welite.lib.background_worker'):new{temp_dir=plugin.settings.data_dir..'/workers',timeout=120}
    plugin.welite_closed_progress_worker=worker
    local function finish(outcome)
        for _,entry in ipairs(entries) do ledger:unlock_position(entry.lock) end
        if plugin.welite_closed_progress_worker~=worker then return end
        plugin.welite_closed_progress_worker=nil
        if Auth.fingerprint(plugin.settings)~=fingerprint
            or plugin.settings:get('account',{}).user_vid~=account then return false end
        local success=outcome.ok==true
        local conflicts={}
        local value=outcome.value or {}
        if outcome.ok then Auth.merge(plugin.settings,fingerprint,value.auth) end
        local books=plugin.settings:get('books',{})
        for _,entry in ipairs(entries) do
            local result=(value.receipts or {})[entry.id]
            local book=books[entry.id]
            if book and equal(book.pending_upload_position,entry.position) then
                if result and result.accepted then
                    book.last_uploaded_position=result.position
                    book.last_remote_position=result.position
                    book.last_upload_at=os.time()
                    book.pending_upload_position=nil;book.pending_upload_reason=nil;book.last_sync_error=nil
                else
                    success=false
                    book.last_sync_error=result and result.conflict and 'cloud_progress_conflict' or 'closed_progress_upload_failed'
                    conflicts[entry.id]=result and result.conflict==true
                end
                BookStore.put(plugin.settings,entry.id,book)
            else success=false end
        end
        local summary=details()
        for id,book in pairs(books) do
            local pending=type(book)=='table' and book.pending_upload_position
            if type(pending)=='table' and pending.account_id==account then
                success=false
                add_detail(summary,conflicts[tostring(id)] and 'conflicts' or 'pending',id,book)
            end
        end
        plugin.settings:flush()
        return success,summary
    end
    local function completed(outcome)
        local ok,result,summary=pcall(finish,outcome)
        if not ok then
            require('welite.lib.logger').scoped('ClosedProgressSync').warn('persist outcome failed:',tostring(result))
            done(false)
        elseif result~=nil then done(result,summary) end
    end
    local started=worker:start{task=function(context)
        local capture=Auth.capture(plugin.settings)
        local receipts={}
        for _,entry in ipairs(entries) do
            context.checkCancelled()
            if entry.lock then
                local ok,result=pcall(M.reconcile,plugin,entry.id,entry.position)
                receipts[entry.id]=ok and result or {error=tostring(result)}
            end
        end
        return {receipts=receipts,auth=capture()}
    end,on_done=completed}
    if not started then completed{ok=false} end
end
return M
