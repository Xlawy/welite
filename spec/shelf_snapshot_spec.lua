package.path = "./?.lua;./?/init.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function() return { open = helper.connect } end
local LibraryDB = require("welite.lib.library_db")
local user = os.tmpname()
os.remove(user)
local account = { user_vid = user }
local settings = { data_dir = "/tmp", get = function() return account end }
local db = LibraryDB:new(settings)
local path = db:databasePath()
local books = { { bookId = "1", title = "One" } }
local archives = { { archiveId = 5, name = "History", bookIds = { "1" } } }
assert(db:cacheShelf(books), "legacy shelf cache failed")
assert(db:getShelfArchives() == nil, "legacy cache invented group metadata")
assert(db:cacheShelf(books, archives))
db = LibraryDB:new(settings)
assert(db:getShelf()[1].bookId == "1" and db:getShelfArchives()[1].archiveId == 5,
    "shelf groups did not survive reopening")
local connection = db:open()
connection:exec([[CREATE TRIGGER reject_archive BEFORE UPDATE ON shelf_state
    BEGIN SELECT RAISE(ABORT, 'fixture failure'); END]])
connection:close()
assert(not db:cacheShelf({ { bookId = "2" } }, {}), "failed group write was accepted")
assert(db:getShelf()[1].bookId == "1" and db:getShelfArchives()[1].archiveId == 5,
    "group failure did not roll back book membership")
connection = db:open()
connection:exec("DROP TRIGGER reject_archive")
connection:close()
account = { user_vid = user .. "-other" }
local other_path = db:databasePath()
assert(#db:getShelf() == 0 and db:getShelfArchives() == nil, "groups leaked into another account")
account = { user_vid = user }
assert(db:getShelfArchives()[1].archiveId == 5)
assert(db:cacheShelf({}, {}))
assert(#db:getShelf() == 0 and #db:getShelfArchives() == 0, "empty snapshot retained stale data")
for _, file in ipairs({ path, other_path }) do
    os.remove(file); os.remove(file .. "-wal"); os.remove(file .. "-shm")
end
helper.cleanup()
print("shelf_snapshot_spec: real SQLite cache, atomic rollback and account isolation passed")
