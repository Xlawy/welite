describe('WeLite thought popup in native KOReader',function()
    local Popup,UI,popup,language
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        Popup=require('weread.ui.thought_popup');UI=require('ui/uimanager')
    end)
    before_each(function()
        language=G_reader_settings:readSetting('language');G_reader_settings:saveSetting('language','zh_CN')
    end)
    after_each(function()
        Popup.closeVisible();popup=nil
        if language then G_reader_settings:saveSetting('language',language) else G_reader_settings:delSetting('language') end
    end)
    it('paginates complete quotes and long thoughts without using an unbounded title',function()
        local items={{abstract=string.rep('合成原文，完整保留。',100),author='合成读者',likes_count=12,
            content=string.rep('这是一段用于验证想法分页的合成内容。',200)}}
        local closed=0
        popup=Popup.show{pages=items,position='center',height_ratio=.75,width_ratio=.92,doc_font_size=20,
            doc_margins={left=20,right=20,top=10,bottom=10},close_callback=function() closed=closed+1 end}
        UI:forceRePaint()
        assert.equals('WeLite · 想法',popup._titlebar.title)
        assert.is_false(popup._pages.skip_quote)
        assert.is_true(popup._pages.full_quote)
        assert.is_true(#popup._page_starts>2)
        assert.is_true(popup._viewport.dimen.h>0)
        local count=#popup._page_starts
        popup._button_table:getButtonById('next_page').callback();assert.equals(2,popup.page_index)
        popup:changePage(count);assert.equals(count,popup.page_index)
        popup:changePage(-count);assert.equals(1,popup.page_index)
        local screenshot=os.getenv('WELITE_SCREENSHOT')
        if screenshot then require('device').screen.bb:writePNG(screenshot:gsub('plugin%-smoke','thought-popup-long-quote')) end
        popup:onClose();assert.equals(1,closed)
        local old=popup
        popup=Popup.show{pages=items,position='center',height_ratio=.75,width_ratio=.92}
        assert.equals(old,popup);assert.equals(1,popup.page_index)
        popup:onClose();assert.equals(1,closed,'a pooled popup must not retain the old close callback')
    end)
    it('keeps thought content and navigation inside small and Kindle screens',function()
        local Screen=require('device').screen;local BB=require('ffi/blitbuffer')
        local original,size=Screen.bb,Screen.screen_size
        local ok,err=pcall(function()
            for _,dimensions in ipairs({{320,600},{600,400},{1072,1448}}) do
                Screen.bb=BB.new(dimensions[1],dimensions[2],BB.TYPE_BB8)
                Screen.screen_size={w=dimensions[1],h=dimensions[2]}
                popup=Popup.show{pages={{abstract='合成原文',author='合成读者',content=string.rep('分页想法。',1000)}},
                    position='center',height_ratio=.75,width_ratio=.90,doc_font_size=18,
                    doc_margins={left=15,right=15,top=10,bottom=10}}
                UI:forceRePaint()
                assert.is_true(popup._viewport.dimen.h>0)
                assert.is_true(popup.container.dimen.h<dimensions[2])
                assert.is_true(popup.container.dimen.w<dimensions[1])
                assert.is_true(#popup._page_starts>1)
                popup:changePage(1);UI:forceRePaint();assert.equals(2,popup.page_index)
                local screenshot=os.getenv('WELITE_SCREENSHOT')
                if screenshot then Screen.bb:writePNG(screenshot:gsub('plugin%-smoke','thought-popup-'..dimensions[1]..'x'..dimensions[2])) end
                popup:onClose();Screen.bb:free();Screen.bb=original
            end
        end)
        if Screen.bb~=original then Screen.bb:free();Screen.bb=original end
        Screen.screen_size=size
        assert.is_true(ok,tostring(err))
    end)
    it('renders short thoughts and restores the background after closing',function()
        popup=Popup.show{pages={{abstract='合成划线原文',author='读者乙',content='这是对应的想法内容。',likes_count=3}},
            position='center',doc_font_size=20,height_ratio=.75,width_ratio=.92,
            doc_margins={left=20,right=20,top=10,bottom=10}}
        UI:forceRePaint()
        assert.equals(1,#popup._page_starts)
        assert.is_true(popup.container.dimen.h<require('device').screen:getHeight())
        local screenshot=os.getenv('WELITE_SCREENSHOT')
        if screenshot then require('device').screen.bb:writePNG(screenshot:gsub('plugin%-smoke','thought-popup-short')) end
        popup:onTapClose(nil,{pos=require('ui/geometry'):new{x=0,y=0,w=1,h=1}})
        assert.is_false(UI:isWidgetShown(popup))
    end)
end)
