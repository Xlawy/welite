describe('WeLite download dialog refresh',function()
    local UI,Dialog,background,dialog,force,dirty
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Dialog=require('weread.ui.download_dialog')
    end)
    after_each(function()
        if force then UI.forceRePaint=force;force=nil end
        if dirty then UI.setDirty=dirty;dirty=nil end
        if dialog then UI:close(dialog);dialog=nil end
        if background then UI:close(background);background=nil end
    end)
    for _,kind in ipairs({'details','shelf'}) do
        it('coalesces stages and refreshes only the popup over '..kind,function()
            if kind=='details' then
                background=require('weread.ui.book_detail_view').show{
                    title='测试书籍',author_line='作者',metadata={},actions={},bottom_actions={}}
            else
                background=require('weread.ui.welite.shelf_adapter').show({books={},mode='books'},{})
            end
            dialog=Dialog:new{title='下载正文',progress_max=6}
            dialog:show();UI:forceRePaint()
            local forced,regions=0,{}
            force=UI.forceRePaint;dirty=UI.setDirty
            UI.forceRePaint=function() forced=forced+1 end
            UI.setDirty=function(manager,widget,refresh,...)
                if widget==dialog and type(refresh)=='function' then
                    local _,region=refresh();regions[#regions+1]=region
                end
                return dirty(manager,widget,refresh,...)
            end
            dialog:setTitle('下载图片');dialog:reportProgress(0.9)
            local task=dialog.refresh_task
            assert.is_function(task)
            dialog:setTitle('处理章节');dialog:reportProgress(1)
            assert.equals(task,dialog.refresh_task)
            assert.equals(0,forced)
            assert.equals(0,#regions)
            UI:unschedule(task);task();force(UI)
            assert.equals(1,#regions)
            assert.is_true(regions[1].h<require('device').screen:getHeight())
            assert.equals(dialog,UI:getTopmostVisibleWidget())
            assert.equals('处理章节',dialog.title_widget.text)
            assert.equals(1/6,dialog.progress_bar.percentage)
            dialog:setTitle('重试第 2 章');local pending=dialog.refresh_task
            UI:close(dialog)
            for _,scheduled in ipairs(UI._task_queue) do assert.are_not.equal(pending,scheduled.action) end
            pending()
            assert.equals(1,#regions,'closed dialog must not redraw')
            assert.equals(background,UI:getTopmostVisibleWidget())
        end)
    end
end)
