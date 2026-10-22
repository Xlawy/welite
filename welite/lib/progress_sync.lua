local PositionMapper = require("welite.lib.position_mapper")

local logger = require("welite.lib.logger").scoped("ProgressSync")

local ProgressSync = {}
ProgressSync.__index = ProgressSync
-- Reader and file-manager plugins are different instances. Home reconciliation
-- must also see uploads that are still mapping their source position, before
-- ReadReport acquires its network slot. Requests live only as long as their job.
local pending_uploads = setmetatable({}, { __mode = "v" })
local function upload_key(settings, book_id)
    local account = tostring(settings:get("account", {}).user_vid or "")
    return tostring(settings.data_dir or settings)..":"..#account..":"..account..":"..tostring(book_id)
end

function ProgressSync.has_pending_upload(settings, book_id)
    local key = upload_key(settings, book_id)
    local request = pending_uploads[key]
    if request and request.is_pending() then return true end
    pending_uploads[key] = nil
    return false
end

local OPEN_DELAY_SECONDS = 0.6
local RESUME_RECHECK_SECONDS = 5 * 60
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local BUSY_RETRY_SECONDS = 2
local BUSY_RETRY_LIMIT = 10
local SAME_THRESHOLD_PERCENT = 2
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.upload_position_async) == "function" or type(options.upload_position) == "function",
        "upload_position callback is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        can_finish_close_upload = options.can_finish_close_upload or function() return true end,
        get_footer = options.get_footer,
        get_view_mode = options.get_view_mode,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        refresh_catalog = options.refresh_catalog,
        refresh_catalog_async = options.refresh_catalog_async,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        upload_position = options.upload_position,
        upload_position_async = options.upload_position_async,
        goto_fraction = options.goto_fraction,
        goto_page = options.goto_page,
        goto_xpointer = options.goto_xpointer,
        prepare_remote_async = options.prepare_remote_async,
        prepare_local_async = options.prepare_local_async,
        capture_local_snapshot = options.capture_local_snapshot,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        on_choice = options.on_choice or function(context)
            context.keep_local()
        end,
        notify = options.notify or function() end,
        run_pull = options.run_pull,
        cancel_pull = options.cancel_pull,
        on_synced = options.on_synced or function() end,
        now = options.now or os.time,
        state = "idle",
        generation = 0,
        pull_retry_token = 0,
        dirty = false,
        verified = false,
    }
    return setmetatable(object, self)
end

-- A request owns one account and document lifetime. Only an explicitly queued
-- close upload may finish after that lifetime ends, before another reader opens.
function ProgressSync:_session_guard(book_id, allow_close)
    local generation = self.generation
    local document = self.get_document()
    local path = document_path(document)
    local account = self.settings:get("account", {}).user_vid
    return function()
        if self.settings:get("account", {}).user_vid ~= account then return false, false end
        local active = generation == self.generation and self.get_document() == document
            and document_path(document) == path and tostring(self.detect_book() or "") == tostring(book_id)
        local closed = allow_close and self.generation == generation + 1 and self.current_book_id == nil
            and self.can_finish_close_upload()
        return active or closed, active
    end
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

function ProgressSync:_persist(book_id, patch)
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end
    local books = self.settings:get("books", {})
    local book = books[book_id] or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return true
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end

    local footer = self.get_footer and self.get_footer()
    local footer_value = footer and tonumber(footer.percent_finished)
    if footer_value then
        if footer_value > 1 then footer_value = footer_value / 100 end
        return math.max(0, math.min(1, footer_value))
    end

    local page
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page and type(document.getPageNumber) == "function" then
        local ok, value = pcall(document.getPageNumber, document)
        if ok then page = tonumber(value) end
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
    return nil
end

function ProgressSync:_rendered_positions(context)
    if not self.get_view_mode then return nil end
    local document, mode = self.get_document(), self.get_view_mode()
    local positions = self.rendered_positions
    if not positions or positions.document ~= document or positions.mode ~= mode
        or positions.context.book_id ~= context.book_id
        or positions.context.path ~= context.path
        or positions.context.chapters ~= context.chapters then
        positions = require("welite.lib.rendered_position").new(document, context, mode)
        self.rendered_positions = positions
    end
    return positions
end

function ProgressSync:_goto_target(fraction, remote, context)
    local positions = self:_rendered_positions(context)
    local page
    if positions then
        local reason
        fraction, reason, page = positions:target(remote)
        if fraction == nil then return false, reason end
    end
    local ok,err
    if page and self.goto_page then ok,err=self.goto_page(page)
    else ok,err=self.goto_fraction(fraction) end
    if ok and positions then positions:accept_target(remote) end
    return ok,err
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    local path = document_path(document)
    if not document or not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            account = self.settings:get("account", {}).user_vid,
            book = book,
            chapters = chapters,
            position_catalog = PositionMapper.catalog(chapters),
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            path = path,
        }
        cached = self.document_context
    end
    local fraction = self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local positions = self:_rendered_positions(cached)
    local position, reason
    if positions then
        position, reason = positions:capture()
    else
        position, reason = PositionMapper.local_to_remote(
            chapters,
            fraction,
            {
                catalog = cached.position_catalog,
                is_full_book = is_full_book == true,
                current_chapter_uid = current_chapter
                    and (current_chapter.chapterUid or current_chapter.chapterId),
                summary = book.summary or book.title or "",
            }
        )
    end
    if not position then return nil, reason end
    position.book_id = book_id
    position.document_path = path
    position.account_id = self.settings:get("account", {}).user_vid
    if self.prepare_local_async and document.getPageXPointer and document.getCurrentPage then
        position.local_xpointer = document:getPageXPointer(document:getCurrentPage())
        local saved = self.source_capture
        if saved and saved.document == document and saved.account == self.settings:get("account", {}).user_vid
            and saved.position.book_id == book_id and saved.position.document_path == path
            and saved.position.local_xpointer == position.local_xpointer
            and tostring(saved.position.chapter_uid) == tostring(position.chapter_uid) then
            position.chapter_offset = saved.position.chapter_offset
            position.summary = saved.position.summary
            position.position_basis = "source_utf16"
        end
    end
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_notify_synced(book_id)
    local ok, err = pcall(self.on_synced, tostring(book_id), self.settings:get("account", {}).user_vid)
    if not ok then log("warn", "sync completion callback failed:", tostring(err)) end
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.session_base = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    local pending=(self.get_book(tostring(book_id)) or {}).pending_upload_position
    if reason=="remote_selected" or reason=="remote_chapter_applied"
        or (reason=="positions_match" and type(pending)=="table"
            and pending.account_id==self.settings:get("account",{}).user_vid
            and PositionMapper.same_position(pending,remote)) then
        self:_persist(book_id,{pending_upload_position=false,pending_upload_reason=false})
    end
    if reason == "positions_match" then self:_notify_synced(book_id) end
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters, valid)
    local gateway
    local web
    local gateway_error
    local web_error
    if self.settings:is_api_configured() then
        local ok, result = pcall(self.client.get_progress, self.client, book_id)
        if ok then
            gateway, gateway_error = PositionMapper.normalize_remote(
                result, book_id, "gateway", chapters)
        else
            gateway_error = tostring(result)
        end
    end
    if valid and not valid() then return nil, "stale_progress_request" end
    if self.settings:is_cookie_configured() then
        local ok, result = pcall(
            self.client.get_web_progress, self.client, book_id)
        if ok then
            web, web_error = PositionMapper.normalize_remote(
                result, book_id, "web", chapters)
        else
            web_error = tostring(result)
        end
    end
    local selected = PositionMapper.choose_remote(
        web,
        gateway,
        SOURCE_CONFLICT_THRESHOLD_PERCENT
    )
    if not selected then
        return nil, gateway_error or web_error or "remote_unavailable"
    end
    return selected
end

-- The host finishes its page update after the jump. Persist only within the
-- same reader lifetime; a late callback must never revive a closed document or
-- write another book's position. Do not clear dirty here: the user may already
-- have turned a page since the jump.
function ProgressSync:_schedule_applied_position(book_id)
    local valid = self:_session_guard(book_id)
    self.scheduler:scheduleIn(0.15, function()
        if not valid() then return end
        local position = self:capture_local()
        if position and tostring(position.book_id) == tostring(book_id) then
            self.local_position = position
            self:_persist(book_id, { last_local_position = position })
            self:_notify_synced(book_id)
        end
    end)
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end

    if target.requires_chapter_open then
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            book_id = context.book_id,
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            remote = copy(remote),
            notify = options.manual == true,
        }
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local function applied()
        self.dirty = false
        self:_mark_verified(context.book_id, "remote_selected", self.local_position, remote)
        if options.manual then self.notify("remote_applied", { position = remote }) end
        self:_schedule_applied_position(context.book_id)
    end
    if self.prepare_remote_async and remote.has_chapter_offset ~= false
        and remote.chapter_offset ~= nil then
        if self.pulling then return false, "progress_mapping_busy" end
        local valid = self:_session_guard(context.book_id)
        local request = {}
        self._mapping_request, self.pulling, self.state = request, true, "pulling"
        local function current() return self._mapping_request == request and valid() end
        local started = self.prepare_remote_async(context, remote, function(xp, mapping_error)
            if not current() then return end
            self._mapping_request, self.pulling = nil, false
            local ok, err
            if xp and self.goto_xpointer then ok, err = self.goto_xpointer(xp) end
            if not ok then
                self.state = "error"
                self.notify("jump_failed", {error=mapping_error or err or "source_position_unavailable"})
                return
            end
            local positions = self:_rendered_positions(context)
            if positions then positions:accept_target(remote, self.get_document():getCurrentPage()) end
            applied()
        end, current)
        if not started and current() then
            self._mapping_request, self.pulling, self.state = nil, false, "error"
            return false, "source mapping could not start"
        end
        return started == true
    end
    local ok, err = self:_goto_target(target.fraction, remote, context)
    if not ok then return false, err or "jump_failed" end
    applied()
    return true
end

-- Keep only the exact source coordinate for the current document position.
-- Page turns only compare the captured XPointer; they never scan chapter text.
function ProgressSync:_prepare_source(position, done, valid, context)
    if position.position_basis == "confirmed_remote_offset" or position.position_basis == "source_utf16" then
        done(position);return true
    end
    context=context or self.document_context
    if not context or not position.local_xpointer then done(nil,"source_position_unavailable");return true end
    local completed=false
    return self.prepare_local_async(context,position,function(offset,err,summary)
        if completed or not valid() then return end
        completed=true
        if offset==nil then done(nil,err);return end
        local mapped=copy(position)
        mapped.chapter_offset,mapped.position_basis,mapped.summary=offset,"source_utf16",summary or position.summary
        mapped.source_snapshot=nil
        self.source_capture={document=self.get_document(),account=self.settings:get("account",{}).user_vid,position=mapped}
        done(mapped)
    end,valid)
end

function ProgressSync:_upload_snapshot(position, reason, show_result)
    if type(position) ~= "table" then return false end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" or self.uploading then return false end
    local source_context=self.document_context
    local snapshot_error
    if reason=="document_close" and self.prepare_local_async and self.capture_local_snapshot
        and not position.source_snapshot
        and position.position_basis~="source_utf16" and position.position_basis~="confirmed_remote_offset" then
        position=copy(position)
        local ok,snapshot,err=pcall(self.capture_local_snapshot,source_context,position)
        if ok and snapshot then position.source_snapshot=snapshot
        else snapshot_error=(ok and err or snapshot) or "source_snapshot_unavailable" end
    end
    if self._report_mapping then
        self._report_mapping=nil
        if self.cancel_pull then self.cancel_pull() end
    end
    self:_persist(book_id, {
        pending_upload_position = position,
        pending_upload_reason = reason or "unspecified",
    })
    if snapshot_error then
        self:_persist(book_id,{last_sync_error=snapshot_error})
        self.state="error"
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if show_result then self.notify("offline", {}) end
        return false
    end
    self.uploading = true
    self.state = "uploading"
    local request = {}
    self._upload_request = request
    local valid = self:_session_guard(book_id, reason == "document_close")
    request.is_pending = function()
        return self._upload_request == request and self.uploading and valid()
    end
    pending_uploads[upload_key(self.settings, book_id)] = request
    local function stale()
        if self._upload_request ~= request then return true end
        if valid() then return false end
        self._upload_request = nil
        self.uploading = false
        return true
    end
    local attempts = 0
    local attempt
    local function finish(ok, accepted, outcome)
        if stale() then return end
        if ok and not accepted and type(outcome) == "table"
            and outcome.error_kind == "busy"
            and attempts < BUSY_RETRY_LIMIT then
            self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, attempt)
            return
        end
        self.uploading = false
        self._upload_request = nil
        local _, active = valid()
        if ok and accepted then
            local current = active and self:capture_local() or nil
            if active then
                self.state = "verified"
                if current then
                    self.dirty = not PositionMapper.same_position(current, position)
                    self.local_position = current
                end
            end
            self.last_uploaded_position = copy(position)
            self.session_base = copy(position)
            self.session_base.sync_base=nil
            self:_persist(book_id, {
                last_local_position = current or position,
                last_uploaded_position = position,
                last_upload_at = self.now(),
                pending_upload_position = false,
                pending_upload_reason = false,
                last_sync_error = false,
            })
            self:_notify_synced(book_id)
            log("info", "upload accepted:",
                "book=", book_id,
                "percent=", tostring(position.percent),
                "reason=", tostring(reason))
            if show_result and active then
                self.notify("upload_success", { position = position })
            end
            return
        end
        local error_message = ok and type(outcome) == "table"
            and outcome.error or outcome
        if active then self.state = "error" end
        self:_persist(book_id, {
            last_sync_error = tostring(error_message or "upload_failed"),
        })
        log("warn", "upload failed:", tostring(error_message))
        if show_result and active then
            self.notify("upload_failed", {
                error = tostring(error_message or "upload_failed"),
            })
        end
    end
    attempt = function()
        if stale() then return end
        attempts = attempts + 1
        if self.upload_position_async then
            local completed = false
            local function done(accepted, outcome)
                if completed then return end
                completed = true
                finish(true, accepted, outcome)
            end
            local ok, started = pcall(self.upload_position_async, book_id, copy(position), done, valid)
            if not ok then
                done(false, {error=tostring(started),error_kind="job"})
            elseif started == false then
                done(false, {error="progress upload could not start",error_kind="job"})
            end
        else
            finish(pcall(self.upload_position, book_id, copy(position), 0))
        end
    end
    local function prepare()
        if stale() then return end
        if not self.prepare_local_async then attempt();return end
        self._source_upload_preparing=true
        local started=self:_prepare_source(position,function(mapped,err)
            if stale() then return end
            self._source_upload_preparing=nil
            if not mapped then finish(false,false,err or "source_position_unavailable");return end
            position=mapped
            self:_persist(book_id,{pending_upload_position=position})
            attempt()
        end,valid,source_context)
        if not started then
            self._source_upload_preparing=nil
            finish(false,false,"source mapping could not start")
        end
    end
    local started = self.run_online("progress_upload", prepare)
    if not started and self._upload_request == request and valid() then
        self._upload_request = nil
        self.uploading = false
        self.state = "offline"
    end
    return started == true
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        self:_upload_snapshot(local_position, options.reason, true)
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    -- Compare the same coordinate system used for uploads, including after a
    -- closed-book upload. A rendered-page estimate is not a source offset.
    local acknowledged=(self.get_book(context.book_id) or {}).last_uploaded_position
    if self.prepare_local_async and not options.source_prepared
        and type(acknowledged)=="table"
        and acknowledged.account_id==self.settings:get("account",{}).user_vid
        and PositionMapper.same_position(acknowledged,remote,1) then
        local valid=self:_session_guard(context.book_id)
        local token={};self._compare_request=token;self.pulling=true
        local function current() return self._compare_request==token and valid() end
        local function prepared(mapped)
            if not current() then return end
            self._compare_request=nil;self.pulling=false
            local latest=self:capture_local()
            if not latest or latest.local_xpointer~=local_position.local_xpointer then
                self.state="unverified";return
            end
            local next_options=copy(options);next_options.source_prepared=true
            self:_resolve(mapped or local_position,remote,context,next_options)
        end
        local started=self:_prepare_source(local_position,prepared,current,context)
        if not started then prepared(nil) end
        return
    end
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    local source_match=(local_position.position_basis=="source_utf16"
        or local_position.position_basis=="confirmed_remote_offset")
        and remote.has_chapter_offset
        and tostring(local_position.chapter_uid)==tostring(remote.chapter_uid)
        and local_position.chapter_offset==remote.chapter_offset
    local comparison = source_match and "same" or PositionMapper.compare(
        local_position,
        remote,
        SAME_THRESHOLD_PERCENT
    )

    -- Explicit sync must not hide different pages behind the automatic 2%
    -- tolerance. Leave automatic conflict policy unchanged.
    if options.manual and comparison == "same" and not source_match
        and not PositionMapper.same_position(local_position, remote) then
        comparison = "different"
    end
    if comparison == "same" and not remote.conflict then
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if options.manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    local ask = self:_config().ask_on_conflict ~= false
    if remote.conflict or ask or (options.manual and comparison == "different") then
        self.state = "awaiting_choice"
        local choice_valid = self:_session_guard(context.book_id)
        local choice_pending = true
        local function take_choice()
            if not choice_pending or not choice_valid() then return false end
            choice_pending = false
            return true
        end
        self.on_choice({
            book_title = context.book.title or context.book_id,
            local_position = copy(local_position),
            remote_position = copy(remote),
            source_conflict = remote.conflict == true,
            cancel = function()
                if not take_choice() then return end
                self.state = "unverified"
                self:_clear_verified("choice_cancelled")
            end,
            use_remote = function()
                if not take_choice() then return end
                local ok, reason = self:_apply_remote(
                    remote, context, { manual = options.manual })
                if not ok then
                    self.state = "error"
                    self.notify("jump_failed", { error = reason })
                end
            end,
            keep_local = function()
                if not take_choice() then return end
                self:_keep_local(local_position, remote, {
                    manual = options.manual,
                    upload_now = true,
                    reason = "explicit_local_choice",
                })
            end,
        })
        return
    end

    if comparison == "remote_ahead" then
        local ok, reason = self:_apply_remote(
            remote, context, { manual = options.manual })
        if not ok then
            self.state = "error"
            self.notify("jump_failed", { error = reason })
        end
    else
        self:_keep_local(local_position, remote, {
            manual = options.manual,
            upload_now = options.manual == true,
            reason = "manual_sync",
        })
    end
end

function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local valid = self:_session_guard(tostring(self.detect_book() or ""))
    self.scheduler:scheduleIn(PULL_RETRY_DELAY_SECONDS, function()
        if not valid() then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull({
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        })
    end)
    log("info", "pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_pull(options)
    options = options or {}
    if self.pulling then return false end
    local retry_token = options.retry_token
    if retry_token == nil then
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        if not (options.manual == true
            and reason == "catalog_unavailable"
            and (type(self.refresh_catalog) == "function"
                or type(self.refresh_catalog_async) == "function")) then
            if options.manual then
                self.notify("local_unavailable", { error = reason })
            end
            return false
        end
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local valid = self:_session_guard(tostring(self.detect_book() or ""))
    local request = {}
    self._pull_request = request
    local function stale()
        if self._pull_request ~= request then return true end
        if valid() then return false end
        self._pull_request = nil
        self.pulling = false
        return true
    end
    self.pulling = true
    self.state = "pulling"
    local started = self.run_online("progress_pull", function()
        if stale() then return end
        local function finish(remote,pull_error)
            if stale() then return end
            self._pull_request = nil
            self.pulling = false
            if not remote then
                self.state = "error"
                self:_persist(context.book_id, {
                    last_pull_at = self.now(),
                    last_sync_error = tostring(pull_error),
                })
                if options.manual then
                    self.notify("pull_failed", { error = tostring(pull_error) })
                end
                return
            end
            -- Reading can continue during the request; compare with the position
            -- currently displayed, not the snapshot taken before network I/O.
            local_position, reason, context = self:capture_local()
            if not local_position then
                self.state="error"
                self.notify("local_unavailable", {error=reason})
                return
            end
            self:_persist(context.book_id, {
                last_remote_position = remote,
                last_local_position = local_position,
                last_pull_at = self.now(),
                last_sync_error = false,
            })
            self:_resolve(local_position, remote, context, options)
        end
        local function fetch_progress()
            if stale() then return end
            if self.run_pull then
                local started=self.run_pull(function(check)
                    return self:_fetch_remote(context.book_id,context.chapters,check)
                end,finish,valid)
                if not started then finish(nil,"progress worker could not start") end
            else
                finish(self:_fetch_remote(context.book_id,context.chapters,valid))
            end
        end
        if local_position then fetch_progress();return end
        local book_id=tostring(self.detect_book() or "")
        local function catalog_ready(refreshed,refresh_error)
            if stale() then return end
            self.document_context=nil
            self.rendered_positions=nil
            local_position,reason,context=self:capture_local()
            if not local_position or type(refreshed)~="table" or #refreshed==0 then
                self.pulling=false
                self._pull_request=nil
                self.state="error"
                self.notify("local_unavailable",{error=refresh_error or reason or "catalog_unavailable"})
                return
            end
            fetch_progress()
        end
        if self.refresh_catalog_async then
            local started=self.refresh_catalog_async(book_id,catalog_ready,valid)
            if not started then catalog_ready(nil,"catalog worker could not start") end
        else
            local ok,chapters,err=pcall(self.refresh_catalog,book_id)
            if ok then catalog_ready(chapters,err) else catalog_ready(nil,chapters) end
        end
    end, { silent_offline = true })
    if not started and self._pull_request == request and valid() then
        self._pull_request = nil
        self.pulling = false
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    if not pending or tostring(pending.book_id) ~= tostring(book_id) then
        return false
    end
    local local_position, _reason, context = self:capture_local()
    if not context or not context.current_chapter
        or tostring(context.current_chapter.chapterUid or context.current_chapter.chapterId)
            ~= tostring(pending.chapter_uid) then
        return false
    end
    self.pending_jump = nil
    if self.prepare_remote_async then
        local ok,err=self:_apply_remote(pending.remote,context,{manual=pending.notify})
        if not ok then self.state="error";self.notify("jump_failed",{error=err}) end
        return true
    end
    local ok, err = self:_goto_target(pending.fraction, pending.remote, context)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self.dirty = false
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        local_position,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    self:_schedule_applied_position(book_id)
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    self.pending_jump = nil
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

-- Account changes revoke choices and pending chapter jumps as well as verification.
-- Reuse reader initialization so no upload can inherit the old account's consent.
function ProgressSync:on_account_changed()
    self.pending_jump = nil
    self.last_uploaded_position = nil
    self:on_reader_ready()
end

function ProgressSync:on_reader_ready()
    self.resume_pull=nil
    self._report_mapping=nil
    self.source_capture=nil
    self._source_upload_preparing=nil
    if self.cancel_pull then self.cancel_pull() end
    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = nil
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.rendered_positions = nil
    self.verified = false
    self.dirty = false
    self.state = "waiting"
    self.uploading = false
    self.pulling = false
    self._upload_request = nil
    self._pull_request = nil
    self.verified_reason = nil

    self.scheduler:scheduleIn(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        local book_id = self.detect_book()
        if not book_id or is_mp_book(book_id) then
            self.state = "unsupported"
            return
        end
        book_id = tostring(book_id)
        self.current_book_id = book_id
        self.session_base = nil
        local observed = (self.get_book(book_id) or {}).home_remote_position
        if self:_apply_pending_jump(book_id) then return end

        local local_position, reason = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            log("warn", "local position unavailable:", tostring(reason))
            return
        end
        self.local_position = local_position
        if observed and observed.account==self.settings:get("account",{}).user_vid
            and (local_position.position_basis=="source_utf16"
                or local_position.position_basis=="confirmed_remote_offset")
            and PositionMapper.same_position(local_position,observed.position,1) then
            self.session_base=copy(observed.position)
        end
        self:_persist(book_id, { last_local_position = local_position })
        local pending=(self.get_book(book_id) or {}).pending_upload_position
        local account=self.settings:get("account",{}).user_vid
        if account~=nil and type(pending)=="table" and pending.account_id==account then
            -- Reconcile only after the user opens this book, never on the shelf.
            -- A newer cloud position still requires the usual conflict choice.
            self:_pull({manual=true})
            return
        end
        if self:_config().pull_on_open ~= true then
            self.state = "unverified"
            return
        end
        self:_pull({ manual = false })
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    local position = self:capture_local()
    if not position then return end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

function ProgressSync:_cancel_source_upload()
    if not self._source_upload_preparing then return false end
    self._source_upload_preparing=nil
    self._upload_request=nil
    self.uploading=false
    return true
end

function ProgressSync:on_close_document()
    self:_cancel_source_upload()
    self._report_mapping=nil
    if self.cancel_pull then self.cancel_pull() end
    self._pull_request=nil
    self.pulling=false
    self.resume_pull=nil
    local position = self:capture_local() or self.local_position
    if position then self:_persist(position.book_id, { last_local_position = position }) end
    if position and (self.dirty or (self.local_position
        and not PositionMapper.same_position(position,self.local_position))) then
        position = copy(position)
        position.sync_base = copy(self.session_base)
        if self.capture_local_snapshot and position.position_basis ~= "source_utf16"
            and position.position_basis ~= "confirmed_remote_offset" then
            local ok,snapshot = pcall(self.capture_local_snapshot,self.document_context,position)
            if ok then position.source_snapshot = snapshot end
        end
        self:_persist(position.book_id,{pending_upload_position=position,
            pending_upload_reason="document_close"})
        if self.verified and self:_config().upload_on_close == true then
            self:_upload_snapshot(position,"document_close",false)
        end
    end
    self.generation = self.generation + 1
    self.current_book_id = nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.rendered_positions = nil
end

function ProgressSync:on_suspend()
    self._report_mapping=nil
    self.resume_pull=self:_cancel_source_upload() or self.pulling or nil
    if self.resume_pull then self.state="unverified" end
    if self.cancel_pull then self.cancel_pull() end
    self._pull_request=nil
    self.pulling=false
    self.suspended_at = self.now()
    local position = self:capture_local() or self.local_position
    if position and self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    if position and self.verified and self.dirty
        and self:_config().upload_on_close == true then
        self:_upload_snapshot(position, "suspend", false)
    end
end

function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    local interrupted=self.resume_pull
    self.resume_pull=nil
    if interrupted or (slept >= RESUME_RECHECK_SECONDS
        and self:_config().pull_on_open == true) then
        self:_clear_verified("resume_recheck")
        self:_pull({ manual = false })
    end
end

function ProgressSync:sync_now()
    return self:_pull({ manual = true })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if not self.verified then
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.prepare_local_async and position.position_basis ~= "source_utf16"
        and position.position_basis ~= "confirmed_remote_offset" then
        if not self._report_mapping and not self.uploading and not self.pulling then
            local request={}
            self._report_mapping=request
            local valid=self:_session_guard(tostring(book_id))
            local started=self:_prepare_source(position,function(mapped,err)
                if self._report_mapping~=request then return end
                self._report_mapping=nil
                if valid() and not mapped then self:_persist(book_id,{last_sync_error=err or "source_position_unavailable"}) end
            end,valid)
            if not started then self._report_mapping=nil end
        end
        return nil,"source_position_preparing",true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    return position, nil, true
end

function ProgressSync:status()
    return {
        state = self.state,
        book_id = self.current_book_id,
        verified = self.verified,
        verified_reason = self.verified_reason,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading == true,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
