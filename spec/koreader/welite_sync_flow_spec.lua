-- Real plugin composition, worker process, storage, shelf, reader, and dialogs.
-- Only remote service responses and the file-manager open-file host are supplied.
describe('WeLite shelf-to-reader sync flow',function()
    local UI,Storage,Settings,Plugin,Dialog,Reader,root,old_full,old_dir
    local manager,reader,target,dialog,old_show,remote,opened,bookpath,online,reading_clock
    local function reports()
        local file=io.open(root..'/server-report.json','r')
        if not file then return 0 end
        local state=require('json').decode(file:read('*a'));file:close()
        remote=state.remote
        return state.count
    end
    local function drain(predicate)
        local socket=require('socket')
        local deadline=socket.gettime()+8
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.02) until socket.gettime()>deadline
        assert.is_true(predicate(),'UI flow did not finish before deadline')
    end
    local function wire(plugin)
        plugin.isNetworkOnline=function() return online end
        plugin.isNetworkConnected=function() return online end
        plugin.read_report.time_ledger.clock=function() return reading_clock end
        plugin.client.get_shelf=function() return {books={{bookId='fixture',title='Fixture',author='Author',progress=remote.progress}}} end
        plugin.client.get_read_stats=function() return {totalReadTime=120,readTimes={}} end
        -- Child uploads update the shared fake service, not the parent's Lua
        -- table. Later reads must observe the acknowledged cloud position.
        plugin.client.get_progress=function() reports();return {book=remote} end
        plugin.client.get_web_progress=function() reports();return {book=remote} end
        plugin.client.get_text=function() return '{"psvts":"fixture-session","token":"fixture-token"}' end
        plugin.client.report_read=function(_,payload)
            if payload.rt~=nil then
                assert.is_true(payload.rt==0 or payload.rt==45,
                    'only a position write or the controlled 45-second session is expected')
                local count=reports()
                local file=io.open(root..'/server-report.json','r')
                local seconds=0
                if file then
                    seconds=require('json').decode(file:read('*a')).read_seconds or 0;file:close()
                end
                if payload.rt==0 then count=count+1 else seconds=seconds+payload.rt end
                remote={progress=payload.pr,chapterUid=1,chapterIdx=1,chapterOffset=payload.co}
                -- Publish one complete simulated service response. The parent
                -- polls this file while the upload worker runs in a child.
                local temporary=root..'/server-report.json.tmp'
                file=assert(io.open(temporary,'w'))
                assert(file:write(require('json').encode({count=count,remote=remote,read_seconds=seconds})))
                assert(file:close());assert(os.rename(temporary,root..'/server-report.json'))
            end
            return {succ=1,synckey='fixture-ack'},200
        end
    end
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Storage=require('datastorage')
        Settings=require('welite.lib.settings');Reader=require('apps/reader/readerui')
        Plugin=dofile('plugins/welite.koplugin/main.lua')
        Dialog=require('welite.ui.progress_sync_dialog')
    end)
    before_each(function()
        online=true;reading_clock=0
        root=os.tmpname();os.remove(root)
        local lfs=require('libs/libkoreader-lfs');lfs.mkdir(root);lfs.mkdir(root..'/settings')
        old_full,old_dir=Storage.getFullDataDir,Storage.getSettingsDir
        Storage.getFullDataDir=function() return root end;Storage.getSettingsDir=function() return root..'/settings' end
        local settings=Settings:new()
        settings:update_auth({api_key='fixture',cookies={wr_vid='123',wr_skey='fixture-session'},account={user_vid='123',login_method='qr'}})
        local cache=settings:get('cache');cache.show_annotations=false;settings:set('cache',cache)
        settings:set('update',{auto_check=false})
        settings:set('shelf',{view_mode='cover',sort_order='default'})
        local book={book_id='fixture',title='Fixture'}
        local Content=require('welite.lib.content')
        local body='<h1>Fixture chapter</h1>'
        for i=1,200 do
            body=body..'<p>Paragraph '..i..': Synthetic reading position text, with enough lines to measure fractional page precision.</p>'
        end
        local chapter={chapterUid=1,chapterIdx=1,wordCount=1000,title='Fixture chapter'}
        Content.cache_annotation_source(settings,book,chapter,body)
        bookpath=Content.save_book_epub(settings,book,{chapter},{['1']=body})
        book.cached_file=bookpath;book.cached_full_book=bookpath
        book.cached_chapters={['1']=bookpath}
        settings:set('books',{fixture=book});settings:flush()
        remote={progress=70,chapterUid=1,chapterIdx=1,chapterOffset=700};opened=0
        local host={menu={registerToMainMenu=function() end},openFile=function(_,path)
            opened=opened+1
            reader=Reader:new{dimen=require('device').screen:getSize(),document=require('document/documentregistry'):openDocument(path)}
            reader.rolling:onGotoPercent(20)
            target=Plugin:new{ui=reader};reader.welite=target;wire(target)
            assert.is_true(target.settings:is_cookie_configured())
            target:onReaderReady()
        end}
        manager=Plugin:new{ui=host};wire(manager)
        assert.equals(manager,host.welite,"WeLite owns its service handle")
        assert(require('welite.lib.content').save_catalog_cache(manager.client,settings,book,
            {{chapterUid=1,chapterIdx=1,wordCount=1000,title='Fixture chapter'}}))
        old_show=Dialog.show_choice
        Dialog.show_choice=function(context) dialog=old_show(context);return dialog end
        manager.welite_stats_attempt=os.time()
        manager:applyShelfSnapshot({{bookId='fixture',title='Fixture',progress=70}}, {})
        manager:showShelfView('books')
    end)
    after_each(function()
        if dialog then UI:close(dialog);dialog=nil end
        if manager then manager:closeWeReadUI() end
        if reader then
            if target then target:onCloseDocument() end
            reader:onClose();reader=nil;target=nil
        end
        Dialog.show_choice=old_show
        Storage.getFullDataDir,Storage.getSettingsDir=old_full,old_dir
        require('ffi/util').purgeDir(root)
    end)
    local function expected_source_offset()
        local doc=reader.document
        local xp=doc:getPageXPointer(doc:getCurrentPage())
        local ranges=target.progress_sync:_rendered_positions(target.progress_sync.document_context).ranges
        local range=ranges['1']
        local prefix=doc:getTextFromXPointers(range.start_xpointer,xp)
        local full=doc:getTextFromXPointers(range.start_xpointer,range.end_xpointer)
        doc:clearSelection()
        local normalize=require('welite.lib.external_annotations').flatten_text
        local byte=#normalize(prefix)+1
        local flat=normalize(full)
        -- The generated paragraphs have a unique number. Include preceding text
        -- to distinguish page starts that fall in an otherwise repeated phrase.
        local first,last=math.max(1,byte-150),math.min(#flat,byte+150)
        local needle=flat:sub(first,last)
        local raw='<h1>Fixture chapter</h1>'
        for i=1,200 do raw=raw..'<p>Paragraph '..i..': Synthetic reading position text, with enough lines to measure fractional page precision.</p>' end
        local text,indices={},{}
        local in_tag=false
        for i=1,#raw do
            local char=raw:sub(i,i)
            if char=='<' then in_tag=true
            elseif char=='>' then in_tag=false
            elseif not in_tag and not char:match('%s') then text[#text+1]=char;indices[#indices+1]=i-1 end
        end
        local source=table.concat(text)
        local found=assert(source:find(needle,1,true))
        assert.is_nil(source:find(needle,found+1,true))
        return indices[found+byte-first]
    end
    local function sync_and_open()
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        assert.equals(0,opened);assert.is_nil(dialog)
        assert.equals('数据已刷新',manager.welite_shelf_status)
        assert.is_true(manager.settings:get('welite_pending_progress_sync').books.fixture)
        assert.equals(120,manager.welite_overview.monthly.total_seconds)
        manager.shelf_view.cards[1].callback()
        drain(function() return dialog~=nil end)
        assert.equals(1,opened)
        assert.is_true(target.settings:get('welite_pending_progress_sync').books.fixture)
    end
    it('persists offline movement but does not accrue offline reading time',function()
        sync_and_open();dialog.cancel_callback();UI:close(dialog);dialog=nil
        online=false;reading_clock=17
        reader.rolling:onGotoPercent(42);target:onPageUpdate()
        target:onSuspend()
        local restored=Settings:new():get_book('fixture')
        assert.is_table(restored.last_local_position)
        assert.is_table(restored.pending_upload_position)
        assert.equals('suspend',restored.pending_upload_reason)
        assert.equals('123',restored.pending_upload_position.account_id)
        assert.is_table(restored.pending_upload_position.source_snapshot)
        assert.equals(0,reports(),'unverified offline position must not be uploaded')
        local ledger=require('welite.lib.reading_time_ledger').open(target.settings,function() return reading_clock end)
        assert.equals(0,ledger:status('123','fixture').pending)
        reading_clock=1000
        assert.equals(0,ledger:status('123','fixture').pending,'offline sleep contributes no reading time')
    end)
    it('syncs the current account while retaining old account files and restoring them on switch-back',function()
        local books=manager.settings:get('books')
        local old_path=root..'/retained-old.epub'
        local file=assert(io.open(old_path,'wb'));file:write('old account cached bytes');file:close()
        books.old={book_id='old',title='Old account cache',cached_file=old_path,
            readUpdateTime=999999,home_remote_position={account='old-account',position={percent=17}}}
        books.metadata={book_id='metadata',title='Old account metadata',readUpdateTime=999999,
            home_remote_position={account='old-account',position={percent=9}}}
        manager.settings:set('books',books);manager.settings:flush()
        local retained=manager.settings:get('books').old
        manager.client.get_progress=function(_,id)
            assert.equals('fixture',id,'current account queried an old local-only book')
            return {book=remote}
        end
        for _=1,2 do
            manager.shelf_view.collection_sync_button.callback()
            drain(function() return not manager.shelf_refreshing end)
            assert.equals('数据已刷新',manager.welite_shelf_status)
            local reloaded=Settings:new()
            assert.same(retained,reloaded:get('books').old)
            assert.equals('old-account',reloaded:get('books').metadata.home_remote_position.account)
            assert.is_nil(reloaded:get('welite_pending_progress_sync').books.old)
            local cached=assert(io.open(old_path,'rb'));assert.equals('old account cached bytes',cached:read('*a'));cached:close()
        end
        manager.settings:update_auth({account={user_vid='old-account',login_method='qr'},
            cookies={wr_vid='old-account',wr_skey='old-fixture-session'}},{replace_cookies=true})
        manager.client.get_shelf=function() return {books={}} end
        manager.client.get_progress=function(_,id)
            assert.is_true(id=='old' or id=='metadata','switch-back queried the other account')
            return {book=remote}
        end
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        assert.equals('数据已刷新',manager.welite_shelf_status)
        local pending=Settings:new():get('welite_pending_progress_sync')
        assert.equals('old-account',pending.account);assert.is_true(pending.books.old)
        assert.is_nil(pending.books.fixture)
        assert.equals(old_path,Settings:new():get('books').old.cached_file)
        assert.equals(0,opened);assert.equals(0,reports())
    end)
    it('defers unread cloud-only progress until the reader opens',function()
        local books=manager.settings:get('books')
        local record=books.fixture
        local full,file,chapters=record.cached_full_book,record.cached_file,record.cached_chapters
        record.cached_full_book,record.cached_file,record.cached_chapters=nil,nil,nil
        manager.settings:set('books',books);manager.settings:flush()
        manager.client.get_progress=function() error('unread cloud-only book must not be queried on the shelf') end
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        assert.equals('数据已刷新',manager.welite_shelf_status)
        assert.equals(0,opened);assert.is_nil(dialog)
        assert.is_nil(manager.settings:get('welite_pending_progress_sync').books.fixture)
        -- Publish the downloaded file immediately before the user opens it.
        books=manager.settings:get('books');record=books.fixture
        record.cached_full_book,record.cached_file,record.cached_chapters=full,file,chapters
        manager.settings:set('books',books);manager.settings:flush()
        manager:openFile(bookpath)
        drain(function() return dialog~=nil end)
        assert.equals(1,opened)
        assert.equals(0,reports(),'opening still preserves the upstream conflict choice')
    end)
    it('keeps repeated home refreshes deferred and persists the request across settings reloads',function()
        for _=1,2 do
            manager.shelf_view.collection_sync_button.callback()
            drain(function() return not manager.shelf_refreshing end)
            assert.equals(0,opened)
            assert.equals(0,reports())
            assert.is_nil(dialog)
            assert.equals('数据已刷新',manager.welite_shelf_status)
        end
        local reloaded=Settings:new()
        assert.is_true(reloaded:get('welite_pending_progress_sync').books.fixture)
        assert.equals('123',reloaded:get('welite_pending_progress_sync').account)
        manager.shelf_view.cards[1].callback()
        drain(function() return dialog~=nil end)
        assert.equals(1,opened)
        assert.equals(0,reports(),'opening a book must not implicitly select local progress')
    end)
    it('refreshes without opening, then uploads only after selecting local progress',function()
        sync_and_open()
        local selected=assert(target.progress_sync:capture_local())
        local source_offset=expected_source_offset()
        dialog.other_buttons[1][1].callback()
        drain(function() return reports()==1 and not target.settings:get('welite_pending_progress_sync').books.fixture end)
        assert.is_true(math.abs(remote.progress-selected.percent)<0.01)
        assert.equals(source_offset,remote.chapterOffset)
        local stored=target.settings:get('books').fixture
        assert.equals(remote.progress,stored.last_uploaded_position.percent)
        assert.is_nil(stored.pending_upload_position)
        assert.is_nil(stored.last_sync_error)
    end)
    it('persists confirmed cloud offset across real settings reload without reusing verification',function()
        local config=manager.settings:get('sync');config.pull_on_open=false;manager.settings:set('sync',config)
        remote={progress=35.7,chapterUid=1,chapterIdx=1,chapterOffset=357}
        sync_and_open();dialog.ok_callback()
        drain(function() return not target.settings:get('welite_pending_progress_sync').books.fixture end)
        assert.equals(357,target.progress_sync:capture_local().chapter_offset)
        assert.is_table(target.settings:get('books').fixture.last_local_position.confirmed_layout)
        target:onCloseDocument();reader:onClose();reader=nil;target=nil;dialog=nil
        manager:openFile(bookpath)
        -- The fixture openFile callback deliberately moves to 20%; return to
        -- the host's saved cloud page before delayed progress initialization.
        local saved=target.settings:get('books').fixture.last_local_position.confirmed_layout
        reader.rolling:onGotoPage(saved.page)
        drain(function() return target.progress_sync:status().state=='unverified' end)
        assert.equals(357,target.progress_sync:capture_local().chapter_offset)
        assert.is_false(target.progress_sync:status().verified)
        assert.is_nil(dialog);assert.equals(0,reports())
    end)
    it('keeps confirmed source offsets beyond catalog words without rewriting server percent',function()
        remote={progress=42,chapterUid=1,chapterIdx=1,chapterOffset=2400}
        sync_and_open();dialog.ok_callback()
        drain(function() return not target.settings:get('welite_pending_progress_sync').books.fixture end)
        local captured=assert(target.progress_sync:capture_local())
        assert.equals(2400,captured.chapter_offset)
        assert.equals(42,captured.percent)
        local stored=target.settings:get('books').fixture.last_local_position
        assert.equals(2400,stored.chapter_offset)
        assert.equals(42,stored.percent)
        assert.equals(0,reports())
    end)
    it('recovers a missing catalog asynchronously before showing the progress choice',function()
        sync_and_open();dialog.cancel_callback();UI:close(dialog);dialog=nil
        local Content=require('welite.lib.content')
        local books=target.settings:get('books');books.fixture.chapters=nil
        target.settings:set('books',books);target.settings:flush()
        target.library_db:putChapters('fixture',{})
        os.remove(Content.catalog_cache_path(target.settings,books.fixture))
        target.progress_sync.document_context=nil;target.progress_sync.rendered_positions=nil
        local position,reason=target.progress_sync:capture_local()
        assert.is_nil(position);assert.equals('catalog_unavailable',reason)
        target.client.post_json=function(_,url,data)
            assert.is_truthy(url:find('/web/book/chapterInfos',1,true))
            return {data={{bookId='fixture',updated={{chapterUid=1,chapterIdx=1,wordCount=1000,title='Fixture chapter'}}}}}
        end
        local failure
        local notify=target.progress_sync.notify
        target.progress_sync.notify=function(code,data)
            if code=='local_unavailable' then failure=data.error end
            return notify(code,data)
        end
        target:onWeLiteSyncProgress()
        drain(function() return dialog~=nil or failure~=nil end)
        assert.is_nil(failure)
        assert.equals(1,#target.library_db:getChapters('fixture'))
        assert.is_table(Content.load_catalog_cache(target.client,target.settings,books.fixture))
        assert.equals(0,reports())
        dialog.ok_callback()
        drain(function() return not target.settings:get('welite_pending_progress_sync').books.fixture end)
    end)
    it('keeps a canceled choice pending and asks again only after reopening the book',function()
        sync_and_open()
        dialog.cancel_callback();UI:close(dialog);dialog=nil
        assert.equals('choice_cancelled',target.progress_sync:status().verified_reason)
        local deadline=require('socket').gettime()+1.2
        drain(function() return require('socket').gettime()>deadline end)
        assert.is_nil(dialog);assert.equals(0,reports())
        assert.is_true(target.settings:get('welite_pending_progress_sync').books.fixture)
        target:onCloseDocument();reader:onClose();reader=nil;target=nil
        manager:openFile(bookpath)
        drain(function() return dialog~=nil end)
        assert.equals(2,opened);assert.equals(0,reports())
        assert.is_nil(target.progress_sync:status().verified_reason)
        dialog.ok_callback()
        drain(function() return not target.settings:get('welite_pending_progress_sync').books.fixture end)
        assert.equals(0,reports())
    end)
    it('does not reopen a quickly canceled automatic choice from the deferred home request',function()
        local config=manager.settings:get('sync')
        config.pull_on_open=true;manager.settings:set('sync',config);manager.settings:flush()
        local choices=0
        Dialog.show_choice=function(context)
            choices=choices+1
            local shown=old_show(context)
            context.cancel();UI:close(shown)
        end
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        manager.shelf_view.cards[1].callback()
        drain(function() return choices==1 end)
        local deadline=require('socket').gettime()+1.2
        drain(function() return require('socket').gettime()>deadline end)
        assert.equals(1,choices);assert.equals(0,reports())
        assert.equals('choice_cancelled',target.progress_sync:status().verified_reason)
        assert.is_true(target.settings:get('welite_pending_progress_sync').books.fixture)
    end)
    it('retains a deferred request while offline and allows an explicit connected retry',function()
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        online=false
        manager.shelf_view.cards[1].callback()
        drain(function() return target.progress_sync:status().state=='offline' end)
        assert.is_nil(dialog);assert.equals(0,reports())
        assert.is_true(target.settings:get('welite_pending_progress_sync').books.fixture)
        online=true
        target:onWeLiteSyncProgress()
        drain(function() return dialog~=nil end)
        dialog.ok_callback()
        drain(function() return target.progress_sync:status().verified
            and not target.settings:get('welite_pending_progress_sync').books.fixture end)
        assert.is_nil(target.settings:get('welite_pending_progress_sync').books.fixture,
            'successful explicit retry must consume the marker without reopening')
        assert.equals(0,reports())
    end)
    it('revokes the old account choice and requires a new comparison in the open reader',function()
        local config=manager.settings:get('sync');config.pull_on_open=false;manager.settings:set('sync',config)
        sync_and_open()
        local old_dialog=dialog
        target.settings:set('account',{user_vid='another-account'})
        target.settings:flush()
        target:onWeLiteAccountChanged()
        old_dialog.other_buttons[1][1].callback()
        old_dialog.ok_callback()
        assert.equals(0,reports())
        local position,reason,applies=target.progress_sync:position_for_report('fixture')
        assert.is_nil(position);assert.equals('progress_unverified',reason);assert.is_true(applies)
        drain(function() return target.progress_sync:status().state=='unverified' end)
        assert.is_false(target.progress_sync:status().verified)
        dialog=nil
        target:onWeLiteSyncProgress()
        drain(function() return dialog~=nil end)
        assert.is_not.equal(old_dialog,dialog)
        dialog.other_buttons[1][1].callback()
        drain(function() return reports()==1 and not target.progress_sync:status().uploading end)
        assert.is_true(target.progress_sync:status().verified)
    end)
    it('keeps pages read during upload dirty after the earlier snapshot is acknowledged',function()
        sync_and_open()
        local selected=assert(target.progress_sync:capture_local())
        local source_offset=expected_source_offset()
        local report=target.client.report_read
        target.client.report_read=function(client,payload)
            if payload.rt~=nil then require('socket').sleep(0.3) end
            return report(client,payload)
        end
        dialog.other_buttons[1][1].callback()
        drain(function() return target.read_report.job~=nil end)
        reader.rolling:onGotoPercent(40)
        target:onPageUpdate()
        local advanced=assert(target.progress_sync:capture_local())
        assert.is_true(advanced.percent>selected.percent)
        assert.is_true(target.progress_sync:status().uploading)
        assert.is_nil(target.settings:get('books').fixture.last_uploaded_position)
        drain(function() return reports()==1 and not target.progress_sync:status().uploading end)
        assert.is_true(target.progress_sync:status().dirty)
        assert.is_true(math.abs(remote.progress-selected.percent)<0.01)
        local stored=target.settings:get('books').fixture
        assert.equals(advanced.chapter_offset,stored.last_local_position.chapter_offset)
        assert.equals(source_offset,stored.last_uploaded_position.chapter_offset)
        assert.equals(selected.percent,stored.last_uploaded_position.percent)
    end)
    it('retains a timed-out upload for explicit reconciliation without reporting success',function()
        sync_and_open()
        target.client.report_read=function() require('socket').sleep(2);return {succ=1},200 end
        dialog.other_buttons[1][1].callback()
        drain(function() return target.read_report.job~=nil end)
        local reporter=target.read_report
        local job=reporter.job
        reporter.now=function() return job.started_at+181 end
        reporter:_poll_job(job,reporter.generation,nil)
        assert.is_nil(reporter.job)
        assert.is_false(target.progress_sync:status().uploading)
        local stored=target.settings:get('books').fixture
        assert.is_table(stored.pending_upload_position)
        assert.is_nil(stored.last_uploaded_position)
        assert.is_truthy(stored.last_sync_error:find('unknown',1,true))
        assert.is_true(target.settings:get('welite_pending_progress_sync').books.fixture)
        assert.equals(0,reports())
    end)
    it('abandons an in-flight upload when the account changes',function()
        sync_and_open()
        target.client.report_read=function() require('socket').sleep(2);return {succ=1},200 end
        dialog.other_buttons[1][1].callback()
        drain(function() return target.read_report.job~=nil end)
        target.settings:set('account',{user_vid='new-account'})
        target:onWeLiteAccountChanged()
        assert.is_nil(target.read_report.job)
        assert.is_false(target.progress_sync:status().uploading)
        assert.is_nil(target.settings:get('books').fixture.last_uploaded_position)
        assert.equals(0,reports())
    end)
    it('preserves sub-percent position precision in the real reader',function()
        sync_and_open()
        -- Use the host as the oracle: its layout may have hundreds of pages.
        -- Quantizing to whole percentages must not change the destination page.
        for _, percent in ipairs({12.345, 26.789, 57.321, 88.654}) do
            reader.rolling:onGotoPercent(percent)
            local expected=reader.document:getCurrentPage()
            reader.rolling:onGotoPercent(1)
            assert.is_true(target.progress_sync.goto_fraction(percent/100))
            assert.equals(expected,reader.document:getCurrentPage())
        end
    end)
    it('applies cloud progress to the real reader and persists the resulting position',function()
        sync_and_open()
        dialog.ok_callback()
        drain(function() return not target.settings:get('welite_pending_progress_sync').books.fixture end)
        assert.equals(0,reports())
        -- Source offset 700 is in paragraph 7, not at 70% of the EPUB.
        local matches=reader.document:findAllText('Paragraph 7: Synthetic re',true,0,2,false,0)
        reader.document:clearSelection()
        assert.equals(1,#matches)
        assert.equals(reader.document:getPageFromXPointer(matches[1]['end']),reader.document:getCurrentPage())
        assert.equals(700,target.settings:get('books').fixture.last_local_position.chapter_offset)
        assert.is_true(math.abs(target.settings:get('books').fixture.last_local_position.percent-70)<2)
    end)
    it('uploads a closed book from home without opening it or asking about an unchanged cloud',function()
        sync_and_open();dialog.ok_callback()
        drain(function() return not target.progress_sync:status().pulling end)
        local config=target.settings:get('sync');config.upload_on_close=false;target.settings:set('sync',config)
        reader.rolling:onGotoPercent(50);target:onPageUpdate()
        local expected=expected_source_offset()
        local page=reader.document:getCurrentPage()
        reading_clock=45
        target:onCloseDocument();reader:onClose();reader=nil
        assert.equals(0,reports(),'disabled automatic upload must not send')
        assert.equals(45,target.read_report.time_ledger:status('123','fixture').pending)
        assert.is_table(Settings:new():get('books').fixture.pending_upload_position)
        if dialog then UI:close(dialog);dialog=nil end
        manager:showShelfView('books');wire(manager)
        local before=opened
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        assert.equals(1,reports())
        assert.equals(expected,remote.chapterOffset)
        assert.equals(before,opened);assert.is_nil(dialog)
        assert.is_nil(Settings:new():get('books').fixture.pending_upload_position)
        assert.equals('数据已刷新',manager.welite_shelf_status)
        local sent=assert(io.open(root..'/server-report.json','r'))
        assert.equals(0,require('json').decode(sent:read('*a')).read_seconds);sent:close()
        assert.equals(45,manager.read_report.time_ledger:status('123','fixture').pending,'home leaves online pending time to the next reader report')
        manager:openFile(bookpath);reader.rolling:onGotoPage(page)
        drain(function() return target.progress_sync:status().verified==true end)
        assert.is_nil(dialog,'acknowledged source position must not become a false conflict on reopening')
        assert.equals(1,reports())
    end)
    for _,wait_for_upload in ipairs({true,false}) do
    it('finishes the first home sync while close upload is '..(wait_for_upload and 'in flight' or 'being prepared'),function()
        sync_and_open();dialog.ok_callback()
        drain(function() return not target.progress_sync:status().pulling end)
        reader.rolling:onGotoPercent(40);target:onPageUpdate()
        local expected=expected_source_offset()
        -- Hold only the close-time service response so the shelf click overlaps
        -- a real child request deterministically, without contacting WeRead.
        local report=target.client.report_read
        target.client.report_read=function(client,payload,...)
            local socket=require('socket');local deadline=socket.gettime()+5
            while not require('lfs').attributes(root..'/allow-close-upload') do
                assert(socket.gettime()<deadline,'close upload was not released')
                socket.sleep(0.02)
            end
            return report(client,payload,...)
        end
        reading_clock=45
        target:onCloseDocument();reader:onClose();reader=nil
        if dialog then UI:close(dialog);dialog=nil end
        if wait_for_upload then
            drain(function() return target.read_report.job and target.read_report.job.upload~=nil end)
        else
            assert.is_nil(target.read_report.job,'click before the close upload acquires the network slot')
        end
        assert.is_true(target.progress_sync:status().uploading)
        manager:showShelfView('books');wire(manager)
        manager.shelf_view.collection_sync_button.callback()
        assert.is_true(manager.shelf_refreshing)
        local file=assert(io.open(root..'/allow-close-upload','w'));file:close()
        drain(function() return not manager.shelf_refreshing and not target.progress_sync:status().uploading end)
        assert.equals('数据已刷新',manager.welite_shelf_status)
        assert.equals(1,reports(),'one close snapshot must produce only one position write')
        assert.equals(expected,remote.chapterOffset)
        assert.is_nil(Settings:new():get('books').fixture.pending_upload_position)
        local sent=assert(io.open(root..'/server-report.json','r'))
        assert.equals(0,require('json').decode(sent:read('*a')).read_seconds);sent:close()
        assert.equals(45,manager.read_report.time_ledger:status('123','fixture').pending,'home leaves online pending time to the next reader report')
        assert.equals(1,opened);assert.is_nil(dialog)
    end)
    end
    it('does not treat a cancelled opening conflict as permission to overwrite cloud from home',function()
        sync_and_open();dialog.cancel_callback()
        reader.rolling:onGotoPercent(50);target:onPageUpdate()
        target:onCloseDocument();reader:onClose();reader=nil
        if dialog then UI:close(dialog);dialog=nil end
        manager:showShelfView('books');wire(manager)
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        assert.equals(0,reports())
        assert.is_table(Settings:new():get('books').fixture.pending_upload_position)
        assert.equals('同步未完成',manager.welite_shelf_status)
    end)
    it('preserves both changed positions for a later choice instead of overwriting cloud at home',function()
        sync_and_open();dialog.ok_callback()
        drain(function() return not target.progress_sync:status().pulling end)
        local config=target.settings:get('sync');config.upload_on_close=false;target.settings:set('sync',config)
        reader.rolling:onGotoPercent(50);target:onPageUpdate()
        target:onCloseDocument();reader:onClose();reader=nil
        if dialog then UI:close(dialog);dialog=nil end
        remote={progress=90,chapterUid=1,chapterIdx=1,chapterOffset=900}
        manager:showShelfView('books');wire(manager)
        manager.shelf_view.collection_sync_button.callback()
        drain(function() return not manager.shelf_refreshing end)
        assert.equals(0,reports());assert.equals(900,remote.chapterOffset)
        assert.is_table(Settings:new():get('books').fixture.pending_upload_position)
        assert.is_nil(dialog)
        assert.equals('同步未完成',manager.welite_shelf_status)
    end)

    it('uploads the last page after the document closes using a bounded text snapshot',function()
        sync_and_open();dialog.other_buttons[1][1].callback()
        drain(function() return reports()==1 and not target.progress_sync:status().uploading end)
        local config=target.settings:get('sync');config.upload_on_close=true;target.settings:set('sync',config)
        reader.rolling:onGotoPercent(40);target:onPageUpdate()
        local expected=expected_source_offset()
        local document=reader.document
        local old_read=document.getTextFromXPointers
        local closed=false
        document.getTextFromXPointers=function(self,...)
            assert.is_false(closed,'closed reader DOM must never be accessed')
            return old_read(self,...)
        end
        local started=require('socket').gettime()
        target:onCloseDocument()
        local elapsed=require('socket').gettime()-started
        local pending=target.settings:get('books').fixture.pending_upload_position
        assert.is_table(pending.source_snapshot)
        assert.is_true(#pending.source_snapshot.text<=3075)
        reader:onClose();reader=nil;closed=true
        drain(function() return reports()==2 and not target.progress_sync:status().uploading end)
        assert.equals(expected,remote.chapterOffset)
        assert.is_nil(target.settings:get('books').fixture.pending_upload_position)
        assert.is_nil(target.settings:get('books').fixture.last_uploaded_position.source_snapshot)
        print(string.format('source close capture: %.6f seconds',elapsed))
    end)

    it('retains an offline close snapshot and reconciles it only after reopening the book',function()
        sync_and_open();dialog.other_buttons[1][1].callback()
        drain(function() return reports()==1 and not target.progress_sync:status().uploading end)
        local config=target.settings:get('sync');config.upload_on_close=true;target.settings:set('sync',config)
        reader.rolling:onGotoPercent(40);target:onPageUpdate()
        local expected=expected_source_offset()
        local page=reader.document:getCurrentPage()
        online=false
        target:onCloseDocument();reader:onClose();reader=nil
        local pending=Settings:new():get('books').fixture.pending_upload_position
        assert.is_table(pending.source_snapshot);assert.equals('123',pending.account_id)
        assert.equals(1,reports(),'offline close must not report success')
        if dialog then UI:close(dialog);dialog=nil end
        target=nil;online=true
        manager:openFile(bookpath)
        reader.rolling:onGotoPage(page)
        drain(function() return dialog~=nil end)
        assert.equals(1,reports(),'reopening requires reconciliation, not blind replay')
        dialog.other_buttons[1][1].callback()
        drain(function() return reports()==2 and not target.progress_sync:status().uploading end)
        assert.equals(expected,remote.chapterOffset)
        assert.is_nil(target.settings:get('books').fixture.pending_upload_position)
    end)

end)
