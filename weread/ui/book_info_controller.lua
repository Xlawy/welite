-- Cache-first details; upstream metadata/progress requests run in one worker.
local Auth=require('weread.lib.worker_settings')
local Util=require('weread.lib.plugin_util')
local _=Util.tr
local M={}
function M.refresh(plugin,book,view,options)
    if plugin._book_info_session then plugin._book_info_session:close() end
    view=view or plugin:showBookMenu(book)
    if not plugin:requireLogin(false,true) then return end
    if not plugin:isNetworkOnline() then plugin:showOffline(_('Book info'));return end
    local id=tostring(book.book_id or book.bookId)
    local account=plugin.settings:get('account',{}).user_vid
    local fingerprint=Auth.fingerprint(plugin.settings)
    local session={view=view};plugin._book_info_session=session
    function session:close()
        self.closed=true
        local worker=self.worker;self.worker=nil
        if worker then worker:cancel(nil,'book_info_closed') end
        if plugin._book_info_session==self then plugin._book_info_session=nil end
    end
    local function current()
        return not session.closed and not view.closed and plugin._book_detail_view==view
            and plugin.settings:get('account',{}).user_vid==account
            and Auth.fingerprint(plugin.settings)==fingerprint
    end
    local function failed(err)
        require('weread.lib.logger').warn('book info refresh failed:',Util.log_error(err))
        plugin:showInfo(Util.T(_('%1 failed:\n%2'),_('Book info'),Util.display_error(err)))
    end
    local worker=require('weread.lib.background_worker'):new{temp_dir=plugin.settings.data_dir..'/workers',timeout=45}
    session.worker=worker
    local started=worker:start{task=function(context)
        local capture=Auth.capture(plugin.settings)
        context.checkCancelled()
        local info=plugin.client:get_book_info(id)
        assert(type(info)=='table','book info response is missing')
        context.checkCancelled()
        local progress=plugin.client:get_progress(id)
        context.checkCancelled()
        return {info=info,progress=progress,auth=capture()}
    end,on_done=function(outcome)
        if session.worker~=worker then return end
        session.worker=nil
        if not current() then session:close();return end
        session:close()
        if not outcome.ok then failed(outcome.error);return end
        local ok,err=pcall(function()
            Auth.merge(plugin.settings,fingerprint,outcome.value.auth)
            local books=plugin.settings:get('books',{})
            local saved=books[id] or book
            -- Preserve downloads and reading state written while the request ran.
            local info=outcome.value.info
            for _,key in ipairs({'title','author','translator','publisher','publishTime','isbn',
                'intro','cover','wordCount','category','categoryName','price','rating','newRating','newRatingCount','finished'}) do
                if info[key]~=nil then saved[key]=info[key] end
            end
            saved.categoryName=info.categoryName or info.category or saved.categoryName
            local result=outcome.value.progress
            local remote=type(result)=='table' and result.book
            if type(remote)=='table' then
                saved.progress=remote.progress or saved.progress or 0
                saved.chapter_uid=remote.chapterUid or remote.chapterId or remote.chapter_uid or saved.chapter_uid
                saved.chapter_idx=tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx) or saved.chapter_idx
                saved.chapter_offset=tonumber(remote.chapterOffset or remote.chapterPos or remote.offset) or saved.chapter_offset or 0
            end
            saved.book_id=id
            saved._library_account_key=plugin.library_db and plugin.library_db:accountKey() or nil
            saved.detail_updated_at=os.time()
            books[id]=saved
            plugin.settings:set('books',books);plugin.settings:flush()
            if plugin.library_db then plugin.library_db:putBook(saved) end
            plugin:showBookMenu(saved,view)
        end)
        if not ok then failed(err) end
    end}
    if not started and session.worker==worker then
        session.worker=nil;session:close();failed('book info worker could not start')
    end
    return session
end
return M
