-- Ordinary chapter-list network boundary. Cached catalogs are handled by the
-- library; this controller owns one cancellable request and its loading panel.
local Auth=require('weread.lib.worker_settings')
local Content=require('weread.lib.content')
local Util=require('weread.lib.plugin_util')
local _=Util.tr
local M={}
function M.load(plugin,book,on_ready)
    if plugin._chapter_catalog_session then plugin._chapter_catalog_session:close() end
    if not plugin:requireLogin(true,false) then return end
    if not plugin:isNetworkOnline() then plugin:showOffline(_('Chapters'));return end
    local id=tostring(book.book_id or book.bookId)
    local fingerprint=Auth.fingerprint(plugin.settings)
    local account=plugin.settings:get('account',{}).user_vid
    local session={};plugin._chapter_catalog_session=session
    function session:close()
        self.closed=true
        local worker=self.worker;self.worker=nil
        if worker then worker:cancel(nil,'chapter_catalog_closed') end
        if plugin._chapter_catalog_session==self then plugin._chapter_catalog_session=nil end
        local view=self.view;self.view=nil
        if view then view:onClose() end
    end
    local function valid()
        return not session.closed and plugin._chapter_catalog_session==session
            and plugin.settings:get('account',{}).user_vid==account
            and Auth.fingerprint(plugin.settings)==fingerprint
    end
    local load
    local function render(error_message)
        local old=session.view;session.view=nil
        if old then old:onClose() end
        local view
        view=require('weread.ui.welite.record_list').show({heading=_('Chapters'),caption=book.title,
            status=error_message and _('Unable to load chapters. Please retry.') or _('Loading chapter list...'),
            action_text=_('Cancel')},{on_action=function() session:close() end,
            on_retry=error_message and function() load() end or nil,
            on_close=function() if session.view==view then session:close() end end})
        session.view=view
    end
    local function fail(err)
        session.error=tostring(err)
        require('weread.lib.logger').warn('chapter catalog failed:',Util.log_error(err))
        render(err)
    end
    load=function()
        if not valid() then session:close();return end
        if session.worker then return end
        render()
        local worker=require('weread.lib.background_worker'):new{
            temp_dir=plugin.settings.data_dir..'/workers',timeout=45}
        session.worker=worker
        local started=worker:start{task=function(context)
            local capture=Auth.capture(plugin.settings)
            local remote={book_id=id,title=book.title,format=book.format}
            context.checkCancelled();Content.ensure_reader_state(plugin.client,remote)
            context.checkCancelled()
            local chapters=Content.fetch_catalog(plugin.client,remote)
            assert(type(chapters)=='table' and #chapters>0,'chapter catalog is empty')
            return {chapters=chapters,auth=capture()}
        end,on_done=function(outcome)
            if session.worker~=worker then return end
            session.worker=nil
            if not valid() then session:close();return end
            if not outcome.ok then fail(outcome.error);return end
            local chapters=outcome.value.chapters
            local ok,err=pcall(function()
                Auth.merge(plugin.settings,fingerprint,outcome.value.auth)
                fingerprint=Auth.fingerprint(plugin.settings)
                local books=plugin.settings:get('books',{})
                local latest=books[id] or book
                local saved,save_err=Content.save_catalog_cache(plugin.client,plugin.settings,latest,chapters)
                assert(saved,save_err or 'catalog cache write failed')
                if plugin.library_db then
                    local stored,db_err=plugin.library_db:putChapters(id,chapters)
                    assert(stored~=false,db_err or 'catalog database write failed')
                end
                latest.chapters=chapters;latest.book_id=id
                books[id]=latest
                plugin.settings:set('books',books);plugin.settings:flush()
                book.chapters=chapters
            end)
            if not ok then fail(err);return end
            session:close();on_ready(chapters)
        end}
        if not started and session.worker==worker then session.worker=nil;fail('catalog worker could not start') end
    end
    load();return session
end
return M
