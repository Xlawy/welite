describe('rendered chapter progress',function()
    local Reader,Content,Mapping,Sync,root,reader,book,chapters,path,context,positions,sync
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        Reader=require('apps/reader/readerui');Content=require('welite.lib.content')
        Mapping=require('welite.lib.rendered_position');Sync=require('welite.lib.progress_sync')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        book={book_id='positions',title='Position fixture'};chapters={}
        local bodies={}
        for i=1,6 do
            chapters[i]={chapterUid=i,chapterIdx=i,wordCount=1000,title='Section '..i}
            -- Unequal rendered lengths deliberately defeat whole-book ratios.
            bodies[tostring(i)]='<h1>Section '..i..'</h1>'..string.rep('<p>Only synthetic text. Each chapter has a different number of paragraphs.</p>',i*9)
        end
        path=Content.save_book_epub({cache_dir=root},book,chapters,bodies)
        reader=Reader:new{dimen=require('device').screen:getSize(),document=require('document/documentregistry'):openDocument(path)}
        context={book=book,chapters=chapters,path=path,is_full_book=true,book_id='positions'}
        positions=Mapping.new(reader.document,context,'page')
        local values={books={positions=book}}
        sync=Sync:new{
            settings={get=function(_,k,d) return values[k] or d end,set=function(_,k,v) values[k]=v end,flush=function() end},
            client={},scheduler={scheduleIn=function() end},
            get_document=function() return reader.document end,get_view_mode=function() return reader.view.view_mode end,
            detect_book=function() return 'positions' end,get_book=function() return book end,
            get_chapters=function() return chapters end,get_file_context=function() return nil,context.current_chapter,context.is_full_book end,
            run_online=function() error('network not needed') end,upload_position=function() error('no account writes') end,
            goto_page=function(page) reader.rolling:onGotoPage(page);return true end,
            goto_fraction=function(f) reader.rolling:onGotoPercent(f*100);return true end,
            open_chapter=function() error('full book must stay open') end,
        }
    end)
    after_each(function() reader:onClose();require('ffi/util').purgeDir(root) end)
    local function check_boundaries()
        for i=1,6 do
            local range=positions.ranges[tostring(i)]
            assert.is_table(range)
            local expected=reader.document:getPageFromXPointer(range.start_xpointer)
            local ok,err=sync:_apply_remote({chapter_uid=i,chapter_offset=0,has_chapter_offset=true,percent=0},context)
            assert.is_true(ok,err)
            assert.equals(expected,reader.document:getCurrentPage())
            local captured,reason=sync:capture_local()
            assert.is_table(captured,reason)
            assert.equals(i,captured.chapter_uid)
            assert.equals(0,captured.chapter_offset)
        end
    end
    it('lands at all six real chapter starts and captures the same chapter',check_boundaries)
    it('recomputes rendered bounds after changing font size',function()
        check_boundaries()
        local old_count=reader.document:getPageCount()
        reader.font:onSetFontSize(32)
        assert.is_not.equals(old_count,reader.document:getPageCount())
        check_boundaries()
    end)
    it('keeps chapter-interior targets inside the actual chapter',function()
        for i=1,6 do
            local ok,err=sync:_apply_remote({chapter_uid=i,chapter_offset=500,has_chapter_offset=true,percent=0},context)
            assert.is_true(ok,err)
            local captured,reason=sync:capture_local()
            assert.is_table(captured,reason);assert.equals(i,captured.chapter_uid)
            assert.is_true(captured.chapter_offset>=0 and captured.chapter_offset<=1000)
        end
    end)
    it('preserves a confirmed cloud offset within the landed page until reading advances',function()
        local remote={chapter_uid=3,chapter_offset=357,has_chapter_offset=true}
        assert.is_true(sync:_apply_remote(remote,context))
        local page=reader.document:getCurrentPage()
        local captured=assert(sync:capture_local())
        assert.equals(3,captured.chapter_uid)
        assert.is_true(math.abs(captured.chapter_offset-357)<=1)
        reader.rolling:onGotoPage(page+1);sync:on_page_update()
        reader.rolling:onGotoPage(page)
        captured=assert(sync:capture_local())
        assert.is_true(math.abs(captured.chapter_offset-357)>1)
    end)
    it('restores a confirmed offset after closing and reopening the same real EPUB',function()
        context.account='fixture'
        local remote={chapter_uid=3,chapter_offset=357,has_chapter_offset=true}
        local mapping=Mapping.new(reader.document,context,'page')
        local _,_,page=mapping:target(remote)
        reader.rolling:onGotoPage(page);mapping:accept_target(remote)
        book.last_local_position=assert(mapping:capture())
        assert.is_table(book.last_local_position.confirmed_layout)
        reader:onClose()
        reader=Reader:new{dimen=require('device').screen:getSize(),document=require('document/documentregistry'):openDocument(path)}
        assert.equals(page,reader.document:getCurrentPage())
        mapping=Mapping.new(reader.document,context,'page')
        assert.equals(357,mapping:capture().chapter_offset)
        reader.font:onSetFontSize(32)
        assert.is_nil(mapping:capture().confirmed_layout)
    end)
    it('maps a single downloaded chapter against the full remote catalog',function()
        reader:onClose()
        path=Content.save_chapter_epub({cache_dir=root},book,chapters[3],
            '<h1>Section 3</h1>'..string.rep('<p>Synthetic partial chapter text.</p>',120))
        reader=Reader:new{dimen=require('device').screen:getSize(),document=require('document/documentregistry'):openDocument(path)}
        context={book=book,chapters=chapters,path=path,is_full_book=false,book_id='positions',current_chapter=chapters[3]}
        sync.document_context=nil
        local _,_,captured_context=sync:capture_local()
        assert.is_table(captured_context)
        for _,offset in ipairs({0,250,750}) do
            assert.is_true(sync:_apply_remote({chapter_uid=3,chapter_offset=offset,has_chapter_offset=true},captured_context))
            local captured=assert(sync:capture_local())
            assert.equals(3,captured.chapter_uid)
            assert.is_true(captured.percent>=33 and captured.percent<=50)
        end
    end)
    it('uses the complete final chapter layout in native scroll mode',function()
        reader.view:onSetViewMode('scroll')
        local scroll=Mapping.new(reader.document,context,'scroll')
        scroll:layout()
        assert.is_true(scroll.ranges['6'].ends_document)
        assert.equals(reader.document.info.doc_height,scroll.by_uid['6'].last)
        assert.equals(1,scroll:target({chapter_uid=6,chapter_offset=1000,has_chapter_offset=true}))
        local ok,err=sync:_apply_remote({chapter_uid=6,chapter_offset=900,has_chapter_offset=true},context)
        assert.is_true(ok,err)
        local captured,reason=sync:capture_local()
        assert.is_table(captured,reason);assert.equals(6,captured.chapter_uid)
        assert.is_true(captured.chapter_offset>0)
    end)
    it('rejects unknown chapter anchors instead of using an unrelated page ratio',function()
        local value,reason=positions:target({chapter_uid=99,chapter_offset=0,percent=50})
        assert.is_nil(value);assert.equals('remote_chapter_not_found',reason)
    end)
end)
