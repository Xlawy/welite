package.path='./?.lua;'..package.path
local Scope=require('weread.lib.progress_scope')
local shelf={}
for i=1,1000 do shelf[i]={bookId=tostring(i),readUpdateTime=i} end
shelf[#shelf+1]={bookId='never-read'}
shelf[#shelf+1]={bookId='MP_WXS_1',readUpdateTime=999999}
local saved={['1']={cached_full_book='full.epub'},['2']={cached_chapters={['3']='chapter.epub'}},
    ['local-only']={cached_file='local.epub'},['metadata-only']={title='not downloaded'},
    ['empty-path']={cached_file='',cached_chapters={['1']=''}},
    ['MP_WXS_1']={cached_file='article.epub'}}
local targets,ids=Scope.select(shelf,saved)
assert(#targets==13 and ids['1'] and ids['2'] and ids['local-only'])
assert(ids['991'] and ids['1000'] and not ids['990'])
assert(not ids['never-read'] and not ids['metadata-only'] and not ids['empty-path'] and not ids['MP_WXS_1'])
assert(#shelf==1002 and saved['local-only'].bookId==nil,'selection does not rewrite source records')
-- Local reading, numeric IDs, duplicate cloud entries and millisecond timestamps.
local entries,selected=Scope.select({{bookId=1,readUpdateTime=1700000000000},{bookId='1'}},
    {[1]={cached_file='one.epub'},two={last_local_position={captured_at=1700000001}}})
assert(#entries==2 and selected['1'] and selected.two)
local empty=Scope.select({{bookId='unread'},{bookId='bad',readUpdateTime='oops'}},{})
assert(#empty==0)
local all=Scope.select({}, {a={cached_file='a'},b={cached_full_book='b'}})
assert(#all==2,'local downloads remain eligible even after removal from cloud bookshelf')
print('progress_scope_spec: 1002 shelf entries -> 13 unique targets; recent cap, downloads, local timestamps and exclusions passed')
