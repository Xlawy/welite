package.path='./?.lua;'..package.path
package.preload['ltn12']=function() return {} end
package.preload['socketutil']=function() return {} end
package.preload['socket.http']=function() return {} end
package.preload['json']=function() return {} end
local Client=require('welite.lib.client')
local client=Client:new{get=function(_,key) assert(key=='api_key');return 'fixture-key' end}
local response,request={books={}},nil
client.post_json=function(_,url,payload,options)
    request={url=url,payload=payload,options=options}
    return response,200,{fixture=true}
end
local rows={
    {'get_shelf','/shelf/sync',{}},
    {'get_book_info','/book/info',{'fixture'}},
    {'get_book_reviews','/review/list',{'fixture',1,20}},
    {'get_progress','/book/getprogress',{'fixture'}},
    {'get_read_stats','/readdata/detail',{'monthly',123}},
}
for _,row in ipairs(rows) do
    response={fixture=true}
    local value,code=client[row[1]](client,unpack(row[3]))
    assert(value==response and code==200)
    assert(request.payload.api_name==row[2] and request.payload.skill_version)
    assert(request.options.skip_cookie and request.options.headers.Authorization=='Bearer fixture-key')
    for _,bad in ipairs({{errCode=-2012},{errcode='-2041'},{succ=0},{succ=false},'invalid'}) do
        response=bad
        local ok,err=pcall(client[row[1]],client,unpack(row[3]))
        assert(not ok and tostring(err):find('gateway',1,true),row[1]..' must reject a business error')
    end
end
response={errCode=0,succ=1,books={}}
assert(client:get_shelf()==response,'empty successful shelf must remain valid')
response={errCode=-2012}
local ok,data,err=client:get_chapter_underlines('fixture',1)
assert(not ok and data==nil and err:find('-2012',1,true))
print('client_gateway_contract_spec: metadata/shelf/stats/progress business errors and annotation failures passed')
