describe('background progress pull',function()
    local UI,Worker,root,plugin,values
    local function pump(predicate)
        local socket=require('socket');local deadline=socket.gettime()+8
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_true(predicate(),'progress worker did not finish')
    end
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Worker=require('weread.lib.progress_pull_worker')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        values={cookies={wr_skey='fixture'}}
        plugin={settings={data_dir=root,get=function(_,k,d) return values[k] or d end,
            flush=function() end,update_auth=function(_,auth) values.cookies=auth.cookies end}}
    end)
    after_each(function() Worker.cancel(plugin);require('ffi/util').purgeDir(root) end)
    it('keeps the UI ticking and applies renewed credentials only after a valid result',function()
        local completed,remote,tick=false,nil,false
        assert.is_true(Worker.start(plugin,function(check)
            check();require('socket').sleep(0.2)
            plugin.settings:update_auth({cookies={wr_skey='renewed'}})
            return {percent=17}
        end,function(value) remote=value;completed=true end,function() return true end))
        UI:scheduleIn(0.01,function() tick=true end)
        assert.equals('fixture',values.cookies.wr_skey)
        pump(function() return tick end);assert.is_false(completed)
        pump(function() return completed end)
        assert.equals(17,remote.percent);assert.equals('renewed',values.cookies.wr_skey)
    end)
    it('cancels work and ignores its completion after the reader closes',function()
        local completed=false
        Worker.start(plugin,function() require('socket').sleep(0.2);return {percent=99} end,
            function() completed=true end,function() return true end)
        local worker=plugin._progress_pull_worker
        Worker.cancel(plugin);pump(function() return worker.job==nil end)
        assert.is_false(completed);assert.is_nil(plugin._progress_pull_worker)
    end)
    it('does not overwrite credentials changed while the worker was running',function()
        local completed,remote,err=false
        Worker.start(plugin,function()
            plugin.settings:update_auth({cookies={wr_skey='obsolete'}});return {percent=99}
        end,function(value,reason) remote,err,completed=value,reason,true end,function() return true end)
        values.cookies={wr_skey='new-account'}
        pump(function() return completed end)
        assert.is_nil(remote);assert.is_truthy(err:find('credentials changed',1,true))
        assert.equals('new-account',values.cookies.wr_skey)
    end)
    it('fetches a missing catalog in the child and commits it before continuing',function()
        local json=require('json')
        plugin.settings.cache_dir=root
        values.books={book={book_id='book',title='Fixture'}}
        local db
        plugin.library_db={putChapters=function(_,id,chapters) assert.equals('book',id);db=chapters end}
        plugin.client={get_text=function() return '{"psvts":"fixture"}' end,
            post_json=function() return {data={{bookId='book',updated={{chapterUid=1,wordCount=100,title='One'}}}}} end,
            json_encode=function(_,value) return json.encode(value) end,
            json_decode=function(_,value) return json.decode(value) end}
        local completed,chapters,err=false
        assert.is_true(Worker.catalog(plugin,'book',function(value,reason)
            completed,chapters,err=true,value,reason
            assert.is_table(db)
        end,function() return true end))
        assert.is_nil(db)
        pump(function() return completed end)
        assert.is_nil(err);assert.equals('One',chapters[1].title)
        local saved=require('weread.lib.content').load_catalog_cache(plugin.client,plugin.settings,values.books.book)
        assert.equals(1,saved[1].chapterUid)
        plugin.client.json_encode=function() error('synthetic catalog persistence failure') end
        completed=false
        Worker.catalog(plugin,'book',function(value,reason) completed,chapters,err=true,value,reason end,function() return true end)
        pump(function() return completed end)
        assert.is_nil(chapters);assert.is_truthy(err:find('persistence failed',1,true))
    end)

    it('upgrades legacy TXT source in the parent and preserves original UTF-16 coordinates',function()
        local Store=require('weread.lib.annotation_store')
        local Content=require('weread.lib.content')
        local Source=require('weread.lib.annotation_source')
        local book={book_id='book',_content_format='txt'}
        local chapter={chapterUid=1}
        Store:new(plugin.settings):put('book','original','1',{{0,3,'old',true}},'1')
        local raw="甲🌿<&乙"
        local decode=Content.decode_content_shards
        local cache=Content.cache_annotation_source
        Content.decode_content_shards=function(a,b) assert.equals(raw,a);assert.equals('',b);return a end
        Content.cache_annotation_source=function() error('child must not write the shared source cache') end
        plugin.client={get_text=function() return '{"psvts":"fixture"}' end,
            json_encode=function(_,v) return require('json').encode(v) end,
            request=function(_,req)
                require('socket').sleep(0.03)
                return req.url:find('t_0',1,true) and raw or '',200
            end}
        local completed,spans,err=false
        local ok,reason=pcall(function()
            assert.is_true(Worker.source(plugin,book,chapter,function(value,why)
                spans,err,completed=value,why,true
            end,function() return true end))
            assert.is_nil(Store:new(plugin.settings):get('book','original','1')[1][5])
            pump(function() return completed end)
            assert.is_nil(err);assert.is_table(spans)
            assert.equals('🌿',Source.quote(spans,'1-3','utf16'))
            local saved=Store:new(plugin.settings):get('book','original','1')
            assert.equals(raw,saved[1][3]);assert.equals(6,saved[1][6])
            -- A current cache requires no further chapter/network request.
            plugin.client.request=function() error('cache hit fetched content') end
            completed=false
            Worker.source(plugin,book,chapter,function(value,why) spans,err,completed=value,why,true end,
                function() return true end)
            pump(function() return completed end)
            assert.is_nil(err);assert.equals(raw,spans[1][3])
        end)
        Content.decode_content_shards,Content.cache_annotation_source=decode,cache
        assert.is_true(ok,tostring(reason))
    end)

    it('reads source cache through a read-only connection while a writer holds a transaction',function()
        local Store=require('weread.lib.annotation_store')
        local store=Store:new(plugin.settings)
        local original={{0,3,'abc',true,0,3}}
        store:put('book','original','1',original,'1')
        local writer=assert(store:open('book',true))
        local ok,err=pcall(function()
            writer:exec('BEGIN IMMEDIATE')
            -- A read-only handle cannot initialize schema, even by accident.
            local reader=assert(store:openReadOnly('book'))
            assert.is_false(pcall(reader.exec,reader,'CREATE TABLE must_not_exist (id INTEGER)'))
            reader:close()
            assert.same(original,store:get('book','original','1',true))
            assert.is_nil(store:get('missing','original','1',true))
        end)
        writer:exec('ROLLBACK');writer:close()
        assert.is_true(ok,tostring(err))
    end)

end)
