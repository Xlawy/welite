-- Persist a UI handoff; position comparison and writes remain upstream-owned.
local M={}
local KEY='welite_pending_progress_sync'
function M.queue(plugin,ids)
    local account=plugin.settings:get('account',{}).user_vid
    local pending=plugin.settings:get(KEY,{})
    if pending.account~=account then pending={account=account,books={}} end
    pending.books=pending.books or {}
    for id in pairs(ids or {}) do pending.books[tostring(id)]=true end
    plugin.settings:set(KEY,pending)
    plugin.settings:flush()
end
function M.complete(plugin,id,account)
    if plugin.settings:get('account',{}).user_vid~=account then return false end
    local pending=plugin.settings:get(KEY,{})
    id=tostring(id or '')
    if pending.account~=account or not (pending.books or {})[id] then return false end
    pending.books[id]=nil
    plugin.settings:set(KEY,pending)
    plugin.settings:flush()
    return true
end
function M.onReaderReady(plugin)
    if not plugin.settings or not plugin.detectWeReadBook then return end
    local id=tostring(plugin:detectWeReadBook() or '')
    local account=plugin.settings:get('account',{}).user_vid
    local pending=plugin.settings:get(KEY,{})
    if pending.account~=account or not (pending.books or {})[id] then return end
    local reader=plugin.ui
    local document=reader and reader.document
    if not document then return end
    local UI=require('ui/uimanager')
    local attempts=0
    local function ready()
        if require('apps/reader/readerui').instance~=reader or reader.document~=document
            or tostring(plugin:detectWeReadBook() or '')~=id
            or plugin.settings:get('account',{}).user_vid~=account then return end
        local current=plugin.settings:get(KEY,{})
        if current.account~=account or not (current.books or {})[id] then return end
        local sync=plugin.progress_sync
        if not sync then return end
        local status=sync:status()
        if status.state=='verified' and status.verified then
            if status.verified_reason=="positions_match" then M.complete(plugin,id,account) end
            return
        end
        if status.verified_reason=='choice_cancelled' then return end
        -- Once upstream owns the request, its completion callback consumes the
        -- marker. Never poll a dialog or impose a timeout on the user's choice.
        if status.state=='awaiting_choice' or status.pulling or status.uploading
            or status.state=='offline' or status.state=='error' then return end
        if status.state=='waiting' then
            attempts=attempts+1
            if attempts<30 then UI:scheduleIn(1,ready) end
            return
        end
        plugin:onWeReadSyncProgress()
    end
    -- Let the upstream delayed ReaderReady initialization finish first.
    UI:scheduleIn(0.7,ready)
end
return M
