package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local prevented = 0
local allowed = 0
local scheduled = {}
local dialog
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        preventStandby = function() prevented = prevented + 1 end,
        allowStandby = function() allowed = allowed + 1 end,
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        show = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["welite.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        fetch_single_chapter_source = function()
            error("injected transient timeout")
        end,
    }
end
package.preload["welite.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            dialog = {
                options = options,
                title = options.title,
                show = function(self) self.visible = true end,
                close = function(self) self.visible = false end,
                setTitle = function(self, title) self.title = title end,
                reportProgress = function() end,
            }
            return dialog
        end,
    }
end
package.preload["welite.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["welite.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["welite.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
    }
end

local Downloader = require("welite.lib.downloader")

local recovered=0
local recovery_failed=true
package.loaded['welite.lib.content'].cleanup_stale_downloads=function()
    recovered=recovered+1
    if recovery_failed then error('synthetic recovery failure') end
    return 1
end
local profile={}
local first_recovery=Downloader:new{settings={store=profile}}
expect(first_recovery:recover()==false,'failed recovery reports failure')
recovery_failed=false
expect(first_recovery:recover()==true and recovered==2,'failed recovery remains retryable')
local second_recovery=Downloader:new{settings={store=profile}}
expect(second_recovery:recover()==true and recovered==2,'reader instance cannot sweep an active profile again')
expect(Downloader:new{settings={store={}}}:recover()==true and recovered==3,'different profiles recover independently')


local completions = {}
local messages = {}
local downloader = Downloader:new{
    client = {},
    settings = {},
    require_login = function() return false end,
    run_online_task = function() error("must not run while logged out") end,
    show_info = function(text) messages[#messages + 1] = text end,
    show_transient = function(text) messages[#messages + 1] = text end,
    refresh_ui = function() end,
}
local started = downloader:start({}, {}, "book", {
    on_complete = function(ok, value)
        completions[#completions + 1] = { ok, value }
    end,
})
expect(started == false, "logged-out download should not start")
expect(#completions == 1 and completions[1][1] == false
    and completions[1][2] == "authentication_required",
    "logged-out completion result was wrong")

downloader.require_login = function() return true end
downloader.run_online_task = function() return false end
started = downloader:start({}, {}, "book", {
    on_complete = function(ok, value)
        completions[#completions + 1] = { ok, value }
    end,
})
expect(started == false, "offline download should not start")
expect(Downloader:new{settings=downloader.settings}:recover()==true and recovered==3,
    'scheduling new work seals startup recovery until the next process')
expect(#completions == 2 and completions[2][2] == "offline",
    "offline completion result was wrong")

local cancellation_count = 0
local cancelled = {
    cancelled = true,
    standby_guard = true,
    on_complete = function(ok, value)
        cancellation_count = cancellation_count + 1
        expect(ok == false and value == "cancelled",
            "cancel completion result was wrong")
    end,
}
downloader:_beginStandby()
downloader:_step(cancelled)
downloader:_step(cancelled)
expect(cancellation_count == 1, "cancel completion callback was not idempotent")
expect(downloader._standby_ref == 0 and allowed == 1,
    "cancel did not release standby exactly once")

local guarded_completion_count = 0
local closed = 0
local guarded = {
    standby_guard = true,
    progress_dialog = { close = function() closed = closed + 1 end },
    on_complete = function(ok, value)
        guarded_completion_count = guarded_completion_count + 1
        expect(ok == false and tostring(value):find("guarded boom", 1, true),
            "guarded error completion result was wrong")
    end,
}
downloader:_beginStandby()
downloader:_scheduleGuarded(guarded, function()
    error("guarded boom")
end, 0)
expect(#scheduled == 1, "guarded step was not scheduled")
scheduled[1]()
expect(guarded_completion_count == 1 and closed == 1,
    "guarded failure did not close and notify exactly once")
expect(downloader._standby_ref == 0 and allowed == 2,
    "guarded failure leaked the standby guard")
expect(#messages >= 2, "lifecycle failures were not surfaced to the user")
expect(prevented == 2, "standby guard was not acquired exactly once per job")

local retry_download = {
    book = { book_id = "book" },
    chapters = { { chapterUid = 30, title = "Chapter 30" } },
    index = 1,
    total = 1,
    failed = {},
}
local scheduled_before_retry = #scheduled
downloader:_step(retry_download)
expect(retry_download.index == 1 and #retry_download.failed == 0,
    "first transient chapter failure was not retained for retry")
expect(#scheduled == scheduled_before_retry + 1,
    "first chapter retry was not scheduled")
scheduled[#scheduled]()
expect(retry_download.index == 1 and #retry_download.failed == 0,
    "second transient chapter failure was not retained for retry")
scheduled[#scheduled]()
expect(retry_download.index == 2 and retry_download.failed[1] == "30",
    "chapter was not skipped after exhausting two retries")

-- Preparation must already be painted while DNS/session/cache work blocks.
local Content = require("welite.lib.content")
local pending_init, painted, reader_calls = nil, false, 0
downloader.refresh_ui = function()
    expect(dialog.visible, "preparation dialog was not shown before repaint")
    painted = true
end
downloader.run_online_task = function(_label, callback)
    expect(painted and dialog.visible and dialog.title == "Checking network...",
        "network check ran before the preparation dialog was painted")
    pending_init = callback
    return true
end
Content.ensure_reader_state = function()
    reader_calls = reader_calls + 1
    expect(dialog.visible and dialog.title == "Connecting to WeRead...",
        "reader session request ran without a visible stage")
end
Content.create_download_workspace = function()
    expect(dialog.visible and dialog.title == "Preparing download...",
        "workspace preparation ran without a visible stage")
    return {}
end
Content.cleanup_download_workspace = function() end
downloader.settings.get = function(_self, key, default)
    if key == "cache" then return { download_book_images = true } end
    return default
end
local chapters = { { chapterUid = 1 }, { chapterUid = 2 } }
local function start_selected()
    painted = false
    return downloader:start({ title = "Book" }, chapters, "chapters", {
        separate_chapters = true,
    })
end
expect(start_selected(), "selected chapter download did not start")
local preparing_dialog = dialog
expect(not start_selected(), "duplicate preparation was accepted")
pending_init()
expect(reader_calls == 1 and dialog == preparing_dialog and dialog.visible,
    "initialization replaced or closed the preparation dialog")
expect(downloader._active_job.standby_guard, "download did not acquire standby guard")
dialog.options.buttons[1][1].callback()
downloader:_step(downloader._active_job)
expect(not dialog.visible and downloader._active_job == nil,
    "cancelled download left the preparation dialog or job active")

expect(start_selected(), "cancel preparation setup failed")
dialog.options.buttons[1][1].callback()
pending_init()
expect(reader_calls == 1 and not dialog.visible and downloader._active_job == nil,
    "cancel before initialization still fetched or reopened the dialog")

Content.ensure_reader_state = function() error("injected reader failure") end
expect(start_selected(), "reader failure setup failed")
pending_init()
expect(not dialog.visible and downloader._active_job == nil,
    "failed initialization left the preparation dialog or job active")
expect(downloader._standby_ref == 0, "preparation failure leaked standby guard")

downloader.run_online_task = function()
    expect(painted and dialog.visible, "offline check ran before repaint")
    return false
end
expect(not start_selected() and not dialog.visible and downloader._active_job == nil,
    "offline start left the preparation dialog or job active")

-- Model Trapper yielding to the UI while a child is blocked on network I/O.
local child_pending, resumed, killed = nil, nil, 0
local trapper = {
    wrap = function(_self, callback)
        local co = coroutine.create(callback)
        local ok, err = coroutine.resume(co)
        assert(ok, err)
    end,
    dismissableRunInSubprocess = function(_self, task, widget)
        local co = coroutine.running()
        child_pending = task
        widget.dismiss_callback = function()
            killed = killed + 1
            child_pending = nil
            local ok, err = coroutine.resume(co, false)
            assert(ok, err)
        end
        resumed = function(value)
            child_pending = nil
            local ok, err = coroutine.resume(co, true, { ok = true, value = value })
            assert(ok, err)
        end
        return coroutine.yield()
    end,
}
require("ffi/util").runInSubProcess = function() end
package.preload["ui/trapper"] = function() return trapper end
downloader.run_online_task = function(_label, callback) callback(); return true end
local cleanup_calls, completion_calls = 0, 0
Content.cleanup_download_workspace = function() cleanup_calls = cleanup_calls + 1 end
local function cancel_job(dl, expected_cleanup)
    local before_killed = killed
    expect(child_pending and dialog.visible, "network request did not yield to the UI")
    dialog.options.buttons[1][1].callback()
    expect(killed == before_killed + 1 and child_pending == nil,
        "cancel did not interrupt the in-flight child")
    expect(dl.cancelled and dl.completion_notified and downloader._active_job == nil,
        "cancel did not finish the job exactly once")
    expect(not dialog.visible and downloader._standby_ref == 0,
        "cancel left a dialog or standby guard active")
    expect(cleanup_calls == expected_cleanup, "cancel removed the wrong workspace")
end

expect(start_selected(), "interruptible preparation did not start")
cancel_job(downloader._active_job, 0)

for _, stage in ipairs({ "source", "images", "cover" }) do
    local dl = {
        book = { title = "Book", cover = "https://example.com/cover.jpg" },
        chapters = chapters, total = 2, index = stage == "cover" and 3 or 1,
        selected = {}, bodies = {}, state = {}, assets = {}, failed = {},
        standby_guard = true, trapper = trapper, workspace = {},
        resumable = true, completed = {}, completed_count = 0,
        workspace_verified = true, footnotes_done = true,
        on_complete = function(ok, reason)
            expect(not ok and reason == "cancelled", "cancel was reported as a failure")
            completion_calls = completion_calls + 1
        end,
    }
    if stage == "images" then dl.current = { chapter = chapters[1], xhtml = "body" } end
    if stage == "cover" then dl.selected = chapters end
    downloader._active_job = dl
    downloader:_beginStandby()
    downloader:_ensureProgressDialog(dl)
    expect(dialog.options.description and dialog.options.description:find("resume", 1, true),
        "full-book progress did not explain cancellation and resume")
    trapper:wrap(function()
        if stage == "images" then downloader:_finishChapter(dl) else downloader:_step(dl) end
    end)
    cancel_job(dl, 0)
end
expect(completion_calls == 3, "network-stage cancellation duplicated completion")

local transferred = {
    book = { book_id = "book", token = "stale" }, chapters = chapters, total = 2, index = 1,
    selected = {}, bodies = {}, state = {}, assets = {}, failed = {},
    standby_guard = true, trapper = trapper,
}
downloader._active_job = transferred
downloader:_beginStandby()
downloader:_ensureProgressDialog(transferred)
trapper:wrap(function() downloader:_step(transferred) end)
resumed({ xhtml = "<p>source</p>", state = { css = "body{}" },
    book = { book_id = "book", psvts = "fresh" } })
expect(child_pending and transferred.state.css == "body{}"
    and transferred.book.psvts == "fresh" and transferred.book.token == nil,
    "source result lost CSS/session changes or retained stale credentials")
resumed({ xhtml = "<p>final</p>", assets = {}, state = { css = "body{}" } })
expect(transferred.bodies["1"] == "<p>final</p>" and transferred.index == 2
    and #transferred.selected == 1, "finalized child result was not saved in the parent")
dialog.options.buttons[1][1].callback()
downloader:_step(transferred)

-- A successful child must clear its dismiss callback before local work begins.
local dl = { book = {}, total = 1, trapper = trapper }
downloader:_ensureProgressDialog(dl)
local child_value
trapper:wrap(function()
    child_value = downloader:_runInterruptible(dl, function() return "unused" end)
end)
resumed("result")
expect(child_value == "result" and dialog.dismiss_callback == nil,
    "finished child left a stale coroutine cancellation callback")

dl.trapper = { dismissableRunInSubprocess = function() return false end }
local worker_ok, worker_err = pcall(downloader._runInterruptible, downloader, dl, function() end)
expect(not worker_ok and tostring(worker_err):find("could not start download worker", 1, true)
    and not dl.cancelled, "worker launch failure was mistaken for user cancellation")

print(("downloader_lifecycle_spec: %d checks"):format(checks))
