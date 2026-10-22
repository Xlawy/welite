describe('source coordinates in real EPUB text',function()
    local Source,Position,Locator,reader,root,map,range,offset,plugin,context
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        Source=require('welite.lib.annotation_source')
        Position=require('welite.lib.source_position')
        Locator=require('welite.lib.external_annotations')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        local html='<h1>Chapter one</h1>'
        for i=1,80 do html=html..'<p>Paragraph '..i..': unique &#91;<span>'..i..'</span>&#93; synthetic words &amp; text.</p>' end
        html=html..'<p>Distinctive target ending.</p>'
        local spans=Source.index(html)
        map=assert(Position.new(spans))
        for _,span in ipairs(spans) do
            if span[3]:find('Paragraph 37:',1,true) then offset=span[5] end
        end
        assert.is_number(offset)
        local book={book_id='source-position',title='Synthetic source coordinates'}
        local chapters={{chapterUid=1,chapterIdx=1,title='Chapter one',wordCount=1000},
            {chapterUid=2,chapterIdx=2,title='Chapter two',wordCount=100}}
        local path=require('welite.lib.content').save_book_epub({cache_dir=root},book,chapters,
            {['1']=html,['2']='<h1>Chapter two</h1><p>Boundary chapter.</p>'})
        reader=require('apps/reader/readerui'):new{dimen=require('device').screen:getSize(),
            document=require('document/documentregistry'):openDocument(path)}
        local _,ranges=require('welite.lib.annotation_chapters').map(reader.document,chapters,
            require('welite.lib.annotation_chapters').descriptor(book,path))
        range=ranges['1']
        context={book=book,chapters=chapters,path=path,book_id=book.book_id,is_full_book=true}
        plugin={ui=reader,settings={data_dir=root,get=function(_,_,d) return d end}}
        require('welite.lib.annotation_store'):new(plugin.settings):put(book.book_id,'original','1',spans,'1')
    end)
    after_each(function()
        require('welite.lib.progress_source_locator').cancel(plugin)
        require('welite.lib.progress_pull_worker').cancel(plugin)
        reader:onClose();require('ffi/util').purgeDir(root)
    end)
    local function pump(predicate)
        local UI=require('ui/uimanager');local socket=require('socket');local deadline=socket.gettime()+8
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.002) until socket.gettime()>deadline
        assert.is_true(predicate(),'source lookup timed out')
    end
    it('loads cached source in a worker and yields the DOM mapping to the UI',function()
        local result,err,ticks,finished=nil,nil,0,false
        local UI=require('ui/uimanager')
        local function tick() if not finished then ticks=ticks+1;UI:scheduleIn(0.002,tick) end end
        UI:scheduleIn(0,tick)
        assert.is_true(require('welite.lib.progress_source_locator').start(plugin,context,
            {chapter_uid=1,chapter_offset=offset},function(xp,reason) result,err,finished=xp,reason,true end,
            function() return true end))
        assert.is_false(finished)
        pump(function() return finished end)
        assert.is_string(result,err);assert.is_true(ticks>1)
        assert.is_nil(plugin._progress_source_request)
    end)
    it('locates and captures a long downloaded chapter beyond the former source limits',function()
        reader:onClose()
        local chunks={'<h1>Chapter one</h1>'}
        for i=1,1100 do
            chunks[#chunks+1]=('<p>Paragraph %04d %s unique ending %04d.</p>'):format(i,
                string.rep('甲乙丙丁戊己庚辛壬癸',10),i)
        end
        local html=table.concat(chunks)
        assert.is_true(#html>256*1024)
        local spans=Source.index(html)
        for _,span in ipairs(spans) do
            if span[3]:find('Paragraph 1000 ',1,true) then offset=span[5] end
        end
        assert.is_true(offset>32768)
        local book={book_id='long-source',title='Long chapter'}
        local chapters={{chapterUid=1,chapterIdx=1,title='Chapter one',wordCount=150000},
            {chapterUid=2,chapterIdx=2,title='Chapter two',wordCount=100}}
        local path=require('welite.lib.content').save_book_epub({cache_dir=root},book,chapters,
            {['1']=html,['2']='<h1>Chapter two</h1><p>Boundary chapter.</p>'})
        reader=require('apps/reader/readerui'):new{dimen=require('device').screen:getSize(),
            document=require('document/documentregistry'):openDocument(path)}
        plugin.ui=reader
        context={book=book,chapters=chapters,path=path,book_id=book.book_id,is_full_book=true}
        assert.is_not_false(require('welite.lib.annotation_store'):new(plugin.settings):put(book.book_id,'original','1',spans,'1'))
        local result,err,finished
        local page=reader.document:getCurrentPage()
        assert.is_true(require('welite.lib.progress_source_locator').start(plugin,context,
            {chapter_uid=1,chapter_offset=offset},function(xp,reason) result,err,finished=xp,reason,true end,
            function() return true end))
        pump(function() return finished end)
        assert.is_string(result,err)
        assert.equals(page,reader.document:getCurrentPage(),'preparing progress must not move the reader')
        local _,ranges=require('welite.lib.annotation_chapters').map(reader.document,chapters,
            require('welite.lib.annotation_chapters').descriptor(book,path))
        local long_map=assert(Position.new(spans))
        local captured,why=long_map:capture_document(reader.document,ranges['1'],result)
        assert.equals(offset,captured,why)
    end)
    it('discards a canceled source lookup before applying a result',function()
        local called=false
        local controller=require('welite.lib.progress_source_locator')
        assert.is_true(controller.start(plugin,context,{chapter_uid=1,chapter_offset=offset},
            function() called=true end,function() return true end))
        controller.cancel(plugin)
        local worker=plugin._progress_pull_worker
        require('welite.lib.progress_pull_worker').cancel(plugin)
        pump(function() return worker.job==nil end)
        assert.is_false(called)
    end)
    it('maps source text and split footnote markers through the actual DOM without moving the viewport',function()
        local doc=reader.document
        local page=doc:getCurrentPage()
        local yields=0
        local xp,reason=map:locate_document(doc,range,offset,{yield=function() yields=yields+1 end})
        assert.is_string(xp,reason)
        assert.equals(page,doc:getCurrentPage())
        assert.is_true(yields>0)
        local prefix=doc:getTextFromXPointers(range.start_xpointer,xp);doc:clearSelection()
        assert.is_true(Locator.flatten_text(prefix):find('Paragraph36:',1,true)~=nil)
        assert.is_nil(Locator.flatten_text(prefix):find('Paragraph37:',1,true))
        local target_page=doc:getPageFromXPointer(xp)
        assert.is_true(target_page>page)
        local full=doc:getTextFromXPointers(range.start_xpointer,range.end_xpointer);doc:clearSelection()
        assert.equals(offset,map:text_to_source(Locator.flatten_text(full),#Locator.flatten_text(prefix)+1))
        local snapshot=assert(Position.snapshot_document(doc,range,xp))
        local json=require('json')
        snapshot=json.decode(json.encode(snapshot))
        assert.is_true(#snapshot.text<=3075)
        assert.equals(offset,map:capture_snapshot(snapshot),'serialized snapshot preserves position')
        local captured,why,summary=map:capture_document(doc,range,xp)
        assert.equals(offset,captured,why)
        local outside,outside_reason=map:capture_document(doc,range,range.end_xpointer)
        assert.is_nil(outside);assert.equals('position_outside_chapter',outside_reason)
        assert.equals('Paragraph37:uniquesyntheticwords',summary)

        reader.font:onSetFontSize(30)
        local resized,err=map:locate_document(doc,range,offset)
        assert.is_string(resized,err)
        local before=doc:getTextFromXPointers(range.start_xpointer,resized);doc:clearSelection()
        assert.equals(Locator.flatten_text(prefix),Locator.flatten_text(before),
            'font changes must preserve text location, not an old page ratio')
    end)
    it('cancels a DOM walk before changing the reader position',function()
        local page=reader.document:getCurrentPage()
        local xp,reason=map:locate_document(reader.document,range,offset,{yield=function() return false end})
        assert.is_nil(xp);assert.equals('cancelled',reason)
        assert.equals(page,reader.document:getCurrentPage())
    end)
end)
