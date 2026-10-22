-- Network reads in a child; credential persistence and progress decisions stay
-- in the parent. One bounded pull per plugin, canceled with its reader lifetime.
local Auth=require('weread.lib.worker_settings')
local M={}
function M.cancel(plugin)
    local worker=plugin._progress_pull_worker
    plugin._progress_pull_worker=nil
    if worker then worker:cancel(nil,'progress_reader_changed') end
end
function M.start(plugin,task,done,valid)
    if plugin._progress_pull_worker then return false end
    local fingerprint=Auth.fingerprint(plugin.settings)
    local worker=require('weread.lib.background_worker'):new{
        temp_dir=plugin.settings.data_dir..'/workers',timeout=45}
    plugin._progress_pull_worker=worker
    local started=worker:start{task=function(context)
        local capture=Auth.capture(plugin.settings)
        local function check() context.checkCancelled();return true end
        check()
        local remote,err=task(check)
        check()
        return {remote=remote,error=err,auth=capture()}
    end,on_done=function(outcome)
        if plugin._progress_pull_worker~=worker then return end
        plugin._progress_pull_worker=nil
        if not valid() then done(nil,'stale_progress_request');return end
        if Auth.fingerprint(plugin.settings)~=fingerprint then
            done(nil,'progress credentials changed during request');return
        end
        if not outcome.ok then done(nil,outcome.error);return end
        local ok,err=pcall(Auth.merge,plugin.settings,fingerprint,outcome.value.auth)
        if not ok then done(nil,'progress credentials persistence failed: '..tostring(err));return end
        done(outcome.value.remote,outcome.value.error)
    end}
    if not started and plugin._progress_pull_worker==worker then plugin._progress_pull_worker=nil end
    return started
end
function M.catalog(plugin,book_id,done,valid)
    local Content=require('weread.lib.content')
    local book=plugin.settings:get('books',{})[tostring(book_id)]
    if type(book)~='table' then done(nil,'book_not_found');return true end
    return M.start(plugin,function(check)
        local remote={book_id=book_id,title=book.title,format=book.format}
        check();Content.ensure_reader_state(plugin.client,remote)
        check()
        local chapters=Content.fetch_catalog(plugin.client,remote)
        assert(type(chapters)=='table' and #chapters>0,'progress catalog is empty')
        return chapters
    end,function(chapters,err)
        if not chapters then done(nil,err);return end
        local ok,reason=pcall(function()
            local latest=assert(plugin.settings:get('books',{})[tostring(book_id)],'book disappeared')
            local saved,save_error=Content.save_catalog_cache(plugin.client,plugin.settings,latest,chapters)
            assert(saved,save_error)
            if plugin.library_db then
                local stored,db_error=plugin.library_db:putChapters(book_id,chapters)
                assert(stored~=false,db_error or 'chapter database write failed')
            end
        end)
        if not ok then done(nil,'progress catalog persistence failed: '..tostring(reason));return end
        done(chapters)
    end,valid)
end
-- Fetch only the selected chapter when an old cache lacks web coordinates.
-- SQLite writes occur in the parent after the normal account/session checks.
function M.source(plugin,book,chapter,done,valid)
    local id=tostring(book.book_id or book.bookId)
    local uid=tostring(chapter.chapterUid or chapter.chapterId)
    return M.start(plugin,function(check)
        local Store=require('weread.lib.annotation_store')
        local spans=Store:new(plugin.settings):get(id,'original',uid,true)
        local indexed=type(spans)=='table' and #spans>0
        local total,limit=0,require('weread.lib.source_position').MAX_BYTES
        for _,span in ipairs(indexed and spans or {}) do
            total=total+#(span[3] or '')
            if total>limit then return nil,'source_limit' end
            if type(span[5])~='number' or type(span[6])~='number' then indexed=false;break end
        end
        if indexed then return {spans=spans} end
        check()
        local html,plain=require('weread.lib.content').fetch_chapter_xhtml(
            plugin.client,plugin.settings,book,chapter,{no_source_cache=true})
        check()
        if #(plain or html)>limit then return nil,'source_limit' end
        local Source=require('weread.lib.annotation_source')
        spans=plain and Source.plain(plain) or Source.index(html)
        return {spans=spans,fetched=true}
    end,function(value,err)
        if not value then done(nil,err);return end
        if value.fetched then
            local ok,reason=pcall(function()
                local saved,save_error=require('weread.lib.annotation_store'):new(plugin.settings):put(
                    id,'original',uid,value.spans,uid)
                assert(saved~=false,save_error or 'source cache write failed')
            end)
            if not ok then done(nil,'progress source persistence failed: '..tostring(reason));return end
        end
        done(value.spans)
    end,valid)
end
return M
