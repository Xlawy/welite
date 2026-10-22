local os=require('os') -- Local handle for filesystem failure injection.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["welite.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["welite.lib.reader_state"] = function() return {} end
package.preload["welite.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/reader/" .. tostring(book_id)
                .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["welite.lib.thoughts"] = function() return {} end

local Content = require("welite.lib.content")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))

local downloads = {}
local client = {}
function client:get_binary()
    error("MP article images must not be buffered in Lua memory")
end
function client:download_to_file(url, path, opts)
    downloads[#downloads + 1] = { url = url, path = path, opts = opts }
    if url:match("qlogo") then error("injected download failure") end
    local file = assert(io.open(path, "wb"))
    file:write("\137PNG\r\n\026\n")
    local chunk = string.rep("x", 64 * 1024)
    for _index = 1, 64 do file:write(chunk) end
    file:close()
    return path
end

local progress = {}
local settings = { cache_dir = root }
local book = { book_id = "mp-book", cache_dir = root }
local article = { reviewId = "review/1", title = "Disk images" }
local other = {reviewId="review_1",title=article.title}
expect(Content.mp_article_path(settings,book,article) ~= Content.mp_article_path(settings,book,other),
    "same-title articles with different IDs must not overwrite each other")
expect(Content.mp_article_path(settings,book,article) == Content.mp_article_path(settings,book,
    {reviewId=article.reviewId,title="Renamed title"}), "title changes must preserve the article cache key")
expect(not pcall(Content.mp_article_path,settings,book,{title="No identity"}),
    "title alone must not masquerade as a stable article identity")
local body = [[
<p><img src="//mmbiz.qpic.cn/image?id=1&amp;format=png"></p>
<p><img src='https://mmbiz.qpic.cn/image?id=1&format=png'></p>
<p><img src="https://mmbiz.qlogo.cn/avatar/fail"></p>
<p><img src="https://example.test/untouched.png"></p>
]]

collectgarbage("collect")
local before_kb = collectgarbage("count")
local rewritten = Content.download_mp_images_to_files(
    client, settings, book, article, body, function(index, total)
        progress[#progress + 1] = { index, total }
    end)
collectgarbage("collect")
local after_kb = collectgarbage("count")

expect(#downloads == 2, "duplicate MP image URL was downloaded more than once")
expect(downloads[1].url
        == "https://mmbiz.qpic.cn/image?id=1&format=png",
    "protocol-relative or HTML-escaped MP image URL was not normalized")
expect(downloads[1].opts.max_bytes == 64 * 1024 * 1024,
    "MP image download size limit was not applied")
expect(#progress == 2 and progress[1][1] == 1 and progress[1][2] == 2
        and progress[2][1] == 2 and progress[2][2] == 2,
    "MP image progress did not count unique URLs")

local asset_key=Content.mp_article_path(settings,book,article):match("/weread%-mp%-(%x+)%.html$")
local relative = ".weread-mp-"..asset_key.."-assets/img-0001.png"
local first_reference = rewritten:find(relative, 1, true)
local second_reference = first_reference
    and rewritten:find(relative, first_reference + #relative, true)
local third_reference = second_reference
    and rewritten:find(relative, second_reference + #relative, true)
expect(first_reference ~= nil and second_reference ~= nil
        and third_reference == nil,
    "duplicate MP image references did not share a local file")
expect(not rewritten:match("data:image") and not rewritten:match(";base64,"),
    "MP image was still embedded as a base64 data URL")
expect(rewritten:match("https://mmbiz%.qlogo%.cn/avatar/fail"),
    "failed MP image download did not retain its remote source")
expect(rewritten:match("https://example%.test/untouched%.png"),
    "non-MP image source was unexpectedly rewritten")

local image = assert(io.open(root .. "/" .. relative, "rb"))
expect(image:read(8) == "\137PNG\r\n\026\n",
    "streamed MP image bytes were corrupted")
image:close()
expect(io.open(root .. "/.weread-mp-"..asset_key.."-assets/img-0001.download", "rb")
        == nil,
    "successful MP image download left an incoming file")
expect(after_kb - before_kb < 1024,
    "MP image download retained resource-sized Lua memory")

-- A failed publication must leave a previously complete cached article intact.
local saved = Content.save_mp_article_html(settings, book, article, '<p>Original body</p>')
local other_path=Content.save_mp_article_html(settings,book,other,'<p>Other article body</p>')
expect(saved~=other_path,'same-title publication collided')
local other_file=assert(io.open(other_path,'rb'));local other_html=other_file:read('*a');other_file:close()
expect(other_html:find('Other article body',1,true),'second article was not saved')
expect(Content.mp_article_cached_path(settings,book,{reviewId=article.reviewId,title='Renamed'})==saved,
    'renamed article lost its offline cache')
local legacy=assert(io.open(root..'/Legacy title.html','wb'));legacy:write('ambiguous legacy article');legacy:close()
expect(Content.mp_article_cached_path(settings,book,{reviewId='legacy-id',title='Legacy title'})==nil,
    'unverified legacy title cache must not be opened as another article')
expect(Content.mp_article_path(settings,book,{originalId='original',title='Fallback'})~=
    Content.mp_article_path(settings,book,{reviewId='original',title='Fallback'}),'identity namespaces collided')
expect(Content.mp_article_path(settings,book,article)~=
    Content.mp_article_path(settings,{book_id='another',cache_dir=root},article),'account/book identity collided')
local second_images=Content.download_mp_images_to_files(client,settings,book,other,
    '<img src="https://mmbiz.qpic.cn/other.png">')
expect(not second_images:find('.weread-mp-'..asset_key..'-assets',1,true),
    'different article images shared a directory')
local original_rename = os.rename
os.rename = function(from, to)
    if to == saved then return nil, 'synthetic rename failure' end
    return original_rename(from, to)
end
local ok = pcall(Content.save_mp_article_html, settings, book, article, '<p>Replacement body</p>')
os.rename = original_rename
expect(not ok, 'failed article publication must be reported')
local file = assert(io.open(saved, 'rb'))
local saved_html = file:read('*a');file:close()
expect(saved_html:find('Original body', 1, true) and not saved_html:find('Replacement body', 1, true),
    'failed publication overwrote the existing article')
expect(io.open(saved .. '.part', 'rb') == nil, 'failed publication left a partial article')

assert(os.execute("rm -rf " .. string.format("%q", root)))
print(("mp_article_images_spec: %d checks"):format(checks))
