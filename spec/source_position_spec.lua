package.path='./?.lua;'..package.path
local Source=require('weread.lib.annotation_source')
local Position=require('weread.lib.source_position')
local options={normalize=function(s) return (s:gsub('%s','')) end,
 decode=function(s) return ({['&amp;']='&',['&#128511;']='🗿'})[s] or s end}
local function make(s,plain)
    return assert(Position.new(plain and Source.plain(s) or Source.index(s), options))
end
local map=make('<p title="🌿">甲 🌿&amp;乙</p>')
assert(map.text=='甲🌿&乙')
for i,offset in ipairs(map.starts) do
    assert(map:source_to_byte(offset)==map.bytes[i])
    assert(map:byte_to_source(map.bytes[i])==offset)
    assert(map:locate(offset,'序言'..map.text)==#'序言'+map.bytes[i])
end
assert(map:source_to_byte(0)==1, 'tag offset must address following text')
local _,reason=map:source_to_byte(map.starts[2]+1)
assert(reason=='partial_source_character','surrogate split accepted')
_,reason=map:source_to_byte(map.starts[3]+1)
assert(reason=='partial_source_character','entity split accepted')
assert(not map:byte_to_source(2),'UTF-8 byte interior accepted')
_,reason=map:locate(map.starts[1],map.text..map.text)
assert(reason=='source_text_ambiguous','repeated text guessed')
assert(not map:locate(map.starts[1],'different edition'))
assert(not map:source_to_byte(99999))
assert(make('甲<&乙',true).text=='甲<&乙')
assert(make('<p>&#128511;乙</p>').text=='🗿乙')
assert(not Position.new({{0,1,'a'}},options),'legacy source guessed')
local spans=Source.index('<p>abc</p>');spans[1][6]=99
assert(not Position.new(spans,options),'invalid cached index accepted')
local ticks=0
options.yield=function() ticks=ticks+1;return ticks<2 end
_,reason=Position.new(Source.plain(string.rep('甲',1024)),options)
assert(reason=='cancelled' and ticks==2)
options.yield=nil
_,reason=Position.new(Source.plain(string.rep('a',Position.MAX_CHARACTERS+1)),options)
assert(reason=='source_limit')
print('source_position_spec: bidirectional UTF-16/text coordinates, entities, ambiguity, limits and cancellation passed')

for i,offset in ipairs(map.starts) do
    assert(map:text_to_source(map.text,map.bytes[i])==offset)
end
local repeated=make(string.rep('same text ',80),true)
local _,why=repeated:text_to_source(string.rep('sametext',30),80)
assert(why=='source_text_ambiguous')
assert(not map:text_to_source(map.text,2))
assert(not map:text_to_source('changed edition',1))
print('source_position_spec: rendered text to original source correspondence passed')

local context_map=make('Start'..string.rep('a',200)..'unique marker'..string.rep('a',200)..'End',true)
assert(context_map:locate(100,context_map.text)==101,
    'bounded wider context must distinguish repeated short fragments')
