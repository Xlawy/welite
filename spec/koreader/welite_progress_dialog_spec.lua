describe('progress conflict dialog uses explicit decisions',function()
    local Dialog,UI,Sync,dialog,sync,uploads,jumps,queue,reader
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
    end)
    teardown(function() reader:onClose() end)
    before_each(function()
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
            get_chapters=function() return {{chapterUid=1,chapterIdx=1,wordCount=1000}} end,
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
    after_each(function() if dialog then UI:close(dialog);dialog=nil end end)
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
end)
