describe('WeLite book details',function()
    local Detail,UI,Screen,view
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        Detail=require('welite.ui.book_detail_view');UI=require('ui/uimanager');Screen=require('device').screen
    end)
    after_each(function() if view then view:onClose();view=nil end end)
    local function data(callback)
        return {title='山间来信',author_line='林知远 · 著',chapter_status='已缓存 12 / 28 章',status_line='已读 42%  ·  已缓存 12 / 28 章',
            refresh_date='2026-10-21 23:40',intro='在山间住下，重新认识四季，也重新认识自己。\n这是一段关于行走、阅读与日常生活的记录。',
            metadata={{left='出版社：山川出版社',right='出版时间：2025-06'},{text='分类：文学 · 散文'},
                {left='字数：12.8 万字',right='评分：8.9'}},
            review_action={text='查看书评 ›',callback=callback},actions={{text='清理本书缓存',callback=callback}},
            bottom_actions={{text='下载全书',callback=callback},{text='目录',callback=callback},
                {text='开始阅读',enabled=false,callback=callback}}}
    end
    it('preserves actions and disabled reading in a scrollable native layout',function()
        local calls=0
        view=Detail.show(data(function() calls=calls+1 end),{on_refresh=function() calls=calls+1 end})
        UI:forceRePaint()
        local function contains(widget,text)
            if widget.text==text then return true end
            for _,child in ipairs(widget) do
                if type(child)=='table' and contains(child,text) then return true end
            end
            return false
        end
        assert.is_false(contains(view,'已缓存 12 / 28 章'))
        assert.is_false(contains(view,'Chapter list'))
        assert.is_true(contains(view,'目录'))
        assert.is_true(contains(view,'查看书评 ›'))
        assert.is_false(contains(view,'2026-10-21 23:40'))
        assert.is_false(contains(view,data().intro))
        assert.equals(2,#view._action_buttons)
        assert.equals(3,#view._footer_actions)
        assert.is_nil(view._refresh_button)
        assert.is_false(contains(view,'Get latest'))
        view._action_buttons[1].callback();view._action_buttons[2].callback()
        view._footer_actions[1].callback();view._footer_actions[2].callback();view._footer_actions[3].callback()
        assert.equals(4,calls)
        assert.is_false(view._footer_actions[3].enabled)
        assert.is_true(view.scroll.dimen.h>0)
        assert.is_true(view[1]:getSize().h<=Screen:getHeight())
        view:onOutside(nil,{pos=require('ui/geometry'):new{x=0,y=0,w=0,h=0}})
        assert.is_true(view.closed)
        view._footer_actions[1].callback();assert.equals(4,calls)
        local readable=data(function() calls=calls+1 end)
        readable.bottom_actions[3].enabled=true
        view=Detail.show(readable,{})
        view._footer_actions[3].callback();assert.equals(5,calls)
    end)
    it('renders cached and missing covers at small and Kindle sizes with bounded previews',function()
        local BB=require('ffi/blitbuffer')
        local original,size=Screen.bb,Screen.screen_size
        local language=G_reader_settings:readSetting('language')
        G_reader_settings:saveSetting('language','zh_CN')
        local ok,err=pcall(function()
            for _,dimensions in ipairs({{600,800},{320,600},{600,400},{1072,1448}}) do
                Screen.bb=BB.new(dimensions[1],dimensions[2],BB.TYPE_BB8)
                Screen.screen_size={w=dimensions[1],h=dimensions[2]}
                local fixture=data(function() end)
                fixture.bottom_actions[3].enabled=true
                if dimensions[1]~=320 then fixture.cover_path='plugins/welite.koplugin/spec/fixtures/cover.png' end
                if dimensions[1]==320 then
                    fixture.title=string.rep('很长的书名',30);fixture.author_line=string.rep('作者与译者 ',20)
                    fixture.intro=string.rep('长简介。',2000)
                end
                view=Detail.show(fixture,{on_refresh=function() end});UI:forceRePaint()
                assert.is_true(view.scroll.dimen.h>0)
                assert.is_false(view.covers_fullscreen)
                assert.equals(0xCC,Screen.bb:getPixel(0,0):getColor8().a)
                -- Repainting the overlay must not progressively darken the background.
                view:paintTo(Screen.bb,0,0)
                assert.equals(0xCC,Screen.bb:getPixel(0,0):getColor8().a)
                assert.equals(255,Screen.bb:getPixel(view.panel_frame.dimen.x+view:px(12),
                    view.panel_frame.dimen.y+view:px(12)):getColor8().a)
                assert.equals(math.floor(dimensions[2]*0.82),view.panel_frame:getSize().h)
                assert.is_true(math.abs(view.panel_frame.dimen.y-(dimensions[2]-view.panel_height)/2)<=1)
                assert.is_true(view.panel_frame.dimen.x>0)
                assert.is_true(view[1]:getSize().h<=dimensions[2])
                assert.is_true(view[1]:getSize().w<=dimensions[1])
                for _,button in ipairs(view._footer_actions) do
                    assert.is_true(button.dimen.y+button.dimen.h<=view.panel_frame.dimen.y+view.panel_height)
                end
                local path=os.getenv('WELITE_SCREENSHOT')
                if path then Screen.bb:writePNG(path:gsub('plugin%-smoke','book-detail-'..dimensions[1]..'x'..dimensions[2])) end
                view:onClose();view=nil;Screen.bb:free();Screen.bb=original
            end
        end)
        if Screen.bb~=original then Screen.bb:free();Screen.bb=original end
        Screen.screen_size=size
        if language then G_reader_settings:saveSetting('language',language)
        else G_reader_settings:delSetting('language') end
        assert.is_true(ok,tostring(err))
    end)
end)
