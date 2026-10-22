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
        UI=require('ui/uimanager');Worker=require('welite.lib.progress_pull_worker')
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
    it('calculates a cloud chapter ratio from cached source coordinates in the child without fetching text',function()
        local Source=require('welite.lib.annotation_source')
        local Store=require('welite.lib.annotation_store')
        local spans=Source.index('<html><head><title>Hidden</title></head><body><p>甲🌿&amp;乙</p></body></html>')
        Store:new(plugin.settings):put('book','original','7',spans,'7')
        plugin.client={get_text=function() error('preview must not fetch') end}
        local remote={chapter_uid=7,chapter_offset=spans[1][5]+3,percent=25}
        local completed,result=false
        Worker.start(plugin,function()
            local fraction,reason=Worker.cached_chapter_fraction(plugin,'book',remote)
            return {fraction=fraction,reason=reason,offset=remote.chapter_offset}
        end,function(value) result=value;completed=true end,function() return true end)
        pump(function() return completed end)
        assert.is_nil(result.reason);assert.equals(0.5,result.fraction)
        assert.equals(remote.chapter_offset,result.offset)
        assert.same(spans,Store:new(plugin.settings):get('book','original','7',true))
        local fraction,reason=Worker.cached_chapter_fraction(plugin,'book',{chapter_uid=7,chapter_offset=spans[1][5]+2})
        assert.is_nil(fraction);assert.equals('partial_source_character',reason)
        fraction,reason=Worker.cached_chapter_fraction(plugin,'book',{chapter_uid=7,chapter_offset=99999})
        assert.is_nil(fraction);assert.equals('source_offset_outside_text',reason)
    end)
    it('keeps missing, legacy, stale and invalid source previews unavailable',function()
        local Store=require('welite.lib.annotation_store'):new(plugin.settings)
        local remote={chapter_uid=7,chapter_offset=0}
        local fraction,reason=Worker.cached_chapter_fraction(plugin,'book',remote)
        assert.is_nil(fraction);assert.equals('source_cache_missing',reason)
        fraction,reason=Worker.cached_chapter_fraction(plugin,'book',{chapter_uid=7,has_chapter_offset=false})
        assert.is_nil(fraction);assert.equals('remote_offset_unavailable',reason)
        for _,spans in ipairs({{{0,3,'old'}},{{0,3,'old',false,0,3}},{{0,3,'bad',true,0,99}}}) do
            Store:put('book','original','7',spans,'7')
            fraction,reason=Worker.cached_chapter_fraction(plugin,'book',remote)
            assert.is_nil(fraction);assert.is_string(reason)
        end
    end)
    it('bounds source payload reads before decoding JSON',function()
        local Store=require('welite.lib.annotation_store'):new(plugin.settings)
        Store:put('book','original','1',{text='甲'},'1')
        local db=Store:openReadOnly('book')
        local bytes=tonumber(db:rowexec("SELECT length(CAST(payload AS BLOB)) FROM annotation_data"))
        db:close()
        assert.same({text='甲'},Store:get('book','original','1',true,bytes))
        local ok,reason=pcall(Store.get,Store,'book','original','1',true,bytes-1)
        assert.is_false(ok);assert.is_truthy(reason:find('source_cache_limit',1,true))
        assert.same({text='甲'},Store:get('book','original','1',true),'limit failure preserves cache')
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
        local saved=require('welite.lib.content').load_catalog_cache(plugin.client,plugin.settings,values.books.book)
        assert.equals(1,saved[1].chapterUid)
        plugin.client.json_encode=function() error('synthetic catalog persistence failure') end
        completed=false
        Worker.catalog(plugin,'book',function(value,reason) completed,chapters,err=true,value,reason end,function() return true end)
        pump(function() return completed end)
        assert.is_nil(chapters);assert.is_truthy(err:find('persistence failed',1,true))
    end)

    it('upgrades legacy TXT source in the parent and preserves original UTF-16 coordinates',function()
        local Store=require('welite.lib.annotation_store')
        local Content=require('welite.lib.content')
        local Source=require('welite.lib.annotation_source')
        local book={book_id='book',_content_format='txt'}
        local chapter={chapterUid=1}
        Store:new(plugin.settings):put('book','original','1',{{0,3,'old',true}},'1')
        local raw="甲🌿<&乙"
        local decode=Content.decode_content_shards
        local cache=Content.cache_annotation_source
        Content.decode_content_shards=function(a,b) assert.equals(raw,a);assert.equals('',b);return a end
        Content.cache_annotation_source=function() error('child must not write the shared source cache') end
        local fetching,allow_fetch=root..'/fetching',root..'/allow-fetch'
        plugin.client={get_text=function() return '{"psvts":"fixture"}' end,
            json_encode=function(_,v) return require('json').encode(v) end,
            request=function(_,req)
                -- Pause at the network boundary, after the child's cache
                -- read has closed. The parent can check the old data before
                -- allowing completion without racing SQLite WAL recovery.
                local marker=assert(io.open(fetching,'w'));marker:close()
                local socket=require('socket');local deadline=socket.gettime()+5
                while not require('libs/libkoreader-lfs').attributes(allow_fetch) do
                    assert(socket.gettime()<deadline,'parent did not release source fetch')
                    socket.sleep(0.01)
                end
                return req.url:find('t_0',1,true) and raw or '',200
            end}
        local completed,spans,err=false
        local ok,reason=pcall(function()
            assert.is_true(Worker.source(plugin,book,chapter,function(value,why)
                spans,err,completed=value,why,true
            end,function() return true end))
            pump(function() return require('libs/libkoreader-lfs').attributes(fetching)~=nil end)
            assert.is_false(completed,'source cannot commit before the fetch completes')
            assert.is_nil(Store:new(plugin.settings):get('book','original','1',true)[1][5])
            local marker=assert(io.open(allow_fetch,'w'));marker:close()
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
        local Store=require('welite.lib.annotation_store')
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

    it('rebuilds only an outdated HTML chapter and preserves it on network or account failure',function()
        local Store=require('welite.lib.annotation_store')
        local Source=require('welite.lib.annotation_source')
        local Position=require('welite.lib.source_position')
        local Content=require('welite.lib.content')
        local store=Store:new(plugin.settings)
        local legacy={{13,15,'未知',false,13,15},{35,42,'Visible',false,35,42}}
        store:put('book','original','1',legacy,'1')
        store:put('book','original','2',legacy,'2')
        store:put('book','source','1',{reviews={{content='fixture annotation'}}},'1')
        local original_fetch=Content.fetch_chapter_xhtml
        local fetch_log=root..'/fetch-log'
        local mode='offline'
        local html='<html><head><title>未知</title></head><body><p>Visible 🌿 text.</p></body></html>'
        Content.fetch_chapter_xhtml=function(_,_,book,chapter,options)
            assert.equals('book',book.book_id);assert.equals(1,chapter.chapterUid)
            assert.is_true(options.no_source_cache)
            local out=assert(io.open(fetch_log,'a'));out:write('fetch\n');out:close()
            if mode=='offline' then error('synthetic network offline') end
            if mode=='account' then require('socket').sleep(0.1) end
            if mode=='limit' then return string.rep('x',Position.MAX_BYTES+1) end
            return html
        end
        local function pull(change_account)
            local completed,spans,err=false
            assert.is_true(Worker.source(plugin,{book_id='book'},{chapterUid=1},function(value,why)
                spans,err,completed=value,why,true
            end,function() return true end))
            if change_account then values.cookies={wr_skey='different-account'} end
            pump(function() return completed end)
            return spans,err
        end
        local ok,reason=pcall(function()
            local spans,err=pull()
            assert.is_nil(spans);assert.is_truthy(err:find('network offline',1,true))
            assert.same(legacy,store:get('book','original','1',true))
            mode='limit';spans,err=pull()
            assert.is_nil(spans);assert.equals('source_limit',err)
            assert.same(legacy,store:get('book','original','1',true))
            mode='account';spans,err=pull(true)
            assert.is_nil(spans);assert.is_truthy(err:find('credentials changed',1,true))
            -- The fixture store uses no account key, isolating the commit guard.
            assert.same(legacy,store:get('book','original','1',true))
            mode='success';spans,err=pull()
            assert.is_nil(err);assert.is_true(Source.is_current_span(spans[1]))
            assert.equals('Visible🌿text.',assert(Position.new(spans)).text)
            assert.same(spans,store:get('book','original','1',true))
            assert.same(legacy,store:get('book','original','2',true))
            assert.equals('fixture annotation',store:get('book','source','1',true).reviews[1].content)
            -- Repeated use must perform no fifth fetch, even if now offline.
            mode='offline';local cached,cached_error=pull()
            assert.is_nil(cached_error);assert.same(spans,cached)
            local log=assert(io.open(fetch_log,'r'));local calls=log:read('*a');log:close()
            assert.equals('fetch\nfetch\nfetch\nfetch\n',calls)
        end)
        Content.fetch_chapter_xhtml=original_fetch
        assert.is_true(ok,tostring(reason))
    end)

end)
