-- Network-only report attempts. Caller owns scheduling, storage and settlement.
local WeRead = require("welite.lib.protocol")
local Response = require("welite.lib.report_response")
local M = {}

function M.run(self, book_id, opts)
    opts = opts or {}
    local outcome = { accepted = false, renew_attempted = false }
    self._time_send_count=0
    local function send(book)
        return self:_send(book_id,book,opts.position,opts.elapsed_seconds)
    end

    local context_ok, book = pcall(function()
        return self:ensure_context(book_id, false)
    end)
    if not context_ok then
        outcome.error = tostring(book)
        outcome.error_kind = "context"
        outcome.error_prefix = "read report context initialization failed:"
        return outcome
    end
    local ok, result, http_code = pcall(function()
        return send(book)
    end)
    outcome.book = self:_context_snapshot(book)
    local accepted, accepted_body = Response.accepted(result, http_code)
    if ok and accepted then
        outcome.accepted = true
        outcome.has_synckey = type(accepted_body) == "table"
            and accepted_body.synckey ~= nil or false
        return outcome
    end
    if not ok then
        outcome.error = tostring(result)
        outcome.error_kind = "transport"
        outcome.error_prefix = "read report request failed:"
        return outcome
    end

    if not Response.rejected(result) then
        outcome.error="reading report response did not confirm acceptance or rejection"
        outcome.error_kind="transport"
        return outcome
    end
    outcome.time_rejected=true
    local failure = Response.summary(self.client, result, http_code)
    if tonumber(http_code)==429 then
        outcome.error=failure;outcome.error_kind='rate_limit'
        return outcome
    end
    local refresh_ok, refreshed = pcall(function()
        return self:ensure_context(book_id, true)
    end)
    if refresh_ok then
        outcome.book = self:_context_snapshot(refreshed)
        local sent_before_retry=self._time_send_count
        local retry_ok, retry_result, retry_code = pcall(function()
            return send(refreshed)
        end)
        outcome.book = self:_context_snapshot(refreshed)
        local retry_accepted, retry_body = Response.accepted(retry_result, retry_code)
        if retry_ok and retry_accepted then
            outcome.accepted = true
            outcome.has_synckey = type(retry_body) == "table"
                and retry_body.synckey ~= nil or false
            return outcome
        end
        -- A missing response is not a rejection. The refreshed write may
        -- already have been accepted; renewal must not replay that interval.
        if not retry_ok then
            -- A failed lookup/context entry before the time write cannot turn
            -- the previous explicit rejection into an unknown time result.
            outcome.time_rejected=self._time_send_count==sent_before_retry
            outcome.error = "initial=" .. failure .. "; refreshed=" .. tostring(retry_result)
            outcome.error_kind = "transport"
            outcome.error_prefix = "read report refreshed request outcome unknown:"
            return outcome
        end
        if not Response.rejected(retry_result) then
            outcome.time_rejected=false
            outcome.error="refreshed reading report response was ambiguous"
            outcome.error_kind="transport"
            return outcome
        end
        failure = "initial=" .. failure .. "; refreshed="
            .. Response.summary(self.client, retry_result, retry_code)
        if tonumber(retry_code)==429 then
            outcome.error=failure;outcome.error_kind='rate_limit'
            return outcome
        end
    else
        failure = failure .. "; context_refresh=" .. tostring(refreshed)
    end

    if not opts.allow_renewal then
        outcome.error = failure
        outcome.error_kind = "server"
        outcome.error_prefix = "read report server rejected:"
        return outcome
    end
    outcome.renew_attempted = true

    local renew_ok, renew_result = pcall(function()
        return self.client:renew_cookie()
    end)
    if not renew_ok or not WeRead.is_success_response(renew_result) then
        outcome.error = failure .. "; renewal=" .. (renew_ok
            and Response.summary(self.client, renew_result)
            or tostring(renew_result))
        outcome.error_kind = "authentication"
        outcome.error_prefix = "read report cookie renewal failed:"
        return outcome
    end

    local final_context_ok, final_book = pcall(function()
        return self:ensure_context(book_id, true)
    end)
    if not final_context_ok then
        outcome.error = failure .. "; final_context=" .. tostring(final_book)
        outcome.error_kind = "context"
        outcome.error_prefix = "read report final context refresh failed:"
        return outcome
    end
    outcome.book = self:_context_snapshot(final_book)
    local sent_before_final=self._time_send_count
    local final_ok, final_result, final_code = pcall(function()
        return send(final_book)
    end)
    outcome.book = self:_context_snapshot(final_book)
    local final_accepted, final_body = Response.accepted(final_result, final_code)
    if final_ok and final_accepted then
        outcome.accepted = true
        outcome.has_synckey = type(final_body) == "table"
            and final_body.synckey ~= nil or false
        return outcome
    end
    outcome.time_rejected=(final_ok and Response.rejected(final_result))
        or (not final_ok and self._time_send_count==sent_before_final)
    outcome.error = failure .. "; final=" .. (final_ok
        and Response.summary(self.client, final_result, final_code)
        or tostring(final_result))
    outcome.error_kind = final_ok and "server" or "transport"
    outcome.error_prefix = "read report final retry failed:"
    return outcome
end

return M
