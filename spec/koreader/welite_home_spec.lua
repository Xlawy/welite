describe('WeLite community shelf integration',function()
    local View,UI,Device,view
    setup(function()
        require('commonrequire')
        package.path='plugins/weread.koplugin/?.lua;'..package.path
        View=require('weread.ui.library_view');UI=require('ui/uimanager');Device=require('device')
    end)
    after_each(function() if view then UI:close(view);view=nil end end)
    it('renders the home with six bounded covers and preserves explicit actions',function()
        local books={}
        for i=1,18 do books[i]={bookId=tostring(i),title='测试书籍 '..i,author='作者'} end
        local layout=View.getLayout(true,#books,'books',true)
        assert.is_true(layout.page_size<=6)
        local selected,held,refreshes,local_opened=0,0,0,0
        view=View.show({welite=true,mode='books',books=books,cover_mode=true,paged=true,page=1,
            page_size=layout.page_size,cover_columns=layout.columns,cover_rows=layout.rows,total_books=18},
            {on_select=function(book) assert.equals(books[1],book);selected=selected+1 end,
             on_hold=function(book) assert.equals(books[1],book);held=held+1 end,on_refresh=function() refreshes=refreshes+1 end,
             on_local=function() local_opened=local_opened+1 end})
        UI:forceRePaint()
        assert.is_truthy(view.clock_label);assert.is_truthy(view.clock_timer)
        assert.equals(0,refreshes)
        view.cards[1].callback();assert.equals(1,selected)
        view.cards[1].hold_callback();assert.equals(1,held)
        view.filters[2].callback();assert.equals(1,local_opened)
        view:setRefreshing(true);assert.is_false(view.collection_sync_button.enabled)
        assert.equals('同步中…',view.sync_button.text)
        view:setRefreshing(false);view:setSyncStatus('同步失败')
        assert.equals('同步失败',view.sync_button.text)
        assert.is_true(view[1]:getSize().h<=Device.screen:getHeight())
        local file=os.getenv('WELITE_SCREENSHOT')
        if file then Device.screen.bb:writePNG(file:gsub('plugin%-smoke','welite-home')) end
        view:onQuickMenu();UI:forceRePaint()
        assert.is_truthy(view.quick_menu)
        view:onSuspend();assert.is_nil(view.clock_timer);assert.is_nil(view.quick_menu)
        view:onResume();assert.is_truthy(view.clock_timer)
        assert.equals(0,refreshes)
    end)
    it('keeps the upstream picker layout available without home actions',function()
        view=View.show({mode='books',books={},paged=true,page_size=6},{})
        assert.is_nil(view.clock_label)
    end)
    it('opens the full community menu with nested functions intact',function()
        local Home=require('weread.ui.welite.home')
        local menu=Home.mainMenu{getMainMenuItems=function() return {{text='下载',callback=function() end},
            {text='设置',sub_item_table_func=function() return {{text='账号'}} end}} end}
        UI:forceRePaint()
        assert.equals(2,#menu.tab_item_table[1])
        assert.equals('账号',menu.tab_item_table[1][2].sub_item_table_func()[1].text)
        UI:close(menu)
    end)
    it('renders narrow, short and high DPI screens with at most six covers',function()
        local BB=require('ffi/blitbuffer')
        local original=Device.screen.bb
        local original_size=Device.screen.screen_size
        local ok,err=pcall(function()
            for _,size in ipairs({{320,600},{600,400},{1072,1448}}) do
                Device.screen.bb=BB.new(size[1],size[2],BB.TYPE_BB8)
                Device.screen.screen_size={w=size[1],h=size[2]}
                local books={{bookId='1',title='很长的书名用于检查两行标题和作者',author='作者'}}
                local layout=View.getLayout(true,12,'books',true)
                assert.is_true(layout.page_size<=6)
                view=View.show({welite=true,mode='books',books=books,cover_mode=true,paged=true,page_size=layout.page_size,
                    cover_columns=layout.columns,cover_rows=layout.rows},{})
                UI:forceRePaint();assert.is_true(view[1]:getSize().h<=Device.screen:getHeight())
                local path=os.getenv('WELITE_SCREENSHOT')
                if path then Device.screen.bb:writePNG(path:gsub('plugin%-smoke','welite-home-'..size[1]..'x'..size[2])) end
                UI:close(view);view=nil;Device.screen.bb:free();Device.screen.bb=original
            end
        end)
        if Device.screen.bb~=original then Device.screen.bb:free();Device.screen.bb=original end
        Device.screen.screen_size=original_size
        assert.is_true(ok,tostring(err))
    end)
    it('paints background reading totals and progress into the visible home',function()
        view=View.show({welite=true,mode='books',books={{bookId='fixture',title='测试'}},
            cover_mode=true,paged=true,page=1,total_books=1},{})
        local task
        local worker={busy=function() return false end,start=function(_,options) task=options;return true end}
        local now=os.time()
        local Reading=require('weread.ui.welite.reading')
        local plugin={shelf_view=view,welite_stats_worker=worker,
            settings={data_dir='/tmp',is_api_configured=function() return true end,
                get=function(_,key,default) if key=='account' then return {user_vid='fixture'} end;return default end},
            requireLogin=function() return true end,
            client={get_read_stats=function() return {totalReadTime=3600,
                readTimes={[tostring(Reading.dayStart(now))]=600}} end,
                get_progress=function() return {book={progress=42}} end}}
        local Stats=require('weread.ui.welite.statistics')
        assert.is_true(Stats.ensure(plugin,view))
        task.on_done{ok=true,value=task.task{checkCancelled=function() end}}
        UI:forceRePaint()
        assert.equals(3600,view.overview.monthly.total_seconds)
        assert.equals(600,Reading.today(view.overview).total_seconds)
        assert.is_true(view.stat_values.monthly.text~='—')
        plugin.welite_progress={fingerprint=require('weread.lib.worker_settings').fingerprint(plugin.settings),
            values={},order={},worker=worker}
        require('weread.ui.welite.progress').ensure(plugin,view)
        task.on_done{ok=true,value=task.task{checkCancelled=function() end}}
        UI:forceRePaint()
        local function contains(widget,text)
            if widget.text==text then return true end
            for _,child in ipairs(widget) do
                if type(child)=='table' and contains(child,text) then return true end
            end
            return false
        end
        assert.is_true(contains(view,'42%'))
    end)
end)
