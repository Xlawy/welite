describe('WeLite annotation catalog preparation',function()
    local Catalog,UI,root,plugin,session,values,stored,ready,binding
    local function drain(predicate)
        local socket=require('socket');local deadline=socket.gettime()+6
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_true(predicate(),'catalog preparation timed out')
    end
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        Catalog=require('weread.ui.annotation_catalog');UI=require('ui/uimanager')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        values={account={user_vid='fixture'}};stored={};ready=nil;binding={book_id='900001',title='合成书籍'}
        plugin={ui={document={file=root..'/fixture.epub'}},_reader_session_gen=1,
            settings={data_dir=root,get=function(_,k,d) return values[k] or d end,flush=function() end},
            requireLogin=function() return true end,_annotationBinding=function() return binding end,
            _annotationStore=function() return {write=function(_,id,changes)
                assert.equals('900001',id)
                for _,change in ipairs(changes) do assert.equals('meta',change.kind);stored[change.key]=change.value end end} end,
            _prepareAnnotationContext=function(_,online)
                assert.is_nil(online,'catalog preparation must use the local-only context API')
                return {catalog=stored.catalog or {}}
            end,
            client={get_text=function() return '{"psvts":"fixture","token":"fixture"}' end,
                post_json=function(_,url,data)
                    assert.is_truthy(url:find('/web/book/chapterInfos',1,true));assert.equals('900001',data.bookIds[1])
                    return {data={{bookId='900001',updated={{chapterUid=1,chapterIdx=1,wordCount=100,title='Chapter one'}}}}}
                end}}
    end)
    after_each(function()
        if session then session:close();session=nil end
        require('ffi/util').purgeDir(root)
    end)
    local function load(refresh) session=Catalog.ensure(plugin,function(context) ready=context end,refresh) end
    it('fetches remotely off the callback and persists before preparing local context',function()
        load();assert.is_not_nil(session.worker);assert.is_nil(stored.catalog)
        drain(function() return ready~=nil end)
        assert.equals('Chapter one',ready.catalog[1].title)
        assert.is_nil(plugin._annotation_catalog_session);assert.is_true(session.closed)
        plugin.requireLogin=function() error('cached preparation must work offline') end
        local result=Catalog.ensure(plugin,function(context) return context.catalog[1].title end)
        assert.equals('Chapter one',result)
    end)
    it('retries failure and records refresh pruning only after a successful catalog',function()
        local fetch=plugin.client.post_json
        plugin.client.post_json=function() error('synthetic offline') end
        load(true);drain(function() return not session.worker end)
        assert.is_nil(ready);assert.is_nil(stored.catalog);assert.is_not_nil(session.view._retry_button)
        plugin.client.post_json=fetch
        session.view._retry_button.callback();drain(function() return ready~=nil end)
        assert.equals(1,#stored.prune_catalog)
    end)
    it('keeps storage failures retryable instead of leaving a frozen loading view',function()
        local store=plugin._annotationStore
        plugin._annotationStore=function() return {write=function() error('synthetic disk failure') end} end
        load();drain(function() return not session.worker end)
        assert.is_nil(ready);assert.is_not_nil(session.view._retry_button)
        assert.is_truthy(tostring(session.error):find('synthetic disk failure',1,true))
        plugin._annotationStore=store
        session.view._retry_button.callback();drain(function() return ready~=nil end)
    end)
    it('discards results when document, account, binding or session changes',function()
        for _,change in ipairs({
            function() plugin.ui.document={} end,
            function() plugin.ui.document.file="other.epub" end,
            function() values.account={user_vid='other'} end,
            function() binding={book_id='other'} end,
            function() plugin._reader_session_gen=2 end,
        }) do
            binding={book_id='900001'};values.account={user_vid='fixture'};plugin._reader_session_gen=1
            load();change();drain(function() return session.closed end)
            assert.is_nil(ready);assert.is_nil(stored.catalog)
        end
    end)
    it('supersedes a pending refresh when a newer action uses cached data',function()
        load(true);local old,worker=session,session.worker
        stored.catalog={{chapterUid=2,title='Cached replacement'}}
        local result=Catalog.ensure(plugin,function(context) return context.catalog[1].title end)
        assert.equals('Cached replacement',result);assert.is_true(old.closed)
        drain(function() return not worker.job end)
        assert.is_nil(ready);assert.equals('Cached replacement',stored.catalog[1].title)
    end)
    it('cancels catalog work through the existing annotation lifecycle cleanup',function()
        load();local worker=session.worker
        require('weread.ui.annotation_sync_controller')._cancelUnifiedAnnotationSync(plugin)
        assert.is_true(session.closed);assert.is_nil(plugin._annotation_catalog_session)
        drain(function() return not worker.job end)
        assert.is_nil(ready);assert.is_nil(stored.catalog)
    end)
end)
