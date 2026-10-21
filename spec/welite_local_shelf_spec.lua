package.path='./?.lua;'..package.path
local M=require('weread.ui.welite.local_shelf')
local saved={a={cached_file='full'},b={cached_chapters={['1']='chapter'}},c={cached_file='missing'}}
local calls=0
local list=M.select({{bookId='a',title='Cloud title'},{bookId='a'}},saved,function(record)
    calls=calls+1;return record.cached_file=='full' or record.cached_chapters~=nil
end)
assert(#list==2 and list[1].title=='Cloud title' and list[2].bookId=='b')
assert(calls==3,'validate each record once; keep chapters removed from cloud')
assert(saved.a.title==nil,'do not mutate saved records')
assert(#M.select({},saved,function() return false end)==0,'missing files are not local books')
print('welite_local_shelf_spec: full/partial/missing, deduplication, cloud removal passed')
