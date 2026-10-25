-- Unit tests for welite/lib/progress_sync.lua.
-- Run from the repo root with:
--   lua spec/progress_sync_spec.lua

package.path = "./?.lua;" .. package.path
local ProgressSync = require("welite.lib.progress_sync")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

-- Mirrors PULL_RETRY_DELAY_SECONDS in welite/lib/progress_sync.lua.
local PULL_RETRY_DELAY_SECONDS = 15

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600 },
}

local function fixture(remote, options)
    options = options or {}
    local document = {
        file = "/cache/book/full.epub",
        page = 25,
        getCurrentPage = function(self) return self.page end,
        getPageCount = function() return 100 end,
    }
    local book = {
        book_id = "book",
        title = "Book",
        summary = "Book",
        cached_file = document.file,
        cached_chapters = {
            ["11"] = document.file,
            ["22"] = document.file,
            ["33"] = document.file,
        },
    }
    local values = {
        sync = {
            pull_on_open = true,
            upload_on_close = true,
            ask_on_conflict = true,
        },
        books = { book = book },
    }
    local settings = {
        get = function(_self, key, default)
            return values[key] or default
        end,
        set = function(_self, key, value)
            values[key] = value
        end,
        flush = function() end,
        is_api_configured = function() return true end,
        is_cookie_configured = function() return true end,
    }
    local queue = {}
    local scheduler = {
        scheduleIn = function(_self, delay, callback)
            queue[#queue + 1] = { delay = delay, callback = callback }
        end,
    }
    local choices = {}
    local uploads = {}
    local jumps = {}
    local notifications = {}
    local client = {
        get_progress = function()
            return { book = remote }
        end,
        get_web_progress = function()
            return remote
        end,
    }
    local sync = ProgressSync:new{
        settings = settings,
        client = client,
        scheduler = scheduler,
        get_document = function() return document end,
        detect_book = function() return "book" end,
        get_book = function() return book end,
        get_chapters = options.get_chapters or function() return chapters end,
        refresh_catalog = options.refresh_catalog,
        refresh_catalog_async = options.refresh_catalog_async,
        can_finish_close_upload = options.can_finish_close_upload,
        get_file_context = function()
            return nil, nil, true
        end,
        run_online = options.run_online or function(_kind, callback)
            callback()
            return true
        end,
        upload_position = function(_book_id, position, elapsed)
            uploads[#uploads + 1] = position
            eq(elapsed, 0, "progress upload has zero reading time")
            return true, { accepted = true }
        end,
        goto_fraction = function(fraction)
            jumps[#jumps + 1] = fraction
            document.page = math.floor(fraction * 100 + 0.5)
            return true
        end,
        open_chapter = function() return true end,
        run_pull = options.run_pull,
        get_remote_chapter_fraction = options.get_remote_chapter_fraction,
        on_synced = options.on_synced,
        on_choice = function(context)
            choices[#choices + 1] = context
        end,
        notify = function(code, data)
            notifications[#notifications + 1] = { code = code, data = data }
        end,
        is_online = options.is_online,
        now = options.now,
    }
    local function step()
        local entry = table.remove(queue, 1)
        if not entry then return false end
        entry.callback()
        return true
    end
    local function drain()
        local count = 0
        while #queue > 0 do
            count = count + 1
            assert(count < 20, "scheduler did not quiesce")
            step()
        end
    end
    return {
        sync = sync,
        document = document,
        values = values,
        choices = choices,
        uploads = uploads,
        jumps = jumps,
        notifications = notifications,
        queue = queue,
        step = step,
        drain = drain,
    }
end

test("page turns reuse word counts and document changes rebuild them", function()
    local word_reads = 0
    local function chapter(uid, words)
        return setmetatable({ chapterUid = uid }, { __index = function(_, key)
            if key == "wordCount" then
                word_reads = word_reads + 1
                return words
            end
        end })
    end
    local catalog = {}
    for index = 1, 5000 do catalog[index] = chapter(index, 10) end
    local f = fixture(nil, { get_chapters = function() return catalog end })
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready()
    f.drain()
    eq(word_reads, 5000, "opening builds one word-count catalog")
    for page = 26, 80 do
        f.document.page = page
        f.sync:on_page_update()
    end
    eq(word_reads, 5000, "page turns do not reread chapter word counts")
    eq(f.sync.local_position.chapter_uid, 4001, "page turn chapter")
    eq(f.sync.local_position.chapter_offset, 0, "page turn offset")

    catalog = { chapter(44, 200), chapter(55, 800) }
    f.document.page = 50
    f.sync.detect_book = function() return "other" end
    local position = assert(f.sync:capture_local())
    eq(word_reads, 5002, "changed book rebuilds catalog even at the same path")
    eq(position.book_id, "other", "fresh book detection is preserved")
    eq(position.chapter_uid, 55, "new book chapter")
    eq(position.chapter_offset, 300, "new book offset")

    f.document.file = "/cache/other/chapter.epub"
    f.sync.get_file_context = function() return 1, catalog[1], false end
    position = assert(f.sync:capture_local())
    eq(word_reads, 5004, "changed file rebuilds catalog")
    eq(position.chapter_uid, 44, "single chapter file")
    eq(position.chapter_offset, 100, "single chapter offset")
    eq(position.percent, 10, "single chapter overall progress")
    f.sync:on_close_document()
    eq(f.sync.document_context, nil, "close releases the document catalog")
    f.sync:on_reader_ready()
    f.drain()
    eq(word_reads, 5006, "reopen rebuilds catalog")
end)

test("matching open progress verifies the reporting gate", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "session verified")
    eq(#f.choices, 0, "no conflict dialog")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(applies, true, "provider applies")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
    eq(position.chapter_offset, 150, "live offset")
end)

test("nearby progress within two percent is treated as aligned", function()
    local f = fixture({
        bookId = "book",
        progress = 26.9,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 169,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "nearby position verifies")
    eq(#f.choices, 0, "nearby position does not prompt")
end)

test("unresolved conflict blocks reports and local choice uploads", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "conflict dialog requested")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position, nil, "position withheld")
    eq(reason, "progress_unverified", "gate reason")
    eq(applies, true, "provider applies")
    f.choices[1].keep_local()
    eq(f.sync:status().verified, true, "local choice verifies")
    eq(#f.uploads, 1, "local choice uploads immediately")
    eq(f.uploads[1].chapter_offset, 150, "uploaded immutable position")
end)

test("page change uploads once on close", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 50
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "page change marks dirty")
    f.sync:on_close_document()
    eq(#f.uploads, 1, "close uploads once")
    eq(f.uploads[1].percent, 50, "close uploads current percent")
    eq(f.uploads[1].chapter_uid, 33, "close uploads current chapter")
    eq(f.values.books.book.pending_upload_position, nil,
        "successful upload clears pending snapshot")
end)

test("remote choice jumps and verifies before reporting", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    f.drain()
    eq(#f.jumps, 1, "one jump")
    eq(f.jumps[1], 0.5, "jump fraction")
    eq(f.sync:status().verified, true, "remote choice verifies")
    local position = f.sync:position_for_report("book")
    eq(position.percent, 50, "report sees jumped position")
end)

test("busy read report is retried with the immutable snapshot", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    local attempts = 0
    local uploaded
    f.sync.upload_position = function(_book_id, position)
        attempts = attempts + 1
        if attempts == 1 then
            return false, { error = "busy", error_kind = "busy" }
        end
        uploaded = position
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].keep_local()
    -- Mutating the live page must not change the already captured retry.
    f.document.page = 75
    f.drain()
    eq(attempts, 2, "busy upload retried")
    eq(uploaded.percent, 25, "retry uses immutable position")
    eq(f.values.books.book.pending_upload_position, nil,
        "retry success clears pending snapshot")
end)

test("suspend captures movement even without a page event", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    eq(#f.uploads, 1, "suspend uploads captured movement")
    eq(f.uploads[1].percent, 40, "suspend uses current page")
end)

test("single chapter cloud choice waits for target chapter then jumps", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    local current_chapter = chapters[1]
    local requested_chapter
    f.sync.get_file_context = function()
        return 1, current_chapter, false
    end
    f.sync.open_chapter = function(_book, chapter)
        requested_chapter = chapter
        return true
    end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "chapter conflict requested")
    f.choices[1].use_remote()
    eq(requested_chapter.chapterUid, 22, "target chapter requested")
    eq(f.sync:status().verified, false, "reporting remains gated")
    eq(f.sync:status().state, "switching_chapter", "waiting for open")

    -- Simulate the downloader opening the requested single-chapter EPUB.
    current_chapter = chapters[2]
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "target chapter verifies")
    eq(f.jumps[#f.jumps], 0.5, "target chapter offset applied")
end)

test("cancelling target chapter download clears the pending jump", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync.get_file_context = function()
        return 1, chapters[1], false
    end
    f.sync.open_chapter = function() return true end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    eq(f.sync:cancel_pending_jump("cancelled"), true, "pending cancelled")
    eq(f.sync:status().state, "unverified", "returns to safe state")
    eq(f.sync:status().verified, false, "reporting stays gated")
end)

test("automatic hooks stay disabled when flags are absent", function()
    local f = fixture({
        bookId = "book",
        progress = 75,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 300,
        updateTime = 10,
    })
    f.values.sync = {}
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().state, "unverified", "open does not pull by default")
    eq(#f.choices, 0, "open does not prompt by default")

    f.sync.verified = true
    f.sync.dirty = true
    f.sync:on_close_document()
    eq(#f.uploads, 0, "close does not upload by default")
end)

test("manual sync refreshes a missing catalog inside the online task", function()
    local available_chapters
    local refresh_count = 0
    local online_count = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        get_chapters = function() return available_chapters end,
        refresh_catalog = function(book_id)
            eq(book_id, "book", "refresh receives current book")
            refresh_count = refresh_count + 1
            available_chapters = chapters
            return chapters
        end,
        run_online = function(_kind, callback)
            online_count = online_count + 1
            callback()
            return true
        end,
    })
    eq(f.sync:sync_now(), true, "manual sync starts")
    eq(refresh_count, 1, "catalog refreshed once")
    eq(online_count, 1, "catalog and progress share one online task")
    eq(f.sync:status().verified, true, "refreshed catalog completes sync")
    eq(#f.notifications, 1, "aligned manual sync notifies once")
    eq(f.notifications[1].code, "already_synced", "sync result notified")
end)

test("automatic open never refreshes a missing catalog", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(refresh_count, 0, "automatic path stays offline")
    eq(f.sync:status().state, "unsafe", "missing catalog degrades safely")
end)

test("offline manual catalog refresh reports offline instead of raw reason", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline sync does not start")
    eq(refresh_count, 0, "offline path does not refresh")
    eq(#f.notifications, 1, "offline failure notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("offline automatic pull schedules a delayed retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    -- Wi-Fi is usually still settling when the open delay expires.
    f.step()
    eq(f.sync:status().state, "offline", "automatic pull records offline")
    eq(#f.queue, 1, "offline automatic pull queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry waits for the link")
    eq(#f.notifications, 0, "automatic retry stays silent")
end)

test("automatic pull retries stop at the attempt limit", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "first retry queued")
    f.step()
    eq(#f.queue, 1, "second retry queued")
    f.step()
    eq(#f.queue, 1, "third retry queued")
    f.step()
    eq(#f.queue, 0, "retries stop at the limit")
    eq(f.sync:status().verified, false, "exhausted retries stay gated")
end)

test("offline manual sync never schedules a retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline manual sync does not start")
    eq(#f.queue, 0, "manual path leaves the queue empty")
    eq(#f.notifications, 1, "manual offline notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("retries queued for a closed book never pull again", function()
    local online_checks = 0
    local f = fixture({}, {
        is_online = function()
            online_checks = online_checks + 1
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "retry queued for the open book")
    f.sync:on_close_document()
    f.step()
    eq(online_checks, 1, "stale retry never reaches the offline check")
    eq(#f.queue, 0, "stale retry does not queue another attempt")
end)

test("a queued retry verifies once the link comes back", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().verified, false, "offline open leaves the gate closed")
    online = true
    f.drain()
    eq(f.sync:status().verified, true, "retry verifies the reporting gate")
    eq(#f.choices, 0, "no conflict dialog")
    eq(#f.notifications, 0, "automatic retry stays silent")
    local position, reason = f.sync:position_for_report("book")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
end)

test("automatic pull retries when the online task cannot start", function()
    local run_options
    local f = fixture({}, {
        is_online = function() return true end,
        run_online = function(_kind, _callback, options)
            run_options = options
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().state, "offline", "failed online task records offline")
    eq(#f.queue, 1, "failed automatic online task queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry remains delayed")
    eq(run_options.silent_offline, true, "automatic preflight stays silent")
    eq(#f.notifications, 0, "automatic start failure does not notify")
end)

test("queued automatic retry does not duplicate a manual conflict", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 80,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 500,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    online = true
    f.sync:sync_now()
    eq(#f.choices, 1, "manual sync opens one conflict")
    f.step()
    eq(#f.choices, 1, "stale automatic retry does not reopen conflict")
    eq(#f.queue, 0, "stale retry chain ends")
end)

test("a fresh automatic pull replaces an older retry chain", function()
    local now = 0
    local f = fixture({}, {
        is_online = function() return false end,
        now = function() return now end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "open queues the first retry chain")
    f.sync:on_suspend()
    now = 5 * 60
    f.sync:on_resume()
    eq(#f.queue, 2, "resume queues its replacement chain")
    f.step()
    eq(#f.queue, 1, "stale chain does not schedule another retry")
    f.step()
    eq(#f.queue, 1, "replacement chain remains active")
end)

test("manual sync compares small differences and choices are single use", function()
    for _,remote_choice in ipairs({true, false}) do
        local f = fixture({ progress = 26, chapterUid = 22, chapterOffset = 160 })
        f.sync:sync_now()
        eq(#f.choices, 1, "one percent difference requires explicit resolution")
        local choice = f.choices[1]
        if remote_choice then
            choice.use_remote()
            choice.keep_local()
            eq(#f.jumps, 1, "one cloud jump")
            eq(#f.uploads, 0, "stale local callback cannot overwrite cloud")
        else
            choice.keep_local()
            choice.keep_local()
            eq(#f.uploads, 1, "one local upload")
        end
    end
    local f = fixture({ progress = 80, chapterUid = 33, chapterOffset = 400 })
    f.sync:sync_now()
    local choice = f.choices[1]
    choice.cancel()
    choice.keep_local()
    choice.use_remote()
    eq(#f.uploads, 0, "dismissed choice cannot upload")
    eq(#f.jumps, 0, "dismissed choice cannot jump")
    eq(f.sync:status().state, "unverified", "cancel leaves progress unresolved")
end)

test("delayed applied positions stay with their document and account", function()
    for _, change in ipairs({"close", "document", "path", "book", "account"}) do
        local f = fixture({ progress = 80, chapterUid = 33, chapterOffset = 400 })
        f.sync:sync_now()
        f.choices[1].use_remote()
        local book = f.values.books.book
        if change == "close" then
            f.sync:on_close_document()
        elseif change == "document" then
            -- Reopening even the same path creates a new document lifetime.
            local replacement = {}
            for key, value in pairs(f.document) do replacement[key] = value end
            f.sync.get_document = function() return replacement end
        elseif change == "path" then
            f.document.file = "/cache/book/other.epub"
        elseif change == "book" then
            f.sync.detect_book = function() return "another" end
        else
            f.values.account = { user_vid = "another-account" }
        end
        local before = book.last_local_position
        f.drain()
        eq(book.last_local_position, before, change .. " discards delayed persistence")
        if change == "close" then
            eq(f.sync.local_position, nil, "close does not resurrect reader state")
        end
    end
end)

test("turning a page before applied-position persistence keeps the upload dirty", function()
    local f = fixture({ progress = 80, chapterUid = 33, chapterOffset = 400 })
    f.sync:sync_now()
    f.choices[1].use_remote()
    f.document.page = 85
    f.sync:on_page_update()
    eq(f.sync.dirty, true, "new reading after the jump needs upload")
    f.drain()
    eq(f.sync.dirty, true, "delayed persistence must not erase new reading")
    eq(f.values.books.book.last_local_position.percent, 85, "save actual reader position")
    f.sync:on_close_document()
    eq(#f.uploads, 1, "closing uploads the newly read position")
    eq(f.uploads[1] and f.uploads[1].percent, 85, "new reading reaches remote")
end)

test("conflict choices are invalid after account or document changes", function()
    for _, change in ipairs({
        function(f) f.values.account = {user_vid="another"} end,
        function(f) f.document.file = "/other.epub" end,
    }) do
        local f = fixture({progress=80,chapterUid=33,chapterOffset=400})
        f.sync:on_reader_ready();f.drain();change(f)
        f.choices[1].use_remote()
        eq(#f.jumps,0,"stale choice cannot jump")
        eq(#f.uploads,0,"stale choice cannot upload")
    end
end)

test("queued upload cannot run in a new reader lifetime", function()
    local callback
    local f=fixture({}, {run_online=function(_,fn) callback=fn;return true end})
    f.sync:_upload_snapshot(f.sync:capture_local(),"manual_sync",true)
    f.sync:on_reader_ready()
    callback()
    eq(#f.uploads,0,"old request does not reach network")
    eq(f.sync.uploading,false,"new lifetime is not blocked by old uploading flag")
    eq(f.sync.state,"waiting","old completion leaves new state alone")
end)

test("upload acknowledgement cannot clear reading performed during the request", function()
    local f=fixture({})
    f.sync.current_book_id="book"
    local original=f.sync.upload_position
    f.sync.upload_position=function(...)
        f.document.page=40;f.sync:on_page_update()
        return original(...)
    end
    f.sync:_upload_snapshot(f.sync:capture_local(),"manual_sync",true)
    eq(f.sync.dirty,true,"new page remains dirty after older snapshot acknowledgement")
    eq(f.values.books.book.last_local_position.percent,40,"new local page remains persisted")
    eq(f.values.books.book.last_uploaded_position.percent,25,"acknowledgement records only the sent snapshot")
end)

test("late upload acknowledgement cannot write another account's records", function()
    local f=fixture({})
    f.sync.upload_position=function()
        f.values.account={user_vid="new-account"}
        f.values.books={book={book_id="book",title="New account book"}}
        return true
    end
    f.sync:_upload_snapshot(f.sync:capture_local(),"manual_sync",true)
    eq(f.values.books.book.last_uploaded_position,nil,"new account has no old upload acknowledgement")
    eq(#f.notifications,0,"no success message for another account")
end)

test("queued pull and its retry cannot move across accounts", function()
    local callback
    local f=fixture({}, {run_online=function(_,fn) callback=fn;return true end})
    local requests=0
    f.sync.client.get_progress=function() requests=requests+1;return {} end
    f.sync:on_reader_ready();f.drain()
    f.values.account={user_vid="another"};callback()
    eq(requests,0,"canceled account pull never reaches network")
    eq(#f.choices,0,"canceled account pull opens no choice")
    local offline=fixture({}, {is_online=function() return false end})
    offline.sync:on_reader_ready();offline.step()
    offline.values.account={user_vid="another"}
    offline.sync.is_online=function() return true end
    offline.drain()
    eq(#offline.choices,0,"offline retries cannot cross accounts")
end)

test("a changed account during pull stops the second progress source and writes", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    local web_calls=0
    f.sync.client.get_progress=function()
        f.values.account={user_vid="new"}
        f.values.books={book={title="New account book"}}
        return {book={progress=80,chapterUid=33,chapterOffset=400}}
    end
    f.sync.client.get_web_progress=function() web_calls=web_calls+1;return {} end
    f.sync:on_reader_ready();f.drain()
    eq(web_calls,0,"no second request with the new account")
    eq(f.values.books.book.last_remote_position,nil,"late pull cannot modify new account")
    eq(#f.choices,0,"late pull opens no choice")
end)

test("an explicit close upload may finish after close but cannot revive reader state", function()
    local callback
    local f=fixture({}, {run_online=function(_,fn) callback=fn;return true end})
    f.sync.current_book_id="book";f.sync.verified=true;f.sync.dirty=true
    f.sync:on_close_document()
    callback()
    eq(#f.uploads,1,"the final closed-book snapshot reaches the server")
    eq(f.sync.current_book_id,nil,"closed book is not resurrected")
    eq(f.sync.verified,false,"closed reader is not marked verified")
    eq(f.values.books.book.pending_upload_position,nil,"acknowledged close snapshot is cleared")
end)

test("a pending close upload stops when another reader instance has opened", function()
    local callback, another_reader
    local f=fixture({}, {run_online=function(_,fn) callback=fn;return true end,
        can_finish_close_upload=function() return not another_reader end})
    f.sync.current_book_id="book";f.sync.verified=true;f.sync.dirty=true
    f.sync:on_close_document();another_reader=true;callback()
    eq(#f.uploads,0,"old close snapshot must not overwrite the new reader's progress")
    eq(f.values.books.book.pending_upload_position~=nil,true,"unacknowledged snapshot is retained")
end)

test("completion follows cloud position persistence", function()
    local events={}
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400}, {
        on_synced=function(id,account) events[#events+1]={id=id,account=account} end})
    f.values.account={user_vid="fixture"}
    f.sync:on_reader_ready();f.drain()
    eq(#events,0,"pending choice is not completion")
    f.choices[1].use_remote()
    eq(#events,0,"cloud jump waits for host position update")
    f.drain()
    eq(#events,1,"persisted cloud position completes once")
    eq(events[1].id,"book","completion identifies book")
    eq(events[1].account,"fixture","completion identifies account")
    eq(f.values.books.book.last_local_position.percent,80,"position persisted before completion")
end)

test("local choice needs an acknowledged upload to complete", function()
    for _,accepted in ipairs({false,true}) do
        local events=0
        local f=fixture({progress=80,chapterUid=33,chapterOffset=400}, {
            on_synced=function() events=events+1 end})
        f.sync.upload_position=function()
            eq(events,0,"local selection alone cannot complete")
            return accepted,{error_kind="unknown"}
        end
        f.sync:on_reader_ready();f.drain();f.choices[1].keep_local();f.drain()
        eq(events,accepted and 1 or 0,"only upload acknowledgement completes")
    end
end)

test("completion callback failure does not undo accepted progress", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400}, {
        on_synced=function() error("fixture completion failure") end})
    f.sync:on_reader_ready();f.drain();f.choices[1].keep_local();f.drain()
    eq(f.sync:status().verified,true,"accepted progress stays verified")
    eq(f.values.books.book.last_uploaded_position~=nil,true,"acknowledgement remains persisted")
end)

test("account change revokes verification and old choices before reinitializing", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    f.sync:on_reader_ready();f.drain()
    local old_choice=f.choices[1]
    f.sync.verified=true;f.sync.dirty=true
    f.sync.pending_jump={book_id="book",fraction=0.8}
    f.values.account={user_vid="new-account"}
    f.values.sync.pull_on_open=false
    f.sync:on_account_changed()
    local position,reason,applies=f.sync:position_for_report("book")
    eq(position,nil,"old verification cannot authorize new account report")
    eq(reason,"progress_unverified","new account must verify first")
    eq(applies,true,"current WeRead book remains gated")
    old_choice.keep_local();old_choice.use_remote()
    eq(#f.uploads,0,"old dialog cannot upload after account change")
    eq(#f.jumps,0,"old dialog cannot move new account")
    eq(f.sync.pending_jump,nil,"chapter jump does not cross accounts")
    f.drain()
    eq(f.sync:status().state,"unverified","reinitialized reader awaits new account sync")
    f.sync:on_close_document()
    eq(#f.uploads,0,"close does not upload unverified account position")
end)

test("closing without uploads still saves the latest observed reading position", function()
    local f=fixture({})
    f.values.sync.upload_on_close=false
    f.values.sync.pull_on_open=false
    f.sync:on_reader_ready();f.drain()
    f.document.page=60;f.sync:on_page_update();f.sync:on_close_document()
    eq(f.values.books.book.last_local_position.percent,60,"close persists latest position even while unverified")
    eq(#f.uploads,0,"disabled close upload stays disabled")
    eq(f.values.books.book.pending_upload_position.percent,60,"home sync retains disabled-close upload position")
end)

test("background pull compares against the page reached during the request", function()
    local task,done
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400},{run_pull=function(run,finish)
        task,done=run,finish;return true end})
    f.sync:on_reader_ready();f.drain()
    eq(f.sync:status().pulling,true,"pull remains active while child works")
    f.document.page=60;f.sync:on_page_update()
    done(task(function() return true end))
    eq(f.choices[1].local_position.percent,60,"choice uses latest page")
    eq(f.choices[1].position_catalog.by_uid["33"].source,chapters[3],
        "preview reuses the cached catalog without a new scan")
    eq(f.values.books.book.last_local_position.percent,60,"saved position is not stale")
end)

test("chapter preview is calculated in the pull task and does not change source coordinates", function()
    local task,done,calls= nil,nil,0
    local f=fixture({progress=25,chapterUid=33,chapterOffset=12345},{
        run_pull=function(run,finish) task,done=run,finish;return true end,
        get_remote_chapter_fraction=function(book_id,remote)
            eq(book_id,'book','preview book');eq(remote.chapter_offset,12345,'source offset preserved')
            calls=calls+1;return 0.35
        end,
    })
    f.sync:sync_now()
    eq(calls,0,'UI schedules the task without calculating the preview')
    done(task(function() return true end))
    eq(calls,1,'only selected remote position is enriched')
    eq(f.choices[1].remote_position.chapter_fraction,0.35,'dialog receives chapter ratio')
    eq(f.choices[1].remote_position.percent,25,'whole-book percentage is preserved')
    eq(f.choices[1].remote_position.chapter_offset,12345,'jump/upload coordinates are untouched')
end)

test("unavailable chapter previews never suppress the progress decision", function()
    for _,preview in ipairs({function() return nil,'source_index_outdated' end,
        function() error('synthetic preview failure') end}) do
        local task,done
        local f=fixture({progress=25,chapterUid=33,chapterOffset=99},{
            run_pull=function(run,finish) task,done=run,finish;return true end,
            get_remote_chapter_fraction=preview,
        })
        f.sync:sync_now();done(task(function() return true end))
        eq(f.sync:status().state,'awaiting_choice','preview failure leaves conflict choice usable')
        eq(f.choices[1].remote_position.chapter_fraction,nil,'unknown ratio is explicit')
        eq(type(f.choices[1].remote_position.chapter_fraction_error),'string','preview error remains traceable')
    end
end)

test("suspend cancels a pending pull and resume restarts even a short sleep", function()
    local starts,done,task=0
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400},{run_pull=function(run,finish)
        starts=starts+1;task,done=run,finish;return true end})
    f.sync:on_reader_ready();f.drain()
    local stale_done,stale_task=done,task
    f.sync:on_suspend()
    eq(f.sync:status().pulling,false,"suspend clears pending state")
    stale_done(stale_task(function() return true end))
    eq(#f.choices,0,"late suspended result cannot show a choice")
    f.sync:on_resume();f.drain()
    eq(starts,2,"interrupted pull restarts after short sleep")
    done(task(function() return true end))
    eq(#f.choices,1,"resumed request completes normally")
end)

test("missing catalog waits for background persistence before comparing progress", function()
    local available=false
    local complete
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400},{
        get_chapters=function() return available and chapters or {} end,
        refresh_catalog_async=function(_,done) complete=done;return true end})
    f.sync.current_book_id="book"
    f.sync:sync_now()
    eq(f.sync:status().pulling,true,"catalog request is pending")
    eq(#f.choices,0,"no premature position comparison")
    available=true;complete(chapters)
    eq(#f.choices,1,"successful catalog enables progress comparison")
end)

test("asynchronous upload waits for acknowledgement and preserves newer reading", function()
    local f=fixture({progress=70,chapterUid=33,chapterOffset=200})
    f.sync:on_reader_ready();f.drain()
    local done
    f.sync.upload_position_async=function(_,_,callback) done=callback;return true end
    local snapshot=f.sync:capture_local()
    f.sync:_upload_snapshot(snapshot,"manual",true)
    eq(f.sync.uploading,true,"pending worker remains uploading")
    eq(f.values.books.book.last_uploaded_position,nil,"launch is not acknowledged")
    f.document.page=40
    done(true,{accepted=true})
    eq(f.sync.uploading,false,"ack completes worker")
    eq(f.sync.dirty,true,"newer local position remains dirty")
    eq(f.values.books.book.last_local_position.percent,40,"new position persisted")
    eq(f.values.books.book.last_uploaded_position.percent,25,"only sent snapshot acknowledged")
    done(false,{error="duplicate"})
    eq(f.values.books.book.last_sync_error,nil,"duplicate callback ignored")
end)

test("remote source mapping waits for a valid completion before applying", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    local done,valid
    f.sync.prepare_remote_async=function(_,_,callback,guard) done,valid=callback,guard;return true end
    f.sync.goto_xpointer=function(xp) eq(xp,'exact-xp','mapped pointer');f.document.page=81;return true end
    f.sync:sync_now();f.choices[1].use_remote()
    eq(f.document.page,25,'mapping does not jump early')
    eq(f.sync.pulling,true,'mapping owns busy state')
    eq(valid(),true,'active mapping is valid')
    done('exact-xp')
    eq(f.document.page,81,'mapped pointer applied')
    eq(f.sync.pulling,false,'mapping busy state cleared')
    eq(f.sync.verified,true,'only successful jump verified')
    done(nil,'late duplicate')
    eq(f.sync.verified,true,'duplicate callback ignored')
end)
test("failed or stale source mapping never falls back to a page estimate", function()
    for _,stale in ipairs({false,true}) do
        local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
        local done
        f.sync.prepare_remote_async=function(_,_,callback) done=callback;return true end
        f.sync.goto_xpointer=function() error('must not jump') end
        f.sync:sync_now();f.choices[1].use_remote()
        if stale then f.values.account={user_vid='another'} end
        done(nil,'source_text_ambiguous')
        eq(f.document.page,25,'no approximate jump')
        eq(f.sync.verified,false,'failed mapping is not verified')
        if not stale then eq(f.sync.state,'error','failure is visible') end
    end
end)

test("local selection converts its snapshot before reporting", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    local done
    f.document.getPageXPointer=function(_,page) return 'xp-'..page end
    f.sync.prepare_local_async=function(_,position,callback)
        eq(position.local_xpointer,'xp-25','immutable selected pointer')
        done=callback;return true
    end
    f.sync:sync_now();f.choices[1].keep_local()
    eq(#f.uploads,0,'no approximate report before source resolution')
    eq(f.sync.uploading,true,'mapping is part of upload')
    eq(ProgressSync.has_pending_upload(f.sync.settings,'book'),true,'home sees source preparation before network start')
    eq(ProgressSync.has_pending_upload(f.sync.settings,'other'),false,'other books remain independent')
    eq(ProgressSync.has_pending_upload({get=function() return {} end},'book'),false,'other storage remains independent')
    done(4321,nil,'actual reading text')
    eq(#f.uploads,1,'one report after resolution')
    eq(f.uploads[1].chapter_offset,4321,'source coordinate sent')
    eq(f.uploads[1].summary,'actual reading text','source summary sent')
    eq(f.sync:capture_local().chapter_offset,4321,'same pointer reuses exact source coordinate')
    eq(f.sync.dirty,false,'acknowledged same page is not falsely dirty')
    eq(ProgressSync.has_pending_upload(f.sync.settings,'book'),false,'acknowledgement releases preparation marker')
end)
test("pending upload coordination is shared by profile and isolated by account", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    f.sync.settings.data_dir='/fixture/pending-upload-profile'
    f.values.account={user_vid='one'}
    f.document.getPageXPointer=function(_,page) return 'xp-'..page end
    local callback
    f.sync.prepare_local_async=function(_,_,done) callback=done;return true end
    f.sync:sync_now();f.choices[1].keep_local()
    local account='one'
    local other_handle={data_dir=f.sync.settings.data_dir,get=function() return {user_vid=account} end}
    eq(ProgressSync.has_pending_upload(other_handle,'book'),true,'file-manager handle sees reader preparation')
    account='two'
    eq(ProgressSync.has_pending_upload(other_handle,'book'),false,'another account does not wait for the previous user')
    account='one';f.values.account={user_vid='two'}
    eq(ProgressSync.has_pending_upload(other_handle,'book'),false,'revoked reader session no longer blocks home')
    callback(4321,nil,'old account')
    eq(#f.uploads,0,'revoked preparation never sends')
end)
test("source lookup failures retain the pending snapshot without sending", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    local done
    f.document.getPageXPointer=function(_,page) return 'xp-'..page end
    f.sync.prepare_local_async=function(_,_,callback) done=callback;return true end
    f.sync:sync_now();f.choices[1].keep_local()
    done(nil,'source_text_ambiguous')
    eq(#f.uploads,0,'ambiguous coordinates never sent')
    eq(f.sync.state,'error','lookup failure visible')
    eq(ProgressSync.has_pending_upload(f.sync.settings,'book'),false,'failed mapping releases preparation marker')
    eq(f.values.books.book.pending_upload_position.local_xpointer,'xp-25','retry snapshot retained')
end)
test("timed reporting waits for source resolution and invalidates it after a page turn", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    local done,calls=nil,0
    f.document.getPageXPointer=function(_,page) return 'xp-'..page end
    f.sync.prepare_local_async=function(_,_,callback) calls=calls+1;done=callback;return true end
    f.sync.verified=true
    local position,reason,applies=f.sync:position_for_report('book')
    eq(position,nil,'approximation withheld');eq(reason,'source_position_preparing','preparation status')
    eq(applies,true,'no legacy report fallback')
    f.sync:position_for_report('book');eq(calls,1,'one preparation per position')
    done(4321,nil,'real text')
    position=f.sync:position_for_report('book');eq(position.chapter_offset,4321,'timed report uses source offset')
    f.document.page=45
    position=f.sync:position_for_report('book');eq(position,nil,'new page requires fresh mapping')
    eq(calls,2,'new position prepared once')
end)

test("suspend cancels source preparation without leaving upload permanently busy", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    local callbacks={}
    f.document.getPageXPointer=function(_,page) return 'xp-'..page end
    f.sync.prepare_local_async=function(_,_,callback) callbacks[#callbacks+1]=callback;return true end
    f.sync:sync_now();f.choices[1].keep_local()
    eq(f.sync.uploading,true,'source upload active')
    f.values.sync.upload_on_close=false
    f.sync:on_suspend()
    eq(f.sync.uploading,false,'canceled source upload releases busy flag')
    eq(ProgressSync.has_pending_upload(f.sync.settings,'book'),false,'suspend cancellation releases preparation marker')
    callbacks[1](9999,nil,'stale')
    eq(#f.uploads,0,'canceled source result not sent')
    f.sync:sync_now();f.choices[#f.choices].keep_local()
    callbacks[#callbacks](4321,nil,'fresh')
    eq(#f.uploads,1,'explicit retry can finish')
end)

test("close preparation keeps its context after the reader lifetime ends", function()
    local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
    local done
    f.document.getPageXPointer=function(_,page) return 'xp-'..page end
    f.sync.prepare_local_async=function(context,position,callback)
        eq(context.book_id,'book','captured context retained')
        eq(position.source_snapshot.text,'snapshot','detached snapshot passed')
        done=callback;return true
    end
    f.sync.capture_local_snapshot=function(context,position)
        eq(context.book_id,'book','snapshot captured before context cleared')
        return {version=1,text='snapshot',byte=1,summary='snapshot'}
    end
    f.sync.verified=true;f.sync.dirty=true
    f.sync:on_close_document()
    eq(f.sync.document_context,nil,'reader context released')
    eq(#f.uploads,0,'source preparation still pending')
    eq(ProgressSync.has_pending_upload(f.sync.settings,'book'),true,'close preparation remains visible across reader teardown')
    done(4321,nil,'snapshot')
    eq(#f.uploads,1,'close upload finishes without reader context')
    eq(f.uploads[1].chapter_offset,4321,'resolved source coordinate uploaded')
    eq(f.values.books.book.pending_upload_position,nil,'ack consumes pending snapshot')
    eq(f.values.books.book.last_uploaded_position.source_snapshot,nil,'temporary source text discarded after mapping')
end)

test("pending close uploads reconcile on book open only for the same account", function()
    for _,same in ipairs({true,false}) do
        local f=fixture({progress=80,chapterUid=33,chapterOffset=400})
        f.values.account={user_vid=same and 'one' or 'two'}
        f.values.sync.pull_on_open=false
        f.values.books.book.pending_upload_position={book_id='book',account_id='one',chapter_uid=22,chapter_offset=100,percent=25}
        f.sync:on_reader_ready();f.drain()
        eq(#f.choices,same and 1 or 0,'pending data cannot cross accounts')
        if same then
            eq(type(f.values.books.book.pending_upload_position),'table','comparison does not consume pending data')
            f.choices[1].use_remote();f.drain()
            eq(f.values.books.book.pending_upload_position,nil,'confirmed cloud choice discards old local retry')
        end
    end
end)

test("offline unverified suspend durably checkpoints movement without a network request", function()
    local f=fixture({progress=25,chapterUid=22,chapterOffset=150},{is_online=function() return false end})
    f.values.account={user_vid='one'}
    f.values.sync.pull_on_open=false
    f.sync:on_reader_ready();f.drain()
    f.document.page=48;f.sync:on_page_update()
    local flushes=0
    f.sync.settings.flush=function() flushes=flushes+1 end
    f.sync.capture_local_snapshot=function() return {text='source anchor'} end
    f.sync:on_suspend()
    local saved=f.values.books.book.pending_upload_position
    eq(type(saved),'table','suspend saves unverified progress')
    eq(saved.percent,48,'latest page survives restart')
    eq(saved.account_id,'one','snapshot owns its account')
    eq(saved.source_snapshot.text,'source anchor','closed recovery retains source anchor')
    eq(flushes,1,'one boundary write instead of separate local/pending writes')
    eq(#f.uploads,0,'offline unverified suspension does not upload')
end)

-- A chapter switch creates a new plugin/ProgressSync instance in KOReader.
-- Explicit navigation carries one receipt; fresh cloud reads still gate reports.
local function chapter_fixture(remote, options)
    local f = fixture(remote, options)
    f.values.account = { user_vid = 'reader' }
    f.document.file = '/cache/book/11.epub'
    f.document.page = 100
    f.sync.get_file_context = function(_, path)
        for index, chapter in ipairs(chapters) do
            if path == '/cache/book/' .. chapter.chapterUid .. '.epub' then
                return index, chapter, false
            end
        end
        return nil, nil, true
    end
    return f
end

local function next_reader(f, index, remote, handoff, options)
    f.sync:on_close_document()
    local g = chapter_fixture(remote, options)
    g.values = f.values
    g.sync.settings = f.sync.settings
    g.sync.get_book = f.sync.get_book
    g.document.file = '/cache/book/' .. chapters[index].chapterUid .. '.epub'
    g.document.page = 1
    g.sync:on_reader_ready()
    if handoff then
        eq(g.sync:accept_chapter_handoff(handoff), true, 'new reader accepts explicit handoff')
    end
    return g
end

local function verified_chapter(remote, options)
    local f = chapter_fixture(remote, options)
    f.sync:on_reader_ready(); f.drain()
    eq(f.sync.verified, true, 'starting chapter verified')
    return f
end

test('consecutive chapter files keep reading with fresh unchanged cloud checks', function()
    local remote = { progress = 10, chapterUid = 11, chapterOffset = 100 }
    local f = verified_chapter(remote)
    for index = 2, 3 do
        local handoff = f.sync:chapter_handoff('/cache/book/' .. chapters[index].chapterUid .. '.epub')
        eq(type(handoff), 'table', 'adjacent navigation creates receipt')
        f = next_reader(f, index, remote, handoff)
        local pulls = 0
        f.sync.client.get_progress = function() pulls = pulls + 1; return { book = remote } end
        f.sync.client.get_web_progress = function() pulls = pulls + 1; return remote end
        eq(f.sync.verified, false, 'reading reports wait for fresh cloud check')
        f.drain()
        eq(pulls, 2, 'one normal pull checks both configured sources')
        eq(#f.choices, 0, 'unchanged cloud does not prompt each chapter')
        eq(#f.uploads, 0, 'handoff does not trigger an immediate position write')
        eq(f.sync.verified_reason, 'chapter_continuation', 'continuation verified')
        eq(f.sync.dirty, true, 'new chapter movement remains pending for upload')
        eq(f.sync:capture_local().chapter_uid, chapters[index].chapterUid, 'new chapter retained')
        eq(f.sync:accept_chapter_handoff(handoff), false, 'receipt is single use')
        f.document.page = 100; f.sync:on_page_update()
    end
    f.sync:on_suspend()
    eq(#f.uploads, 1, 'normal lifecycle still uploads continued reading')
    eq(f.uploads[1].chapter_uid, 33, 'latest chapter uploaded')
end)

test('a confirmed source upload at close can advance the continuation baseline', function()
    local remote = { progress = 9, chapterUid = 11, chapterOffset = 90 }
    local f = verified_chapter(remote)
    f.sync.dirty = true
    local original_capture = f.sync.capture_local
    f.sync.capture_local = function(self)
        local position, err, context = original_capture(self)
        position.position_basis = 'source_utf16'
        return position, err, context
    end
    local handoff = f.sync:chapter_handoff('/cache/book/22.epub')
    local g = next_reader(f, 2, { progress = 10, chapterUid = 11, chapterOffset = 100 }, handoff)
    eq(#f.uploads, 1, 'old reader confirmed its final source coordinate')
    g.drain()
    eq(#g.choices, 0, 'acknowledged final coordinate is safe')
    eq(g.sync.verified, true, 'new chapter verified')
end)

for name, changed in pairs({
    another_chapter = { progress = 70, chapterUid = 33, chapterOffset = 300 },
    backward = { progress = 8, chapterUid = 11, chapterOffset = 80 },
    same_percent_different_offset = { progress = 10, chapterUid = 11, chapterOffset = 99 },
    near_new_local_page = { progress = 10, chapterUid = 22, chapterOffset = 2 },
    changed_timestamp = { progress = 10, chapterUid = 11, chapterOffset = 100, updateTime = 9 },
    missing_offset = { progress = 10, chapterUid = 11 },
}) do
    test('chapter continuation protects cloud change: ' .. name, function()
        local f = verified_chapter({ progress = 10, chapterUid = 11, chapterOffset = 100 })
        local handoff = f.sync:chapter_handoff('/cache/book/22.epub')
        local g = next_reader(f, 2, changed, handoff)
        g.drain()
        eq(#g.choices, 1, 'changed or incomplete cloud coordinates require choice')
        eq(g.sync.verified, false, 'conflict blocks reports')
        eq(#g.uploads, 0, 'conflict never silently overwrites cloud')
    end)
end

test('unknown close upload result is not an acknowledgement', function()
    local f = verified_chapter({ progress = 9, chapterUid = 11, chapterOffset = 90 })
    f.sync.dirty = true
    f.sync.upload_position = function() return false, { error = 'unknown write outcome' } end
    local handoff = f.sync:chapter_handoff('/cache/book/22.epub')
    local g = next_reader(f, 2, { progress = 10, chapterUid = 11, chapterOffset = 100 }, handoff)
    g.drain()
    eq(#g.choices, 1, 'unconfirmed write cannot suppress a conflict')
end)

test('conflicting cloud sources still require a chapter choice', function()
    local remote = { progress = 10, chapterUid = 11, chapterOffset = 100 }
    local f = verified_chapter(remote)
    local g = next_reader(f, 2, remote, f.sync:chapter_handoff('/cache/book/22.epub'))
    g.sync.client.get_progress = function() return {book={progress=80,chapterUid=33,chapterOffset=400}} end
    g.drain()
    eq(#g.choices, 1, 'source conflict preserved')
    eq(g.choices[1].source_conflict, true, 'source conflict disclosed')
end)

test('handoff is limited to verified adjacent chapter navigation', function()
    local remote = { progress = 10, chapterUid = 11, chapterOffset = 100 }
    local f = chapter_fixture(remote)
    eq(f.sync:chapter_handoff('/cache/book/22.epub'), nil, 'unverified reader cannot grant continuation')
    f.sync:on_reader_ready(); f.drain()
    eq(f.sync:chapter_handoff('/cache/book/33.epub'), nil, 'skipping chapter uses normal reconciliation')
    eq(f.sync:chapter_handoff('/cache/book/11.epub'), nil, 'reopen is not continuation')
    eq(f.sync:chapter_handoff('/other/22.epub'), nil, 'unrecognized target rejected')
    local g = next_reader(f, 2, remote)
    g.drain()
    eq(#g.choices, 1, 'ordinary reopen without navigation receipt keeps conflict protection')
end)

for _, mismatch in ipairs({'account', 'profile', 'path', 'book', 'expired', 'clock_backwards'}) do
    test('handoff rejects mismatched lifetime: ' .. mismatch, function()
        local now = 100
        local remote = { progress = 10, chapterUid = 11, chapterOffset = 100 }
        local f = verified_chapter(remote, { now = function() return now end })
        local handoff = f.sync:chapter_handoff('/cache/book/22.epub')
        local g = next_reader(f, 2, remote, nil, { now = function() return now end })
        if mismatch == 'account' then g.values.account.user_vid = 'other'
        elseif mismatch == 'profile' then g.sync.settings.data_dir = '/other-profile'
        elseif mismatch == 'path' then g.document.file = '/cache/book/33.epub'
        elseif mismatch == 'book' then g.sync.detect_book = function() return 'other' end
        elseif mismatch == 'expired' then now = 161
        elseif mismatch == 'clock_backwards' then now = 99 end
        eq(g.sync:accept_chapter_handoff(handoff), false, 'wrong lifetime cannot inherit verification')
        eq(g.sync.verified, false, 'still unverified')
    end)
end

test('manual synchronization and suspend revoke a waiting continuation', function()
    for _, action in ipairs({'manual', 'suspend', 'account', 'slow_pull'}) do
        local now = 100
        local remote = { progress = 10, chapterUid = 11, chapterOffset = 100 }
        local f = verified_chapter(remote, { now = function() return now end })
        local g = next_reader(f, 2, remote, f.sync:chapter_handoff('/cache/book/22.epub'),
            { now = function() return now end })
        if action == 'manual' then g.sync:sync_now()
        elseif action == 'suspend' then g.sync:on_suspend()
        elseif action == 'account' then g.sync:on_account_changed()
        else now = 161 end
        g.drain()
        eq(#g.choices, 1, action .. ' does not reuse continuation')
    end
end)

test('offline continuation never grants verification before the cloud returns', function()
    local remote = { progress = 10, chapterUid = 11, chapterOffset = 100 }
    local f = verified_chapter(remote)
    local g = next_reader(f, 2, remote, f.sync:chapter_handoff('/cache/book/22.epub'),
        { is_online = function() return false end })
    g.drain()
    eq(g.sync.verified, false, 'offline reader remains unverified')
    eq(#g.choices, 0, 'no fabricated offline conflict')
    eq(#g.uploads, 0, 'no unverified upload')
    eq(g.sync:position_for_report('book'), nil, 'reading report cannot bypass progress verification')
end)

for _, changed in ipairs({'small_offset', 'missing_source'}) do
    test('continuation checks both sources even when selected web progress is unchanged: ' .. changed, function()
        local remote={progress=10,chapterUid=11,chapterOffset=100}
        local f=verified_chapter(remote)
        local g=next_reader(f,2,remote,f.sync:chapter_handoff('/cache/book/22.epub'))
        g.sync.client.get_progress=function()
            if changed=='missing_source' then error('gateway timeout') end
            return {book={progress=10,chapterUid=11,chapterOffset=99}}
        end
        g.drain()
        eq(#g.choices,1,'partial or subtly changed source cannot inherit verification')
        eq(g.sync.verified,false,'cloud comparison remains protected')
    end)
end

for _, timing in ipairs({'during_reading', 'drained_on_close', 'old_session', 'other_account'}) do
    test('continuation recognizes only current-session acknowledged time report: ' .. timing, function()
        local remote={progress=9,chapterUid=11,chapterOffset=90}
        local reported={account='reader',position={percent=10,chapter_uid=11,chapter_offset=100}}
        local f=chapter_fixture(remote)
        if timing=='old_session' then f.values.books.book.last_reported_position=reported end
        f.sync:on_reader_ready();f.drain()
        if timing=='during_reading' then f.values.books.book.last_reported_position=reported end
        local handoff=f.sync:chapter_handoff('/cache/book/22.epub')
        if timing=='drained_on_close' or timing=='other_account' then
            if timing=='other_account' then reported.account='another' end
            f.values.books.book.last_reported_position=reported
        end
        local g=next_reader(f,2,{progress=10,chapterUid=11,chapterOffset=100},handoff)
        g.drain()
        local safe=timing=='during_reading' or timing=='drained_on_close'
        eq(#g.choices,safe and 0 or 1,'only newly acknowledged own reports can suppress the choice')
        eq(g.sync.verified,safe,'verification follows the receipt')
    end)
end

test('full-book EPUB page updates remain local across chapter boundaries', function()
    local f=fixture({progress=25,chapterUid=22,chapterOffset=150})
    f.sync:on_reader_ready();f.drain()
    f.document.page=41;f.sync:on_page_update();f.drain()
    eq(#f.choices,0,'ordinary page update has no new conflict')
    eq(#f.uploads,0,'ordinary page update does not upload')
    eq(f.sync:chapter_handoff('/cache/book/22.epub'),nil,'full book cannot create chapter receipt')
end)

print(string.format(
    "progress_sync_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
