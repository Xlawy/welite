local Search=require('weread.lib.book_search')
local Auth=require('weread.lib.worker_settings')
local View=require('weread.ui.book_search_view')
local _=require('weread.lib.i18n').tr
local M={}
function M.show(plugin,value)
    local query,reason=Search.query(value)
    if not query then
        if reason=='query_too_long' then plugin:showInfo(_('Search query is too long.')) end
        return nil,reason
    end
    if not plugin:requireLogin(true,true) then return end
    if plugin._book_search_session then plugin._book_search_session:close() end
    local session={query=query};plugin._book_search_session=session
    local account=plugin.settings:get('account',{}).user_vid
    local fingerprint=Auth.fingerprint(plugin.settings)
    local function same_account()
        return plugin.settings:get('account',{}).user_vid==account and Auth.fingerprint(plugin.settings)==fingerprint
    end
    function session:close()
        self.closed=true
        local worker=self.worker;self.worker=nil
        if worker then worker:cancel(nil,'search_closed') end
        if plugin._book_search_session==self then plugin._book_search_session=nil end
        local view=self.view;self.view=nil
        if view and not view.closed then view:onClose() end
    end
    local load
    local function render(items,status,retry)
        local old=session.view;session.view=nil
        if old then old:onClose() end
        local view
        view=View.show({query=query,items=items,status=status},{
            on_search=function() plugin:showSearch() end,
            on_retry=retry and function() load() end or nil,
            on_select=function(book)
                if not same_account() then session:close();return end
                plugin:showBookRecord(book)
            end,
            on_close=function() if session.view==view then session:close() end end,
        })
        session.view=view
    end
    load=function()
        if session.closed or session.worker then return end
        if not same_account() then session:close();return end
        render(nil,_('Searching books...'))
        local worker=require('weread.lib.background_worker'):new{temp_dir=plugin.settings.data_dir..'/workers',timeout=45}
        session.worker=worker
        local function failed() render(nil,_('Unable to search books. Please retry.'),true) end
        local started=worker:start{task=function(context)
            local capture=Auth.capture(plugin.settings)
            context.checkCancelled()
            local data=plugin.client:gateway('/store/search',{keyword=query,count=Search.limit})
            return {items=Search.results(data),auth=capture()}
        end,on_done=function(outcome)
            if session.closed or session.worker~=worker then return end
            session.worker=nil
            if not same_account() then session:close();return end
            if not outcome.ok then
                session.error=outcome.error
                require('weread.lib.logger').warn('book search failed:',require('weread.lib.plugin_util').log_error(outcome.error))
                failed();return
            end
            Auth.merge(plugin.settings,fingerprint,outcome.value.auth)
            fingerprint=Auth.fingerprint(plugin.settings)
            session.error=nil
            render(outcome.value.items)
        end}
        if not started and session.worker==worker then session.worker=nil;failed() end
    end
    load();return session
end
return M
