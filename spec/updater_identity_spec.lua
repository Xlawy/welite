package.path = "./?.lua;" .. package.path
package.preload["welite.lib.logger"] = function()
    return {info=function() end,warn=function() end,err=function() end}
end
local U = require("welite.lib.updater")
local legacy = {auto_check=true,prefer_proxy=false,available_version="1.6.0",
    last_check=os.time(),skipped_version="1.6.0",snoozed_version="1.6.0",
    snooze_until=os.time()+86400,release_notes="foreign notes",
    archive_url="https://github.com/finlater/weread.koplugin/releases/download/v1.6.0/weread.koplugin-v1.6.0.zip"}
local state=legacy
local flushes=0
local settings={data_dir="/must-not-touch",get=function() return state end,
    set=function(_,_,value) state=value end,flush=function() flushes=flushes+1 end}
local u=U:new{settings=settings,current_version="1.0.4",plugin_dir="/fixture/welite.koplugin"}
assert(state~=legacy and state.source=="Xlawy/welite")
assert(state.auto_check and state.prefer_proxy==false)
assert(state.last_check==nil and state.skipped_version==nil and state.snoozed_version==nil)
assert(not u:has_update() and not u:cached_release())
assert(legacy.available_version=="1.6.0" and legacy.release_notes=="foreign notes")
assert(flushes==1)
local function release(version)
    local url=U.RELEASE_PREFIX.."v"..version.."/welite.koplugin-v"..version..".zip"
    return {source=U.SOURCE,version=version,archive_url=url,checksum_url=url..".sha256"}
end
local valid=release("1.0.5")
assert(u:cache_release(valid))
assert(u:has_update() and u:available_version()=="1.0.5")
local n=flushes
local reopened=U:new{settings=settings,current_version="1.0.4",plugin_dir=u.plugin_dir}
assert(reopened:cached_release().archive_url==valid.archive_url and flushes==n)
local requests=0
u._http_get=function() requests=requests+1;error("unexpected network request") end
for _,mutate in ipairs({
    function(r) r.source="finlater/weread.koplugin" end,
    function(r) r.source=nil end,
    function(r) r.archive_url=legacy.archive_url end,
    function(r) r.checksum_url=legacy.archive_url..".sha256" end,
    function(r) r.version="1.6.0" end,
    function(r) r.archive_url=r.archive_url.."/../foreign.zip" end,
}) do
    local invalid=release("1.0.5");mutate(invalid)
    assert(not u:cache_release(invalid),"invalid release entered cache")
    assert(not u:install_release(invalid),"invalid release reached installation")
end
assert(requests==0,"foreign release must fail before any download or file operation")
state.archive_url=legacy.archive_url
assert(not u:has_update() and not u:cached_release(),"source marker alone must not trust URLs")
state=legacy
assert(not u:has_update(),"late stale state must be rejected too")
print("updater_identity_spec: migration, identity, URL binding and side-effect rejection passed")
