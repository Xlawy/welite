package.path='./?.lua;'..package.path
local Cookie=require('welite.lib.cookie')
local original={wr_skey='XXX-original-session'}
local copied=Cookie.merge(original,{wr_vid='42'})
assert(original.wr_vid==nil and Cookie.to_header(copied)=='wr_skey=XXX-original-session; wr_vid=42')
Cookie.merge_set_cookie(copied,{'wr_skey=; Path=/','wr_gid=12345; HttpOnly','foreign=ignored'})
assert(copied.wr_skey==nil and copied.foreign==nil and Cookie.has_login_cookie(copied))
assert(not Cookie.has_login_cookie({wr_skey='short'}))
local Crypto=require('welite.lib.crypto')
assert(Crypto.md5_hex('abc')=='900150983cd24fb0d6963f7d28e17f72')
assert(Crypto.sha256_hex('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
local Reader=require('welite.lib.reader_state')
local html='window.__INITIAL_STATE__ = fixture; (function'
local state=Reader.extract(html,function(encoded)
    assert(encoded=='fixture')
    return {reader={bookInfo={bookId='42',title='中文'},currentChapter={chapterUid=7},
        progress={book={chapterOffset=39,progress=0.42}}}}
end)
local book=Reader.apply_to_book({},state)
assert(state.book_id=='42' and state.title=='中文' and book.chapter_uid==7 and book.chapter_offset==39)
assert(Reader.extract('"bookId":"fallback"',function() error('invalid JSON') end).book_id=='fallback')
local Stats=require('welite.lib.read_stats')
local calls=0
local stats=Stats.fetch({get_read_stats=function(_,mode,base)
    calls=calls+1;assert(mode=='overall' and base==nil)
    return {totalReadTime='120',readTimes={['100']='3',['20']='7'},readLongest={{book={title='书'},readTime=8}}}
end},'overall')
assert(calls==1 and stats.total_read_time==120 and not stats.allow_prev and not stats.allow_next)
assert(stats.buckets[1].ts==20 and stats.buckets[2].value==3 and stats.top_books[1].title=='书')
print('namespace_helpers_spec: cookie isolation, digest vectors, reader state and statistics passed')
