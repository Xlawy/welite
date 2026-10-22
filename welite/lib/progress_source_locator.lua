-- Coordinate preparation: source I/O in the existing worker, bounded DOM work
-- in a cooperative reader task. No viewport mutation or protocol implementation.
local M={}
function M.cancel(plugin)
    plugin._progress_source_request=nil
end
local function start(plugin,context,remote,done,valid,capture)
    if plugin._progress_source_request then return false end
    local document=plugin.ui and plugin.ui.document
    local detached=capture and remote.source_snapshot
    if not document and not detached then return false end
    local chapter
    for _,item in ipairs(context.chapters) do
        if tostring(item.chapterUid or item.chapterId)==tostring(remote.chapter_uid) then chapter=item;break end
    end
    if not chapter then done(nil,'remote_chapter_not_found');return true end
    local token={}
    plugin._progress_source_request=token
    local function current()
        return plugin._progress_source_request==token and valid()
            and (detached or (plugin.ui and plugin.ui.document==document))
    end
    local function finish(xp,err,summary)
        if not current() then return end
        plugin._progress_source_request=nil
        done(xp,err,summary)
    end
    local started=require('welite.lib.progress_pull_worker').source(plugin,context.book,chapter,function(spans,err)
        if not current() then return end
        if not spans then finish(nil,err);return end
        local UI=require('ui/uimanager')
        local task=coroutine.create(function()
            local function pause()
                coroutine.yield()
                return current()
            end
            local map,reason=require('welite.lib.source_position').new(spans,{yield=pause})
            if not map then return nil,reason end
            if detached then return map:capture_snapshot(detached) end
            local Chapters=require('welite.lib.annotation_chapters')
            local _,ranges=Chapters.map(document,context.chapters,Chapters.descriptor(context.book,context.path))
            local range=ranges[tostring(remote.chapter_uid)]
            if capture then return map:capture_document(document,range,remote.local_xpointer) end
            return map:locate_document(document,range,remote.chapter_offset,{yield=pause})
        end)
        local function step()
            if not current() then return end
            local ok,xp,reason,summary=coroutine.resume(task)
            if not ok then finish(nil,'source mapping failed: '..tostring(xp))
            elseif coroutine.status(task)=='dead' then finish(xp,reason,summary)
            else UI:scheduleIn(0.001,step) end
        end
        UI:scheduleIn(0,step)
    end,current)
    if not started then plugin._progress_source_request=nil end
    return started
end
function M.start(plugin,context,remote,done,valid)
    return start(plugin,context,remote,done,valid,false)
end
function M.snapshot(plugin,context,position)
    local document=plugin.ui and plugin.ui.document
    if not document or not context then return nil,'document_unavailable' end
    local Chapters=require('welite.lib.annotation_chapters')
    local _,ranges=Chapters.map(document,context.chapters,Chapters.descriptor(context.book,context.path))
    return require('welite.lib.source_position').snapshot_document(document,
        ranges[tostring(position.chapter_uid)],position.local_xpointer)
end
function M.capture(plugin,context,position,done,valid)
    return start(plugin,context,position,done,valid,true)
end
return M
