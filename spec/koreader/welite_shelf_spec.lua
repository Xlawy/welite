describe("welite cover shelf",function()
    local Shelf,view,UI
    setup(function()
        require("commonrequire");package.path="plugins/weread.koplugin/?.lua;"..package.path
        Shelf=require("weread.ui.welite.shelf");UI=require("ui/uimanager")
    end)
    after_each(function() if view then UI:close(view);view=nil end end)
    it("explains oversized covers separately from download failures",function()
        assert.equals("封面像素超限",Shelf.coverErrorText{kind="cover_pixels"})
        assert.equals("封面加载失败",Shelf.coverErrorText{kind="timeout"})
        assert.is_nil(Shelf.coverErrorText(nil))
    end)
    it("paginates only visible cards, searches locally and exposes keyboard paging",function()
        local items={};for n=1,30 do items[n]={id=tostring(n),kind="book",title="山间来信 "..n,author="林知远"} end
        local paged=0;local opened
        view=Shelf:new{items=items,actions={refresh=function() end,search=function() end,more=function() end,
            statistics=function() end,page=function(visible) paged=#visible end,detail=function(item) opened=item end}}
        UI:show(view);UI:forceRePaint()
        assert.is_true(#view:visibleItems()<=6);assert.is_true(view.pages>1)
        view:onNextPage();assert.equals(2,view.page);assert.equals(view.page_size,paged)
        view.cards[1].callback();assert.equals(items[view.page_size+1],opened)
        view:onSwipe(nil,{direction="east"});assert.equals(1,view.page)
        view:setQuery("山间来信 30");assert.equals(1,#view:visibleItems());assert.equals(1,view.pages)
        view:setQuery("不存在");assert.equals(0,#view:visibleItems())
    end)
    it("offers a bordered sync action beside both collection tabs and disables it while syncing",function()
        local calls=0
        view=Shelf:new{items={},actions={refresh=function() calls=calls+1 end}}
        UI:show(view);UI:forceRePaint()
        for _,category in ipairs({"shelf","local"}) do
            view:setCollection(category);UI:forceRePaint()
            local b=view.collection_sync_button
            assert.equals("同步",b.text)
            assert.is_true(b.bordersize>0)
            assert.is_true(b.dimen.x>=view.filters[2].dimen.x+view.filters[2].dimen.w)
            local filter=view.filter_button
            assert.equals(filter.dimen.x+filter.dimen.w,b.dimen.x+b.dimen.w)
            assert.is_true(filter.dimen.y>=b.dimen.y+b.dimen.h)
            assert.is_true(b.dimen.y<view.filters[2].dimen.y+view.filters[2].dimen.h)
            b:onTapSelectButton()
        end
        assert.equals(2,calls)
        view.refreshing=true;view:redraw();UI:forceRePaint()
        assert.is_false(view.collection_sync_button.enabled)
        view.collection_sync_button:onTapSelectButton();assert.equals(2,calls)
        view.refreshing=false;view:redraw()
        assert.is_true(view.collection_sync_button.enabled)
    end)
    it("renders cached image cards with correctly scoped reading totals",function()
        local path=require("ffi/util").realpath("plugins/welite.koplugin").."/spec/fixtures/cover.png"
        local items={
            {id="a",kind="book",title="很长很长的书名，用于验证中文标题单行截断与居中对齐",author="测试作者"},
            {id="b",kind="book",title="山间来信",author="林知远",percent=42},
            {id="c",kind="book",title="湖岸手记",author="许初"},
            {id="d",kind="book",title="未下载封面的书",author="测试作者"},
            {id="e",kind="album",title="听见山川",author="测试演播"},
            {id="f",kind="articles",title="文章收藏",author=""},
        }
        view=Shelf:new{items=items,downloads={["book:a"]="full",["book:b"]="partial"},
            statistics={total_seconds=7260,days=5,updated=1792425600},mode="monthly",cover_paths={["book:a"]=path,["book:b"]=path,["book:c"]=path},
            actions={refresh=function() end,search=function() end,more=function() end,statistics=function() end,detail=function() end}}
        UI:show(view);UI:forceRePaint()
        assert.equals("2 小时 1 分",view.stat_values.monthly.text)
        local long=view.cards[1].label_container[1]
        local short=view.cards[2].label_container[1]
        assert.equals(short[3]:getSize().h,long[3]:getSize().h)
        local _,ellipsis=long[3]:getFittedText()
        assert.is_true(ellipsis)
        assert.equals(require("ui/font"):getFace("cfont",13),long[5].face)
        assert.is_true(long[3]:getSize().h+long[4]:getSize().h<42)
        local output=os.getenv("WELITE_SCREENSHOT")
        if output then require("device").screen.bb:writePNG(output:gsub("plugin%-smoke","cover-shelf")) end
    end)
    it("renders a full page at Kindle-sized resolution without double font scaling",function()
        local screen=require("device").screen
        local previous,previous_size=screen.bb,screen.screen_size
        local bb=require("ffi/blitbuffer").new(1072,1448)
        screen.bb=bb;screen.screen_size={w=1072,h=1448}
        local ok,err=pcall(function()
            local items={};for n=1,6 do items[n]={id=tostring(n),kind="book",title="山间来信 "..n,author="林知远"} end
            view=Shelf:new{items=items,downloads={["book:1"]="full",["book:2"]="partial"},statistics={total_seconds=7260,days=5},actions={refresh=function() end,
                search=function() end,more=function() end,statistics=function() end,detail=function() end}}
            assert.equals(6,#view.cards);assert.equals(15,view.sync_button.text_font_size)
            assert.is_true(view[1]:getSize().h<=1448)
            view:paintTo(bb,0,0)
            local output=os.getenv("WELITE_SCREENSHOT")
            if output then bb:writePNG(output:gsub("plugin%-smoke","cover-shelf-large")) end
            view:free();view=nil
        end)
        screen.bb=previous;screen.screen_size=previous_size;bb:free()
        assert.is_true(ok,tostring(err))
    end)
    it("formats valid cloud percentages without inventing unknown progress",function()
        assert.equals("0%",Shelf.progressText{percent=0})
        assert.equals("42%",Shelf.progressText{percent=42.8})
        assert.equals("100%",Shelf.progressText{percent=100})
        assert.equals("—",Shelf.progressText{})
        assert.equals("—",Shelf.progressText{percent=101})
    end)
    it("lays out huge statistics and cancels minute updates on suspend and close",function()
        view=Shelf:new{items={},overview={monthly={total_seconds=10000*3600+3540},weekly={total_seconds=1000*3600+3540}},
            actions={refresh=function() end,more=function() end,statistics=function() end}}
        UI:show(view);UI:forceRePaint()
        assert.is_truthy(view.clock_timer)
        assert.is_true(view.stat_values.monthly.size>=18)
        assert.is_true(view.stat_values.monthly.text:find('10000',1,true)~=nil)
        local output=os.getenv('WELITE_SCREENSHOT')
        if output then require('device').screen.bb:writePNG(output:gsub('plugin%-smoke','shelf-long-duration')) end
        local clock=view.clock_label;view.last_status.time='old'
        view:updateStatus();assert.equals(clock,view.clock_label)
        view:onSuspend();assert.is_nil(view.clock_timer)
        view:onResume();assert.is_truthy(view.clock_timer)
        UI:close(view);assert.is_nil(view.clock_timer);view=nil
    end)
    it("shows today's bucket and clears yesterday's value on midnight repaint",function()
        local R=require('weread.ui.welite.reading');local now=os.time();local day=R.dayStart(now)
        view=Shelf:new{items={},overview={weekly={total_seconds=8353,updated=now,daily_times={[tostring(day)]=204}}},
            actions={refresh=function() end,more=function() end,statistics=function() end}}
        UI:show(view);assert.equals('3 分钟',view.stat_values.daily.text)
        UI:forceRePaint();local path=os.getenv('WELITE_SCREENSHOT')
        if path then require('device').screen.bb:writePNG(path:gsub('plugin%-smoke','shelf-today')) end
        view.overview.weekly.updated=day-1;view.day_stamp=day-86400
        view:updateStatus();assert.equals('—',view.stat_values.daily.text)
    end)
end)
