local UI=require('ui/uimanager')
local Confirm=require('ui/widget/confirmbox')
local List=require('welite.ui.welite.record_list')
local _=require('welite.lib.i18n').tr
local T=require('ffi/util').template
local M={}
function M.show(plugin)
    if plugin._time_review_session then plugin._time_review_session:close() end
    local ledger=plugin.read_report and plugin.read_report.time_ledger
    if not ledger then return end
    local account=plugin.settings:get('account',{}).user_vid
    local ok,entries=pcall(function() ledger:recover(account);return ledger:unresolved(account) end)
    if not ok then plugin:showInfo(tostring(entries));return end
    local books=plugin.settings:get('books',{})
    local items={}
    for _i,entry in ipairs(entries) do
        local book=books[entry.book] or {}
        items[#items+1]={book=entry.book,seconds=entry.seconds,revision=entry.revision,title=book.title or entry.book,
            author=T(_('Unconfirmed: %1 seconds'),entry.seconds)}
    end
    local view,closed,dialog
    local session={}
    function session:close()
        if closed then return end
        closed=true
        if plugin._time_review_session==self then plugin._time_review_session=nil end
        if dialog then UI:close(dialog);dialog=nil end
        if view and not view.closed then UI:close(view) end
    end
    plugin._time_review_session=session
    local function valid()
        if plugin.settings:get('account',{}).user_vid~=account then session:close() end
        return not closed
    end
    local function show_dialog(widget)
        if dialog then UI:close(dialog) end
        dialog=widget;UI:show(widget)
    end
    local function resolve(item,decision)
        if not valid() then return end
        local saved,result=pcall(ledger.resolve,ledger,account,item.book,item.seconds,decision,item.revision)
        if not saved or not result then
            plugin:showInfo(saved and _('This time record changed. Reopen the list before deciding.') or tostring(result))
            return
        end
        UI:close(view);M.show(plugin)
    end
    view=List.show({heading=_('Review reading time'),
        caption=_('Check your WeRead reading history before deciding.'),
        empty_text=_('No unconfirmed reading time.'),items=items}, {
        on_close=function() session:close() end,
        on_action=function() UI:close(view) end,
        on_select=function(item)
            if not valid() then return end
            show_dialog(Confirm:new{
                title=_('Review reading time'),
                text=T(_('%1\n\n%2 seconds have no confirmed receipt. They have not been retried. Has WeRead already counted this time?'),item.title,item.seconds),
                ok_text=_('Already counted'),cancel_text=_('Keep for later'),
                ok_callback=function() resolve(item,'counted') end,
                other_buttons={{{text=_('Not counted: retry'),callback=function()
                    if not valid() then return end
                    show_dialog(Confirm:new{
                        text=_('Retry on the next sync? If WeRead already counted this time, retrying will count it again.'),
                        ok_text=_('Queue for retry'),cancel_text=_('Keep for later'),
                        ok_callback=function() resolve(item,'retry') end})
                end}}},
            })
        end,
    })
    return view
end
return M
