package.path='./?.lua;'..package.path
package.preload['ltn12']=function() return {} end
package.preload['socketutil']=function() return {} end
package.preload['socket.http']=function() return {} end
package.preload['json']=function() return {} end
package.preload['welite.lib.cookie']=function() return {} end
package.preload['welite.lib.protocol']=function() return {
    urlencode=function(s) return s end,reader_url=function(id) return 'reader/'..id end} end
local Client=require('welite.lib.client')
local function fixture(responses,renew_error)
    local calls,renewals=0,0
    local client=setmetatable({}, {__index=Client})
    client.get_text=function(_,url,opts)
        calls=calls+1
        assert(url:find('bookId=fixture',1,true) and opts.referer=='reader/fixture')
        return '',200,{}
    end
    client.decode_http_json=function() return responses[calls] end
    client.renew_cookie=function() renewals=renewals+1;if renew_error then error(renew_error) end end
    return client,function() return calls,renewals end
end
for _,code in ipairs({-2012,-2041}) do
    local client,count=fixture({{errCode=code},{book={progress=17}}})
    assert(client:get_web_progress('fixture').book.progress==17)
    local calls,renewals=count();assert(calls==2 and renewals==1)
end
local client,count=fixture({{errCode=-2012},{errCode=-2012}})
local ok,err=pcall(client.get_web_progress,client,'fixture')
assert(not ok and tostring(err):find('errCode=-2012',1,true))
local calls,renewals=count();assert(calls==2 and renewals==1,'retry must be bounded')
client,count=fixture({{errCode=-2012}},'renewal failed')
assert(not pcall(client.get_web_progress,client,'fixture'))
calls,renewals=count();assert(calls==1 and renewals==1)
client,count=fixture({{errCode=-999}})
assert(not pcall(client.get_web_progress,client,'fixture'))
calls,renewals=count();assert(calls==1 and renewals==0,'unrelated errors must not renew')
client,count=fixture({{book={progress=0}}})
assert(client:get_web_progress('fixture').book.progress==0)
calls,renewals=count();assert(calls==1 and renewals==0)
print('client_web_progress_spec: expired credentials, bounded renewal, failure and zero progress passed')

for _,response in ipairs({false, 'invalid', {errcode=-2012}, {succ=false}, {errCode='invalid'}}) do
    client,count=fixture({response,response})
    assert(not pcall(client.get_web_progress,client,'fixture'),'business failure returned as progress')
    calls,renewals=count()
    local expired=type(response)=='table' and response.errcode==-2012
    assert(calls==(expired and 2 or 1) and renewals==(expired and 1 or 0))
end
