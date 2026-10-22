describe('durable elapsed reading time',function()
    local Ledger,Report,UI,root,clock,settings,values,ledger,report,online,position_ready
    local function pump()
        local socket=require('socket');local deadline=socket.gettime()+5
        repeat UI:_checkTasks();if not report.job then return end;socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_nil(report.job,'time report did not finish')
    end
    local function tick()
        UI:unschedule(report.task)
        report:_tick(report.generation,report.task)
    end
    local function sent()
        local f=assert(io.open(root..'/sent.json','r'));local data=require('json').decode(f:read('*a'));f:close();return data
    end
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        Ledger=require('weread.lib.reading_time_ledger');Report=require('weread.lib.read_report');UI=require('ui/uimanager')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        clock=0;online=true;position_ready=true
        values={account={user_vid='one'},cookies={wr_skey='fixture'},
            read_report={enabled=true,mode='auto',interval_seconds=30},
            books={book={book_id='book',title='Synthetic book',chapters={{chapterUid=1,chapterIdx=1,wordCount=1000}},
                chapter_uid=1,psvts='fixture',pclts='fixture',read_context_updated_at=1000,read_session_entered_at=1}}}
        settings={data_dir=root,get=function(_,k,d) return values[k] or d end,
            set=function(_,k,v) values[k]=v end,flush=function() end,is_cookie_configured=function() return true end}
        ledger=Ledger.open(settings,function() return clock end)
        local json=require('json')
        local client={json_encode=function(_,v) return json.encode(v) end,json_decode=function(_,s) return json.decode(s) end,
            report_read=function(_,payload)
                local f=assert(io.open(root..'/sent.json','w'));f:write(json.encode(payload));f:close()
                return {succ=1},200
            end}
        local document={file=root..'/synthetic.epub'}
        report=Report:new{settings=settings,client=client,scheduler=UI,time_ledger=ledger,
            now=function() return 1000+clock end,get_document=function() return document end,
            detect_book=function() return 'book' end,is_online=function() return online end,
            position_provider=function()
                if not position_ready then return nil,'source_position_preparing',true end
                return {chapter_uid=1,chapter_idx=1,chapter_offset=200,percent=20,summary='synthetic'},nil,true
            end}
        values.books.book.read_session_id=report.session_id
        assert.is_true(report:start('test'))
    end)
    after_each(function() report:stop('test_cleanup');require('ffi/util').purgeDir(root) end)
    it('preserves offline and position-wait time, excludes suspended time and sends actual seconds',function()
        clock=30;online=false;tick()
        assert.equals(30,Ledger.open(settings,function() return clock end):status('one','book').pending)
        clock=60;online=true;position_ready=false;tick()
        assert.equals(60,ledger:status('one','book').pending)
        clock=75;position_ready=true;tick();pump()
        assert.equals(75,sent().rt);assert.equals(75,ledger:status('one','book').acknowledged)
        assert.equals('one',values.books.book.last_reported_position.account)
        assert.equals(sent().co,values.books.book.last_reported_position.position.chapter_offset)
        clock=82;report:on_suspend()
        assert.equals(7,ledger:status('one','book').pending)
        clock=1000;report:on_resume()
        values.books.book.read_context_updated_at=2000
        clock=1010;tick();pump()
        assert.equals(17,sent().rt);assert.equals(92,ledger:status('one','book').acknowledged)
        assert.equals(0,ledger:status('one','book').pending)
    end)
    it('keeps an ambiguous write separate and never resends its time',function()
        local send=report.client.report_read
        report.client.report_read=function(client,payload) send(client,payload);error('synthetic lost response') end
        clock=30;tick();pump()
        assert.equals(30,sent().rt);assert.equals(30,ledger:status('one','book').uncertain)
        report.client.report_read=send
        clock=40;tick();pump()
        assert.equals(10,sent().rt)
        assert.equals(10,ledger:status('one','book').acknowledged)
        assert.equals(30,ledger:status('one','book').uncertain)
    end)
    it('returns an unspawned batch to pending without inventing an unknown server result',function()
        report.subprocess={run=function() return nil,'synthetic fork failure' end}
        clock=19;tick()
        assert.equals(19,ledger:status('one','book').pending)
        assert.equals(0,ledger:status('one','book').uncertain)
        assert.equals(0,ledger:status('one','book').inflight)
    end)
    it('does not credit old-account time to a newly signed-in account',function()
        clock=13;values.account={user_vid='two'};report:on_account_changed()
        clock=24;report:stop('test')
        assert.equals(13,ledger:status('one','book').pending)
        assert.equals(11,ledger:status('two','book').pending)
    end)
    it('retries only time the service explicitly rejected',function()
        local send=report.client.report_read
        report.client.report_read=function() return {errCode=-2012},200 end
        clock=30;tick();pump()
        assert.equals(30,ledger:status('one','book').pending)
        assert.equals(0,ledger:status('one','book').uncertain)
        report.client.report_read=send
        clock=40;tick();pump()
        assert.equals(40,sent().rt)
        assert.equals(40,ledger:status('one','book').acknowledged)
    end)

    it('allows only one live timer per profile',function()
        local another=Ledger.open(settings,function() return clock end)
        local ok,err=another:start('one','book')
        assert.is_false(ok);assert.equals('reading_time_active_elsewhere',err)
        clock=12;report:stop('transfer')
        assert.is_true(another:start('one','book'))
        clock=19;another:stop()
        assert.equals(19,ledger:status('one','book').pending)
    end)

    it('reserves closed-book time durably without opening or starting a reader',function()
        clock=37;report:stop('closed')
        local home=Ledger.open(settings,function() return clock end)
        assert.same({'book'},home:pending_books('one',6))
        local batch=assert(home:begin_pending('one','book',30))
        assert.equals(30,batch.seconds);assert.is_nil(home.active)
        local reloaded=Ledger.open(settings,function() return clock end)
        assert.equals(30,reloaded:status('one','book').inflight)
        assert.is_nil(reloaded:begin_pending('one','book'))
        assert.is_true(reloaded:start('one','book'),'reading clock can start while a home batch is in flight')
        assert.equals(30,reloaded:status('one','book').inflight)
        assert.equals(0,reloaded:status('one','book').uncertain)
        assert.is_true(home:settle(batch,'accepted'))
        assert.is_false(reloaded:settle(batch,'accepted'))
        assert.equals(7,reloaded:status('one','book').pending)
        assert.is_true(reloaded:start('one','book'))
        local _,busy=home:begin_pending('one','book')
        assert.equals('reading_time_active',busy)
        clock=40;reloaded:stop()
        assert.equals(10,home:status('one','book').pending)
    end)

    it('home sync catches up closed-book time before statistics using fresh cloud progress',function()
        clock=37;report:stop('closed')
        report.client.get_shelf=function() return {books={{bookId='book'}}} end
        report.client.get_progress=function() return {book={chapterUid=1,chapterOffset=800,progress=80}} end
        report.client.get_read_stats=function()
            return {totalReadTime=sent().rt+100}
        end
        local view={keyword='',setRefreshing=function() end,setSyncStatus=function() end}
        local plugin={settings=settings,read_report=report,client=report.client,shelf_view=view,
            requireLogin=function() return true end,applyShelfSnapshot=function() end,
            showShelfView=function() error('must not reopen closed shelf') end,
            showInfo=function(_,message) error(message) end}
        assert.is_true(require('weread.ui.welite.sync').refresh(plugin,view,{}))
        view.welite_closed=true
        assert.equals(37,ledger:status('one','book').inflight)
        local socket=require('socket');local deadline=socket.gettime()+10
        repeat UI:_checkTasks();socket.sleep(0.01) until not plugin.shelf_refreshing or socket.gettime()>deadline
        assert.is_nil(plugin.shelf_refreshing)
        assert.equals('数据已刷新',plugin.welite_shelf_status)
        assert.equals(37,sent().rt);assert.equals(800,sent().co)
        assert.equals(137,plugin.welite_overview.monthly.total_seconds)
        assert.equals(37,Ledger.open(settings,function() return clock end):status('one','book').acknowledged)
        assert.equals(0,ledger:status('one','book').pending)
        assert.is_nil(ledger.active)
    end)

    it('returns explicitly rejected catch-up time to pending when the next cloud lookup fails',function()
        clock=27;report:stop('closed')
        report.ensure_context=function() return values.books.book end
        local reads=0
        report.client.get_progress=function()
            reads=reads+1
            if reads==2 then error('synthetic offline cloud lookup') end
            return {book={chapterUid=1,chapterOffset=800,progress=80}}
        end
        report.client.report_read=function() return {errCode=-1},200 end
        local adapter=require('weread.lib.reading_time_sync')
        local task=adapter.prepare(report,'one')
        local receipts=adapter.run(task,{checkCancelled=function() end},function(value) adapter.apply(task,value,false) end)
        adapter.apply(task,receipts,false)
        assert.is_false(adapter.finish(task))
        local stored=Ledger.open(settings,function() return clock end):status('one','book')
        assert.equals(27,stored.pending);assert.equals(0,stored.uncertain)
        assert.equals(0,stored.inflight);assert.equals(0,stored.acknowledged)
    end)

    it('recovers abandoned requests from SQLite at home without reopening their book',function()
        clock=40;report:stop('closed')
        local batch=assert(ledger:begin_pending('one','book',30))
        assert.is_table(batch)
        local adapter=require('weread.lib.reading_time_sync')
        assert.equals(0,ledger:recover('one'),'live request is still owned')
        batch=nil;assert.is_nil(batch);collectgarbage('collect')
        local fresh=Ledger.open(settings,function() return clock end)
        report.time_ledger=fresh
        local task=adapter.prepare(report,'one')
        assert.equals(1,#task.batches);assert.equals(10,task.batches[1].seconds)
        assert.equals(30,fresh:status('one','book').uncertain)
        assert.equals(0,fresh:recover('one'),'live home request must not be recovered')
        assert.is_false(adapter.finish(task,true))
        assert.equals(30,task.uncertain_seconds)
        assert.equals(10,fresh:status('one','book').pending)
        assert.is_nil(fresh.active)
    end)
    it('renders a WeLite time-review list and queues retry only after explicit confirmation',function()
        clock=19;report:stop('closed')
        local batch=assert(ledger:begin_pending('one','book'));ledger:settle(batch,'unknown')
        local plugin={settings=settings,read_report=report,showInfo=function(_,message) error(message) end}
        local language=G_reader_settings:readSetting('language')
        G_reader_settings:saveSetting('language','zh_CN')
        values.books.book.title='合成阅读书籍'
        local shown={};local show=UI.show
        UI.show=function(self,widget,...) shown[#shown+1]=widget;return show(self,widget,...) end
        local ok,err=pcall(function()
            local view=require('weread.ui.reading_time_review').show(plugin)
            assert.equals(1,#view._item_buttons)
            UI:forceRePaint()
            local screenshot=os.getenv('WELITE_SCREENSHOT')
            if screenshot then require('device').screen.bb:writePNG(screenshot:gsub('plugin%-smoke','reading-time-review-zh')) end
            view._item_buttons[1].callback()
            local choice=shown[#shown]
            require('weread.ui.library').closeWeReadUI(plugin)
            assert.is_nil(plugin._time_review_session)
            assert.is_true(view.closed)
            choice.ok_callback()
            assert.equals(19,ledger:status('one','book').uncertain)
            view=require('weread.ui.reading_time_review').show(plugin)
            view._item_buttons[1].callback();choice=shown[#shown]
            UI:close(choice);choice.other_buttons[1][1].callback()
            local confirm=shown[#shown]
            assert.equals(19,ledger:status('one','book').uncertain)
            UI:close(confirm);confirm.ok_callback()
            local fresh=Ledger.open(settings,function() return clock end):status('one','book')
            assert.equals(19,fresh.pending);assert.equals(0,fresh.uncertain)
            assert.equals(0,fresh.acknowledged)
            assert.equals(0,#shown[#shown]._item_buttons)
        end)
        UI.show=show
        if language then G_reader_settings:saveSetting('language',language) else G_reader_settings:delSetting('language') end
        for _,widget in ipairs(shown) do UI:close(widget) end
        assert.is_true(ok,tostring(err))
    end)

    it('keeps counting while home catch-up owns the book and serializes later position writes',function()
        clock=20;report:stop('home')
        local home=Ledger.open(settings,function() return clock end)
        local batch=assert(home:begin_pending('one','book'))
        assert.is_true(report:start('opened_during_home_sync'))
        clock=35;tick()
        assert.is_nil(report.job);assert.equals('waiting',report.state)
        assert.equals(15,ledger:status('one','book').pending)
        local reason
        report:upload_position_async('book',{chapter_uid=1,chapter_idx=1,chapter_offset=200,percent=20},
            function(ok,value) assert.is_false(ok);reason=value.error_kind end,function() return true end)
        assert.equals('busy',reason);assert.is_nil(report.job)
        assert.is_true(home:settle(batch,'accepted'))
        clock=40;tick();pump()
        assert.equals(20,sent().rt,'only time accrued since opening belongs to the reader batch')
        assert.equals(40,ledger:status('one','book').acknowledged)
        clock=45;report:stop('closed')
        local finished=false
        assert.is_true(report:upload_position_async('book',{chapter_uid=1,chapter_idx=1,chapter_offset=300,percent=30},
            function(ok) assert.is_true(ok);finished=true end,function() return true end))
        local pending,why=home:begin_pending('one','book')
        assert.is_nil(pending);assert.equals('time_report_busy',why)
        pump();assert.is_true(finished);assert.equals(0,sent().rt)
        pending=assert(home:begin_pending('one','book'));assert.equals(5,pending.seconds)
        home:settle(pending,'accepted')
        assert.equals(45,ledger:status('one','book').acknowledged)
        assert.equals(0,ledger:status('one','book').uncertain)
    end)
    it('releases a position lock after launch failure',function()
        clock=19;report:stop('closed')
        report.subprocess={run=function() error('synthetic launch failure') end}
        local failed=false
        assert.is_false(report:upload_position_async('book',{},function(ok,result)
            assert.is_false(ok);assert.equals('job',result.error_kind);failed=true
        end,function() return true end))
        assert.is_true(failed)
        local batch=assert(ledger:begin_pending('one','book'))
        assert.equals(19,batch.seconds);ledger:settle(batch,'retryable')
    end)
    it('holds a cancelled position lock until its child has actually exited',function()
        report:stop('closed')
        local done,terminated=false,false
        report.subprocess={run=function() return 123,456 end,is_done=function() return done end,
            terminate=function() terminated=true end,read_size=function() return 0 end,
            read_all=function() return '' end}
        assert.is_true(report:upload_position_async('book',{},function() end,function() return true end))
        report:stop('cancel')
        assert.is_true(terminated);assert.is_nil(ledger:lock_position('one','book'))
        done=true
        local socket=require('socket');local deadline=socket.gettime()+5
        local acquired
        repeat UI:_checkTasks();acquired=ledger:lock_position('one','book');if acquired then break end
            socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_table(acquired);ledger:unlock_position(acquired)
        -- The same exit rule applies to positive-duration reports, not only
        -- rt=0 position writes.
        done=false;terminated=false
        assert.is_true(report:start('timer_after_position'))
        clock=19;tick();assert.is_table(report.job)
        report:stop('cancel_timer')
        assert.is_true(terminated)
        assert.equals(19,ledger:status('one','book').inflight)
        assert.equals(0,ledger:status('one','book').uncertain)
        assert.is_nil(ledger:lock_position('one','book'))
        done=true;deadline=socket.gettime()+5
        repeat UI:_checkTasks();acquired=ledger:lock_position('one','book');if acquired then break end
            socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_table(acquired);ledger:unlock_position(acquired)
        assert.equals(0,ledger:status('one','book').inflight)
        assert.equals(19,ledger:status('one','book').uncertain)
    end)

    it('preserves failed SQLite checkpoints across reader and home ledger handles',function()
        local SQ=require('lua-ljsqlite3/init')
        local writer=SQ.open(root..'/reading-time.sqlite3')
        writer:exec('BEGIN IMMEDIATE')
        clock=10
        local saved=pcall(ledger.stop,ledger)
        writer:exec('ROLLBACK');writer:close()
        assert.is_false(saved,'test must actually exercise a locked SQLite write')
        report:stop('checkpoint_failure')
        local home=Ledger.open(settings,function() return clock end)
        assert.equals(10,home:status('one','book').pending)
        assert.is_true(home:start('one','another'))
        clock=15;home:stop()
        assert.is_true(ledger:start('one','book'))
        clock=20;ledger:stop()
        local db=SQ.open(root..'/reading-time.sqlite3','ro')
        local stored=require('json').decode(db:rowexec('SELECT value FROM ledger WHERE id=1'))
        db:close()
        assert.equals(15,stored.accounts.one.book.pending)
        assert.equals(5,stored.accounts.one.another.pending)
    end)
    it('retries a dirty acknowledgement instead of losing it through a second SQLite handle',function()
        clock=19;report:stop('closed')
        local batch=assert(ledger:begin_pending('one','book'))
        local SQ=require('lua-ljsqlite3/init')
        local writer=SQ.open(root..'/reading-time.sqlite3');writer:exec('BEGIN IMMEDIATE')
        local saved=pcall(ledger.settle,ledger,batch,'accepted')
        local home=Ledger.open(settings,function() return clock end)
        local retried=pcall(home.recover,home,'one')
        writer:exec('ROLLBACK');writer:close()
        assert.is_false(saved);assert.is_false(retried,'recovery cannot silently accept an unwritable ledger')
        assert.equals(0,home:recover('one'),'flush acknowledgement without inventing orphan recovery')
        assert.is_false(home:settle(batch,'accepted'),'receipt cannot add seconds twice')
        assert.is_true(home:start('two','another'))
        clock=22;home:stop()
        local db=SQ.open(root..'/reading-time.sqlite3','ro')
        local stored=require('json').decode(db:rowexec('SELECT value FROM ledger WHERE id=1'));db:close()
        assert.equals(19,stored.accounts.one.book.acknowledged)
        assert.is_nil(stored.accounts.one.book.inflight)
        assert.equals(0,stored.accounts.one.book.uncertain)
        assert.equals(3,stored.accounts.two.another.pending)
    end)

    it('starts and reports a new book after completed bookkeeping fills the SQLite working set',function()
        report:stop('seed_completed_history')
        local state={accounts={one={}},sequence=Ledger.MAX_ENTRIES}
        for i=1,Ledger.MAX_ENTRIES do
            state.accounts.one[string.format('done%03d',i)]={pending=0,uncertain=0,acknowledged=1}
        end
        local SQ=require('lua-ljsqlite3/init')
        local db=SQ.open(root..'/reading-time.sqlite3')
        local stmt=db:prepare('INSERT OR REPLACE INTO ledger(id,value) VALUES(1,?)')
        stmt:bind(require('json').encode(state)):step();stmt:close();db:close()
        assert.is_true(report:start('new_book_after_settled_history'))
        clock=10;tick();pump()
        assert.equals(10,sent().rt)
        db=SQ.open(root..'/reading-time.sqlite3','ro')
        local stored=require('json').decode(db:rowexec('SELECT value FROM ledger WHERE id=1'));db:close()
        local count=0;for _,books in pairs(stored.accounts) do for _ in pairs(books) do count=count+1 end end
        assert.equals(Ledger.MAX_ENTRIES,count)
        assert.is_nil(stored.accounts.one.done001)
        assert.equals(10,stored.accounts.one.book.acknowledged)
        assert.equals(0,stored.accounts.one.book.pending)
    end)

end)
