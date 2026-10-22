describe('WeLite background book info',function()
    local UI,Controller,View,root,plugin,values,session,view,writes
    local function drain(predicate)
        local socket=require('socket');local deadline=socket.gettime()+8
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.02) until socket.gettime()>deadline
        assert.is_true(predicate(),'book info worker did not finish')
    end
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Controller=require('welite.ui.book_info_controller')
        View=require('welite.ui.book_detail_view')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        writes=0;values={account={user_vid='fixture'},books={book={book_id='book',title='Cached'}}}
        plugin={settings={data_dir=root,get=function(_,k,d) return values[k] or d end,
            set=function(_,k,v) values[k]=v end,flush=function() writes=writes+1 end},
            requireLogin=function() return true end,isNetworkOnline=function() return true end,
            showInfo=function(_,err) plugin.error=err end,showOffline=function() plugin.offline=true end,
            client={get_book_info=function() return {title='Updated',intro='New introduction'} end,
                get_progress=function() return {book={progress=42,chapterUid=2}} end}}
        plugin.showBookMenu=function(_,book,existing)
            view=View.show({title=book.title,intro=book.intro,bottom_actions={},metadata={},actions={}},
                {on_close=function() if plugin._book_info_session then plugin._book_info_session:close() end end},existing)
            plugin._book_detail_view=view;return view
        end
    end)
    after_each(function()
        if session then session:close();session=nil end
        if view then view:onClose();view=nil end
        require('ffi/util').purgeDir(root)
    end)
    it('shows cached data before worker completion and updates the existing modal',function()
        session=Controller.refresh(plugin,values.books.book)
        local original=view
        local overlay=require('ui/widget/infomessage'):new{text='Other operation'}
        UI:show(overlay)
        local stack_size=#UI._window_stack
        assert.equals('Cached',view.data.title);assert.is_not_nil(session.worker)
        values.books.book.cached_full_book='/new-download.epub'
        values.books.book.last_local_position={percent=60}
        drain(function() return session.closed end)
        assert.is_nil(plugin.error);assert.equals(original,view)
        assert.equals(stack_size,#UI._window_stack)
        assert.equals(overlay,UI:getTopmostVisibleWidget())
        UI:close(overlay)
        assert.equals('Updated',view.data.title);assert.equals(42,values.books.book.progress)
        assert.equals('/new-download.epub',values.books.book.cached_full_book)
        assert.equals(60,values.books.book.last_local_position.percent)
        assert.equals(1,writes)
        UI:forceRePaint()
    end)
    it('keeps cached details on failure and allows another explicit attempt',function()
        plugin.client.get_book_info=function() error('synthetic 503') end
        session=Controller.refresh(plugin,values.books.book)
        drain(function() return session.closed end)
        assert.is_not_nil(plugin.error);assert.equals('Cached',view.data.title);assert.equals(0,writes)
        plugin.error=nil;plugin.client.get_book_info=function() return {title='Recovered'} end
        session=Controller.refresh(plugin,values.books.book,view)
        drain(function() return session.closed end)
        assert.is_nil(plugin.error);assert.equals('Recovered',view.data.title)
    end)
    it('cancels on close and never resurrects the modal or persists a late result',function()
        plugin.client.get_book_info=function() require('socket').sleep(0.2);return {title='Late'} end
        session=Controller.refresh(plugin,values.books.book)
        view:onClose()
        assert.is_true(session.closed);assert.is_nil(session.worker)
        local deadline=require('socket').gettime()+0.4
        drain(function() return require('socket').gettime()>deadline end)
        assert.equals(0,writes);assert.is_true(view.closed)
    end)
    it('drops results after an account change',function()
        session=Controller.refresh(plugin,values.books.book)
        values.account={user_vid='other'}
        drain(function() return session.closed end)
        assert.equals(0,writes);assert.equals('Cached',view.data.title)
    end)
    it('shows offline cache without launching a worker',function()
        plugin.isNetworkOnline=function() return false end
        session=Controller.refresh(plugin,values.books.book)
        assert.is_nil(session);assert.is_true(plugin.offline)
        assert.equals('Cached',view.data.title);assert.equals(0,writes)
    end)
end)
