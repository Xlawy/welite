-- One active child, one pending replacement; results stay in a pipe, never on disk.
local ffi = require("ffi")
local util = require("ffi/util")
local Json = require("rapidjson")
require("ffi/posix_h")
local Worker = {}
Worker.__index = Worker
local LIMIT = 4 * 1024 * 1024

function Worker.new(scheduler, now)
    return setmetatable({scheduler = scheduler, now = now or require("socket").gettime}, Worker)
end

function Worker:_schedule()
    if self.tick then return end
    self.tick = function() self.tick = nil; self:pump() end
    self.scheduler:scheduleIn(0.1, self.tick)
end

function Worker:start(task, callback, timeout)
    if self.job then
        if not self.job.cancelled then return nil, {kind = "busy"} end
        self.pending = {task, callback, timeout}
        return true
    end
    local pid, fd = util.runInSubProcess(function(_, output)
        local ok, value, err = pcall(task)
        local result = ok and {value = value, error = err} or {error = {kind = "worker_error"}}
        local encoded = Json.encode(result)
        if #encoded > LIMIT then encoded = Json.encode({error = {kind = "response_limit"}}) end
        -- Chunked writes avoid assuming a large result fits the kernel pipe buffer.
        local offset = 1
        while offset <= #encoded do
            local chunk = encoded:sub(offset, offset + 8191)
            local n = tonumber(ffi.C.write(output, chunk, #chunk))
            if n <= 0 then break end
            offset = offset + n
        end
        ffi.C.close(output)
    end, true, false)
    if not pid then return nil, {kind = "worker_unavailable"} end
    self.job = {pid = pid, fd = fd, callback = callback, chunks = {}, size = 0,
        deadline = self.now() + (timeout or 25)}
    self:_schedule()
    return true
end

function Worker:cancel()
    self.pending = nil
    if self.job and not self.job.cancelled then
        self.job.cancelled, self.job.callback = true, nil
        util.terminateSubProcess(self.job.pid)
        self:_schedule()
    end
end

function Worker:pump()
    local job = self.job
    if not job then return end
    if not job.cancelled and not job.error and self.now() >= job.deadline then
        job.error = {kind = "timeout"}
        util.terminateSubProcess(job.pid)
    end
    local available = util.getNonBlockingReadSize(job.fd)
    if available == nil then
        job.error = {kind = "worker_unavailable"}
        util.terminateSubProcess(job.pid)
    elseif available > 0 then
        local count = math.min(available, 65536)
        local buffer = ffi.new("char[?]", count)
        local read = tonumber(ffi.C.read(job.fd, buffer, count))
        if read > 0 and not job.cancelled and not job.error then
            job.size = job.size + read
            if job.size > LIMIT then
                job.error = {kind = "response_limit"}
                util.terminateSubProcess(job.pid)
            else
                job.chunks[#job.chunks + 1] = ffi.string(buffer, read)
            end
        end
    end
    local done = job.done or util.isSubProcessDone(job.pid, false)
    job.done = done
    if not done or (util.getNonBlockingReadSize(job.fd) or 0) > 0 then
        self:_schedule()
        return
    end
    ffi.C.close(job.fd)
    self.job = nil
    if job.callback then
        local ok, result = pcall(Json.decode, table.concat(job.chunks))
        if job.error then job.callback(nil, job.error)
        elseif not ok or type(result) ~= "table" then job.callback(nil, {kind = "worker_error"})
        else job.callback(result.value, result.error) end
    end
    local pending = self.pending
    self.pending = nil
    if pending then self:start(unpack(pending)) end
end

return Worker
