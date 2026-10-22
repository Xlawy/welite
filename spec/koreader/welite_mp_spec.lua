describe('WeLite public accounts',function()
    local Controller,UI,root,plugin,session,values,cache,selected
    local function drain(predicate)
        local socket=require('socket');local deadline=socket.gettime()+5
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_true(predicate(),'MP task did not finish')
    end
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        Controller=require('welite.ui.mp_controller');UI=require('ui/uimanager')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        values={account={user_vid='fixture'},cache={download_dir=root}};cache=nil;selected=nil
        plugin={settings={data_dir=root,get=function(_,k,d) return values[k] or d end,flush=function() end},
            client={},requireLogin=function() return true end,rememberMPAccount=function() end,
            getCachedMPArticles=function() return cache end,cacheMPArticles=function(_,_,items) cache=items end,
            downloadMPArticleAndRead=function(_,book,article) selected=article end,
            showMPAccount=function(_,book) selected=book end,openFile=function(_,path) selected=path end}
        plugin.client.get_mp_content=function()
            return '<html><div id="js_content"><p>Synthetic article body.</p></div><script></script></html>'
        end
        plugin.client.get_mp_articles=function(_,id,start,count)
            assert.equals('MP_WXS_fixture',id);assert.equals(0,start);assert.equals(100,count)
            return {reviews={{subReviews={{review={reviewId='a',mpInfo={title='Synthetic article'},createTime=1}}}}}}
        end
    end)
    after_each(function()
        if session then session:close();session=nil end
        require('ffi/util').purgeDir(root)
    end)
    local function book() return {bookId='MP_WXS_fixture',title='Synthetic account',cache_dir=root} end
    it('loads articles in a worker and delegates selection to the upstream reading path',function()
        session=Controller.show(plugin,book())
        assert.is_not_nil(session.worker)
        drain(function() return not session.worker end)
        assert.equals('Synthetic article',cache[1].title)
        assert.equals(1,#session.view._item_buttons)
        session.view._item_buttons[1].callback()
        assert.is_nil(selected);assert.is_not_nil(session.worker)
        drain(function() return session.closed end)
        local file=assert(io.open(selected,'rb'));local text=file:read('*a');file:close()
        assert.is_truthy(text:find('Synthetic article body.',1,true))
        assert.is_truthy(text:find('</html>',1,true))
        UI:forceRePaint()

    end)
    it('opens the correct offline body for same-title articles with distinct IDs',function()
        local Content=require('welite.lib.content')
        cache={{title='Same title',reviewId='review/1'},{title='Same title',reviewId='review_1'}}
        for i,article in ipairs(cache) do
            Content.save_mp_article_html(plugin.settings,book(),article,'<p>Article body '..i..'</p>')
        end
        plugin.requireLogin=function() error('offline article must not request login') end
        session=Controller.show(plugin,book())
        for i=1,2 do
            session.view._item_buttons[i].callback()
            local file=assert(io.open(selected,'rb'));local body=file:read('*a');file:close()
            assert.is_truthy(body:find('Article body '..i,1,true))
        end
    end)
    it('pages by review groups, retains the first-page cache and retries the same cursor',function()
        local failing=false
        plugin.client.get_mp_articles=function(_,id,offset,count)
            assert.equals(100,count)
            if failing then error('synthetic next-batch failure') end
            local function item(article_id) return {review={reviewId=tostring(article_id),mpInfo={title='Article '..article_id}}} end
            if offset==0 then return {reviews={{subReviews={item(1),item(2)}},{subReviews={item(3)}}}} end
            if offset==2 then return {reviews={{subReviews={item(4)}}}} end
            assert.equals(3,offset);return {reviews={}}
        end
        session=Controller.show(plugin,book());drain(function() return not session.worker end)
        assert.equals(3,#session.view.items);assert.equals(2,session.next_offset)
        failing=true;session.view._batch_buttons[1].callback();drain(function() return not session.worker end)
        assert.is_not_nil(session.view._retry_button);assert.equals(0,session.offset)
        failing=false;session.view._retry_button.callback();drain(function() return not session.worker end)
        assert.equals(2,session.offset);assert.equals('Article 4',session.view.items[1].title)
        assert.equals('Article 1',cache[1].title)
        assert.equals(2,#session.view._batch_buttons)
        session.view._batch_buttons[2].callback();drain(function() return not session.worker end)
        assert.equals(3,session.offset);assert.equals(0,#session.view.items);assert.is_nil(session.next_offset)
        session.view._batch_buttons[1].callback();drain(function() return not session.worker end)
        assert.equals(2,session.offset);assert.equals('Article 4',session.view.items[1].title)
        session.view._batch_buttons[1].callback();drain(function() return not session.worker end)
        assert.equals(0,session.offset);assert.equals(3,#session.view.items)
    end)
    it('uses cached articles offline and renders only ten cards per page',function()
        cache={};for i=1,23 do
            cache[i]={title='Article '..i,reviewId=tostring(i)}
            require('welite.lib.content').save_mp_article_html(plugin.settings,book(),cache[i],'<p>Cached article</p>')
        end
        plugin.requireLogin=function() error('cached list must not require network') end
        session=Controller.show(plugin,book())
        assert.is_nil(session.worker);assert.equals(10,#session.view._item_buttons)
        session.view._next_button.callback();assert.equals(2,session.view.page)
        session.view._item_buttons[1].callback();assert.equals(require('welite.lib.content').mp_article_path(plugin.settings,book(),cache[11]),selected)
        session.view._next_button.callback();assert.equals(3,#session.view._item_buttons)
        session.view._previous_button.callback();assert.equals(2,session.view.page)
    end)
    it('retries failed article downloads and opens the generated HTML in the native reader',function()
        local article={reviewId='body',title='Native article'}
        plugin.client.get_mp_content=function() error('synthetic download failure') end
        plugin.client.renew_cookie=function() end
        session=Controller.download(plugin,book(),article)
        drain(function() return not session.worker end)
        assert.is_nil(selected);assert.is_not_nil(session.view._retry_button)
        plugin.client.get_mp_content=function()
            return '<div id="js_content"><p>Native article body.</p></div><script></script>'
        end
        session.view._retry_button.callback();drain(function() return session.closed end)
        assert.is_truthy(selected)
        local document=assert(require('document/documentregistry'):openDocument(selected))
        local reader=require('apps/reader/readerui'):new{dimen=require('device').screen:getSize(),document=document}
        local ok,err=pcall(function()
            UI:show(reader);UI:forceRePaint()
            assert.is_true(reader.document:getPageCount()>0)
            local screenshot=os.getenv('WELITE_SCREENSHOT')
            if screenshot then require('device').screen.bb:writePNG(screenshot:gsub('plugin%-smoke','mp-reader')) end
        end)
        reader:onClose()
        assert.is_true(ok,tostring(err))
    end)
    it('cancels a running article request without opening or publishing incomplete HTML',function()
        local article={reviewId='slow',title='Slow article'}
        local marker=root..'/started'
        plugin.client.get_mp_content=function()
            local file=assert(io.open(marker,'wb'));file:write('started');file:close()
            require('socket').sleep(2)
            return '<div id="js_content"><p>Late content.</p></div><script></script>'
        end
        session=Controller.download(plugin,book(),article)
        drain(function() return require('lfs').attributes(marker)~=nil end)
        local worker=session.worker
        session:close()
        drain(function() return worker.job==nil end)
        assert.is_nil(selected);assert.is_nil(session.worker)
        assert.is_nil(require('welite.lib.content').mp_article_cached_path(plugin.settings,book(),article))
    end)
    it('keeps errors retryable and refreshes an empty cached list explicitly',function()
        cache={};session=Controller.show(plugin,book());assert.is_nil(session.worker)
        plugin.client.get_mp_articles=function() error('synthetic offline') end
        session.view._action_button.callback();drain(function() return not session.worker end)
        assert.is_not_nil(session.view._retry_button);assert.is_not_nil(session.error)
        plugin.client.get_mp_articles=function() return {reviews={}} end
        session.view._retry_button.callback();drain(function() return not session.worker end)
        assert.is_nil(session.view.status);assert.equals(0,#cache)
    end)
    it('retries once after renewing rejected credentials',function()
        local requests,renewals=0,0
        plugin.client.get_mp_articles=function()
            requests=requests+1
            if requests==1 then return nil,-2012 end
            assert.equals(2,requests);assert.equals(1,renewals)
            return {reviews={{subReviews={{reviewId='renewed',mpInfo={title='Renewed article'}}}}}}
        end
        plugin.client.renew_cookie=function() renewals=renewals+1 end
        session=Controller.show(plugin,book());drain(function() return not session.worker end)
        assert.equals('Renewed article',cache[1].title);assert.is_nil(session.error)
    end)
    it('renews rejected credentials once and never loops on repeated rejection',function()
        plugin.client.get_mp_articles=function() return nil,-2041 end
        plugin.client.renew_cookie=function() end
        session=Controller.show(plugin,book());drain(function() return not session.worker end)
        assert.is_not_nil(session.error);assert.is_not_nil(session.view._retry_button)
        assert.equals(require('welite.lib.i18n').tr('WeRead could not refresh the public-account credential. Please scan the QR code again.'),session.view.status)
    end)
    it('shows accounts and cancels stale requests on account changes or library close',function()
        plugin.shelf_mp={book()};session=Controller.show(plugin)
        session.view._item_buttons[1].callback();assert.equals('MP_WXS_fixture',selected.bookId)
        session=Controller.show(plugin,book());values.account={user_vid='other'}
        drain(function() return session.closed end);assert.is_nil(cache)
        session=Controller.show(plugin,book())
        require('welite.ui.library').closeWeReadUI(plugin)
        assert.is_true(session.closed);assert.is_nil(session.worker)
    end)
end)
