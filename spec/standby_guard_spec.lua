package.path='./?.lua;'..package.path
local prevented,allowed=0,0
local share={}
package.preload['ui/uimanager']=function() return {
    preventStandby=function() prevented=prevented+1 end,allowStandby=function() allowed=allowed+1 end} end
package.preload.device=function() return {isKindle=function() return false end,
    isKobo=function() return true end,isCervantes=function() return false end} end
package.preload.pluginshare=function() return share end
local Guard=require('welite.lib.standby_guard')
local a,b=Guard.acquire(),Guard.acquire()
assert(prevented==2 and share.pause_auto_suspend)
assert(Guard.release(a) and share.pause_auto_suspend)
assert(not Guard.release(a) and allowed==1)
assert(Guard.release(b) and allowed==2 and not share.pause_auto_suspend)
assert(not Guard.release(nil))
print('standby_guard_spec: overlapping ownership and idempotent release passed')
