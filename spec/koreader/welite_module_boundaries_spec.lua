describe('WeLite relocated module boundaries', function()
    local UIManager, widgets, root, db
    setup(function()
        require('commonrequire')
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        UIManager=require('ui/uimanager')
    end)
    before_each(function() widgets={} end)
    after_each(function()
        for _,widget in ipairs(widgets) do UIManager:close(widget) end
        if db then require('welite.lib.thought_db').close(db);db=nil end
        if root then require('ffi/util').purgeDir(root);root=nil end
    end)
    it('round-trips Unicode thoughts and replaces only the requested chapter in real SQLite', function()
        local DB=require('welite.lib.thought_db')
        root=os.tmpname();os.remove(root);db=assert(DB.open(root))
        local reviews={{range='10-20',pageReviews={
            {review={author={nick='读者'},content='保留想法',abstract='原文'},likesCount=3},
            {review={content='第二条'}}}}}
        assert.is_true(DB.putReviews(db,7,reviews));assert.is_true(DB.putReviews(db,8,reviews))
        DB.close(db);db=assert(DB.open(root))
        local items=DB.getReviewItems(db,7,'10-20')
        assert.equals(2,#items);assert.equals('读者',items[1].author)
        assert.equals('保留想法',items[1].content);assert.equals(3,items[1].likes_count)
        assert.is_true(DB.putReviews(db,7,{}))
        assert.same({},DB.getReviewItems(db,7,'10-20'))
        assert.equals(2,#DB.getReviewItems(db,8,'10-20'))
    end)
    it('routes native chapter selection and toolbar actions to their own callbacks', function()
        local selected,refresh,download,closed=nil,0,0,0
        local source={chapterUid=7}
        local view=require('welite.ui.chapter_list_view').show({title='目录',chapters={
            {title='第一章',status='已下载',source=source}}}, {
            on_select=function(item) selected=item end,
            on_refresh=function() refresh=refresh+1 end,
            on_select_download=function() download=download+1 end,
            on_close=function() closed=closed+1 end,
        })
        widgets[#widgets+1]=view
        view._chapter_rows[1].callback();assert.equals(source,selected)
        view._toolbar_buttons[1].callback();view._toolbar_buttons[2].callback()
        assert.equals(1,refresh);assert.equals(1,download)
        view:onClose();widgets={}
        local socket=require('socket');local deadline=socket.gettime()+1
        repeat UIManager:_checkTasks();socket.sleep(0.02) until closed==1 or socket.gettime()>deadline
        assert.equals(1,closed)
    end)
    it('honors statistics period boundaries and ignores a redundant mode switch', function()
        local data=require('welite.lib.read_stats').fetch({get_read_stats=function() return {} end},'overall')
        local prev,next_count,switched=0,0,nil
        local view=require('welite.ui.read_stats_view').show(data,{
            on_prev=function() prev=prev+1 end,on_next=function() next_count=next_count+1 end,
            on_switch=function(mode) switched=mode end,
        })
        widgets[#widgets+1]=view
        view:onPrevPeriod();view:onNextPeriod();view:onSwitchMode('overall')
        assert.equals(0,prev);assert.equals(0,next_count);assert.is_nil(switched)
        data.allow_prev=true;view:onPrevPeriod();view:onSwitchMode('month')
        assert.equals(1,prev);assert.equals('month',switched)
    end)
    it('resolves its own emoji font and builds popup settings despite unavailable page margins', function()
        local factory=require('welite.ui.thought_popup.face_factory')
        local path=factory:findEmojiFont()
        assert.equals(require('ffi/util').realpath('plugins/welite.koplugin/fonts/NotoEmoji-Regular.ttf'),path)
        assert.equals(path,factory:findEmojiFont())
        local pages={{text='想法'}}
        local opts=require('welite.ui.thought_popup.popup_config').build({
            settings={get=function() return {font_size_relative=2,height_ratio='0.6'} end},
            ui={font={font_face='Fixture'},document={configurable={font_size=20},
                getPageMargins=function() error('no layout yet') end}},
        },pages,{width_ratio=0.9})
        assert.equals(pages,opts.pages);assert.equals('Fixture',opts.doc_font_name)
        assert.equals(require('device').screen:scaleBySize(20)+2,opts.doc_font_size)
        assert.equals(0.6,opts.height_ratio);assert.equals(0.9,opts.width_ratio);assert.is_nil(opts.doc_margins)
    end)
end)
