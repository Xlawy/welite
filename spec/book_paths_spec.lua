package.path='./?.lua;'..package.path
local P=require('welite.lib.book_paths')
local settings={cache_dir='/new'}
assert(P.book_dir_name('a/b')=='a_b' and P.book_dir_name('')=='weread')
assert(P.book_cache_dir(settings,'b')=='/new/b')
assert(P.book_resolved_dir(settings,'b',{})=='/new/b')
assert(P.book_resolved_dir(settings,'b',{cache_dir='/pinned',cached_file='/old/file'})=='/pinned')
assert(P.book_resolved_dir(settings,'b',{cached_full_book='/full/book',cached_file='/chapter/book'})=='/full')
assert(P.book_resolved_dir(settings,'b',{cached_chapters={one='/chapter/one'}})=='/chapter')
assert(P.book_resolved_dir(settings,'b',{cached_file=''})=='/new/b')
print('book_paths_spec: sanitized names, directory precedence, moved caches and missing paths passed')
