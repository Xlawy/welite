package.path='./?.lua;'..package.path
local Search=require('weread.lib.book_search')
assert(Search.query('  山间 来信  ')=='山间 来信')
assert(select(2,Search.query(' \n\t '))=='empty_query')
assert(select(2,Search.query(string.rep('长',200)))=='query_too_long')
local source={bookId=1,title='山间来信',author='合成作者'}
local result=Search.results({results={{books={{bookInfo=source},source,{bookId='2'},false,{} }},{books={{bookInfo={bookId=1,title='duplicate'}}}}}})
assert(#result==2 and result[1].bookId=='1' and result[1].title=='山间来信')
assert(source.bookId==1 and result[1]~=source,'normalization must not mutate cached source records')
assert(result[2].title=='2' and result[2].author=='')
local rows={};for i=1,100 do rows[i]={bookId=tostring(i),title='Book '..i} end
assert(#Search.results({results={{books=rows}}})==10)
assert(#Search.results({results={}})==0)
assert(not pcall(Search.results,{}),'malformed data must not masquerade as an empty result')
print('book_search_spec: query validation, deduplication, bounded records and invalid response passed')
