describe('WeLite annotation chapter picker layout',function()
    local Picker,Selection,UI,view
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        Picker=require('welite.ui.annotation_chapter_picker');Selection=require('welite.lib.chapter_selection')
        UI=require('ui/uimanager')
    end)
    after_each(function() if view and not view._closed then view:onClose() end;view=nil end)
    it('bounds chapter rows and the floating frame across portrait and landscape screens',function()
        local Screen=require('device').screen;local BB=require('ffi/blitbuffer')
        local original,size=Screen.bb,Screen.screen_size
        local language=G_reader_settings:readSetting('language');G_reader_settings:saveSetting('language','zh_CN')
        local ok,err=pcall(function()
            for _,dimensions in ipairs({{320,600},{600,400},{600,800},{1072,1448}}) do
                Screen.bb=BB.new(dimensions[1],dimensions[2],BB.TYPE_BB8)
                Screen.screen_size={w=dimensions[1],h=dimensions[2]}
                local chapters={};for i=1,2000 do chapters[i]={chapterUid=tostring(i),title='合成章节 '..i,level=1} end
                view=Picker.show{model=Selection:new(chapters,{},nil,20),book_title='合成书籍',on_select=function() end}
                UI:forceRePaint()
                assert.is_false(view.covers_fullscreen)
                assert.is_true(view.panel_frame.dimen.h<=dimensions[2]*0.83)
                assert.is_true(view.panel_frame.dimen.w<dimensions[1])
                assert.is_true(view.list_height>=view.row_height)
                assert.is_true(view.per_page<20)
                assert.is_true(view.width-44*view.scale-92*view.scale>0)
                local screenshot=os.getenv('WELITE_SCREENSHOT')
                if screenshot then Screen.bb:writePNG(screenshot:gsub('plugin%-smoke','annotation-picker-'..dimensions[1]..'x'..dimensions[2])) end
                view:onNextPage();UI:forceRePaint();view:onPrevPage()
                view:onOutside(nil,{pos={x=0,y=0}})
                assert.is_true(view._closed)
                view=nil;Screen.bb:free();Screen.bb=original
            end
        end)
        if Screen.bb~=original then Screen.bb:free();Screen.bb=original end
        Screen.screen_size=size
        if language then G_reader_settings:saveSetting('language',language) else G_reader_settings:delSetting('language') end
        assert.is_true(ok,tostring(err))
    end)
end)
