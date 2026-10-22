package.path='./?.lua;'..package.path
local Worker=require('welite.lib.annotation_prefetch_worker')
local function settings()
    return {get=function(_,_,default) return default end,flush=function() error('worker cannot flush settings') end}
end
local emitted,slept=0,0
local ctx={book_id='book',store={legacy={},get=function(_,_,kind)
    if kind=='source_status' then return {revision=1} end
end}}
local network=setmetatable({},{__index=function() error('cached chapter must not request network') end})
local worker={checkCancelled=function() end,emit=function(state) emitted=emitted+1;assert(state.stage=='saved') end,
    sleep=function(delay) slept=slept+1;assert(delay>0) end}
local result=Worker.run(settings(),network,ctx,{{chapterUid=1}},worker)
assert(type(result)=='table' and result.auth==nil and emitted==1 and slept==1)
assert(ctx.store.legacy.busy_timeout_ms==1000)
worker.checkCancelled=function() error('fixture cancelled') end
assert(not pcall(Worker.run,settings(),network,ctx,{{chapterUid=1}},worker))
worker.checkCancelled=function() end;worker.emit=function() end;worker.sleep=function() end
ctx.store.get=function() return nil end
local attempts=0
local client={get_chapter_underlines=function() attempts=attempts+1;return false,nil,'fixture timeout' end}
local ok,err=pcall(Worker.run,settings(),client,ctx,{{chapterUid=1}},worker)
assert(not ok and tostring(err):find('fixture timeout',1,true) and attempts==3)
print('annotation_prefetch_worker_spec: cached completion, cancellation and bounded failure passed')
