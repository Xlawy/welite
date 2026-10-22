-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        make_enter_read_payload = function(options)
            return {
                kind = "enter",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
            }
        end,
        make_read_payload = function(options)
            return {
                kind = "report",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
                elapsed_seconds = options.elapsed_seconds,
            }
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

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

local function fixture(provider)
    local records = {}
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
    }
    local client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function() end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = function() return true end,
        subprocess = false,
        now = function() return 100 end,
    }
    return report, records
end

test("legacy fixed targets cannot override the current book or start background counting", function()
    local report = fixture()
    local get = report.settings.get
    report.settings.get = function(self, key)
        local value = get(self, key)
        if key == "read_report" then
            value.mode = "manual"
            value.book_id = "other-book"
            value.book_title = "Other Book"
            value.report_on_open = false
        end
        return value
    end
    local started, title, source = report:on_reader_ready()
    eq(started, true, "recognized book starts reporting")
    eq(report.current_book_id, "book", "time follows the open book, never the fixed target")
    eq(title, "Book", "title follows the open book")
    eq(source, "current_document", "target comes from the reader")
    report:on_close_document()
    eq(report.task, nil, "close stops the timer even before the document reference is cleared")
    eq(report.current_book_id, nil, "close clears the target")
    report.detect_book = function() return nil end
    local local_started, _, local_reason = report:on_reader_ready()
    eq(local_started, false, "unrecognized local books cannot report to the fixed target")
    eq(local_reason, "document_not_weread", "local document has an explicit skip reason")
    report.get_document = function() return nil end
    report.detect_book = function() error("no document must not require detection") end
    local resumed, _, reason = report:on_resume()
    eq(resumed, false, "resuming on the shelf cannot start reporting")
    eq(reason, "no_document", "no background reporting")
    eq(report.task, nil, "no timer on the shelf")
end)

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 3, "enter plus two reports")
    eq(records[1].kind, "enter", "first request enters")
    eq(records[2].kind, "report", "second request reports")
    eq(records[2].chapter_uid, 22, "live chapter used")
    eq(records[2].chapter_offset, 150, "live offset used")
    eq(records[2].elapsed_seconds, 0, "progress-only report has zero time")
    eq(records[3].elapsed_seconds, 30, "time report keeps interval")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

test("account switch abandons old report and restarts with a fresh progress gate", function()
    local report,records=fixture(function() return nil,"progress_unverified",true end)
    report:on_reader_ready()
    local old_task,old_session=report.task,report.session_id
    report.count=3;report.failure_count=2;report.last_time=99
    report.last_error="old account error"
    local terminated,drained=0,0
    report.subprocess={terminate=function() terminated=terminated+1 end,
        is_done=function() return true end,read_all=function() drained=drained+1 end}
    report.job={pid=123,read_fd=456,poll=function() end}
    report:on_account_changed()
    eq(terminated,1,"old subprocess terminated")
    eq(drained,1,"old pipe collected")
    eq(report.job,nil,"old result detached")
    eq(report.session_id~=old_session,true,"new account has a fresh reading session")
    eq(report.task~=old_task,true,"new interval does not inherit elapsed time")
    eq(report.count,0,"old success count cleared")
    eq(report.last_time,nil,"old success time cleared")
    eq(report.last_error,nil,"old failure cleared")
    old_task()
    eq(#records,0,"stale tick cannot report")
    eq(report:_precheck(),false,"new account waits for progress verification")
    report.settings.is_cookie_configured=function() return false end
    report:on_account_changed()
    eq(report.task,nil,"logout cannot restart reporting")
    report.settings.is_cookie_configured=function() return true end
    local get=report.settings.get
    report.settings.get=function(self,key)
        local value=get(self,key)
        if key=="read_report" then value.mode="manual";value.book_id="old-target" end
        return value
    end
    report:on_account_changed()
    eq(report.current_book_id,"book","new account follows the open book instead of the old fixed target")
    eq(report:_precheck(),false,"legacy target cannot bypass fresh account progress verification")
    report.get_document=function() return nil end
    report:on_account_changed()
    eq(report.task,nil,"account change on the shelf cannot restart background reporting")
end)

test("spawn failure never falls back to UI network and can recover next interval", function()
    local report, records = fixture(function() return {percent=20}, nil, true end)
    local scheduled, attempts = {}, 0
    report.scheduler.scheduleIn=function(_,delay,fn)
        scheduled[#scheduled+1]={delay=delay,fn=fn}
    end
    report:maybe_start("test")
    local task=report.task
    scheduled={}
    -- Without subprocess support, no network context or report may be built.
    report.client.get_text=function() error("network on UI thread") end
    task()
    eq(report.last_error_kind,"job","explicit subprocess error")
    eq(report.last_error:find("no subprocess support",1,true)~=nil,true,"original cause retained")
    eq(#records,0,"no inline report")
    eq(#scheduled,1,"one retry at normal cadence")
    eq(scheduled[1].delay,30,"no fast retry loop")
    report.subprocess={run=function()
        attempts=attempts+1
        return nil,"fixture fork failure"
    end}
    scheduled={};task()
    eq(attempts,1,"one spawn per tick")
    eq(report.last_error:find("fixture fork failure",1,true)~=nil,true,"spawn cause retained")
    eq(#scheduled,1,"failed fork schedules one next tick")
    eq(#records,0,"failed fork has no inline report")
    -- Recovery starts a real job boundary; the child is not executed by this
    -- runner. Its acknowledgement remains the poller's responsibility.
    report.subprocess.run=function() attempts=attempts+1;return 123,456 end
    scheduled={};task()
    eq(report.job.pid,123,"later spawn recovers")
    eq(#scheduled,1,"only poll is scheduled while job runs")
    eq(scheduled[1].fn,report.job.poll,"result must be polled")
    eq(report.count,0,"spawn is not successful delivery")
end)

test("async progress shares the report slot and preserves unknown cancellation", function()
    local report=fixture()
    local result, calls, spawned=nil,0,0
    local function done(accepted,outcome) calls=calls+1;result=outcome;eq(accepted,false,"not acknowledged") end
    report.job={}
    report:upload_position_async("book",{},done,function() return true end)
    eq(result.error_kind,"busy","time report owns the shared slot")
    report.job=nil
    report:upload_position_async("book",{},done,function() return true end)
    eq(result.error_kind,"job","no inline fallback on spawn failure")
    report.subprocess={run=function() spawned=spawned+1;return 123,456 end,
        terminate=function() end,is_done=function() return true end,read_all=function() return '' end}
    local before=calls
    report:upload_position_async("book",{},done,function() return true end)
    eq(calls,before,"launch does not complete upload")
    eq(spawned,1,"one worker")
    report:stop("suspend")
    eq(calls,before+1,"interruption completes once")
    eq(result.error_kind,"transport","interruption has unknown write outcome")
    eq(report.job,nil,"interruption frees shared slot")
    eq(report.count,0,"progress upload is not reading time success")
end)

test("unknown refreshed writes are never replayed by cookie renewal", function()
    for _,elapsed in ipairs({0,30}) do
        for _,unknown_at in ipairs({1,2,3}) do
            local report=fixture()
            local requests,renewals=0,0
            local book={book_id="book",chapter_uid=11,psvts="fixture",
                read_session_id=report.session_id,read_session_entered_at=100}
            report.ensure_context=function() return book end
            report.client.report_read=function(_,payload)
                requests=requests+1
                eq(payload.elapsed_seconds,elapsed,"original interval retained")
                if requests==unknown_at then error("synthetic response lost after write") end
                return {errCode=-1},200
            end
            report.client.renew_cookie=function() renewals=renewals+1;return {succ=1} end
            local outcome=report:_run_pipeline("book",{allow_renewal=true,elapsed_seconds=elapsed})
            eq(requests,unknown_at,"no further write after unknown response")
            eq(renewals,unknown_at==3 and 1 or 0,"renewal only follows explicit rejections")
            eq(outcome.accepted,false,"unknown result is not acknowledged")
            eq(outcome.error_kind,"transport","transport error preserved at every stage")
        end
    end
end)

test("explicit rejection still permits bounded renewal recovery", function()
    local report=fixture()
    local requests,renewals=0,0
    local book={book_id="book",chapter_uid=11,psvts="fixture",
        read_session_id=report.session_id,read_session_entered_at=100}
    report.ensure_context=function() return book end
    report.client.report_read=function()
        requests=requests+1
        return requests==3 and {succ=1} or {errCode=-1},200
    end
    report.client.renew_cookie=function() renewals=renewals+1;return {succ=1} end
    local outcome=report:_run_pipeline("book",{allow_renewal=true,elapsed_seconds=30})
    eq(requests,3,"bounded upstream recovery")
    eq(renewals,1,"one renewal")
    eq(outcome.accepted,true,"confirmed recovery accepted")
end)

test("ambiguous HTTP replies cannot trigger a second reading-time write", function()
    for _,unknown_at in ipairs({1,2,3}) do
        local report=fixture()
        local calls=0
        local book={book_id="book",chapter_uid=11,psvts="fixture",read_session_id=report.session_id,read_session_entered_at=100}
        report.ensure_context=function() return book end
        report.client.renew_cookie=function() return {succ=1} end
        report.client.report_read=function()
            calls=calls+1
            if calls==unknown_at then return {},500 end
            return {errCode=-1},200
        end
        local outcome=report:_run_pipeline("book",{allow_renewal=true,elapsed_seconds=30})
        eq(calls,unknown_at,"ambiguous reply not replayed")
        eq(outcome.time_rejected==true,false,"unknown duration cannot be safely retried")
        eq(outcome.accepted,false,"no synthetic success")
    end
end)

test("time catch-up reads fresh cloud coordinates before each bounded attempt",function()
    local report=fixture()
    local reads,writes=0,0
    local book={book_id='book',chapter_uid=11,chapter_offset=2,progress=1,psvts='fixture',
        chapters={{chapterUid=11,chapterIdx=1}},read_session_id=report.session_id,read_session_entered_at=100}
    report.ensure_context=function() return book end
    report.client.get_progress=function()
        reads=reads+1
        return {book={chapterUid=11,chapterOffset=reads*100,progress=reads*10}}
    end
    report.client.report_read=function(_,payload)
        writes=writes+1
        eq(payload.chapter_offset,reads*100,'fresh cloud offset, never stale local offset')
        eq(payload.progress,reads*10,'fresh cloud percentage')
        eq(payload.elapsed_seconds,17,'only actual pending seconds')
        return writes==1 and {errCode=-1} or {succ=1},200
    end
    local result=report:_run_pipeline('book',{cloud_position=true,elapsed_seconds=17})
    eq(result.accepted,true,'catch-up acknowledged');eq(reads,2,'refresh cloud on explicit retry')
end)
test("missing cloud coordinates never fall back to the closed reader position",function()
    for _,remote in ipairs({{}, {book={progress=50}},
        {book={chapterUid=99,chapterOffset=10,progress=20}},
        {book={chapterUid=11,chapterOffset=-1,progress=20}}}) do
        local report=fixture()
        report.ensure_context=function() return {book_id='book',chapters={{chapterUid=11,chapterIdx=1}}} end
        report.client.get_progress=function() return remote end
        local writes=0;report.client.report_read=function() writes=writes+1 end
        local result=report:_child_report('book',false,nil,17,true)
        eq(writes,0,'no write without a valid cloud position')
        eq(result.time_report_sent,false,'unsent duration remains retryable')
        eq(result.accepted,false,'incomplete cloud data is not success')
    end
end)

test("rejected time remains retryable when a later attempt fails before its time write",function()
    for _,stage in ipairs({2,3}) do
        for _,failure in ipairs({'lookup','entry','write'}) do
            local report=fixture()
            local contexts,writes,reads=0,0,0
            local book={book_id='book',chapter_uid=11,psvts='fixture',
                chapters={{chapterUid=11,chapterIdx=1}},
                read_session_id=report.session_id,read_session_entered_at=100}
            report.ensure_context=function()
                contexts=contexts+1
                if contexts==stage and failure=='entry' then book.read_session_entered_at=nil end
                return book
            end
            report.client.get_progress=function()
                reads=reads+1
                if reads==stage and failure=='lookup' then error('synthetic progress fetch failed') end
                return {book={chapterUid=11,chapterOffset=10,progress=20}}
            end
            report.client.renew_cookie=function() return {succ=1} end
            report.client.report_read=function(_,payload)
                if contexts==stage and failure=='entry' then error('synthetic entry failed') end
                writes=writes+1
                if writes==stage and failure=='write' then error('synthetic response lost') end
                return {errCode=-1},200
            end
            local result=report:_child_report('book',true,nil,17,true)
            eq(result.accepted,false,'failure cannot report success')
            eq(result.time_rejected,failure~='write','only an attempted time write can become unknown')
            eq(writes,failure=='write' and stage or stage-1,'no unexpected time request')
            eq(result.time_report_sent,true,'earlier explicitly rejected writes are still recorded')
        end
    end
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
