package.path='./?.lua;'..package.path
local A=require('welite.lib.worker_settings')
local writes=0
local data={account={user_vid='one'},cookies={a='b;c=d'}}
local prototype={get=function(_,k,d) return data[k] or d end,flush=function() writes=writes+1 end,
 update_auth=function(self,value,options) data.cookies=value.cookies;if options.flush~=false then self:flush() end end}
local settings=setmetatable({},{__index=prototype})
local fingerprint=A.fingerprint(settings)
data.cookies={a='b',c='d'}
assert(fingerprint~=A.fingerprint(settings),'cookie delimiters cannot alias')
fingerprint=A.fingerprint(settings);data.account.user_vid='two'
assert(not A.merge(settings,fingerprint,{cookies={a='old'}}),'same credentials on another account cannot merge')
local outer,restore_outer=A.capture(settings)
for _=1,10 do
    local inner,restore_inner=A.capture(settings)
    settings:update_auth({cookies={a='new'}},{})
    assert(inner().cookies.a=='new' and outer().cookies.a=='new' and writes==0)
    restore_inner()
end
restore_outer();assert(rawget(settings,'flush')==nil and rawget(settings,'update_auth')==nil)
settings:flush();assert(writes==1,'restores inherited storage methods')
assert(A.merge(settings,A.fingerprint(settings),{cookies={a='latest'}}) and writes==2)
print('worker_settings_spec: account guards, unambiguous fingerprints and nested capture restoration passed')
