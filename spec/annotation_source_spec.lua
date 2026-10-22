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

local function joined(rows)
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = row[3] end
    return table.concat(out)
end
local documents = '<html><head><title>未知</title><style>p {x:"<body>"}</style></head>'
    .. '<body><h1>章节甲</h1></body></html>'
    .. '<html><head><title>未知</title></head><body><p>正文🌿&amp;乙</p></body></html>'
local indexed = Source.index(documents)
assert(joined(indexed) == '章节甲正文🌿&amp;乙', 'concatenated document heads entered body text')
for _, row in ipairs(indexed) do
    assert(Source.is_current_span(row))
    assert(row[7] == Source.INDEX_VERSION)
end
assert(joined(Source.index('<HEAD><TITLE>metadata</TITLE><STYLE>hidden</STYLE>hidden</HEAD>'
    .. '<BODY><P>visible</P></BODY>tail')) == 'visible', 'case-insensitive body bounds failed')
assert(joined(Source.index('before<html><body>visible</body></html>after')) == 'visible')
assert(joined(Source.index('<head><title>hidden</title><style>x</style>also hidden</head><p>fragment</p>'))
    == 'fragment', 'a nested style must not end head suppression')
assert(joined(Source.index('<title>hidden</title><p>fragment</p>')) == 'fragment')
assert(joined(Source.index('<!-- <body>fake</body> --><p>fragment</p>')) == 'fragment')
assert(joined(Source.index('<script>if (a < b) {"<body>fake</body>"}</script><p>fragment</p>')) == 'fragment')
assert(joined(Source.index('<!DOCTYPE html [<!ENTITY sample "hidden > value">]><p>fragment</p>')) == 'fragment')
assert(joined(Source.index('<html><head><title>hidden</title></head><body></body></html>')) == '')

local prefix = '\239\187\191<html><head><title>甲🌿</title></head><body><p>'
local unicode = Source.index(prefix .. '乙🌿&amp;丙</p></body></html>')[1]
-- Original source offsets include the whole head, tags and BOM, regardless of
-- what the renderer displays. One CJK rune uses 3 bytes; the emoji uses 4.
local expected_rune = #prefix - 2 - 2 - 3 - 1
local expected_units = expected_rune + 2 -- leading BOM + supplementary rune
assert(unicode[1] == expected_rune and unicode[5] == expected_units)
assert(Source.quote({unicode}, expected_units .. '-' .. (expected_units + 3), 'utf16') == '乙🌿')
assert(Source.quote({unicode}, expected_rune .. '-' .. (expected_rune + 2)) == '乙🌿')
local cdata = Source.index('<body><![CDATA[甲<&乙]]><p>丙</p></body>')
assert(joined(cdata) == '甲<&乙丙' and cdata[1][4] == true)
assert(cdata[1][5] == #'<body><![CDATA[')
assert(Source.quote(cdata, '15-19', 'utf16') == '甲<&乙')
assert(not Source.is_current_span({0, 3, 'old', false, 0, 3}))
assert(not Source.is_current_span({0, 3, 'future', false, 0, 3, Source.INDEX_VERSION + 1}))
assert(Source.is_current_span({0, 3, 'TXT', true, 0, 3}), 'unchanged indexed TXT needs no migration')
assert(not Source.is_current_span({0, 3, 'TXT', true}), 'TXT without original units needs refetch')
print('annotation_source_spec: body-only XHTML, fragments, raw text, comments, CDATA and index versions passed')
