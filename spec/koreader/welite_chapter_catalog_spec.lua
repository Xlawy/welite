describe('ordinary chapter catalog background loading',function()
    local UI,Library,Content,root,plugin,values,session,delivered,db
    local function pump(predicate)
        local socket=require('socket');local deadline=socket.gettime()+8
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_true(predicate(),'catalog request did not finish')
    end
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Library=require('welite.ui.library');Content=require('welite.lib.content')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        values={account={user_vid='fixture'},books={book={book_id='book',title='Book'}}}
        delivered,db=nil,nil
        local json=require('json')
        plugin={settings={data_dir=root,cache_dir=root,get=function(_,k,d) return values[k] or d end,
            set=function(_,k,v) values[k]=v end,flush=function() end},
            requireLogin=function() return true end,isNetworkOnline=function() return true end,
            showOffline=function() plugin.offline=true end,
            client={get_text=function() require('socket').sleep(0.15);return '{"psvts":"fixture"}' end,
                post_json=function() return {data={{bookId='book',updated={{chapterUid=1,wordCount=50,title='One'}}}}} end,
                json_encode=function(_,v) return json.encode(v) end,json_decode=function(_,v) return json.decode(v) end},
            library_db={getChapters=function() return db end,putChapters=function(_,_,v) db=v;return true end}}
    end)
    after_each(function()
        if session then session:close();session=nil end
        require('ffi/util').purgeDir(root)
    end)
    local function load(force)
        session=Library.loadChapters(plugin,values.books.book,function(chapters) delivered=chapters end,force)
    end
    it('loads from the library entry without blocking UI and preserves newer book state',function()
        load()
        local tick=false;UI:scheduleIn(0.01,function() tick=true end)
        pump(function() return tick end)
        assert.is_nil(delivered)
        values.books.book={book_id='book',title='Updated',last_local_position={percent=60},cached_full_book=root..'/latest.epub'}
        pump(function() return delivered~=nil end)
        assert.is_true(session.closed);assert.equals(1,delivered[1].chapterUid)
        assert.equals('Updated',values.books.book.title)
        assert.equals(60,values.books.book.last_local_position.percent)
        assert.equals(root..'/latest.epub',values.books.book.cached_full_book)
        assert.equals(1,db[1].chapterUid)
        local cached=Content.load_catalog_cache(plugin.client,plugin.settings,values.books.book)
        assert.equals(1,cached[1].chapterUid)
        delivered=nil
        plugin.client.get_text=function() error('cache must avoid network') end
        load()
        assert.is_table(delivered);assert.is_nil(session)
    end)
    it('shows a retry action for failure and requires successful persistence before callback',function()
        plugin.client.post_json=function() error('synthetic catalog 503') end
        load(true);pump(function() return session.error~=nil end)
        assert.is_nil(delivered);assert.is_nil(db)
        assert.is_not_nil(session.view._retry_button)
        plugin.client.post_json=function() return {data={{bookId='book',updated={{chapterUid=1,wordCount=50,title='One'}}}}} end
        plugin.library_db.putChapters=function() return false,'synthetic database failure' end
        session.error=nil;session.view._retry_button.callback()
        pump(function() return session.error~=nil end)
        assert.is_truthy(session.error:find('database failure',1,true));assert.is_nil(delivered)
        plugin.library_db.putChapters=function(_,_,v) db=v;return true end
        session.view._retry_button.callback()
        pump(function() return delivered~=nil end)
        assert.is_true(session.closed)
    end)
    it('discards a result from another account',function()
        load(true);values.account={user_vid='other'}
        pump(function() return session.closed end)
        assert.is_nil(delivered);assert.is_nil(db);assert.is_nil(values.books.book.chapters)
    end)
    it('cancels on library close and never invokes the download callback',function()
        load(true)
        Library.closeWeReadUI(plugin)
        assert.is_true(session.closed);assert.is_nil(session.worker)
        local deadline=require('socket').gettime()+0.3
        pump(function() return require('socket').gettime()>deadline end)
        assert.is_nil(delivered);assert.is_nil(db)
    end)
    it('uses an offline cached catalog and does not start forced network work offline',function()
        db={{chapterUid=1,title='Cached'}}
        plugin.isNetworkOnline=function() return false end
        load();assert.is_table(delivered);assert.is_nil(session)
        delivered=nil;load(true)
        assert.is_nil(delivered);assert.is_nil(session);assert.is_true(plugin.offline)
    end)
end)
