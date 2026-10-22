describe('WeLite cloud book search',function()
    local Controller,View,UI,root,plugin,session,values,selected,language,layout_view
    local function drain(predicate)
        local socket=require('socket');local deadline=socket.gettime()+5
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_true(predicate(),'search did not finish')
    end
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        Controller=require('welite.ui.book_search_controller');View=require('welite.ui.book_search_view');UI=require('ui/uimanager')
    end)
    before_each(function()
        language=G_reader_settings:readSetting('language');G_reader_settings:saveSetting('language','zh_CN')
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        values={account={user_vid='fixture'}};selected=nil
        plugin={settings={data_dir=root,get=function(_,k,d) return values[k] or d end,flush=function() end},
            requireLogin=function() return true end,client={},showInfo=function() end,
            showBookRecord=function(_,book) selected=book end,showSearch=function() selected='search_again' end}
        plugin.client.gateway=function(_,api,data)
            assert.equals('/store/search',api);assert.equals(10,data.count)
            return {results={{books={{bookInfo={bookId='one',title=data.keyword,author='合成作者'}}}}}}
        end
    end)
    after_each(function()
        if layout_view then layout_view:onClose();layout_view=nil end
        if session then session:close();session=nil end
        require('ffi/util').purgeDir(root)
        if language then G_reader_settings:saveSetting('language',language) else G_reader_settings:delSetting('language') end
    end)
    it('loads results off the UI callback and forwards selected books to existing details',function()
        session=Controller.show(plugin,'  山间来信  ')
        assert.is_not_nil(session.worker);assert.is_not_nil(session.view.status)
        drain(function() return not session.worker end)
        assert.equals('山间来信',session.query)
        assert.equals(1,#session.view._item_buttons)
        session.view._item_buttons[1].callback()
        assert.equals('one',selected.bookId);assert.equals('山间来信',selected.title)
        session.view._action_button.callback();assert.equals('search_again',selected)
        UI:forceRePaint()
        local screenshot=os.getenv('WELITE_SCREENSHOT')
        if screenshot then require('device').screen.bb:writePNG(screenshot:gsub('plugin%-smoke','book-search')) end
        local old=session.view;old:onClose();assert.is_true(session.closed)
        selected=nil;old._item_buttons[1].callback();assert.is_nil(selected)
    end)
    it('keeps empty results distinct from errors and permits explicit retry',function()
        plugin.client.gateway=function() error('synthetic offline') end
        session=Controller.show(plugin,'空结果');drain(function() return not session.worker end)
        assert.is_not_nil(session.view._retry_button)
        plugin.client.gateway=function() return {results={}} end
        session.view._retry_button.callback();drain(function() return not session.worker end)
        assert.is_nil(session.view.status);assert.equals(0,#session.view._item_buttons)
    end)
    it('invalidates older searches and prevents another account from using cached results',function()
        session=Controller.show(plugin,'旧搜索');local old=session
        session=Controller.show(plugin,'新搜索')
        assert.is_true(old.closed);assert.is_nil(old.worker)
        drain(function() return not session.worker end)
        assert.equals('新搜索',session.view.items[1].title)
        values.account={user_vid='other'}
        session.view._item_buttons[1].callback()
        assert.is_true(session.closed);assert.is_nil(selected)
        session=Controller.show(plugin,'账号切换')
        values.account={user_vid='third'}
        drain(function() return session.closed end)
        assert.is_nil(session.view)
    end)
    it('fits ten long result cards in small and Kindle layouts without overlap',function()
        local Screen=require('device').screen;local BB=require('ffi/blitbuffer')
        local original,size=Screen.bb,Screen.screen_size
        local ok,err=pcall(function()
            for _,dimensions in ipairs({{320,600},{600,400},{1072,1448}}) do
                Screen.bb=BB.new(dimensions[1],dimensions[2],BB.TYPE_BB8)
                Screen.screen_size={w=dimensions[1],h=dimensions[2]}
                local items={};for i=1,10 do items[i]={bookId=tostring(i),title=string.rep('长书名',30),author=string.rep('合成作者',20)} end
                layout_view=View.show({query='合成搜索',items=items}, {})
                UI:forceRePaint()
                assert.is_true(layout_view.scroll.dimen.h>0)
                assert.equals(10,#layout_view._item_buttons)
                for _,button in ipairs(layout_view._item_buttons) do
                    assert.equals(button.frame:getSize().h,button:getSize().h)
                    assert.is_true(button:getSize().h>=button.label_container[1]:getSize().h)
                end
                local screenshot=os.getenv('WELITE_SCREENSHOT')
                if screenshot then Screen.bb:writePNG(screenshot:gsub('plugin%-smoke','book-search-'..dimensions[1]..'x'..dimensions[2])) end
                layout_view:onClose();layout_view=nil;Screen.bb:free();Screen.bb=original
            end
        end)
        if Screen.bb~=original then Screen.bb:free();Screen.bb=original end
        Screen.screen_size=size
        assert.is_true(ok,tostring(err))
    end)
    it('does not request empty queries and closes pending work when leaving the library',function()
        assert.is_nil(Controller.show(plugin,' \n '));assert.is_nil(plugin._book_search_session)
        session=Controller.show(plugin,'合成书籍')
        require('welite.ui.library').closeWeReadUI(plugin)
        assert.is_true(session.closed);assert.is_nil(session.worker)
        assert.is_nil(plugin._book_search_session)
    end)
end)
