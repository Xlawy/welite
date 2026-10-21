describe('welite native pull-down menu',function()
    local P,UI,panel
    setup(function() require('commonrequire');package.path='plugins/weread.koplugin/?.lua;'..package.path;P=require('weread.ui.welite.pulldown');UI=require('ui/uimanager') end)
    after_each(function() if panel then panel:onClose();panel=nil end end)
    local function controls()
        return {snapshot=function() return {wifi='WIFI已连接',wifi_on=true,wifi_supported=true,network='家庭网络 ›',time='12:54',battery='88%',capacity=88,
            light_supported=true,light_on=true,brightness=68,night=false} end,brightness=function() return true end,night=function() end}
    end
    it('renders five compact actions and cleans up timers on outside close',function()
        local c=controls();local writes=0;c.refresh=function() writes=writes+1 end
        panel=P:new{controls=c};UI:show(panel);UI:forceRePaint()
        assert.equals(5,#panel.buttons);assert.is_true(panel.buttons[2].enabled)
        assert.same({'WIFI','夜间模式','全屏刷新','KO 设置','WeLite 设置'},
            {panel.action_titles[1].text,panel.action_titles[2].text,panel.action_titles[3].text,panel.action_titles[4].text,panel.action_titles[5].text})
        for i=2,5 do assert.equals(panel.buttons[2].dimen.y,panel.buttons[i].dimen.y) end
        assert.is_true(panel.panel_height<require('device').screen:getHeight())
        local path=os.getenv('WELITE_SCREENSHOT');if path then require('device').screen.bb:writePNG(path:gsub('plugin%-smoke','pulldown-home')) end
        assert.is_truthy(panel.timer)
        panel.buttons[3].callback();assert.is_true(panel.closed);assert.equals(1,writes);assert.is_nil(panel.timer)
        panel.buttons[3].callback();assert.equals(1,writes) -- ignore stale callbacks
    end)
    it('paints all control icons and both toggle states using bounded geometry',function()
        local Icon=require('weread.ui.welite.controlicon');local bb=require('ffi/blitbuffer').new(100,60)
        for _,kind in ipairs({'wifi','moon','settings','refresh','toggle'}) do
            for _,on in ipairs({true,false}) do
                local icon=Icon:new{kind=kind,on=on,width=44,height=24}
                icon:paintTo(bb,5,5);assert.equals(24,icon:getSize().h);assert.is_truthy(icon._bb);icon:free()
            end
        end
        bb:free()
    end)
    it('reuses the host icon cache for repeated menus at the same size',function()
        local Icon=require('weread.ui.welite.controlicon');local bb=require('ffi/blitbuffer').new(60,60)
        local first=Icon:new{kind='moon',width=24,height=24};first:paintTo(bb,0,0)
        local rendered=first._bb;first:free()
        local second=Icon:new{kind='moon',width=24,height=24};second:paintTo(bb,0,0)
        assert.equals(rendered,second._bb);second:free();bb:free()
    end)
    it('shows native reading information without changing position and closes on suspend',function()
        local host={document={info={number_of_pages=392}},rolling={current_page=128},toc={getTocTitleByPage=function() return '第五章' end}}
        panel=P:new{controls=controls(),host=host,home=function() end,chapters={previous=function() end,catalog=function() end,next=function() end},result={full=true,item={title='围城'}}}
        UI:show(panel);UI:forceRePaint();assert.equals('全书 128 / 392 页',panel.reading_info.pages)
        assert.equals(128,host.rolling.current_page)
        local path=os.getenv('WELITE_SCREENSHOT');if path then require('device').screen.bb:writePNG(path:gsub('plugin%-smoke','pulldown-reading')) end
        panel:onSuspend();assert.is_true(panel.closed);assert.is_nil(panel.timer)
    end)
    it('toggles native night mode once and restores it without changing brightness',function()
        local Controls=require('weread.ui.welite.controls');local c=Controls.new(nil)
        local before=G_reader_settings:isTrue('night_mode')
        local ok,err=pcall(function()
            panel=P:new{controls=c};UI:show(panel);UI:forceRePaint()
            panel.buttons[2].callback();assert.equals(not before,G_reader_settings:isTrue('night_mode'))
            assert.equals(not before,panel.state.night)
            panel.buttons[2].callback();assert.equals(before,G_reader_settings:isTrue('night_mode'))
        end)
        if G_reader_settings:isTrue('night_mode')~=before then c:night() end
        assert.is_true(ok,tostring(err))
    end)
    it('opens WeLite settings only after closing either home or reader panel',function()
        for _,reading in ipairs({false,true}) do
            local c=controls();local called=0
            c.weliteSettings=function() assert.is_true(panel.closed);called=called+1;return true end
            panel=P:new{controls=c,host=reading and {document={info={number_of_pages=10}},rolling={current_page=1}} or nil}
            UI:show(panel);panel.buttons[5].callback();assert.equals(1,called)
            panel.buttons[5].callback();assert.equals(1,called)
        end
    end)
    it('offers return home only while reading and closes the overlay before navigation',function()
        local called=0
        panel=P:new{controls=controls()};assert.is_nil(panel.home_button);panel:free();panel=nil
        panel=P:new{controls=controls(),host={document={info={number_of_pages=10}},rolling={current_page=3}},home=function()
            assert.is_true(panel.closed);called=called+1
        end}
        UI:show(panel);panel.home_button.callback();assert.equals(1,called)
        panel.home_button.callback();assert.equals(1,called)
    end)
    it('closes before opening chapter selection and disables chapter boundaries',function()
        local called=0
        panel=P:new{controls=controls(),host={document={info={number_of_pages=10}},rolling={current_page=1}},chapters={catalog=function()
            assert.is_true(panel.closed);called=called+1
        end}}
        UI:show(panel)
        assert.is_false(panel.chapter_buttons[1].enabled);assert.is_false(panel.chapter_buttons[3].enabled)
        panel.chapter_buttons[2].callback();assert.equals(1,called)
    end)
    it('fits Kindle, short landscape and narrow screens with bounded native widgets',function()
        local screen=require('device').screen
        local original,size=screen.bb,screen.screen_size
        local ok,err=pcall(function()
            for _,dim in ipairs({{1072,1448},{600,400},{320,600}}) do
                local bb=require('ffi/blitbuffer').new(dim[1],dim[2]);screen.bb=bb;screen.screen_size={w=dim[1],h=dim[2]}
                panel=P:new{controls=controls(),host={document={info={number_of_pages=100}},rolling={current_page=40}},chapters={previous=function() end,catalog=function() end,next=function() end},result={full=true,item={title=string.rep('长书名',30)}}}
                panel:paintTo(bb,0,0)
                assert.is_true(panel.panel_height<=dim[2]);assert.equals(5,#panel.buttons)
                for i=2,5 do
                    assert.equals(panel.buttons[2].dimen.y,panel.buttons[i].dimen.y)
                    assert.is_true(panel.buttons[i].dimen.x+panel.buttons[i].dimen.w<=dim[1])
                end
                local path=os.getenv('WELITE_SCREENSHOT')
                if path then bb:writePNG(path:gsub('plugin%-smoke','pulldown-'..dim[1]..'x'..dim[2])) end
                panel:free();panel=nil;screen.bb=original;screen.screen_size=size;bb:free()
            end
        end)
        screen.bb=original;screen.screen_size=size
        assert.is_true(ok,tostring(err))
    end)
    it('keeps the entire backlight bottom border after footer repaint at fractional scales',function()
        local screen=require('device').screen
        local original,size=screen.bb,screen.screen_size
        local active
        local function reset(widget)
            for _,child in ipairs(widget) do reset(child) end
            if widget.resetLayout then widget:resetLayout() end
        end
        local ok,err=pcall(function()
            for _,dim in ipairs({{600,800},{1072,1448},{1080,1440}}) do
                for _,fraction in ipairs({0,0.25,0.75}) do
                    active=require('ffi/blitbuffer').new(dim[1],dim[2]);active:fill(require('ffi/blitbuffer').COLOR_WHITE)
                    screen.bb=active;screen.screen_size={w=dim[1],h=dim[2]}
                    panel=P:new{controls=controls(),host={document={info={number_of_pages=100}},rolling={current_page=40}},
                        chapters={catalog=function() end},result={full=true,item={title='边框回归'}}}
                    -- Simulate a host child reporting fractional layout metrics.
                    panel.light_box.padding_bottom=panel.light_box.padding_bottom+fraction
                    reset(panel[1]);panel:paintTo(active,0,0)
                    local g=panel.light_box.dimen
                    local function assertBottom()
                        local y=math.ceil(g.y)+math.ceil(g.h)-1
                        local inset=math.ceil(panel.light_box.radius)+2
                        for x=math.ceil(g.x)+inset,math.ceil(g.x)+math.ceil(g.w)-inset-1 do
                            assert.is_true(active:getPixel(x,y):getColor8().a<128,
                                'missing bottom pixel at '..x..','..y..' fraction='..fraction..' width='..dim[1])
                        end
                    end
                    assertBottom()
                    local footer=panel.close_button.dimen
                    panel.close_button:paintTo(active,footer.x,footer.y)
                    assertBottom()
                    panel.light_box:paintTo(active,g.x,g.y);assertBottom()
                    panel:free();panel=nil;active:free();active=nil
                end
            end
        end)
        screen.bb=original;screen.screen_size=size
        if active then active:free() end
        assert.is_true(ok,tostring(err))
    end)
    it('consumes slider drag and outside taps without closing or touching the background',function()
        local c=controls();local writes=0;c.brightness=function(_,v) writes=writes+1;return true end
        panel=P:new{controls=c};UI:show(panel);UI:forceRePaint()
        local slider=panel.slider;local x=slider.dimen.x+slider.width/2;local y=slider.dimen.y+10
        panel:handleEvent(require('ui/event'):new('Gesture',{ges='pan',pos=require('ui/geometry'):new{x=x,y=y},start_pos=require('ui/geometry'):new{x=x-5,y=y},relative={x=5,y=0}}))
        assert.is_true(slider.dragging);assert.equals(0,writes)
        panel:onSliderDrag(nil,{ges='pan_release',pos={x=10000,y=y}})
        assert.equals(1,writes);assert.is_false(panel.closed or false)
        local brightness=panel.brightness
        panel:updateStatus();assert.equals(brightness,panel.brightness)
        panel:onOutside(nil,{pos={y=panel.panel_height+10}});assert.is_true(panel.closed)
    end)
    it('opens from the shelf top edge and preserves horizontal paging',function()
        local View=require('weread.ui.library_view')
        local shelf=View.show({welite=true,cover_mode=true,books={},mode='books',paged=true,page_size=6},{})
        assert.is_nil(shelf:onSwipe(nil,{direction='south',pos={y=400}}))
        assert.is_true(shelf:onSwipe(nil,{direction='south',pos={y=5}}))
        local first=shelf.quick_menu;shelf:onQuickMenu();assert.equals(first,shelf.quick_menu)
        shelf:onClose();assert.is_nil(shelf.quick_menu)
    end)
end)
