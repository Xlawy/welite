package.path='./?.lua;'..package.path
local version={mode='file',size=100,modification=1}
package.preload['libs/libkoreader-lfs']=function() return {attributes=function() return version end} end
local Mapping=require('welite.lib.rendered_position')
local chapters={{chapterUid=1,wordCount=1000,title='开篇'}, {chapterUid=2,wordCount=1000,title='续篇'}, {chapterUid=3,wordCount=1000,title='终篇'}}
local reads,hash,page=0,1,1
local anchors={a=2,b=5,c=17,z=30}
local document={info={doc_height=3000},
    getToc=function() return {{title='开篇',xpointer='a'},{title='续篇',xpointer='b'},{title='终篇',xpointer='c'}} end,
    getPageCount=function() return 30 end,getCurrentPage=function() return page end,
    getPageXPointer=function() return 'z' end,getNextVisibleWordEnd=function() return nil end,
    getPageFromXPointer=function(_,xp) reads=reads+1;return anchors[xp] end,
    getDocumentRenderingHash=function() return hash end,
    getCurrentPos=function() return page*100 end,getPosFromXPointer=function(_,xp) return anchors[xp]*100 end,
}
local context={account='fixture',book={title='Fixture'},path='/test',chapters=chapters,is_full_book=true}
local map=Mapping.new(document,context,'page')
local cover=assert(map:capture())
assert(cover.chapter_uid==1 and cover.chapter_offset==0,'cover page maps to first chapter start')
for i,expected in ipairs({2,5,17}) do
    local _,err,target=map:target({chapter_uid=i,chapter_offset=0})
    assert(not err and target==expected)
    page=expected;local local_position=assert(map:capture());assert(local_position.chapter_uid==i and local_position.chapter_offset==0)
end
local remote={chapter_uid=2,chapter_offset=357,has_chapter_offset=true}
local _,_,landing_page=map:target(remote)
page=landing_page
assert(map:capture().chapter_offset~=357,'computing target must not claim successful landing')
map:accept_target(remote)
assert(math.abs(map:capture().chapter_offset-357)<=1,'confirmed cloud offset survives page quantization')
assert(map:capture().chapter_fraction==(page-5)/12,'display ratio must use the actual chapter layout')
local preview_remote={chapter_uid=2,chapter_offset=3000,has_chapter_offset=true,
    chapter_fraction=0.4,chapter_fraction_basis='source_text'}
map:accept_target(preview_remote,page)
assert(map:capture().chapter_fraction==0.4,'confirmed source ratio must not divide HTML offsets by wordCount')
assert(map:capture().chapter_offset==3000,'display precision must not alter source coordinates')
map:accept_target(remote)
map:accept_target({chapter_uid=2,has_chapter_offset=false,percent=50})
assert(map:capture().chapter_offset~=357,'a newer target without an offset must clear old precision')
map:accept_target(remote)
page=landing_page+1;map:capture();page=landing_page
assert(map:capture().chapter_offset~=357,'returning to a page must not resurrect old cloud offset')
map:accept_target(remote);hash=hash+1
assert(map:capture().chapter_offset~=357,'layout change invalidates the confirmed offset')
map:accept_target(remote)
context.book.last_local_position=assert(map:capture())
local reopened=Mapping.new(document,context,'page')
assert(reopened:capture().chapter_offset==357,'matching reopened document restores confirmed offset')
context.account='other'
assert(Mapping.new(document,context,'page'):capture().chapter_offset~=357,'another account cannot restore it')
context.account='fixture';version.modification=2
assert(Mapping.new(document,context,'page'):capture().chapter_offset~=357,'changed file cannot restore it')
version.modification=1;hash=hash+1
assert(Mapping.new(document,context,'page'):capture().chapter_offset~=357,'changed layout cannot restore it')
context.book.last_local_position=nil
map:layout()
local before=reads
for i=1,1000 do page=6;assert(map:capture().chapter_uid==2) end
assert(reads==before,'unchanged page turns must not resolve all anchors again')
anchors.b=7;hash=hash+1
local _,_,target=map:target({chapter_uid=2,chapter_offset=0})
assert(target==7 and reads>before,'same page count with new rendering hash must invalidate bounds')
anchors.c=7;hash=hash+1;page=7
local value,reason=map:capture()
assert(value==nil and reason=='chapter_page_ambiguous','two short chapters on a page must not silently select one')
local target_value,target_reason=map:target({chapter_uid=2,chapter_offset=0})
assert(target_value==nil and target_reason=='chapter_page_ambiguous',
    'cloud target must not claim success on a page shared by chapter starts')
-- A server source offset is not a word count, and its percentage is independent.
anchors.c=17;hash=hash+1
local source_remote={chapter_uid=2,chapter_offset=2400,percent=42,has_chapter_offset=true,summary="actual remote text"}
local _,_,source_page=map:target(source_remote)
page=source_page;map:accept_target(source_remote)
local accepted=assert(map:capture())
assert(accepted.summary=='actual remote text','confirmed cloud summary must not become the book title')
assert(accepted.chapter_offset==2400,'confirmed source offset must not be clamped to 1000 words')
assert(accepted.percent==42 and accepted.fraction==0.42,'confirmed server percentage must not be recomputed from HTML offset')
context.book.last_local_position=accepted
local restored=Mapping.new(document,context,'page')
assert(restored:capture().chapter_offset==2400 and restored:capture().percent==42,
    'reopening preserves both independent confirmed fields')
context.book.last_local_position=nil
page=source_page-1
assert(map:capture().position_basis=='rendered_chapter_span','moving away releases the confirmed position')
local bad=Mapping.new({},context,'page');assert(select(2,bad:capture())=='document_position_unsupported')
local missing=Mapping.new(document,{book={},path='/other',chapters={{chapterUid=4,title='Missing',wordCount=100}}},'page')
assert(select(2,missing:capture())=='chapter_mapping_unavailable')
-- Scroll positions use the same chapter anchors in pixel coordinates.
anchors.c=17;anchors.b=5;hash=4;page=11
local scroll=Mapping.new(document,context,'scroll')
assert(scroll:capture().chapter_uid==2)
assert(scroll:target({chapter_uid=2,chapter_offset=500})==1100/3000)
-- The last text anchor precedes the end of the layout in scroll mode.
anchors.z=28;document.info.doc_height=3200;hash=5;page=30
local last=assert(scroll:capture())
assert(last.chapter_uid==3,'trailing layout after the last text anchor belongs to final chapter')
assert(scroll:target({chapter_uid=3,chapter_offset=1000})==1,'last chapter end reaches document end')
print('rendered_position_spec: chapter identity, ambiguity, layout invalidation and 1000 cached captures passed')
