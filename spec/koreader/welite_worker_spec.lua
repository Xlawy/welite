describe("welite background worker", function()
    local Worker, socket, worker
    setup(function()
        require("commonrequire")
        package.path = "plugins/welite.koplugin/?.lua;" .. package.path
        Worker = require("weread.ui.welite.worker"); socket = require("socket")
    end)
    local function drain()
        local until_time=socket.gettime()+5
        while worker.job and socket.gettime()<until_time do worker:pump(); socket.sleep(0.005) end
        assert.is_nil(worker.job)
    end
    before_each(function() worker=Worker.new{scheduleIn=function() end} end)
    after_each(function() worker:cancel(); drain() end)
    it("returns a result larger than the pipe buffer without blocking the UI", function()
        local received
        local start=socket.gettime()
        assert(worker:start(function() socket.sleep(0.1); return {text=string.rep("x",200000)} end,
            function(result) received=result end))
        assert.is_true(socket.gettime()-start<0.1)
        assert.is_nil(received)
        drain(); assert.equals(200000,#received.text)
    end)
    it("bounds concurrency and cancels old results before starting replacement work", function()
        local calls=0
        worker:start(function() socket.sleep(2); return "old" end,function() calls=calls+100 end)
        local ok,err=worker:start(function() end,function() end)
        assert.is_nil(ok); assert.equals("busy",err.kind)
        worker:cancel()
        assert(worker:start(function() return "new" end,function(value) assert.equals("new",value);calls=calls+1 end))
        drain(); assert.equals(1,calls)
    end)
    it("kills and reaps timed out work, and sanitizes child exceptions", function()
        local failure
        worker:start(function() socket.sleep(2) end,function(_,err) failure=err end,0.02)
        drain(); assert.equals("timeout",failure.kind)
        worker:start(function() error("private credential") end,function(_,err) failure=err end)
        drain(); assert.same({kind="worker_error"},failure)
    end)
end)
