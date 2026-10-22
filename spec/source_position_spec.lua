package.path='./?.lua;'..package.path
local Source=require('welite.lib.annotation_source')
local Position=require('welite.lib.source_position')
local options={normalize=function(s) return (s:gsub('%s','')) end,
 decode=function(s) return ({['&amp;']='&',['&#128511;']='🗿'})[s] or s end}
local function make(s,plain)
    return assert(Position.new(plain and Source.plain(s) or Source.index(s), options))
end
local map=make('<p title="🌿">甲 🌿&amp;乙</p>')
assert(map.text=='甲🌿&乙')
for index,offset in ipairs(map.starts) do
    assert(map:chapter_fraction(offset)==(index-1)/4,'chapter ratio counts visible Unicode characters')
end
assert(map:chapter_fraction(0)==0,'chapter start includes leading markup')
assert(map:chapter_fraction(map.ends[#map.ends])==1,'chapter end is complete')
assert(not map:chapter_fraction(map.starts[2]+1),'surrogate interior must not yield a ratio')
assert(not map:chapter_fraction(99999),'out-of-range source must not masquerade as 100%')
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
_,reason=Position.new(Source.plain(string.rep('a',Position.MAX_BYTES+1)),options)
assert(reason=='source_limit','byte limit must remain bounded')
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

-- A long chapter must remain bidirectional past the previous 32k/256KiB caps.
local long_text=string.rep('甲乙丙丁戊己庚辛壬癸',11000)..'独特的定位目标🌿结束'
local yields=0
options.yield=function() yields=yields+1;return true end
collectgarbage('collect')
local memory=collectgarbage('count')
local started=os.clock()
local long_map=assert(Position.new(Source.plain(long_text),options))
local used=collectgarbage('count')-memory
assert(long_map.text==long_text)
local target=110000
local byte=assert(long_map:source_to_byte(target))
assert(long_map:byte_to_source(byte)==target)
assert(long_map:locate(target,long_text)==byte)
assert(long_map:text_to_source(long_text,byte)==target)
assert(yields>=400,'long chapters must yield throughout indexing')
print(('source_position long chapter: characters=%d bytes=%d elapsed=%.3fs memory_delta=%.0fKiB yields=%d')
    :format(#long_map.starts,#long_text,os.clock()-started,used,yields))
options.yield=nil

local marker_options={decode=function(s)
    return ({['&#91;']='[',['&#93;']=']',['&amp;']='&'})[s] or s
end}
local marked_html='<p>甲&#91;<b>3</b>6&#93;乙 🌿&amp;丙</p>'
local marked=assert(Position.new(Source.index(marked_html),marker_options))
assert(marked.text=='甲乙🌿&丙')
local target_byte=assert(marked_html:find('乙',1,true))
local target_offset=Source.plain(marked_html:sub(1,target_byte-1))[1][6]
assert(marked:source_to_byte(target_offset)==#'甲'+1)
assert(marked:byte_to_source(#'甲'+1)==target_offset,'removed markers must not shift source offsets')
local marker_start=Source.plain('<p>甲')[1][6]
assert(marked:source_to_byte(marker_start)==#'甲'+1,'marker offsets address the following body character')
assert(marked:locate(target_offset,marked.text)==#'甲'+1)
assert(marked:text_to_source(marked.text,#'甲'+1)==target_offset)
assert(Position.new(Source.plain('甲[1][25]乙'),marker_options).text=='甲乙')
assert(Position.new(Source.plain('甲[ 36 ]乙'),marker_options).text=='甲[36]乙',
    'normalize original text once: whitespace removal must not invent a marker')
local spaced=assert(Position.new(Source.plain('甲　[36] 🌿乙'),marker_options))
assert(spaced.text=='甲🌿乙','Unicode spaces and footnotes share one normalization')
for i,offset in ipairs(spaced.starts) do
    assert(spaced:source_to_byte(offset)==spaced.bytes[i])
    assert(spaced:byte_to_source(spaced.bytes[i])==offset)
end
local ambiguous=assert(Position.new(Source.plain('甲[1]乙甲[2]乙'),marker_options))
local _,ambiguous_reason=ambiguous:locate(0,ambiguous.text..ambiguous.text)
assert(ambiguous_reason=='source_text_ambiguous','removed footnotes must not bypass ambiguity checks')
local _,unsupported=Position.new(Source.plain('A'),{normalize=string.lower,decode=marker_options.decode})
assert(unsupported=='unsupported_normalization','unmapped substitutions must still be rejected')
local steps=0
local _,cancelled=Position.new(Source.plain(string.rep('a',300)),{decode=marker_options.decode,
 yield=function() steps=steps+1;return steps<2 end})
assert(cancelled=='cancelled' and steps==2,'normalization pass must remain cancelable')
print('source_position_spec: whole footnote markers, split tags/entities, exact offsets and ambiguity passed')

local complete='<html><head><title>未知</title></head><body><h1>章节甲</h1></body></html>'
    ..'<html><head><title>未知</title></head><body><p>正文🌿&amp;乙</p></body></html>'
local body_map=assert(Position.new(Source.index(complete),marker_options))
assert(body_map.text=='章节甲正文🌿&乙')
assert(body_map:locate(0,body_map.text)==1,'chapter start must skip invisible head text')
for i,source_offset in ipairs(body_map.starts) do
    assert(body_map:locate(source_offset,body_map.text)==body_map.bytes[i])
    assert(body_map:text_to_source(body_map.text,body_map.bytes[i])==source_offset)
end
local _,outdated=Position.new({{0,2,'未知',false,0,2}},marker_options)
assert(outdated=='source_index_outdated','old HTML with UTF-16 fields must not silently enter matching')
local changed,changed_reason=body_map:locate(0,'a different edition')
assert(not changed and changed_reason=='source_text_mismatch','real text differences must remain rejected')
local _,repeated_reason=body_map:locate(0,body_map.text..body_map.text)
assert(repeated_reason=='source_text_ambiguous','body-only indexing must preserve ambiguity protection')
print('source_position_spec: head-free chapter starts, bidirectional coordinates and legacy rejection passed')
