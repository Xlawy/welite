describe('WeLite chapter prefetch settings',function()
    local UI,Home,settings,path,plugin,controller,started,cancelled,annotation_cancelled
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Home=require('weread.ui.welite.home')
    end)
    before_each(function()
        path=os.tmpname();os.remove(path);settings=require('luasettings'):open(path)
        started,cancelled,annotation_cancelled=0,0,0
        plugin={settings={get=function(_,k,d) return settings:readSetting(k,d) end,
            set=function(_,k,v) settings:saveSetting(k,v) end,flush=function() settings:flush() end},
            downloader={cancelPrefetch=function() cancelled=cancelled+1 end},
            cancelAnnotationPrefetch=function() annotation_cancelled=annotation_cancelled+1 end,
            _current_weread_book_id='fixture',maybePrefetchNextChapter=function() started=started+1 end}
        local upstream=require('weread.ui.annotation_sync_controller')
        plugin.isAnnotationPrefetchEnabled=upstream.isAnnotationPrefetchEnabled
        plugin.setAnnotationPrefetchEnabled=upstream.setAnnotationPrefetchEnabled
        settings:saveSetting('cache',{});settings:saveSetting('account',{user_vid='fixture'})
        controller=Home.settings({welite_plugin=plugin})
    end)
    after_each(function() controller:close();os.remove(path);os.remove(path..'.old') end)
    it('connects the shelf settings entry to upstream preference actions and persists them',function()
        controller:show()
        assert.equals('章节预下载',controller.dialog.buttons[3][1].text)
        controller.dialog.buttons[3][1].callback()
        local view=controller.dialog
        assert.is_false(view._annotations_button.enabled)
        view._chapters_button.callback()
        assert.is_true(settings:readSetting('cache').auto_prefetch_next_chapter)
        assert.is_true(view._annotations_button.enabled)
        view._annotations_button.callback()
        assert.is_true(plugin:isAnnotationPrefetchEnabled())
        view._notifications_button.callback()
        assert.is_false(settings:readSetting('cache').show_prefetch_notifications)
        assert.is_true(require('luasettings'):open(path):readSetting('cache').prefetch_annotations)
        UI:forceRePaint()
        local screenshot=os.getenv('WELITE_SCREENSHOT')
        if screenshot then require('device').screen.bb:writePNG(screenshot:gsub('plugin%-smoke','prefetch-settings')) end
        view._chapters_button.callback()
        assert.equals(1,cancelled);assert.equals(1,annotation_cancelled)
        assert.is_false(view._notifications_button.enabled)
        view._close_button.callback()
        assert.equals('WeLite 设置',controller.dialog.title)
        local old=view;old._chapters_button.callback()
        assert.is_false(settings:readSetting('cache').auto_prefetch_next_chapter)
    end)
    it('reader settings use the same plugin and external closure does not reopen settings',function()
        controller=Home.settings(plugin)
        controller:prefetch()
        assert.equals(plugin,controller.dialog.plugin)
        local view=controller.dialog
        controller:close()
        assert.is_true(view.closed);assert.is_nil(controller.dialog)
    end)
end)
