describe('WeLite bounded book storage',function()
    local Settings,Storage,BookStore,root,full,dir,settings,load,save
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        Settings=require('welite.lib.settings');Storage=require('datastorage')
        BookStore=require('welite.lib.book_store')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root)
        require('util').makePath(root..'/settings')
        full,dir=Storage.getFullDataDir,Storage.getSettingsDir
        Storage.getFullDataDir=function() return root end
        Storage.getSettingsDir=function() return root..'/settings' end
        settings=Settings:new()
        local books={}
        for i=1,30 do books[tostring(i)]={title='Book '..i,cache_dir=root..'/books/'..i} end
        settings:set('books',books);settings:flush()
        load,save=BookStore.load,BookStore.save
    end)
    after_each(function()
        BookStore.load,BookStore.save=load,save
        Storage.getFullDataDir,Storage.getSettingsDir=full,dir
        require('ffi/util').purgeDir(root)
    end)
    it('performs no metadata reads on page identity lookup and saves only the changed book',function()
        local reads,writes=0,0
        BookStore.load=function(...) reads=reads+1;return load(...) end
        BookStore.save=function(...) writes=writes+1;return save(...) end
        local life=require('welite.lib.reader_lifecycle')
        local plugin={settings=settings,ui={document={file=root..'/books/12/chapter.epub'}}}
        for _=1,1000 do assert.equals('12',life.detectWeReadBook(plugin)) end
        assert.equals(0,reads)
        local other=Settings:new()
        local book=BookStore.get(settings,'12');book.progress=42
        BookStore.put(settings,'12',book);settings:flush()
        assert.equals(1,reads);assert.equals(1,writes)
        assert.equals(42,other:get_book('12').progress)
        assert.equals('Book 13',other:get_book('13').title)
        -- A stale settings instance sees current shared indexes immediately.
        book.cache_dir=root..'/moved';BookStore.put(other,'12',book);other:flush()
        assert.is_nil(life.detectWeReadBook(plugin))
        plugin.ui.document.file=root..'/moved/chapter.epub'
        assert.equals('12',life.detectWeReadBook(plugin))
    end)
    it('does not replace the index or another book when a single-book save fails',function()
        BookStore.save=function() return false,'synthetic disk full' end
        local ok,err=pcall(settings.set_book,settings,'12',{title='replacement',cache_dir=root..'/wrong'})
        assert.is_false(ok);assert.is_truthy(tostring(err):find('synthetic disk full',1,true))
        BookStore.save=save
        assert.equals('Book 12',settings:get_book('12').title)
        assert.equals('Book 13',settings:get_book('13').title)
        assert.equals('12',settings:find_book(root..'/books/12/chapter.epub'))
    end)
end)
