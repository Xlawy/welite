package.path = "./?.lua;./?/init.lua;" .. package.path

local Groups = require("welite.lib.shelf_groups")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local books = {
    { bookId = "one", title = "One" },
    { bookId = "two", title = "Two" },
    { bookId = "three", title = "Three" },
}
local groups = Groups.list({
    { archiveId = 7, name = "Reading", bookIds = { "two", "one", "two", "missing" } },
    { name = "", bookIds = { "three" } },
}, books, "Unnamed group")

expect(#groups == 2, "user-defined groups were dropped")
expect(groups[1].label == "Reading" and #groups[1].books == 2,
    "group did not retain known members in user order")
expect(groups[1].books[1].bookId == "two" and groups[1].books[2].bookId == "one",
    "group order or duplicate handling is wrong")
expect(groups[2].label == "Unnamed group" and groups[2].books[1].bookId == "three",
    "blank group name did not retain its book")
expect(groups[1].key == "archive:7" and Groups.find(groups, "archive:7") == groups[1]
        and Groups.find(groups, "archive:99") == nil,
    "group selection lookup is not stable")

local projected = Groups.list({
    { archiveId = 8, name = "Reading", bookIds = { "one" } },
    { archiveId = 9, name = "公众号", bookIds = { "MP_WXS_123" } },
    { archiveId = 10, name = "Empty", bookIds = {} },
}, books, "Unnamed group", "Uncategorized")
expect(#projected == 3 and projected[1].label == "Reading"
        and projected[2].label == "Empty" and projected[3].label == "Uncategorized",
    "public-account archive or ungrouped books were projected incorrectly")
expect(#projected[3].books == 2 and projected[3].books[1].bookId == "two"
        and projected[3].books[2].bookId == "three",
    "ungrouped books were not retained in shelf order")

local reordered = Groups.list({
    { archiveId = 10, name = "Empty", bookIds = {} },
    { archiveId = 7, name = "Reading", bookIds = { "one" } },
}, books, "Unnamed group", "Uncategorized")
expect(Groups.find(reordered, "archive:7").label == "Reading",
    "server group identifier did not survive a reordered shelf response")

expect(#Groups.list({}, books, "Unnamed group", "Uncategorized") == 0,
    "an ungrouped shelf added a duplicate all-books choice")

print(("shelf_groups_spec: %d checks"):format(checks))
