local Response = require("welite.lib.report_response")
local BookStore = require("welite.lib.book_store")
local Content = require("welite.lib.content")
local WorkerSettings = require("welite.lib.worker_settings")
local WeRead = require("welite.lib.protocol")

local logger = require("welite.lib.logger").scoped("ReadReport")

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil then
    ffiutil = nil
end

local DEFAULT_INTERVAL_SECONDS = 30
local MIN_INTERVAL_SECONDS = 10
local CONTEXT_TTL_SECONDS = 15 * 60
local RENEWAL_COOLDOWN_SECONDS = 10 * 60
local JOB_POLL_INITIAL_SECONDS = 0.25
local JOB_POLL_MAX_SECONDS = 2
local JOB_TIMEOUT_SECONDS = 180
local JOB_COLLECT_INTERVAL_SECONDS = 2

-- Context fields that the subprocess sends back for the parent to persist.
-- Mirrors the scalar reading-state fields stored by BookStore; the chapter
-- catalog itself stays in the on-disk catalog cache written by the child.
local CONTEXT_FIELDS = {
    "title", "reader_url", "app_id", "psvts", "pclts", "token",
    "chapter_uid", "chapter_idx", "chapter_offset", "progress", "summary",
    "read_context_updated_at", "read_session_entered_at", "read_session_id",
}

local ReadReport = {}
ReadReport.__index = ReadReport

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function make_subprocess_runner()
    if not ffiutil or type(ffiutil.runInSubProcess) ~= "function" then
        return nil
    end
    return {
        -- Returns pid, parent_read_fd on success; false, error message on failure.
        run = function(child_func)
            return ffiutil.runInSubProcess(child_func, true)
        end,
        -- Blocking write from inside the child; closes the fd when done.
        write_all = function(fd, data)
            return ffiutil.writeToFD(fd, data, true)
        end,
        -- Non-blocking waitpid; also reaps the child once it has exited.
        is_done = function(pid)
            return ffiutil.isSubProcessDone(pid)
        end,
        terminate = function(pid)
            ffiutil.terminateSubProcess(pid)
        end,
        -- Non-blocking readable-size probe (0 when nothing is buffered).
        read_size = function(fd)
            return ffiutil.getNonBlockingReadSize(fd)
        end,
        -- Reads until EOF and closes the fd.
        read_all = function(fd)
            return ffiutil.readAllFromFD(fd)
        end,
    }
end

function ReadReport:new(options)
    options = options or {}
    assert(options.settings, "read report settings are required")
    assert(options.client, "read report client is required")
    assert(options.scheduler, "read report scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        library_db = options.library_db,
        scheduler = options.scheduler,
        get_document = options.get_document,
        detect_book = options.detect_book,
        position_provider = options.position_provider,
        time_ledger = options.time_ledger,
        is_online = options.is_online or function() return true end,
        now = options.now or os.time,
        session_id = tostring({}) .. ":" .. tostring((options.now or os.time)()),
        subprocess = options.subprocess or make_subprocess_runner(),
        state = "stopped",
        generation = 0,
        count = 0,
        failure_count = 0,
        consecutive_failures = 0,
    }
    return setmetatable(object, self)
end

function ReadReport:_config()
    return self.settings:get("read_report")
end

function ReadReport:_interval()
    local interval = tonumber(self:_config().interval_seconds) or DEFAULT_INTERVAL_SECONDS
    return math.max(MIN_INTERVAL_SECONDS, interval)
end

function ReadReport:status()
    return {
        time_ledger = self.time_ledger and self.time_ledger:status(
            self.settings:get("account",{}).user_vid,self.current_book_id) or nil,
        running = self.task ~= nil,
        state = self.state,
        count = self.count or 0,
        failure_count = self.failure_count or 0,
        consecutive_failures = self.consecutive_failures or 0,
        last_time = self.last_time,
        last_error = self.last_error,
        last_error_kind = self.last_error_kind,
        stop_reason = self.stop_reason,
        target_book_id = self.current_book_id,
        target_book_title = self.current_book_title,
        target_source = self.current_book_source,
    }
end

function ReadReport:resolve_target()
    if not self.get_document() then
        return nil, nil, "no_document"
    end

    local detected_id = self.detect_book()
    if detected_id then
        detected_id = tostring(detected_id)
        -- Avoid reloading every book record from disk on each tick just for
        -- the title; reuse the cached one while the target stays the same.
        if detected_id == self.current_book_id
            and tostring(self.current_book_title or "") ~= "" then
            return detected_id, self.current_book_title, "current_document"
        end
        local book = BookStore.get(self.settings, detected_id)
        return detected_id,
            type(book) == "table" and book.title or detected_id,
            "current_document"
    end
    return nil, nil, "document_not_weread"
end

function ReadReport:_set_error(err, kind, prefix)
    local message = tostring(err)
    self.last_error = message
    self.last_error_kind = kind or "error"
    self.failure_count = (self.failure_count or 0) + 1
    self.consecutive_failures = (self.consecutive_failures or 0) + 1
    self.state = "error"
    if self.logged_error ~= message then
        log("warn", prefix or "read report error:", message)
        self.logged_error = message
    end
end

function ReadReport:_record_success(result)
    local recovered = self.last_error ~= nil
    self.count = (self.count or 0) + 1
    self.last_time = self.now()
    self.last_error = nil
    self.last_error_kind = nil
    self.logged_error = nil
    self.last_skip = nil
    self.consecutive_failures = 0
    self.state = "active"
    if recovered or self.count == 1 or self.count % 20 == 0 then
        log("info", "read report success:",
            "count=", self.count,
            "has_synckey=", type(result) == "table" and result.synckey ~= nil or false)
    end
end

function ReadReport:_log_skip(reason)
    if self.last_skip ~= reason then
        log("info", "read report skipped:", reason)
        self.last_skip = reason
    end
end

function ReadReport:maybe_start(reason)
    local config = self:_config()
    if not config.enabled then
        self:_log_skip("disabled")
        return false, nil, "disabled"
    end
    if self.suspended then
        self.state = "suspended"
        self:_log_skip("suspended")
        return false, nil, "suspended"
    end
    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        self:_log_skip(source)
        return false, nil, source
    end
    if self.task and self.current_book_id~=book_id then self:stop("document_changed") end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    if self.task then
        return true, title, source
    end
    return self:start(reason), title, source
end

function ReadReport:start(reason)
    if self.task then
        return true
    end
    local book_id, title, source = self:resolve_target()
    if not self:_config().enabled or self.suspended or not book_id then
        return false
    end

    if self.time_ledger and self.is_online() then
        local ok,started,err=pcall(self.time_ledger.start,self.time_ledger,self.settings:get("account",{}).user_vid,book_id)
        if not ok or not started then self:_set_error(ok and err or started,"accounting");return false end
    end
    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    self.state = "waiting"
    self.stop_reason = nil
    self.last_skip = nil

    local task
    task = function()
        if self.generation ~= generation or self.task ~= task then
            return
        end
        self:_tick(generation, task)
    end
    self.task = task
    self.scheduler:scheduleIn(self:_interval(), task)
    log("info", "reading time report started:",
        "reason=", reason or "unknown",
        "book_id=", book_id,
        "source=", source)
    return true
end

function ReadReport:stop(reason)
    reason = reason or "unspecified"
    local had_task = self.task ~= nil
    if self.time_ledger then
        local finish = self.is_online() and self.time_ledger.stop or self.time_ledger.pause
        local ok,err=pcall(finish,self.time_ledger)
        if not ok then self:_set_error(err,"accounting") end
    end
    self.generation = self.generation + 1
    if self.task then
        self.scheduler:unschedule(self.task)
        self.task = nil
    end
    if self.job then
        self:_abandon_job(self.job)
    end
    self.state = reason == "suspend" and "suspended"
        or "stopped"
    self.stop_reason = reason
    if had_task then
        log("info", "reading time report stopped:",
            "reason=", reason,
            "success_count=", self.count or 0,
            "failure_count=", self.failure_count or 0)
    end
end

-- Apply an interval change to a running session without interrupting it.
-- An in-flight job is left alone: the poller reschedules once it finishes, so
-- its result (including any renewed credentials) is still written back.
-- Otherwise only the pending tick is re-armed, right away, with the new
-- interval.
function ReadReport:reschedule(reason)
    if not self.task or self.job then
        return false
    end
    self.scheduler:unschedule(self.task)
    self.scheduler:scheduleIn(self:_interval(), self.task)
    log("info", "reading time report rescheduled:",
        "reason=", reason or "unspecified",
        "interval=", self:_interval())
    return true
end

function ReadReport:on_account_changed()
    self:stop("account_changed")
    self.session_id = tostring({}) .. ":" .. tostring(self.now())
    self.current_book_id = nil
    self.current_book_title = nil
    self.current_book_source = nil
    self.count, self.failure_count, self.consecutive_failures = 0, 0, 0
    self.last_time, self.last_error, self.last_error_kind = nil, nil, nil
    self.logged_error, self.last_skip = nil, nil
    -- Resume only the currently open WeRead book. Its position provider
    -- still requires fresh progress verification for the new account.
    if self.settings:is_cookie_configured() then
        return self:maybe_start("account_changed")
    end
    return false
end

function ReadReport:on_reader_ready()
    self.suspended = false
    return self:maybe_start("reader_ready")
end

function ReadReport:on_suspend()
    self.suspended = true
    self:stop("suspend")
end

function ReadReport:on_resume()
    self.suspended = false
    return self:maybe_start("resume")
end

function ReadReport:on_close_document()
    self:stop("document_closed")
    self.current_book_id = nil
    self.current_book_title = nil
    self.current_book_source = nil
end

-- Host connectivity events provide the precise boundary; periodic checks
-- cover devices that do not deliver an event. Neither path performs network I/O.
function ReadReport:on_network_disconnected()
    if self.time_ledger then
        local ok,err=pcall(self.time_ledger.stop,self.time_ledger)
        if not ok then self:_set_error(err,"accounting");return end
    end
    if self.task then self.state="offline" end
end

function ReadReport:_update_online_clock()
    if not self.time_ledger then return true end
    if not self.is_online() then
        self.time_ledger:pause()
        return true
    end
    if self.task and not self.suspended and not self.time_ledger.active then
        local started,err=self.time_ledger:start(self.settings:get("account",{}).user_vid,self.current_book_id)
        if not started then self:_set_error(err,"accounting");return false end
    end
    return true
end

function ReadReport:on_network_connected()
    local ok,err=pcall(self._update_online_clock,self)
    if not ok then self:_set_error(err,"accounting") end
end

-- ------------------------------------------------------------------
-- Scheduled tick: cheap parent-side checks, then hand the network
-- pipeline to a subprocess. A spawn failure must never run network on the UI.
-- ------------------------------------------------------------------

function ReadReport:_schedule_next(generation, task)
    if task and self.generation == generation and self.task == task then
        self.scheduler:scheduleIn(self:_interval(), task)
    end
end

function ReadReport:_tick(generation, task)
    local ok, err = pcall(function()
        if not self:_update_online_clock() then
            self:_schedule_next(generation,task)
            return
        end
        if self.time_ledger then self.time_ledger:checkpoint() end
        local proceed, book_id, position = self:_precheck()
        if not proceed then
            self:_schedule_next(generation, task)
            return
        end
        if self.job then
            -- Previous report is still in flight; keep the cadence and let
            -- the poller reschedule once it completes.
            self:_schedule_next(generation, task)
            return
        end
        local batch
        if self.time_ledger then
            local reason
            batch,reason=self.time_ledger:begin(300)
            if not batch then
                if reason=="time_report_busy" then self.state="waiting";self.last_skip=reason
                elseif reason~="no_elapsed_time" then self:_set_error(reason,"accounting") end
                self:_schedule_next(generation,task)
                return
            end
        end
        local allow_renewal = self:_renewal_allowed()
        local ok,spawned,spawn_err = pcall(self._start_job,self,
            book_id, allow_renewal, generation, task, position,nil,batch)
        if not ok then
            if batch then self.time_ledger:settle(batch,"unknown") end
            error(spawned)
        end
        if spawned then
            return
        end
        if batch then self.time_ledger:settle(batch,"retryable") end
        self:_set_error("cannot start report subprocess: " .. tostring(spawn_err),
            "job", "read report deferred:")
        self:_schedule_next(generation, task)
    end)
    if not ok then
        self:_set_error(err, "task", "read report task failed:")
        self:_schedule_next(generation, task)
    end
end

-- Parent-side gate before any network work. Returns true, book_id when a
-- report should be attempted. Must stay cheap: it runs on the UI loop.
function ReadReport:_precheck()
    local config = self:_config()
    if not config.enabled then
        self:stop("disabled")
        return false
    end
    if self.suspended then
        self:stop("suspend")
        return false
    end

    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        return false
    end
    if self.current_book_id and self.current_book_id ~= book_id then
        self:stop("document_changed")
        self:maybe_start("document_changed")
        return false
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source

    if not self.settings:is_cookie_configured() then
        self:_set_error("cookie not configured", "authentication", "read report skipped:")
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        self:_log_skip("offline")
        return false
    end
    local position
    if type(self.position_provider) == "function" then
        local provided, reason, applies = self.position_provider(book_id)
        if applies and not provided then
            self.state = "waiting_for_progress"
            self:_log_skip(reason or "progress_unverified")
            return false
        end
        position = provided
    end
    return true, book_id, position
end

function ReadReport:_renewal_allowed()
    return self.now() - (self.last_renew_attempt or 0) >= RENEWAL_COOLDOWN_SECONDS
end

function ReadReport:_auth_fingerprint()
    return WorkerSettings.fingerprint(self.settings)
end

function ReadReport:_context_fingerprint(book_id)
    local book = BookStore.get(self.settings, book_id) or {}
    local parts = {}
    for _i, field in ipairs(CONTEXT_FIELDS) do
        parts[#parts + 1] = field .. "=" .. tostring(book[field])
    end
    return table.concat(parts, ";")
end

-- ------------------------------------------------------------------
-- Subprocess job management (parent side)
-- ------------------------------------------------------------------

function ReadReport:_start_job(book_id, allow_renewal, generation, task, position, upload, batch)
    local runner = self.subprocess
    if not runner then
        return false, "no subprocess support"
    end
    local pid, read_fd = runner.run(function(_pid, child_write_fd)
        local outcome = self:_child_report(book_id, allow_renewal, position, upload and 0 or (batch and batch.seconds))
        local ok, encoded = pcall(function()
            return self.client:json_encode(outcome)
        end)
        if not ok or type(encoded) ~= "string" then
            encoded = '{"accepted":false,"error":"failed to serialize report outcome",'
                .. '"error_kind":"job"}'
        end
        runner.write_all(child_write_fd, encoded)
    end)
    if not pid then
        return false, tostring(read_fd)
    end

    local job = {
        upload = upload,
        time_batch = batch,
        pid = pid,
        read_fd = read_fd,
        book_id = book_id,
        started_at = self.now(),
        poll_interval = JOB_POLL_INITIAL_SECONDS,
        auth_fingerprint = self:_auth_fingerprint(),
        context_fingerprint = self:_context_fingerprint(book_id),
    }
    job.poll = function()
        self:_poll_job(job, generation, task)
    end
    self.job = job
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
    return true
end

function ReadReport:_poll_job(job, generation, task)
    if self.job ~= job then
        return
    end
    local runner = self.subprocess
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd)
    if done or (readable and readable > 0) then
        local payload
        if job.read_fd then
            payload = runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.job = nil
        if not done then
            -- Output was read while the child was still exiting; reap it in
            -- the background so it does not linger as a zombie.
            self:_collect_pid(job.pid)
        end
        local outcome = self:_decode_outcome(payload)
        if job.upload then
            if self.time_ledger then self.time_ledger:unlock_position(job.upload.lock) end
            if not job.upload.valid() or self:_auth_fingerprint() ~= job.auth_fingerprint then
                outcome = {accepted=false,error="stale progress upload result",error_kind="stale"}
            else
                self:_apply_job_outcome(job, outcome, true)
            end
            job.upload.done(type(outcome)=="table" and outcome.accepted==true, outcome)
        else
            self:_apply_job_outcome(job, outcome)
        end
        self:_schedule_next(generation, task)
        return
    end
    if self.now() - job.started_at > JOB_TIMEOUT_SECONDS then
        log("warn", "read report job timed out, terminating:", "pid=", job.pid)
        self:_abandon_job(job)
        self:_set_error("report job timed out", "transport", "read report job failed:")
        self:_schedule_next(generation, task)
        return
    end
    job.poll_interval = math.min(job.poll_interval * 2, JOB_POLL_MAX_SECONDS)
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
end

-- Kill a running job and keep reaping until the child is collected, so a
-- stopped or timed-out report can never leave a zombie behind.
function ReadReport:_abandon_job(job)
    job = job or self.job
    if not job then
        return
    end
    if self.job == job then
        self.job = nil
    end
    local runner = self.subprocess
    if job.poll then
        self.scheduler:unschedule(job.poll)
    end
    runner.terminate(job.pid)
    local collect, payload
    collect = function()
        if runner.is_done(job.pid) then
            if job.read_fd then
                payload = runner.read_all(job.read_fd)
                job.read_fd = nil
            end
            if job.time_batch and self.time_ledger then
                -- Closing before the next poll must not discard an already
                -- received acknowledgement or an explicit pre-send failure.
                local result = Response.settlement(self:_decode_outcome(payload))
                local ok,err=pcall(self.time_ledger.settle,self.time_ledger,job.time_batch,result)
                if not ok then self:_set_error(err,"accounting") end
            end
            if job.upload and self.time_ledger then self.time_ledger:unlock_position(job.upload.lock) end
            return
        end
        if job.read_fd and (runner.read_size(job.read_fd) or 0) ~= 0 then
            -- Drain and retain the receipt while the terminated child exits.
            payload = runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
    end
    collect()
    if job.upload then
        job.upload.done(false, {accepted=false,error="progress upload interrupted; server result unknown",error_kind="transport"})
    end
end

function ReadReport:_collect_pid(pid)
    local runner = self.subprocess
    local collect
    collect = function()
        if not runner.is_done(pid) then
            self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
        end
    end
    self.scheduler:scheduleIn(1, collect)
end

function ReadReport:_decode_outcome(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return self.client:json_decode(payload)
    end)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

-- ------------------------------------------------------------------
-- Outcome application (parent side)
-- ------------------------------------------------------------------

function ReadReport:_apply_job_outcome(job, outcome, context_only)
    local book_id = job.book_id
    local auth_matches=self:_auth_fingerprint()==job.auth_fingerprint
    local accounting_error
    if job.time_batch and self.time_ledger then
        local result=Response.settlement(outcome)
        local ok,err=pcall(self.time_ledger.settle,self.time_ledger,job.time_batch,result)
        if not ok then accounting_error=err end
    end
    if type(outcome) == "table" then
        if type(outcome.auth) == "table" then
            if self:_auth_fingerprint() ~= job.auth_fingerprint then
                log("info", "skip renewed auth write-back: parent auth changed during job")
            else
                local ok, err = pcall(function()
                    self.settings:update_auth({
                        cookies = outcome.auth.cookies,
                        wr_ticket = outcome.auth.wr_ticket,
                        wr_wrpa = outcome.auth.wr_wrpa,
                    }, { replace_cookies = true })
                end)
                if not ok then
                    log("warn", "persist renewed auth failed:", tostring(err))
                end
            end
        end
        if auth_matches and type(outcome.book) == "table" then
            if self:_context_fingerprint(book_id) ~= job.context_fingerprint then
                log("info", "skip report context write-back: parent record changed during job")
            else
                local ok, err = pcall(function()
                    self:_persist_context(book_id, outcome.book, outcome.accepted==true and auth_matches)
                end)
                if not ok then
                    log("warn", "persist report context failed:", tostring(err))
                end
            end
        end
    end
    if accounting_error then self:_set_error(accounting_error,"accounting");return false end
    if context_only then
        if outcome and outcome.renew_attempted then self.last_renew_attempt=self.now() end
        return
    end
    return self:_apply_outcome(outcome)
end

function ReadReport:_apply_outcome(outcome)
    if type(outcome) ~= "table" then
        self:_set_error("report job returned no result", "job", "read report job failed:")
        return false
    end
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if outcome.accepted then
        self:_record_success({ synckey = outcome.has_synckey and true or nil })
        return true
    end
    self:_set_error(outcome.error or "unknown report failure",
        outcome.error_kind or "error",
        outcome.error_prefix)
    return false
end

function ReadReport:_context_snapshot(book)
    local snapshot = { book_id = book.book_id }
    for _i, field in ipairs(CONTEXT_FIELDS) do
        snapshot[field] = book[field]
    end
    return snapshot
end

function ReadReport:_persist_context(book_id, snapshot, accepted)
    local book = BookStore.get(self.settings, book_id) or { book_id = book_id }
    local changed = false
    -- Replace semantics, not merge: a refreshed context may legitimately
    -- clear session fields (notably pclts), and the old wholesale record
    -- overwrite dropped them too. JSON strips nils from the outcome, so a
    -- missing snapshot field means "cleared".
    for _i, field in ipairs(CONTEXT_FIELDS) do
        local value = snapshot[field]
        if book[field] ~= value then
            book[field] = value
            changed = true
        end
    end
    if accepted then
        book.last_reported_position={account=self.settings:get("account",{}).user_vid,
            position={book_id=book_id,percent=snapshot.progress,chapter_uid=snapshot.chapter_uid,
                chapter_idx=snapshot.chapter_idx,chapter_offset=snapshot.chapter_offset}}
        changed=true
    end
    if not changed then
        return
    end
    book.book_id = book.book_id or book_id
    BookStore.put(self.settings, book_id, book)
    self.settings:flush()
end

-- ------------------------------------------------------------------
-- Shared report pipeline (scheduled reports run in the subprocess).
-- ------------------------------------------------------------------

-- Child entry point. Neuters settings persistence inside the fork and
-- captures auth changes (Set-Cookie merges, cookie renewal) so the parent
-- can persist them from the outcome.
function ReadReport:_child_report(book_id, allow_renewal, position, elapsed_seconds)
    self._no_persist = true
    self._time_report_sent = false
    local capture, restore = WorkerSettings.capture(self.settings)

    local ok, outcome = pcall(function()
        return self:_run_pipeline(book_id, {
            allow_renewal = allow_renewal,
            position = position,
            elapsed_seconds = elapsed_seconds,
        })
    end)
    if not ok then
        outcome = {
            accepted = false,
            error = tostring(outcome),
            error_kind = "task",
            error_prefix = "read report task failed:",
        }
    end
    outcome.time_report_sent = self._time_report_sent == true
    outcome.auth = capture()
    restore()
    return outcome
end

-- Full report attempt: context, send, refresh-retry, renewal, final retry.
-- Pure with respect to the parent state machine: everything the caller needs
-- is described by the returned outcome table.
ReadReport._run_pipeline = require("welite.lib.report_pipeline").run

-- ------------------------------------------------------------------
-- Report context
-- ------------------------------------------------------------------

function ReadReport:_merge_remote_progress(book_id, book)
    local ok, result = pcall(function()
        return self.client:get_progress(book_id)
    end)
    if not ok or type(result) ~= "table" then
        return
    end
    local remote = type(result.book) == "table" and result.book or result
    book.progress = tonumber(remote.progress) or tonumber(book.progress) or 0
    book.chapter_uid = remote.chapterUid or remote.chapterId or remote.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx)
        or tonumber(book.chapter_idx)
    book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos or remote.offset)
        or tonumber(book.chapter_offset) or 0
    book.summary = remote.summary or book.summary or ""
end

-- Build (and refresh when stale) the reader context on the given book
-- record. Performs network I/O; never persists settings.
function ReadReport:_build_context(book_id, force, book)
    book.book_id = book.book_id or book.bookId or book_id
    book.reader_url = WeRead.reader_url(book_id)

    -- BookStore never persists the chapter list, so a freshly loaded record
    -- has no chapters. Restore them from the on-disk catalog cache first;
    -- otherwise the TTL check below can never pass and every report would
    -- refetch the whole reader page.
    if type(book.chapters) ~= "table" or #book.chapters == 0 then
        local chapters = Content.load_catalog_cache(
            self.client, self.settings, book)
        if type(chapters) == "table" and #chapters > 0 then
            if self.library_db then
                self.library_db:putChapters(book_id, chapters)
            end
        else
            chapters = self.library_db
                and self.library_db:getChapters(book_id) or nil
            if type(chapters) == "table" and #chapters > 0 then
                book.chapters = chapters
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, chapters)
                if not cache_ok then
                    log("warn", "save chapter catalog cache failed:",
                        tostring(cache_err))
                end
            end
        end
    end

    local age = self.now() - (tonumber(book.read_context_updated_at) or 0)
    local ready = tostring(book.psvts or "") ~= ""
        and book.chapter_uid ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0
        and book.read_session_id == self.session_id
    if not force and ready and age < CONTEXT_TTL_SECONDS then
        return book
    end

    Content.ensure_reader_state(self.client, book)
    if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
        book.pclts = WeRead.e(self.now())
    end
    book.read_session_entered_at = nil
    book.read_session_id = self.session_id
    if force or type(book.chapters) ~= "table" or #book.chapters == 0 then
        local chapters = Content.fetch_catalog(self.client, book)
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            log("warn", "save chapter catalog cache failed:", tostring(cache_err))
        end
        if self.library_db then
            self.library_db:putChapters(book_id, chapters)
        end
    end
    self:_merge_remote_progress(book_id, book)

    local selected
    for _i, chapter in ipairs(book.chapters or {}) do
        if tostring(chapter.chapterUid or "") == tostring(book.chapter_uid or "") then
            selected = chapter
            break
        end
    end
    selected = selected or Content.first_readable_chapter(book.chapters)
    if not selected then
        error("no readable chapter found for report context")
    end
    book.chapter_uid = selected.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(selected.chapterIdx) or tonumber(book.chapter_idx) or 0
    book.app_id = book.app_id or WeRead.web_app_id()
    book.read_context_updated_at = self.now()
    if tostring(book.psvts or "") == "" or book.chapter_uid == nil then
        error("reader context is incomplete")
    end
    return book
end

function ReadReport:ensure_context(book_id, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end
    if not self.settings:is_cookie_configured() then
        error("cookie not configured")
    end

    local book = BookStore.get(self.settings, book_id) or {
        book_id = book_id,
        title = self.current_book_title or book_id,
    }
    self:_build_context(book_id, force, book)
    if self._no_persist then
        -- Forked child: the parent persists the context from the outcome.
        return book
    end
    BookStore.put(self.settings, book_id, book)
    self.settings:flush()
    return book
end

local function apply_position(book, position)
    if type(position) ~= "table" then return book end
    book.chapter_uid = position.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(position.chapter_idx) or tonumber(book.chapter_idx) or 0
    book.chapter_offset = tonumber(position.chapter_offset)
        or tonumber(book.chapter_offset) or 0
    book.progress = tonumber(position.percent or position.progress)
        or tonumber(book.progress) or 0
    book.summary = position.summary or book.summary or ""
    return book
end

function ReadReport:build_payload(book_id, elapsed_seconds, book, position)
    book = book or self:ensure_context(book_id, false)
    apply_position(book, position)
    return WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid,
        chapter_idx = tonumber(book.chapter_idx) or 0,
        chapter_offset = tonumber(book.chapter_offset) or 0,
        progress = tonumber(book.progress) or 0,
        summary = book.summary or "",
        elapsed_seconds = elapsed_seconds,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
end

function ReadReport:_send(book_id, book, position, elapsed_seconds)
    apply_position(book, position)
    if book.pclts == nil or book.pclts == "" or tonumber(book.pclts) == 0 then
        book.pclts = WeRead.e(self.now())
    end
    if book.read_session_id ~= self.session_id then
        book.read_session_id = self.session_id
        book.read_session_entered_at = nil
    end
    if not book.read_session_entered_at then
        local enter_payload = WeRead.make_enter_read_payload{
            book_id = book_id,
            chapter_uid = book.chapter_uid,
            chapter_idx = tonumber(book.chapter_idx) or 0,
            chapter_offset = tonumber(book.chapter_offset) or 0,
            progress = tonumber(book.progress) or 0,
            summary = book.summary or "",
            app_id = book.app_id or WeRead.web_app_id(),
            psvts = book.psvts,
            pclts = book.pclts,
        }
        self.client:report_read(
            enter_payload,
            book.reader_url or WeRead.reader_url(book_id)
        )
        book.read_session_entered_at = self.now()
        book.read_session_id = self.session_id
    end
    local payload = self:build_payload(
        book_id,
        elapsed_seconds == nil and self:_interval() or elapsed_seconds,
        book,
        position
    )
    self._time_report_sent = true
    self._time_send_count=(self._time_send_count or 0)+1
    return self.client:report_read(payload, book.reader_url or WeRead.reader_url(book_id))
end

-- Shares the time-report job slot and upstream protocol; completion is an
-- acknowledgement, never merely a successful process launch.
function ReadReport:upload_position_async(book_id, position, done, valid)
    if self.job then
        done(false, {error="read_report_busy",error_kind="busy"})
        return true
    end
    if not valid() then
        done(false, {error="stale progress upload",error_kind="stale"})
        return true
    end
    local lock
    if self.time_ledger then
        local ok,value,err=pcall(self.time_ledger.lock_position,self.time_ledger,
            self.settings:get("account",{}).user_vid,book_id)
        if not ok or not value then
            done(false,{error=tostring(ok and err or value),
                error_kind=ok and err=="time_report_busy" and "busy" or "accounting"})
            return true
        end
        lock=value
    end
    local ok,started,err=pcall(self._start_job,self,tostring(book_id),self:_renewal_allowed(),
        self.generation,nil,position,{done=done,valid=valid,lock=lock})
    if not ok or not started then
        if self.time_ledger then self.time_ledger:unlock_position(lock) end
        done(false,{error=tostring(ok and err or started),error_kind="job"})
    end
    return ok and started or false
end


return ReadReport
