-- Fetch only catalog data in a child; document mapping and SQLite writes stay in the parent.
local Auth=require('weread.lib.worker_settings')
local Content=require('weread.lib.content')
local _=require('weread.lib.i18n').tr
local M={}
function M.ensure(plugin,on_ready,refresh)
    if plugin._annotation_catalog_session then plugin._annotation_catalog_session:close() end
    local context=plugin:_prepareAnnotationContext()
    if not refresh and context and context.catalog and #context.catalog>0 then return on_ready(context) end
    if not plugin:requireLogin(true,true) then return end
    local binding=plugin:_annotationBinding()
    if not binding then return end
    local session={};plugin._annotation_catalog_session=session
    local document=plugin.ui.document
    local path=document.file
    local generation=plugin._reader_session_gen
    local account=plugin.settings:get('account',{}).user_vid
    local fingerprint=Auth.fingerprint(plugin.settings)
    local function valid()
        local current=plugin:_annotationBinding()
        return not session.closed and plugin.ui.document==document and document.file==path and plugin._reader_session_gen==generation
            and current and tostring(current.book_id)==tostring(binding.book_id)
            and plugin.settings:get('account',{}).user_vid==account and Auth.fingerprint(plugin.settings)==fingerprint
    end
    function session:close()
        self.closed=true
        local worker=self.worker;self.worker=nil
        if worker then worker:cancel(nil,'annotation_catalog_closed') end
        if plugin._annotation_catalog_session==self then plugin._annotation_catalog_session=nil end
        local view=self.view;self.view=nil
        if view then view:onClose() end
    end
    local load
    local function render(failed)
        local old=session.view;session.view=nil
        if old then old:onClose() end
        local view
        view=require('weread.ui.welite.record_list').show({heading=_('Underlines and thoughts'),
            caption=binding.title,status=failed and _('Unable to load chapters. Please retry.') or _('Loading chapter list...'),
            action_text=_('Cancel')},{on_action=function() session:close() end,
            on_retry=failed and function() load() end or nil,
            on_close=function() if session.view==view then session:close() end end})
        session.view=view
    end
    load=function()
        if not valid() then session:close();return end
        if session.worker then return end
        render(false)
        local worker=require('weread.lib.background_worker'):new{temp_dir=plugin.settings.data_dir..'/workers',timeout=45}
        session.worker=worker
        local started=worker:start{task=function(task)
            local capture=Auth.capture(plugin.settings)
            task.checkCancelled()
            local remote={bookId=binding.book_id,title=binding.title,author=binding.author,format=binding.format}
            Content.ensure_reader_state(plugin.client,remote)
            task.checkCancelled()
            local catalog=Content.fetch_catalog(plugin.client,remote)
            assert(type(catalog)=='table' and #catalog>0,'annotation catalog: empty catalog')
            return {catalog=catalog,auth=capture()}
        end,on_done=function(outcome)
            if session.closed or session.worker~=worker then return end
            session.worker=nil
            if not valid() then session:close();return end
            if not outcome.ok then
                session.error=outcome.error
                require('weread.lib.logger').warn('annotation catalog failed:',require('weread.lib.plugin_util').log_error(outcome.error))
                render(true);return
            end
            local ok,prepared=pcall(function()
                Auth.merge(plugin.settings,fingerprint,outcome.value.auth)
                fingerprint=Auth.fingerprint(plugin.settings)
                local changes={{kind='meta',key='catalog',value=outcome.value.catalog}}
                if refresh then changes[#changes+1]={kind='meta',key='prune_catalog',value=outcome.value.catalog} end
                plugin:_annotationStore():write(tostring(binding.book_id),changes)
                plugin._annotation_context=nil
                return assert(plugin:_prepareAnnotationContext(),'annotation catalog: document context unavailable')
            end)
            if not ok then
                session.error=prepared
                require('weread.lib.logger').warn('annotation catalog apply failed:',require('weread.lib.plugin_util').log_error(prepared))
                render(true);return
            end
            session:close()
            on_ready(prepared)
        end}
        if not started and session.worker==worker then session.worker=nil;render(true) end
    end
    load();return session
end
return M
