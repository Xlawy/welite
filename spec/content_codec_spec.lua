package.path='./?.lua;'..package.path
local runtime=(os.getenv('LUAJIT_BIN') or '.dev/emulator/luajit'):match('^(.*)/[^/]+$')
-- Local runs reuse KOReader; CI supplies the same LuaSocket module via lua-socket.
if runtime then
    package.path=runtime..'/common/?.lua;'..package.path
    package.cpath=runtime..'/common/?.so;'..package.cpath
end
local Codec=require('welite.lib.content_codec')
local Crypto=require('welite.lib.crypto')
local function checked(body) return Crypto.md5_hex(body):upper()..body end
-- Fixed short protocol vectors (the prefix is not part of the Base64 text).
assert(Codec.decode_content_shard(checked('0==Zg'))=='f')
assert(Codec.decode_content_shard(checked('0JjYW'))=='abc')
assert(Codec.decode_content_shards(checked('0J'),checked('j'),checked('YW'))=='abc')
assert(Codec.decode_content_shard(nil)=='')
assert(not pcall(Codec.decode_content_shard,string.rep('0',32)..'0JjYW'),'corrupt shard must fail')
local Content=require('welite.lib.content')
assert(Content.decode_content_shard(checked('0JjYW'))=='abc','public content API retained')
-- Compare the sparse swap path to a retained independent protocol oracle.
local function reference(encoded)
    local n=math.min(4,math.floor((#encoded+9)/10))
    local tmp={}
    for i=#encoded,#encoded-n+1,-1 do
        local byte,bin=encoded:byte(i),{}
        repeat table.insert(bin,1,tostring(byte%2));byte=math.floor(byte/2) until byte==0
        tmp[#tmp+1]=tostring(tonumber(table.concat(bin),4) or 0)
    end
    tmp=table.concat(tmp)
    local positions,m={},#encoded-n-2
    local step,i=#tostring(m),1
    while #positions<10 and i+step-1<#tmp do
        positions[#positions+1]=(tonumber(tmp:sub(i,i+step-1)) or 0)%m
        positions[#positions+1]=(tonumber(tmp:sub(i+1,math.min(i+step,#tmp))) or 0)%m
        i=i+step
    end
    local chars={};for j=1,#encoded do chars[j]=encoded:sub(j,j) end
    for j=#positions,1,-2 do for k=1,0,-1 do
        local left,right=positions[j]+k+1,positions[j-1]+k+1
        chars[left],chars[right]=chars[right],chars[left]
    end end
    return require('mime').unb64(table.concat(chars)) or ''
end
for size=12,5000,37 do
    local encoded=('YWJjZGVmZ2hp'):rep(math.ceil(size/12)):sub(1,size)
    -- Pad before both implementations; padding contributes to the protocol swaps.
    encoded=encoded..string.rep('=',(4-#encoded%4)%4)
    assert(Codec.decode_content_shard(checked('0'..encoded))==reference(encoded),'sparse swap mismatch at '..size)
end
print('content_codec_spec: native decoder, integrity, public API and 135 sparse swap vectors passed')
