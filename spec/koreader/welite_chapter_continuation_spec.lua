-- Exercise the actual ReaderUI switchDocument -> plugin init -> ReaderReady ->
-- after_open_callback ordering, with deterministic service responses only.
describe('WeLite chapter continuation in the native reader', function()
    local UI, Reader, Settings, Storage, Loader, Plugin, Content
    local root, old_full, old_dir, old_plugins, reader, remote, requests, choices, chapters, book
    local function drain(predicate)
        local socket = require('socket')
        local deadline = socket.gettime() + 10
        repeat
            UI:_checkTasks()
            if predicate() then return end
            socket.sleep(0.02)
        until socket.gettime() > deadline
        assert.is_true(predicate(), 'chapter switch did not settle')
    end
    setup(function()
        require('commonrequire'); disable_plugins()
        package.path = 'plugins/welite.koplugin/?.lua;' .. package.path
        UI = require('ui/uimanager'); Reader = require('apps/reader/readerui')
        Storage = require('datastorage'); Loader = require('pluginloader')
        Settings = require('welite.lib.settings'); Content = require('welite.lib.content')
        Plugin = dofile('plugins/welite.koplugin/main.lua')
    end)
    before_each(function()
        root = os.tmpname(); os.remove(root)
        local lfs = require('libs/libkoreader-lfs'); lfs.mkdir(root); lfs.mkdir(root .. '/settings')
        old_full, old_dir, old_plugins = Storage.getFullDataDir, Storage.getSettingsDir, Loader.enabled_plugins
        Storage.getFullDataDir = function() return root end
        Storage.getSettingsDir = function() return root .. '/settings' end
        local settings = Settings:new()
        settings:update_auth({api_key='fixture',account={user_vid='123',login_method='qr'},
            cookies={wr_vid='123',wr_skey='fixture-session'}})
        settings:set('update', {auto_check=false})
        settings:set('read_report', {enabled=false})
        settings:set('sync', {pull_on_open=true,upload_on_close=false,ask_on_conflict=true})
        local cache = settings:get('cache'); cache.show_annotations=false; cache.auto_prefetch_next_chapter=false
        settings:set('cache', cache)
        chapters = {}
        book = {book_id='continuation',title='Continuation',cached_chapters={}}
        for i = 1, 3 do
            local chapter = {chapterUid=i,chapterIdx=i,wordCount=1000,title='Chapter ' .. i}
            chapters[i] = chapter
            local body = '<h1>Chapter ' .. i .. '</h1>'
            for paragraph = 1, 60 do
                body = body .. '<p>Chapter ' .. i .. ', paragraph ' .. paragraph
                    .. ': Deterministic native reader chapter transition fixture.</p>'
            end
            book.cached_chapters[tostring(i)] = Content.save_chapter_epub(settings, book, chapter, body)
            Content.cache_annotation_source(settings, book, chapter, body)
        end
        book.chapters=chapters
        settings:set('books', {continuation=book}); settings:flush()
        assert(Content.save_catalog_cache(require('welite.lib.client'):new(settings), settings, book, chapters))
        remote={progress=0,chapterUid=1,chapterOffset=0};requests=0;choices={}
        -- Register the actual plugin via KOReader's plugin loader. Only network
        -- execution/responses and choice presentation are injected.
        Loader.enabled_plugins = { Plugin:extend{init=function(self)
            Plugin.init(self)
            self.isNetworkConnected=function() return true end
            self.progress_sync.run_online=function(_, callback) callback();return true end
            self.progress_sync.run_pull=function(task,done,valid)
                done(task(valid));return true
            end
            self.client.get_progress=function() requests=requests+1;return {book=remote} end
            self.client.get_web_progress=function() requests=requests+1;return remote end
            self.progress_sync.on_choice=function(context) choices[#choices+1]=context end
        end} }
        reader=Reader:new{dimen=require('device').screen:getSize(),
            document=require('document/documentregistry'):openDocument(book.cached_chapters['1'])}
        UI:show(reader)
        assert.is_table(reader.welite)
        drain(function() return reader.welite.progress_sync.state ~= 'waiting'
            and reader.welite.progress_sync.state ~= 'pulling' end)
        if #choices > 0 then
            choices[#choices].use_remote()
            drain(function() return reader.welite.progress_sync.verified end)
            choices={}
        end
        assert.is_true(reader.welite.progress_sync.verified, 'initial sync state: '
            .. tostring(reader.welite.progress_sync.state) .. ', error: '
            .. tostring(select(2,reader.welite.progress_sync:capture_local())))
    end)
    after_each(function()
        reader=Reader.instance or reader
        if reader and reader.document then reader:onClose() end
        reader=nil
        Loader.enabled_plugins=old_plugins
        Storage.getFullDataDir,Storage.getSettingsDir=old_full,old_dir
        require('ffi/util').purgeDir(root)
    end)
    local function switch(index)
        local old_reader=reader
        old_reader.welite:openChapter(old_reader.welite.settings:get_book('continuation'),chapters[index])
        drain(function() return Reader.instance and Reader.instance ~= old_reader end)
        reader=Reader.instance
        drain(function() return reader.welite.progress_sync.state ~= 'waiting'
            and reader.welite.progress_sync.state ~= 'pulling' end)
        assert.equals(book.cached_chapters[tostring(index)],reader.document.file)
    end
    it('continues through two real chapter EPUBs with fresh pulls and no repeated choice', function()
        local initial_requests=requests
        for index=2,3 do
            reader.rolling:onGotoPage(reader.document:getPageCount())
            reader.welite:onPageUpdate()
            switch(index)
            assert.equals(0,#choices)
            assert.is_true(reader.welite.progress_sync.verified)
            assert.equals('chapter_continuation',reader.welite.progress_sync.verified_reason)
            assert.is_true(reader.welite.progress_sync.dirty)
        end
        assert.equals(4,requests-initial_requests,'two sources per transition, no extra network work')
        reader.welite:onSuspend()
        local pending=Settings:new():get_book('continuation').pending_upload_position
        assert.equals(3,pending.chapter_uid,'latest chapter survives lifecycle persistence')
        assert.equals('123',pending.account_id)
    end)
    it('keeps a real cross-device conflict when cloud advances during the switch', function()
        remote={progress=90,chapterUid=3,chapterOffset=800}
        switch(2)
        assert.equals(1,#choices)
        assert.equals('awaiting_choice',reader.welite.progress_sync.state)
        assert.is_false(reader.welite.progress_sync.verified)
        assert.equals(3,choices[1].remote_position.chapter_uid)
        choices[1].cancel()
        assert.is_false(reader.welite.progress_sync.verified)
    end)
end)
