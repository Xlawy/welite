-- One startup decision per process, independent of new reader/file-manager instances.
local S={};S.__index=S
function S.new() return setmetatable({},S) end
function S:queue(scheduler,read,ask,open)
    if self.claimed then return end
    self.claimed=true
    local task=function()
        local value=read()
        if not value.decided then ask(open)
        elseif value.autostart then open() end
    end
    scheduler:nextTick(task)
    return task
end
S.instance=S.new()
return S
