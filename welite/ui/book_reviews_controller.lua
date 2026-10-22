-- One review session owns one cancellable request and two bounded tab caches.
local View=require('welite.ui.book_reviews_view')
local Reviews=require('welite.lib.book_reviews')
local Auth=require('welite.lib.worker_settings')
local _=require('welite.lib.i18n').tr
local M={}
function M.show(plugin,book)
    if not plugin:requireLogin(false,true) then return end
    if plugin._book_reviews_session then plugin._book_reviews_session:close() end
    local session={cache={}}
    plugin._book_reviews_session=session
    local account=plugin.settings:get('account',{}).user_vid
    local fingerprint=Auth.fingerprint(plugin.settings)
    local function current_account()
        return plugin.settings:get('account',{}).user_vid==account and Auth.fingerprint(plugin.settings)==fingerprint
    end
    local function cancel()
        local worker=session.worker;session.worker=nil
        if worker then worker:cancel(nil,'reviews_closed') end
    end
    function session:close()
        self.closed=true;cancel()
        if plugin._book_reviews_session==self then plugin._book_reviews_session=nil end
        if self.detail then self.detail:onClose();self.detail=nil end
        local view=self.view;self.view=nil
        if view and not view.closed then view:onClose() end
    end
    local load
    local function render(mode,result,status,retry)
        local old=session.view;session.view=nil
        if old then old:onClose() end
        local view
        view=View.show({book_title=book.title,mode=mode,result=result,status=status},{
            on_switch=function(new_mode) load(new_mode) end,
            on_retry=retry and function() load(mode) end or nil,
            on_select=function(review,selected_mode)
                if not current_account() then session:close();return end
                if session.detail then session.detail:onClose() end
                session.detail=plugin:showBookReviewDetail(book,review,selected_mode)
            end,
            on_close=function() if session.view==view then session:close() end end,
        })
        session.view=view
    end
    load=function(mode)
        if session.closed then return end
        if not current_account() then session:close();return end
        cancel()
        if session.cache[mode] then render(mode,session.cache[mode]);return end
        render(mode,nil,_('Loading book reviews...'))
        local worker=require('welite.lib.background_worker'):new{temp_dir=plugin.settings.data_dir..'/workers',timeout=45}
        session.worker=worker
        local function failed()
            render(mode,nil,_('Unable to load book reviews. Please retry.'),true)
        end
        local started=worker:start{task=function(context)
            local capture=Auth.capture(plugin.settings)
            context.checkCancelled()
            local result=plugin.client:get_book_reviews(book.book_id or book.bookId,mode=='latest' and 3 or 1,20)
            assert(type(result)=='table' and type(result.reviews)=='table','invalid review response')
            return {result=Reviews.normalize_list(result),auth=capture()}
        end,on_done=function(outcome)
            if session.worker~=worker or session.closed then return end
            session.worker=nil
            if not current_account() then session:close();return end
            if not outcome.ok then
                session.error=outcome.error
                require('welite.lib.logger').warn('book reviews fetch failed:',
                    require('welite.lib.plugin_util').log_error(outcome.error))
                failed();return
            end
            session.error=nil
            Auth.merge(plugin.settings,fingerprint,outcome.value.auth)
            fingerprint=Auth.fingerprint(plugin.settings)
            session.cache[mode]=outcome.value.result
            render(mode,session.cache[mode])
        end}
        if not started and session.worker==worker then session.worker=nil;failed() end
    end
    load('recommended')
    return session
end
return M
