describe('WeLite reviews UI and background session',function()
    local View,Controller,UI,Screen,root,values,plugin,session,detail,book,language
    local function drain(predicate)
        local socket=require('socket');local deadline=socket.gettime()+5
        repeat UI:_checkTasks();if predicate() then return end;socket.sleep(0.01) until socket.gettime()>deadline
        assert.is_true(predicate(),'review session timed out')
    end
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        View=require('weread.ui.book_reviews_view');Controller=require('weread.ui.book_reviews_controller')
        UI=require('ui/uimanager');Screen=require('device').screen
    end)
    before_each(function()
        language=G_reader_settings:readSetting("language")
        G_reader_settings:saveSetting("language","zh_CN")
        root=os.tmpname();os.remove(root);require('libs/libkoreader-lfs').mkdir(root)
        values={account={user_vid='fixture'}}
        plugin={requireLogin=function() return true end,settings={data_dir=root,
            get=function(_,k,d) return values[k] or d end,flush=function() end},client={}}
        plugin.client.get_book_reviews=function(_,id,kind,count)
            assert.equals('fixture',id);assert.equals(20,count)
            return {reviews={{reviewId='one',author={name='合成读者'},star=90,isFinish=1,content=kind==3 and '最新合成书评。' or '推荐合成书评。'}},reviewsCnt=1}
        end
        plugin.showBookReviewDetail=function(_,b,review) detail=View.showDetail(b,review);return detail end
        book={book_id='fixture',title='山间来信'}
    end)
    after_each(function()
        if language then G_reader_settings:saveSetting("language",language) else G_reader_settings:delSetting("language") end
        if detail then detail:onClose();detail=nil end
        if session then session:close();session=nil end
        require('ffi/util').purgeDir(root)
    end)
    it('loads, switches, reuses cached tabs and opens a matching detail panel',function()
        session=Controller.show(plugin,book)
        assert.is_not_nil(session.worker)
        assert.is_not_nil(session.view.status)
        drain(function() return session.worker==nil end)
        local view=session.view
        UI:forceRePaint()
        assert.equals(1,#view._review_buttons)
        assert.is_false(view.covers_fullscreen)
        assert.is_true(view.scroll.dimen.h>0)
        view._review_buttons[1].callback()
        assert.is_not_nil(detail);assert.equals(view.heading,detail.heading)
        local function has_finished(widget)
            if type(widget.text)=='string' and widget.text:find('已读完',1,true) then return true end
            for _,child in ipairs(widget) do if type(child)=='table' and has_finished(child) then return true end end
            return false
        end
        assert.is_true(has_finished(detail),'review completion metadata must survive the UI redesign')
        detail:onClose();detail=nil
        view._tab_buttons[2].callback()
        drain(function() return session.worker==nil end)
        assert.equals('latest',session.view.mode)
        assert.equals('最新合成书评。',session.view.result.items[1].content)
        plugin.client.get_book_reviews=function() error('cached switch must not request again') end
        session.view._tab_buttons[1].callback()
        assert.is_nil(session.worker);assert.equals('recommended',session.view.mode)
        local screenshot=os.getenv('WELITE_SCREENSHOT')
        UI:forceRePaint()
        if screenshot then Screen.bb:writePNG(screenshot:gsub('plugin%-smoke','book-reviews')) end
        session.view:onClose();assert.is_true(session.closed)
    end)
    it('preserves emoji and supplies glyphs in both preview and full review text',function()
        local review={author='合成读者',rating=0,create_time=0,content='中文 🌿 English'}
        local function check(view)
            local found=false
            local function visit(widget)
                if type(widget.text)=='string' and widget.text:find('🌿',1,true) then
                    local face=widget.face
                    local covered=face.ftsize:hasGlyph(0x1F33F)
                    for _,fallback in ipairs(face.fallbacks or {}) do
                        if fallback and fallback.ftsize:hasGlyph(0x1F33F) then covered=true end
                    end
                    assert.is_true(covered,'review text must resolve the emoji to a glyph')
                    found=true
                end
                for _,child in ipairs(widget) do if type(child)=='table' then visit(child) end end
            end
            UI:forceRePaint();visit(view)
            assert.is_true(found,'emoji must survive preview and full text')
        end
        detail=View.show({book_title=book.title,result={items={review}}},{})
        check(detail);detail:onClose()
        detail=View.showDetail(book,review);check(detail)
    end)
    it('shows a retry action after failure and treats an empty list as success',function()
        plugin.client.get_book_reviews=function() error('synthetic offline') end
        session=Controller.show(plugin,book);drain(function() return session.worker==nil end)
        assert.is_not_nil(session.view._retry_button)
        plugin.client.get_book_reviews=function() return {reviews={}} end
        session.view._retry_button.callback();drain(function() return session.worker==nil end)
        assert.is_nil(session.view.status);assert.equals(0,#session.view._review_buttons)
    end)
    it('keeps long review cards and fixed controls inside small and Kindle panels',function()
        local BB=require('ffi/blitbuffer')
        local original,size=Screen.bb,Screen.screen_size
        local ok,err=pcall(function()
            for _,dimensions in ipairs({{320,600},{600,400},{1072,1448}}) do
                Screen.bb=BB.new(dimensions[1],dimensions[2],BB.TYPE_BB8)
                Screen.screen_size={w=dimensions[1],h=dimensions[2]}
                local items={}
                for i=1,20 do items[i]={author='合成读者',rating=9,create_time=1700000000,content=string.rep('长书评测试。',100)} end
                detail=View.show({book_title=string.rep('长书名',30),result={items=items}}, {})
                UI:forceRePaint()
                assert.is_true(detail.scroll.dimen.h>0)
                assert.equals(20,#detail._review_buttons)
                for _,button in ipairs(detail._review_buttons) do
                    assert.equals(button.frame:getSize().h,button:getSize().h)
                    assert.is_true(button:getSize().h>=button.label_container[1]:getSize().h)
                end
                assert.equals(math.floor(dimensions[2]*0.82),detail.panel_frame:getSize().h)
                for _,button in ipairs(detail._tab_buttons) do
                    assert.is_true(button.dimen.x>=detail.panel_frame.dimen.x)
                    assert.is_true(button.dimen.x+button.dimen.w<=detail.panel_frame.dimen.x+detail.panel_frame.dimen.w)
                end
                local screenshot=os.getenv('WELITE_SCREENSHOT')
                if screenshot then Screen.bb:writePNG(screenshot:gsub('plugin%-smoke','book-reviews-'..dimensions[1]..'x'..dimensions[2])) end
                detail:onClose();detail=nil;Screen.bb:free();Screen.bb=original
            end
        end)
        if Screen.bb~=original then Screen.bb:free();Screen.bb=original end
        Screen.screen_size=size
        assert.is_true(ok,tostring(err))
    end)
    it('replaces duplicate sessions and closes review details when leaving the library',function()
        session=Controller.show(plugin,book);drain(function() return session.worker==nil end)
        local old=session
        session.view._review_buttons[1].callback()
        local old_detail=detail
        session=Controller.show(plugin,book)
        assert.is_true(old.closed);assert.is_true(old_detail.closed)
        drain(function() return session.worker==nil end)
        session.view._review_buttons[1].callback()
        require('weread.ui.library').closeWeReadUI(plugin)
        assert.is_true(session.closed);assert.is_true(detail.closed)
        assert.is_nil(plugin._book_reviews_session)
    end)
    it('cancels closed pages and rejects responses belonging to another account',function()
        plugin.client.get_book_reviews=function() require('socket').sleep(0.1);return {reviews={}} end
        session=Controller.show(plugin,book)
        session.view:onClose()
        assert.is_true(session.closed);assert.is_nil(session.worker);assert.is_nil(session.view)
        session=Controller.show(plugin,book)
        values.account={user_vid='other'}
        drain(function() return session.closed end)
        assert.is_nil(session.view)
    end)
end)
