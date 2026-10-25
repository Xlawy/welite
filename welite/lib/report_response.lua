-- Interpret acknowledgements conservatively; HTTP success alone is not a receipt.
-- Diagnostics expose only bounded structural metadata, never arbitrary response data.
local M = {}
local function body(result)
    if type(result) ~= 'table' then return result end
    if result.succ ~= nil or result.synckey ~= nil then return result end
    return type(result.data) == 'table' and result.data
        or type(result.result) == 'table' and result.result or result
end
local function rejected(value)
    if type(value) ~= 'table' then return false end
    if value.succ == false or tonumber(value.succ) == 0 then return true end
    for _, key in ipairs({'errCode', 'errcode', 'errorCode'}) do
        local code = tonumber(value[key])
        if code and code ~= 0 then return true end
    end
    return false
end
function M.rejected(result)
    return rejected(result) or rejected(body(result))
end
function M.accepted(result, http_code)
    local value = body(result)
    local status = tonumber(http_code)
    if (status and (status < 200 or status >= 300)) or M.rejected(result)
        or type(value) ~= 'table' then return false, value end
    for _,container in ipairs({result,value}) do
        for _,key in ipairs({'errCode','errcode','errorCode'}) do
            if container[key] ~= nil and tonumber(container[key]) ~= 0 then return false,value end
        end
    end
    return tonumber(value.succ) == 1 or value.succ == true or value.synckey ~= nil, value
end
-- Online ledger settlement is identical for timer jobs and exit.
function M.settlement(outcome)
    if type(outcome) ~= 'table' then return 'unknown' end
    if outcome.accepted == true then return 'accepted' end
    if outcome.time_report_sent == false or outcome.time_rejected == true then return 'retryable' end
    return 'unknown'
end
function M.summary(_client, result, http_code)
    local value = body(result)
    local parts = {'http=' .. tostring(http_code):sub(1, 16), 'body_type=' .. type(value)}
    if type(value) == 'table' then
        parts[#parts + 1] = 'succ=' .. tostring(value.succ):sub(1, 8)
        parts[#parts + 1] = 'has_synckey=' .. tostring(value.synckey ~= nil)
        local code = tonumber(value.errCode or value.errcode or value.errorCode)
        if code then parts[#parts + 1] = 'error_code=' .. tostring(code) end
    end
    return table.concat(parts, ', ')
end
return M
