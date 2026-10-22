package.path = "./?.lua;" .. package.path

package.preload["ltn12"] = function() return {} end
package.preload["socketutil"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end
package.preload["weread.lib.cookie"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end

local Client = require("weread.lib.client")
local client = setmetatable({}, { __index = Client })
local ranges = {}
for index = 1, 61 do ranges[index] = tostring(index) end

local batches = client:build_chapter_review_batches(ranges)
assert(#batches == 3, "61 ranges must be split into three requests")
assert(#batches[1] == 30 and #batches[2] == 30 and #batches[3] == 1,
    "thought requests must contain at most 30 ranges")
assert(batches[1][1].range == "1" and batches[2][1].range == "31"
        and batches[3][1].range == "61",
    "thought range order changed while batching")
assert(batches[1][1].count == 30 and batches[1][1].maxIdx == 0
        and batches[1][1].synckey == 0,
    "thought pagination parameters changed")

print("client_annotation_batch_spec: 30-range thought batches passed")

local calls=0
client.gateway=function(_,api,params)
    assert(api=='/book/readreviews')
    calls=calls+1
    if calls==2 then error('fixture authentication expired') end
    return {reviews={{range=params.reviews[1].range}}}
end
local ok,value,err=client:get_chapter_reviews('fixture',1,ranges)
assert(not ok and value==nil and err:find('batch 2/3',1,true))
assert(err:find('authentication expired',1,true))
assert(calls==2,'must stop after failed batch and not report partial data as success')
calls=0
client.gateway=function(_,_,params) calls=calls+1;return {reviews={{range=params.reviews[1].range}}} end
ok,value=client:get_chapter_reviews('fixture',1,ranges)
assert(ok and #value.reviews==3 and calls==3)
assert(value.reviews[3].range=='61')
print('client_annotation_batch_spec: partial failure, bounded abort and successful retry passed')
