describe('WeLite annotation management panel',function()
    local UI,Panel,Bridge,plugin,view,calls,values
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Panel=require('welite.ui.welite.annotations')
        Bridge=require('welite.ui.welite.reader_controls')
    end)
    before_each(function()
        calls={};values={account={user_vid='fixture'},cache={show_annotations=true}}
        plugin={ui={document={info={number_of_pages=100}}},_reader_session_gen=1,
            settings={get=function(_,key,default) return values[key] or default end},
            _xpointerOverlayPrototypeAvailable=function() return true end,
            _annotationBinding=function() return {book_id='fixture',title='合成书籍'} end,
            getUnifiedAnnotationMenuItems=require('welite.ui.annotation_sync_controller').getUnifiedAnnotationMenuItems,
            toggleAnnotationVisibility=function() calls.visibility=true end,
            bindExternalAnnotationsBook=function() calls.binding=true end,
            chooseAnnotationChapters=function() calls.chapters=true;return 'picker' end,
            isNetworkConnected=function() return false end,
            startUnifiedAnnotationSync=function(_,options) calls.sync=options end,
            clearUnifiedAnnotationProjections=function() calls.clear=true end}
    end)
    after_each(function() Bridge.close(plugin);view=nil end)
    it('opens from the reader pulldown and dispatches to existing chapter selection',function()
        Bridge.show(plugin)
        local panel=plugin.welite_reader_panel
        assert.is_not_nil(panel.annotations_button)
        panel.annotations_button.callback()
        assert.is_nil(plugin.welite_reader_panel)
        view=assert(plugin.welite_annotations_panel)
        assert.equals(4,#view._management_buttons)
        view._management_buttons[3].callback()
        assert.is_true(calls.chapters);assert.is_true(view.closed)
        assert.is_nil(plugin.welite_annotations_panel)
    end)
    it('uses upstream visibility, offline matching and clearing actions',function()
        view=Panel.show(plugin);view._visibility_button.callback();assert.is_true(calls.visibility)
        view=Panel.show(plugin);view._management_buttons[2].callback();assert.is_true(calls.sync.offline)
        view=Panel.show(plugin);view._management_buttons[4].callback();assert.is_true(calls.clear)
    end)
    it('discards stale actions after document, account or reader-session changes',function()
        view=Panel.show(plugin);plugin.ui.document={};view._management_buttons[3].callback()
        assert.is_nil(calls.chapters)
        view=Panel.show(plugin);values.account={user_vid='other'};view._management_buttons[3].callback()
        assert.is_nil(calls.chapters)
        view=Panel.show(plugin);plugin._reader_session_gen=2;view._management_buttons[3].callback()
        assert.is_nil(calls.chapters)
        view=Panel.show(plugin);Bridge.close(plugin);view._management_buttons[4].callback()
        assert.is_nil(calls.clear)
    end)
    it('fits a scrollable management panel in small and Kindle layouts',function()
        local Screen=require('device').screen;local BB=require('ffi/blitbuffer')
        local original,size=Screen.bb,Screen.screen_size
        local ok,err=pcall(function()
            for _,dimensions in ipairs({{320,600},{600,400},{1072,1448}}) do
                Screen.bb=BB.new(dimensions[1],dimensions[2],BB.TYPE_BB8)
                Screen.screen_size={w=dimensions[1],h=dimensions[2]}
                view=Panel.show(plugin);UI:forceRePaint()
                assert.is_true(view.scroll.dimen.h>0)
                assert.equals(5,#view._action_buttons)
                local screenshot=os.getenv('WELITE_SCREENSHOT')
                if screenshot then Screen.bb:writePNG(screenshot:gsub('plugin%-smoke','annotation-panel-'..dimensions[1]..'x'..dimensions[2])) end
                view:onClose();Screen.bb:free();Screen.bb=original
            end
        end)
        if Screen.bb~=original then Screen.bb:free();Screen.bb=original end
        Screen.screen_size=size
        assert.is_true(ok,tostring(err))
    end)
end)
