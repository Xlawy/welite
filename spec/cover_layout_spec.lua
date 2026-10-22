package.path = "./?.lua;./?/init.lua;" .. package.path

local CoverLayout = require("welite.lib.cover_layout")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local kindle_touch = CoverLayout.calculate{
    width = 600,
    height = 800,
    size_scale = 1,
}
expect(kindle_touch.columns == 3 and kindle_touch.rows == 2,
    "Kindle Touch layout should remain a 3x2 grid")
expect(kindle_touch.page_size == 6,
    "Kindle Touch page should contain six covers")

local modern_medium = CoverLayout.calculate{
    width = 1080,
    height = 1440,
    size_scale = 1.8,
}
expect(modern_medium.columns == 4 and modern_medium.rows == 3,
    "1080x1440 layout should expand to a 4x3 grid")
expect(modern_medium.page_size == 12,
    "1080x1440 layout should contain more than eight covers")

local modern_large = CoverLayout.calculate{
    width = 1404,
    height = 1872,
    size_scale = 2.34,
}
expect(modern_large.columns == 4 and modern_large.rows == 3,
    "large modern layout should cap the shelf at four columns and three rows")
expect(modern_large.page_size == 12,
    "large modern layout should preserve readable cover density")

local very_large = CoverLayout.calculate{
    width = 2808,
    height = 3744,
    size_scale = 4.68,
}
expect(very_large.columns == 4 and very_large.rows == 3,
    "very large screens should retain the configured cover density")

local no_reserved_space = CoverLayout.calculate{
    width = 600,
    height = 800,
    size_scale = 1,
    reserved_height = 0,
}
expect(no_reserved_space.content_height == 800,
    "an explicit zero reserved height should be retained")

local tiny = CoverLayout.calculate{
    width = 1,
    height = 1,
    size_scale = 100,
}
expect(tiny.columns == 1 and tiny.rows == 1 and tiny.page_size == 1,
    "tiny screens should degrade to one valid cell")
expect(tiny.cell_width == 1 and tiny.cell_height == 1,
    "tiny-screen cell geometry escaped the screen")

local invalid = CoverLayout.calculate{
    width = 0,
    height = -1,
    size_scale = "invalid",
}
expect(invalid.columns == 3 and invalid.rows == 2,
    "invalid geometry should fall back to Kindle Touch dimensions")

local card = CoverLayout.card{ width = 200, height = 300, size_scale = 1 }
expect(card.gutter == 6 and card.shadow == 3,
    "cover card should reserve a stable gutter and shadow")
expect(card.cover_width == 179 and card.cover_height == 262,
    "cover card should use a portrait cover box")
expect(card.card_width == 176 and card.card_height == 259,
    "cover shadow should remain inside its shelf slot")
expect(card.radius == 5,
    "cover frame should use a stable e-ink-friendly corner radius")

local portrait_crop = CoverLayout.centerCrop(300, 600, 180, 260)
expect(portrait_crop.width == 180 and portrait_crop.height == 360
        and portrait_crop.offset_x == 0 and portrait_crop.offset_y == 50,
    "portrait cover should crop equally from top and bottom")

local landscape_crop = CoverLayout.centerCrop(600, 300, 180, 260)
expect(landscape_crop.width == 520 and landscape_crop.height == 260
        and landscape_crop.offset_x == 170 and landscape_crop.offset_y == 0,
    "landscape cover should crop equally from both sides")

local tiny_card = CoverLayout.card{ width = 1, height = 1, size_scale = 100 }
expect(tiny_card.cover_width == 1 and tiny_card.cover_height == 1
        and tiny_card.card_width == 1 and tiny_card.card_height == 1,
    "tiny cover cards should remain drawable")

print(("cover_layout_spec: %d checks"):format(checks))
