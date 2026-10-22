describe('progress conflict dialog uses explicit decisions',function()
    local Dialog,UI,Sync,dialog,sync,uploads,jumps,queue,reader,language
    local function contains(text, needle)
        assert.is_truthy(text:find(needle,1,true), 'missing dialog text: '..needle)
    end
    local function preview(context)
        UI:close(dialog)
        context.book_title=context.book_title or 'Fixture'
        context.use_remote=function() end
        context.keep_local=function() end
        dialog=Dialog.show_choice(context)
        return dialog.text
    end
    setup(function()
        require('commonrequire')
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        Dialog=require('welite.ui.progress_sync_dialog')
        Sync=require('welite.lib.progress_sync')
        UI=require('ui/uimanager')
        disable_plugins()
        reader=require('apps/reader/readerui'):new{
            dimen=require('device').screen:getSize(),
            document=require('document/documentregistry'):openDocument('spec/front/unit/data/juliet.epub'),
        }
        UI:show(reader)
    end)
    teardown(function() reader:onClose() end)
    before_each(function()
        language=G_reader_settings:readSetting('language')
        G_reader_settings:saveSetting('language','C')
        reader.rolling:onGotoPercent(20)
        uploads,jumps,queue=0,0,{}
        local values={sync={ask_on_conflict=true},books={book={book_id='book',title='Fixture'}}}
        sync=Sync:new{
            settings={get=function(_,k,d) return values[k] or d end,
                set=function(_,k,v) values[k]=v end,flush=function() end,
                is_api_configured=function() return true end,is_cookie_configured=function() return false end},
            client={get_progress=function() return {book={progress=70,chapterUid=1,chapterOffset=700}} end},
            scheduler={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end},
            get_document=function() return reader.document end,
            get_footer=function() return reader.view.footer end,
            detect_book=function() return 'book' end,get_book=function() return values.books.book end,
            get_chapters=function() return {{chapterUid=1,chapterIdx=1,wordCount=1000,title='Act One'}} end,
            get_file_context=function() return nil,nil,true end,
            run_online=function(_,fn) fn();return true end,
            upload_position=function(_,position) assert.is_true(math.abs(position.percent-20)<2);uploads=uploads+1;return true,{} end,
            goto_fraction=function(fraction) assert.equals(0.7,fraction)
                reader.rolling:onGotoPercent(fraction*100)
                assert.is_true(math.abs(reader.document:getCurrentPage()/reader.document:getPageCount()-fraction)<0.02)
                jumps=jumps+1;return true end,
            open_chapter=function() error('unexpected chapter open') end,
            on_choice=function(context) dialog=Dialog.show_choice(context) end,
        }
        assert.is_true(sync:sync_now())
        UI:forceRePaint()
        assert.equals('awaiting_choice',sync:status().state)
    end)
    after_each(function()
        if dialog then UI:close(dialog);dialog=nil end
        G_reader_settings:saveSetting('language',language)
    end)
    it('Back dismisses without uploading or moving the reader',function()
        dialog:onClose();dialog=nil
        assert.equals(0,uploads);assert.equals(0,jumps)
        assert.equals('unverified',sync:status().state)
        assert.is_false(sync:status().verified)
    end)
    it('outside tap dismisses without a hidden upload',function()
        local Geom=require('ui/geometry')
        dialog:onTapClose(nil,{pos=Geom:new{x=-10,y=-10,w=1,h=1}});dialog=nil
        assert.equals(0,uploads);assert.equals(0,jumps)
        assert.equals('unverified',sync:status().state)
    end)
    it('only the explicit local action uploads local progress',function()
        dialog.other_buttons[1][1].callback()
        assert.equals(1,uploads);assert.equals(0,jumps)
        assert.equals('verified',sync:status().state)
    end)
    it('the cloud action applies the remote position without uploading',function()
        dialog.ok_callback()
        assert.equals(0,uploads);assert.equals(1,jumps)
        assert.equals('verified',sync:status().state)
    end)
    it('shows chapters from the sync catalog without reading or displaying body text',function()
        contains(dialog.text,'KOReader: Act One · about ')
        contains(dialog.text,'% of chapter')
        contains(dialog.text,'WeRead: Act One · chapter progress unavailable')
        assert.is_falsy(dialog.text:find('Excerpt',1,true))
        assert.equals(0,uploads);assert.equals(0,jumps)
    end)
    it('combines the real pull worker, cached source and conflict dialog at equal whole-book percentages',function()
        local Worker=require('welite.lib.progress_pull_worker')
        local root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        sync.settings.data_dir=root
        local plugin={settings=sync.settings,client=sync.client}
        local ok,err=pcall(function()
            require('welite.lib.annotation_store'):new(sync.settings):put('book','original','1',
                require('welite.lib.annotation_source').plain(string.rep('甲',100)),'1')
            local whole_book=sync:capture_local().percent
            sync.client.get_progress=function() return {book={progress=whole_book,chapterUid=1,chapterOffset=50}} end
            sync.run_pull=function(task,done,valid) return Worker.start(plugin,task,done,valid) end
            sync.get_remote_chapter_fraction=function(id,remote) return Worker.cached_chapter_fraction(plugin,id,remote) end
            UI:close(dialog);dialog=nil
            assert.is_true(sync:sync_now())
            local socket=require('socket');local deadline=socket.gettime()+5
            repeat UI:_checkTasks();socket.sleep(0.01) until dialog or socket.gettime()>deadline
            assert.is_not_nil(dialog)
            contains(dialog.text,'WeRead: Act One · about 50% of chapter')
            assert.equals(whole_book,sync.remote_position.percent)
            assert.equals(50,sync.remote_position.chapter_offset)
            assert.equals('awaiting_choice',sync:status().state)
            assert.equals(0,uploads);assert.equals(0,jumps)
        end)
        Worker.cancel(plugin);require('ffi/util').purgeDir(root)
        if not ok then error(err) end
    end)
    it('distinguishes chapters and chapter ratios despite identical whole-book percentages',function()
        local chapters={
            {chapterUid=101,chapterIdx=2,title='Into the forest',wordCount=100},
            {chapterUid=303,chapterIdx=3,title='Across the river',wordCount=100},
        }
        local local_position={percent=25,chapter_uid=101,chapter_idx=99,chapter_fraction=0.35,summary='Private local text'}
        local remote_position={percent=25,chapter_uid='303',chapter_fraction=0.7,summary='Private cloud text',chapter_offset=9999}
        local text=preview{
            position_catalog=require('welite.lib.position_mapper').catalog(chapters),
            local_position=local_position,remote_position=remote_position,
            document=setmetatable({}, {__index=function() error('preview must not read the document') end}),
        }
        contains(text,'KOReader: Into the forest · about 35% of chapter')
        contains(text,'WeRead: Across the river · about 70% of chapter')
        assert.is_falsy(text:find('25%',1,true))
        assert.is_falsy(text:find('Private',1,true))
        assert.equals('Private local text',local_position.summary)
        assert.equals(9999,remote_position.chapter_offset)
    end)
    it('distinguishes positions within one chapter at the same whole-book percentage',function()
        local text=preview{
            local_position={percent=25,chapter_idx=3,chapter_fraction=0.351},
            remote_position={percent=25,chapter_idx=3,chapter_fraction=0.354},
        }
        contains(text,'KOReader: Chapter 3 · about 35.1% of chapter')
        contains(text,'WeRead: Chapter 3 · about 35.4% of chapter')
    end)
    it('does not guess a chapter ratio from source offsets, catalog words or whole-book percentages',function()
        local text=preview{
            position_catalog=require('welite.lib.position_mapper').catalog({{chapterUid=999,wordCount=1000}}),
            local_position={percent=25,chapter_uid=999,chapter_offset=888},
            remote_position={percent=25,chapter_offset=777},
        }
        contains(text,'KOReader: Chapter ID 999 · chapter progress unavailable')
        contains(text,'WeRead: Chapter unavailable · chapter progress unavailable')
        assert.is_falsy(text:find('89%',1,true));assert.is_falsy(text:find('25%',1,true))
    end)
    it('supports chapter boundaries and rejects invalid proportions',function()
        local text=preview{local_position={chapter_idx=1,chapter_fraction=0},
            remote_position={chapter_idx=2,chapter_fraction=1}}
        contains(text,'Chapter 1 · about 0% of chapter')
        contains(text,'Chapter 2 · about 100% of chapter')
        for _,fraction in ipairs({-0.1,1.5,0/0,math.huge,'invalid'}) do
            text=preview{local_position={chapter_fraction=fraction},remote_position={}}
            assert.is_falsy(text:find('about',1,true))
        end
    end)
    it('renders a concise Chinese choice with no excerpts or whole-book percentages',function()
        G_reader_settings:saveSetting('language','zh_CN')
        local text=preview{book_title='测试书籍',
            position_catalog=require('welite.lib.position_mapper').catalog({
                {chapterUid=1,title='第二章 山间的清晨'},{chapterUid=2,title='第三章 渡过河流'},
            }),
            local_position={percent=20,chapter_uid=1,chapter_fraction=0.35,summary='不应显示的正文'},
            remote_position={percent=20,chapter_uid=2,chapter_fraction=0.7,summary='不应显示的正文'},
        }
        contains(text,'KOReader：第二章 山间的清晨 · 章内约 35%')
        contains(text,'微信读书：第三章 渡过河流 · 章内约 70%')
        assert.is_falsy(text:find('正文',1,true))
        if os.getenv('WELITE_PROGRESS_SCREENSHOT') then
            UI:forceRePaint()
            require('device').screen:shot(os.getenv('WELITE_PROGRESS_SCREENSHOT'))
        end
        assert.is_true(dialog.movable:getSize().h<=require('device').screen:getHeight())
    end)
    it('bounds long Unicode chapter titles and identifies the selected cloud source',function()
        G_reader_settings:saveSetting('language','zh_CN')
        local text=preview{book_title=string.rep('书',60),source_conflict=true,
            position_catalog=require('welite.lib.position_mapper').catalog({{chapterUid=1,title=string.rep('甲🌿',500)}}),
            local_position={chapter_uid=1,chapter_fraction=0.35},
            remote_position={chapter_idx=3,chapter_fraction=0.7},
        }
        contains(text,string.rep('甲🌿',20)..'… · 章内约 35%')
        contains(text,'选中的云端位置：第 3 章 · 章内约 70%')
        assert.is_falsy(text:find(string.rep('书',29),1,true))
        assert.is_true(dialog.movable:getSize().h<=require('device').screen:getHeight())
    end)
end)
