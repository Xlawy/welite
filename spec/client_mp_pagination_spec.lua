package.path='./?.lua;'..package.path
package.preload['ltn12']=function() return {} end
package.preload['socketutil']=function() return {} end
package.preload['socket.http']=function() return {} end
package.preload['json']=function() return {} end
package.preload['welite.lib.cookie']=function() return {} end
package.preload['welite.lib.protocol']=function() return {urlencode=function(s) return s end} end
local Client=require('welite.lib.client')
local client=setmetatable({settings={get=function(_,_,d) return d end}}, {__index=Client})
local request
client.request=function(_,value) request=value;return '{}',200,{} end
client.decode_http_json=function() return {reviews={}} end
assert(client:get_mp_articles('MP_WXS_fixture',17,100,'ticket'))
assert(request.url:find('offset=17',1,true) and not request.url:find('maxIdx',1,true))
assert(request.headers['x-wr-ticket']=='ticket')
assert(client:get_mp_articles('MP_WXS_fixture'))
assert(request.url:find('offset=0',1,true))
print('client_mp_pagination_spec: upstream offset and credential headers passed')

for _,response in ipairs({false,'invalid',{errcode=-2012},{succ=false},{errCode='-2041'}}) do
    client.decode_http_json=function() return response end
    local data,err=client:get_mp_articles('MP_WXS_fixture')
    assert(data==nil and err~=nil,'business failure must not appear as empty articles')
end
client.decode_http_json=function() return {errCode='0',reviews={}} end
assert(client:get_mp_articles('MP_WXS_fixture'),'string zero is successful')
