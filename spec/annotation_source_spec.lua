package.path = "./?.lua;" .. package.path
package.preload["util"] = function()
    return { htmlEntitiesToUtf8 = function(text) return text:gsub("&amp;", "&") end }
end
local Source = require("welite.lib.annotation_source")
local spans = Source.index("\239\187\191<p>甲乙<b>丙</b>&amp;丁</p>")
assert(Source.quote(spans, "3-5") == "甲乙", "rune offsets must not become UTF-8 byte offsets")
assert(Source.quote(spans, "4-9") == "乙丙", "quote failed across tags")
assert(Source.quote(spans, "13-19") == "&丁", "entity did not decode")
assert(Source.quote(spans, "13-15") == "", "partial entity was accepted")
assert(Source.quote(spans, "15-18") == "", "range starting inside an entity was accepted")
assert(Source.quote(Source.plain("甲<&乙"), "1-3") == "<&", "raw TXT offsets were interpreted as HTML")
local scripted = Source.index('<script>x</script><p>abc</p>')
assert(#scripted == 1 and scripted[1][3] == "abc", "script text entered quote source")
print("annotation_source_spec: original rune offsets, UTF-8, tags and entities passed")

-- Web progress uses UTF-16 source positions, including tags and a leading BOM.
local web = Source.index("\239\187\191<p title='🌿'>甲🌿乙&amp;丁</p>")
assert(web[1][1] == 13 and web[1][5] == 15, "markup and BOM units were lost")
assert(Source.quote(web, "16-18", "utf16") == "🌿")
assert(Source.quote(web, "18-19", "utf16") == "乙")
assert(Source.quote(web, "19-25", "utf16") == "&丁")
assert(Source.quote(web, "14-15") == "🌿", "annotation rune behavior changed")
for _,range in ipairs({"16-17", "17-18"}) do
    local text, reason = Source.quote(web, range, "utf16")
    assert(text == "" and reason == "partial_character", "split surrogate accepted")
end
local text, reason = Source.quote({{0, 3, "abc"}}, "0-1", "utf16")
assert(text == "" and reason == "missing_utf16_index", "legacy cache silently guessed units")
local plain = Source.plain("\239\187\191甲🌿<&乙")
assert(Source.quote(plain, "2-4", "utf16") == "🌿")
assert(Source.quote(plain, "4-6", "utf16") == "<&")
assert(Source.quote(Source.index("<p>甲</p><p>🌿乙</p>"), "3-14", "utf16") == "甲🌿乙")
print("annotation_source_spec: UTF-16 source offsets, BOM, supplementary characters and legacy rejection passed")
