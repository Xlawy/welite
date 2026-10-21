-- Compact, e-ink-friendly bookshelf. Navigation and actions share one row.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local CoverLayout = require("weread.lib.cover_layout")
local T = require("ffi/util").template
local HEADER_SIZE = 72
local icons_dir = debug.getinfo(1, "S").source:match("^@(.*/)") .. "../../icons/"

local function _(text) return I18n.tr(text) end

local CoverShadow = Widget:extend{
    width = 1,
    height = 1,
    radius = 1,
}

function CoverShadow:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(1, math.floor(tonumber(self.radius) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function CoverShadow:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, Blitbuffer.gray(0.5), self.radius)
end

local function inside_rounded_rect(px, py, width, height, radius)
    if px < 0 or py < 0 or px >= width or py >= height then return false end
    if radius <= 0 then return true end
    local center_x, center_y
    if px < radius and py < radius then
        center_x, center_y = radius, radius
    elseif px >= width - radius and py < radius then
        center_x, center_y = width - radius - 1, radius
    elseif px < radius and py >= height - radius then
        center_x, center_y = radius, height - radius - 1
    elseif px >= width - radius and py >= height - radius then
        center_x, center_y = width - radius - 1, height - radius - 1
    else
        return true
    end
    local delta_x, delta_y = px - center_x, py - center_y
    return delta_x * delta_x + delta_y * delta_y <= radius * radius
end

-- FrameContainer does not clip its child to its radius. This card masks the
-- four image corners before painting one anti-aliased border, so the cover,
-- border, and drop shadow all share the same smooth geometry.
local RoundedCoverCard = Widget:extend{
    inner = nil,
    width = 1,
    height = 1,
    radius = 0,
    border_size = 0,
    shadow_offset = 0,
    shadow_color = nil,
}

function RoundedCoverCard:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(0, math.floor(tonumber(self.radius) or 0))
    self.border_size = math.max(0, math.floor(tonumber(self.border_size) or 0))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function RoundedCoverCard:free(...)
    if self.inner and self.inner.free then self.inner:free(...) end
end

-- Plain Widget wrappers do not forward CloseWidget to their owned content.
RoundedCoverCard.onCloseWidget = RoundedCoverCard.free

function RoundedCoverCard:_masked_corner_color(px, py)
    if self.shadow_color
        and inside_rounded_rect(px - self.shadow_offset, py - self.shadow_offset,
            self.width, self.height, self.radius) then
        return self.shadow_color
    end
    return Blitbuffer.COLOR_WHITE
end

function RoundedCoverCard:paintTo(bb, x, y)
    if self.inner then self.inner:paintTo(bb, x + self.border_size, y + self.border_size) end
    local radius = self.radius
    if radius > 0 then
        for dy = 0, radius - 1 do
            for dx = 0, radius - 1 do
                local corners = {
                    { dx, dy },
                    { self.width - 1 - dx, dy },
                    { dx, self.height - 1 - dy },
                    { self.width - 1 - dx, self.height - 1 - dy },
                }
                for _, point in ipairs(corners) do
                    if not inside_rounded_rect(point[1], point[2], self.width, self.height, radius) then
                        bb:paintRect(x + point[1], y + point[2], 1, 1,
                            self:_masked_corner_color(point[1], point[2]))
                    end
                end
            end
        end
    end
    if self.border_size > 0 then
        bb:paintBorder(x, y, self.width, self.height, self.border_size,
            Blitbuffer.COLOR_BLACK, radius, true)
    end
end

local FinishedBadge = Widget:extend{}

function FinishedBadge:init()
    self.label = TextWidget:new{
        text = _("Read complete"),
        face = Font:getFace("cfont", 9),
    }
    -- Chinese glyphs occupy their line box unevenly. Use separate horizontal
    -- and vertical padding so the visible whitespace around “读完” is balanced.
    self.padding_x = math.max(1, Screen:scaleBySize(2))
    self.padding_y = 1
    local label_size = self.label:getSize()
    self.width = math.max(Screen:scaleBySize(20), label_size.w + 2 * self.padding_x)
    self.height = label_size.h + 2 * self.padding_y
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function FinishedBadge:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x, y, self.width, self.height, Size.border.thin,
        Blitbuffer.COLOR_BLACK, 0, true)
    local label_size = self.label:getSize()
    self.label:paintTo(bb,
        x + math.floor((self.width - label_size.w) / 2),
        y + math.floor((self.height - label_size.h) / 2))
end

function FinishedBadge:free(...)
    if self.label and self.label.free then self.label:free(...) end
end

FinishedBadge.onCloseWidget = FinishedBadge.free

-- WeRead marks private reading with a black corner pennant and a white mask.
-- The badge honours the cover's rounded silhouette, so it does not square off
-- the lower-left corner while reproducing the official visual language.
local PrivateReadingBadge = Widget:extend{
    size = 1,
    card_width = 1,
    card_height = 1,
    card_radius = 0,
    card_offset_x = 0,
    card_offset_y = 0,
}

function PrivateReadingBadge:init()
    self.size = math.max(1, math.floor(tonumber(self.size) or 1))
    self.dimen = Geom:new{ w = self.size, h = self.size }
end

function PrivateReadingBadge:_inside_cover(px, py)
    return inside_rounded_rect(self.card_offset_x + px, self.card_offset_y + py,
        self.card_width, self.card_height, self.card_radius)
end

-- Paint one horizontal glyph run, clipped to the lower-left pennant triangle:
-- at badge row `local_y` the pennant only covers columns `0..local_y`, so
-- smaller badges cannot leave stray glyph pixels on the cover artwork.
function PrivateReadingBadge:_paint_triangle_run(bb, origin_x, origin_y, local_x, local_y, width, color)
    local stop_x = math.min(local_x + width - 1, local_y)
    if stop_x < local_x then return end
    bb:paintRect(origin_x + local_x, origin_y + local_y, stop_x - local_x + 1, 1, color)
end

function PrivateReadingBadge:_paint_mask(bb, origin_x, origin_y, mask_x, mask_y, width, height)
    -- Official private-reading glyph: a flat crown and straight cheeks that
    -- finish with a shallow rounded chin.  A tapering wedge reads as a clipped
    -- shape at thumbnail size, so retain the vertical sides through most of it.
    local straight_rows = math.max(1, math.floor(height * 0.58))
    local curve_rows = math.max(1, height - straight_rows)
    for row = 0, height - 1 do
        local inset = 0
        if row >= straight_rows then
            local curve = (row - straight_rows + 1) / curve_rows
            local arc = 1 - math.sqrt(math.max(0, 1 - curve * curve))
            inset = math.min(math.floor((width - 3) / 2),
                math.floor((width / 2) * arc))
        end
        self:_paint_triangle_run(bb, origin_x, origin_y, mask_x + inset, mask_y + row,
            math.max(3, width - 2 * inset), Blitbuffer.COLOR_WHITE)
    end
end

function PrivateReadingBadge:paintTo(bb, x, y)
    -- The lower-left right triangle, clipped against the cover's corner arc.
    for row = 0, self.size - 1 do
        for column = 0, row do
            if self:_inside_cover(column, row) then
                bb:paintRect(x + column, y + row, 1, 1, Blitbuffer.COLOR_BLACK)
            end
        end
    end
    -- The corner pennant and its glyph intentionally use separate scales:
    -- shrinking the full pennant previously left too little room for a
    -- recognisable mask.
    local mask_width = math.max(5, math.floor(self.size * 0.28))
    local mask_height = math.max(6, math.floor(self.size * 0.34))
    -- Place the whole hood below the diagonal rather than across it, while
    -- keeping it clear of the rounded lower-left cover corner.
    -- The visual centre of a lower-left right triangle is offset left and up
    -- from its bounding-box centre.
    local mask_x = math.max(0, math.floor(self.size * 0.083) + 3)
    -- Leave five pixels below the glyph, so the cover's rounded clipping never
    -- removes the mask's lower edge.
    local mask_y = math.max(0, self.size - mask_height - 8)
    self:_paint_mask(bb, x, y, mask_x, mask_y, mask_width, mask_height)
    -- Two short slanted eye openings stay legible at e-ink thumbnail scale.
    local eye_y = mask_y + math.max(1, math.floor(mask_height * 0.35))
    local eye_width = math.max(2, math.floor(mask_width * 0.20))
    local left_eye_x = mask_x + math.max(1, math.floor(mask_width * 0.20))
    local right_eye_x = mask_x + mask_width - eye_width
        - math.max(1, math.floor(mask_width * 0.20))
    self:_paint_triangle_run(bb, x, y, left_eye_x, eye_y, eye_width, Blitbuffer.COLOR_BLACK)
    self:_paint_triangle_run(bb, x, y, left_eye_x + 1, eye_y + 1,
        math.max(1, eye_width - 1), Blitbuffer.COLOR_BLACK)
    self:_paint_triangle_run(bb, x, y, right_eye_x, eye_y + 1,
        math.max(1, eye_width - 1), Blitbuffer.COLOR_BLACK)
    self:_paint_triangle_run(bb, x, y, right_eye_x + 1, eye_y, eye_width, Blitbuffer.COLOR_BLACK)
end

local function is_private_book(book)
    local secret = book and book.secret
    return secret == true or tonumber(secret) == 1
end

local function is_finished(book)
    return tonumber(book and book.finishReading) == 1
end

local DownloadStatus = Widget:extend{
    size = 1,
}

-- Keep this small container local: it gives shelf titles a fixed measured
-- width and an explicit left paint origin without adding a KOReader widget
-- dependency that is absent from the lightweight Lua test harness.
local LeftAlignedTitle = Widget:extend{
    width = 1,
    height = 1,
    content = nil,
}

function LeftAlignedTitle:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function LeftAlignedTitle:paintTo(bb, x, y)
    local content_size = self.content:getSize()
    self.content:paintTo(bb, x, y + math.floor((self.height - content_size.h) / 2))
end

function LeftAlignedTitle:free(...)
    if self.content and self.content.free then self.content:free(...) end
end

LeftAlignedTitle.onCloseWidget = LeftAlignedTitle.free

local function build_center_cropped_cover(path, width, height)
    -- Keep image preparation independent from ImageWidget's "fit" and
    -- "stretch" modes: neither offers a cover-fill mode for raster files.
    -- Rendering once, scaling proportionally, and cropping the excess gives
    -- every thumbnail a uniform frame without distorting its artwork.
    local ok, cropped = pcall(function()
        local RenderImage = require("ui/renderimage")
        local source = RenderImage:renderImageFile(path, false)
        if not source then return nil end
        local source_width, source_height = source:getWidth(), source:getHeight()
        if source_width < 1 or source_height < 1 then
            source:free()
            return nil
        end
        local crop = CoverLayout.centerCrop(source_width, source_height, width, height)
        -- Scale through KOReader's MuPDF path: a shelf turn can rebuild a
        -- dozen covers, and the per-pixel Lua fallback is far too slow for it.
        local filled = RenderImage:scaleBlitBuffer(source, crop.width, crop.height, true)
        local output = Blitbuffer.new(width, height, filled:getType())
        output:blitFrom(filled, 0, 0, crop.offset_x, crop.offset_y, width, height)
        filled:free()
        return output
    end)
    if ok then return cropped end
    return nil
end

-- Public-account covers are typically square profile images. Keep their
-- proportions and center them on white instead of cropping a portrait card
-- tightly around an avatar.
local function build_center_contained_cover(path, width, height, inset)
    local ok, contained = pcall(function()
        local RenderImage = require("ui/renderimage")
        local source = RenderImage:renderImageFile(path, false)
        if not source then return nil end
        local source_width, source_height = source:getWidth(), source:getHeight()
        if source_width < 1 or source_height < 1 then
            source:free()
            return nil
        end
        inset = math.max(0, math.floor(tonumber(inset) or 0))
        local available_width = math.max(1, width - 2 * inset)
        local available_height = math.max(1, height - 2 * inset)
        local factor = math.min(available_width / source_width, available_height / source_height)
        local target_width = math.max(1, math.floor(source_width * factor + 0.5))
        local target_height = math.max(1, math.floor(source_height * factor + 0.5))
        local scaled = RenderImage:scaleBlitBuffer(source, target_width, target_height, true)
        local output = Blitbuffer.new(width, height, scaled:getType())
        output:paintRect(0, 0, width, height, Blitbuffer.COLOR_WHITE)
        output:blitFrom(scaled,
            math.floor((width - target_width) / 2),
            math.floor((height - target_height) / 2),
            0, 0, target_width, target_height)
        scaled:free()
        return output
    end)
    if ok then return contained end
    return nil
end

function DownloadStatus:init()
    self.size = math.max(1, math.floor(tonumber(self.size) or 1))
    self.dimen = Geom:new{ w = self.size, h = self.size }
end

local function paint_status_line(bb, x1, y1, x2, y2, stroke, color)
    local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1), 1)
    for step = 0, steps do
        local ratio = step / steps
        bb:paintRect(
            math.floor(x1 + (x2 - x1) * ratio),
            math.floor(y1 + (y2 - y1) * ratio),
            stroke, stroke, color
        )
    end
end

function DownloadStatus:paintTo(bb, x, y)
    local stroke = math.max(1, math.floor(self.size / 8))
    local radius = math.max(1, math.floor((self.size - 1) / 2))
    local center_x = x + math.floor((self.size - 1) / 2)
    local center_y = y + math.floor((self.size - 1) / 2)
    -- paintCircle fills when its stroke width matches its radius.
    bb:paintCircle(center_x, center_y, radius, Blitbuffer.COLOR_BLACK)
    paint_status_line(bb,
        center_x - math.floor(radius * 0.52), center_y,
        center_x - math.floor(radius * 0.12), center_y + math.floor(radius * 0.42),
        stroke, Blitbuffer.COLOR_WHITE)
    paint_status_line(bb,
        center_x - math.floor(radius * 0.12), center_y + math.floor(radius * 0.42),
        center_x + math.floor(radius * 0.58), center_y - math.floor(radius * 0.42),
        stroke, Blitbuffer.COLOR_WHITE)
end

local ShelfRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    font_size = 22,
    callback = nil,
    show_parent = nil,
}

function ShelfRow:init()
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", self.font_size)
    local status_widget = TextWidget:new{ text = self.status or "", face = face }
    local status_width = status_widget:getSize().w
    local gap = Size.padding.large
    local title_widget = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - status_width - gap),
    }
    gap = math.max(gap, inner_width - title_widget:getSize().w - status_width)
    self.frame = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding_left = padding,
        padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            title_widget,
            HorizontalSpan:new{ width = gap },
            status_widget,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapShelfRow = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function ShelfRow:onTapShelfRow()
    if not self.callback then return true end
    self.frame.invert = true
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:forceRePaint()
    self.frame.invert = false
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:setDirty(nil, "fast", self.frame.dimen)
    self.callback()
    return true
end

function ShelfRow:onFocus()
    self.frame.invert = true
    return true
end

function ShelfRow:onUnfocus()
    self.frame.invert = false
    return true
end

local CoverCell = InputContainer:extend{
    book = nil,
    width = nil,
    height = nil,
    cover_path = nil,
    cover_loading = false,
    contain_cover = false,
    cached = false,
    callback = nil,
    show_parent = nil,
}

function CoverCell:init()
    local metrics = CoverLayout.card{
        width = self.width,
        height = self.height,
        size_scale = Screen:scaleBySize(1000) / 1000,
    }
    local border = Size.border.thin
    local image_width = math.max(1, metrics.card_width - 2 * border)
    local image_height = math.max(1, metrics.card_height - 2 * border)
    self._cover_fit = self.contain_cover and "contain" or "crop"
    local cover_content
    if self.cover_path then
        local image
        local ok = pcall(function()
            local rendered
            if self.contain_cover then
                -- Let square avatars fill the card width; the portrait card
                -- naturally retains its white breathing room above and below.
                rendered = build_center_contained_cover(self.cover_path, image_width, image_height, 0)
            else
                rendered = build_center_cropped_cover(self.cover_path, image_width, image_height)
            end
            if rendered then
                image = ImageWidget:new{
                    image = rendered,
                    image_disposable = true,
                    scale_factor = 1,
                }
            else
                -- Preserve the pre-existing safe fallback when a malformed
                -- legacy cover cannot be decoded for cropping.
                image = ImageWidget:new{
                    file = self.cover_path,
                    width = image_width,
                    height = image_height,
                    scale_factor = nil,
                    file_do_cache = false,
                }
            end
            image:getSize()
        end)
        if ok and image then
            cover_content = image
            self._has_cover = true
        elseif image and type(image.free) == "function" then
            pcall(image.free, image)
        end
    end
    if not cover_content then
        -- Center the placeholder text inside the card, like the pre-grid
        -- layout did before the rounded card painted its content top-left.
        cover_content = CenterContainer:new{
            dimen = Geom:new{ w = image_width, h = image_height },
            TextWidget:new{
                text = self.cover_loading and _("Cover loading") or _("No cover"),
                face = Font:getFace("cfont", 18),
                max_width = image_width,
            },
        }
        self._has_cover = false
        self._placeholder_centered = true
    end
    local cover_card = RoundedCoverCard:new{
        inner = cover_content,
        width = metrics.card_width,
        height = metrics.card_height,
        border_size = border,
        radius = metrics.radius,
        shadow_offset = metrics.shadow,
        shadow_color = metrics.shadow > 0
            and (Blitbuffer.gray and Blitbuffer.gray(0.5) or Blitbuffer.COLOR_GRAY) or nil,
    }
    local cover_layers = {
        dimen = Geom:new{ w = metrics.cover_width, h = metrics.cover_height },
    }
    if metrics.shadow > 0 then
        local shadow = CoverShadow:new{
            width = metrics.card_width,
            height = metrics.card_height,
            radius = metrics.radius,
        }
        shadow.overlap_offset = { metrics.shadow, metrics.shadow }
        cover_layers[#cover_layers + 1] = shadow
    end
    cover_layers[#cover_layers + 1] = cover_card
    self._finished = is_finished(self.book)
    self._has_finished_badge = self._finished
    if self._finished then
        local badge = FinishedBadge:new{}
        -- Keep the completion stamp inside the rounded cover silhouette. If it
        -- touches the outer top-right corner, its square white background
        -- hides the cover radius and makes the card read as a right angle.
        local badge_inset = math.max(border, math.floor(metrics.radius * 0.55))
        badge.overlap_offset = {
            math.max(0, metrics.card_width - badge.width - badge_inset),
            badge_inset,
        }
        cover_layers[#cover_layers + 1] = badge
    end
    self._private_reading = is_private_book(self.book)
    self._has_private_badge = self._private_reading
    if self._private_reading then
        local badge_size = math.max(1, math.min(metrics.card_width, metrics.card_height,
            -- Retain the current pennant size; only the inner glyph is tuned.
            Screen:scaleBySize(24)))
        local badge = PrivateReadingBadge:new{
            size = badge_size,
            card_width = metrics.card_width,
            card_height = metrics.card_height,
            card_radius = metrics.radius,
            card_offset_x = 0,
            card_offset_y = metrics.card_height - badge_size,
        }
        badge.overlap_offset = { 0, metrics.card_height - badge_size }
        cover_layers[#cover_layers + 1] = badge
        self._private_badge = badge
        self._private_badge_size = badge_size
    end
    local cover = OverlapGroup:new(cover_layers)
    local title = self.book.title or self.book.bookId or self.book.book_id or _("Untitled")
    local status_size = math.max(1, math.min(metrics.title_height, Screen:scaleBySize(10)))
    local title_gap = math.max(1, Screen:scaleBySize(2))
    self._has_download_status = self.cached == true
    self._download_status_checked = self._has_download_status
    local title_widget = TextWidget:new{
        text = title,
        face = Font:getFace("cfont", 15),
        max_width = math.max(1, metrics.cover_width
            - (self._has_download_status and status_size + title_gap or 0)),
    }
    local title_line = HorizontalGroup:new{}
    if self._has_download_status then
        title_line[#title_line + 1] = DownloadStatus:new{ size = status_size }
        title_line[#title_line + 1] = HorizontalSpan:new{ width = title_gap }
    end
    title_line[#title_line + 1] = title_widget
    -- The fixed-width custom container participates in measurement and paints
    -- all titles from the cover's left edge, even when the title is short.
    local title_container = LeftAlignedTitle:new{
        width = metrics.cover_width,
        height = metrics.title_height,
        content = title_line,
    }
    self.frame = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            VerticalGroup:new{
                align = "center",
                CenterContainer:new{
                    dimen = Geom:new{ w = metrics.cover_width, h = metrics.cover_height },
                    cover,
                },
                VerticalSpan:new{ width = metrics.title_gap },
                CenterContainer:new{
                    dimen = Geom:new{ w = metrics.cover_width, h = metrics.title_height },
                    title_container,
                },
            },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapCoverCell = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function CoverCell:onTapCoverCell()
    if self.callback then self.callback() end
    return true
end

function CoverCell:onFocus()
    self.frame.invert = true
    return true
end

function CoverCell:onUnfocus()
    self.frame.invert = false
    return true
end

local LibraryView = FocusManager:extend{
    mode = "books",
    title = nil,
    wp_enable = true,
    books = nil,
    accounts = nil,
    keyword = nil,
    sort_label = nil,
    filter_label = nil,
    groups = nil,
    group_key = nil,
    group_label = nil,
    on_select_group = nil,
    on_display_change = nil,
    scroll_offset = nil,
    on_switch = nil,
    on_search = nil,
    on_refresh = nil,
    on_sort = nil,
    on_filter = nil,
    on_select = nil,
    paged = false,
    page = 1,
    page_size = 10,
    cover_mode = false,
    cover_columns = 3,
    cover_rows = 2,
    cover_cell_height = nil,
    cover_paths = nil,
    cover_loading = nil,
    on_page_changed = nil,
}

-- Defer destructive callbacks until Button has finished repainting its feedback.
local function after_tap(callback)
    return function() UIManager:nextTick(callback) end
end

function LibraryView:headerBar()
    local size = Screen:scaleBySize(HEADER_SIZE)
    local title = self.mode == "public_account" and _("Public Accounts")
        or T(_("Books · %1"), self.group_label or _("All"))
    local function button(text, icon, width, callback, align, icon_file, max_width)
        local widget = Button:new{
            text = text, icon = icon, width = width, max_width = max_width, height = size,
            icon_width = Screen:scaleBySize(36), icon_height = Screen:scaleBySize(36),
            padding = 0, radius = 0, margin = 0, bordersize = 0,
            padding_h = max_width and Screen:scaleBySize(6) or 0,
            text_font_size = 24, align = align or "center",
            avoid_text_truncation = false, show_parent = self,
            callback = after_tap(callback),
        }
        if icon_file then
            widget.label_widget:free()
            widget.label_widget = IconWidget:new{
                file = icons_dir .. icon_file, width = Screen:scaleBySize(36), height = Screen:scaleBySize(36),
            }
            widget.label_container[1] = widget.label_widget
        end
        return widget
    end
    local back = button(nil, "chevron.left", size, function() self:onClose() end)
    local location_width = self.screen_w - 4 * size
    local location = button(title .. " ▾", nil, nil,
        function() self:showSourceMenu() end, "left", nil, location_width)
    local search = button(nil, "appbar.search", size,
        function() if self.on_search then self.on_search() end end, nil, "shelf-search.svg")
    self.refresh_button = button(nil, "appbar.search", size,
        function() if self.on_refresh then self.on_refresh() end end, nil, "shelf-refresh.svg")
    local menu = button(nil, "appbar.menu", size, function() self:showOptions() end, nil, "shelf-menu.svg")
    self._header_buttons = { back, location, search, self.refresh_button, menu }
    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{ back, location,
            HorizontalSpan:new{ width = math.max(0, location_width - location:getSize().w) },
            search, self.refresh_button, menu },
        LineWidget:new{ dimen = Geom:new{ w = self.screen_w, h = Size.border.thin } },
    }
end

function LibraryView:setRefreshing(refreshing)
    self.refresh_button:enableDisable(not refreshing)
    UIManager:setDirty(self, "ui", self.refresh_button.dimen)
end

function LibraryView:getScrollOffset()
    return self.scroll and self.scroll:getScrolledOffset()
end

function LibraryView:showSourceMenu(menu_mode)
    local Menu = require("ui/widget/menu")
    menu_mode = menu_mode or self.mode
    local width = math.floor(self.screen_w * 0.9)
    local dialog
    local function select(callback)
        return after_tap(function()
            UIManager:close(dialog)
            callback()
        end)
    end
    local tab_width = math.floor((width - 2 * Size.border.window) / 2)
    local tabs = {}
    for _, tab in ipairs({
        { mode = "books", text = _("Books") },
        { mode = "public_account", text = _("Public Accounts") },
    }) do
        tabs[#tabs + 1] = Button:new{
            text = tab.text, width = tab_width, height = Screen:scaleBySize(HEADER_SIZE),
            text_font_size = 24,
            padding = 0, radius = 0, margin = 0, bordersize = 0,
            checked_func = function() return menu_mode == tab.mode end,
            enabled = tab.mode == "books" or self.wp_enable,
            callback = select(function()
                if tab.mode == "books" then
                    self:showSourceMenu("books")
                elseif self.on_switch then
                    self.on_switch(tab.mode)
                end
            end),
        }
    end
    -- Menu owns pagination, truncation, dismiss gestures and keyboard focus.
    local header = HorizontalGroup:new{ tabs[1], tabs[2] }
    header.getHeight = function(widget) return widget:getSize().h end
    header.generateVerticalLayout = function() return { { tabs[1] }, { tabs[2] } } end
    local items = {}
    local function add_group(key, label, count)
        items[#items + 1] = {
            text = label,
            mandatory = (self.mode == "books" and self.group_key == key and "✓  " or "")
                .. tostring(count),
            callback = select(function()
                if self.on_select_group then self.on_select_group(key) end
            end),
        }
    end
    if menu_mode == "books" then
        add_group(nil, _("All books"), self.total_books or #(self.books or {}))
        for _, group in ipairs(self.groups or {}) do
            add_group(group.key, group.label, #group.books)
        end
    else
        items[1] = {
            text = _("Public Accounts"), mandatory = tostring(#(self.accounts or {})),
            callback = select(function() if self.on_switch then self.on_switch("public_account") end end),
        }
    end
    local header_height = header:getSize().h
    local row_height = Screen:scaleBySize(54)
    local available_height = self.screen_h - header_height - 2 * Size.border.window
    local paged = #items * row_height > available_height
    local per_page = paged and math.max(1, math.floor((available_height - Screen:scaleBySize(HEADER_SIZE)) / row_height))
        or #items
    dialog = Menu:new{
        title = _("Select content"), custom_title_bar = header,
        width = width,
        height = header_height + per_page * row_height + 2 * Size.border.window
            + (paged and Screen:scaleBySize(HEADER_SIZE) or 0),
        item_table = items, items_per_page = per_page, items_font_size = 22,
        _recalculateDimen = function(menu, ...)
            Menu._recalculateDimen(menu, ...)
            if not paged then
                -- Native Menu reserves a footer even for one page.
                menu.available_height = menu.inner_dimen.h - header_height
                menu.item_dimen.h = math.floor(menu.available_height / per_page)
            end
        end,
        -- Unlike the standard title bar, these buttons have no Sym/Menu key
        -- shortcuts. Keep them reachable with the five-way controller, too.
        mergeTitleBarIntoLayout = function(menu)
            table.insert(menu.layout, 1, { tabs[2] })
            table.insert(menu.layout, 1, { tabs[1] })
            menu.selected.y = menu.selected.y + 2
        end,
    }
    if not paged then
        -- Keep ownership for cleanup, but no invisible controls over the last row.
        dialog.page_info.paintTo = function() end
        dialog.page_info.handleEvent = function() return false end
    end
    -- Keep popout dismissal, but use square corners like the bookshelf.
    dialog[1].radius = 0
    UIManager:show(dialog)
end

function LibraryView:showOptions()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function action(callback)
        return after_tap(function() UIManager:close(dialog) callback() end)
    end
    local buttons = {{ {
        text = T(_("Sort: %1"), self.sort_label or ""),
        callback = action(function() if self.on_sort then self.on_sort() end end),
    } }}
    if self.mode == "books" then
        buttons[#buttons + 1] = {{
            text = T(_("Filter: %1"), self.filter_label or _("All")),
            callback = action(function() if self.on_filter then self.on_filter() end end),
        }}
        local row = {}
        for _, option in ipairs({ { "list", _("List view") }, { "cover", _("Cover view") } }) do
            row[#row + 1] = {
                text = option[2], checked_func = function() return self.cover_mode == (option[1] == "cover") end,
                callback = action(function() self.on_display_change("view_mode", option[1]) end),
            }
        end
        buttons[#buttons + 1] = row
    end
    if not self.cover_mode then
        local row = {}
        for _, option in ipairs({ { true, _("Page mode") }, { false, _("Continuous scrolling") } }) do
            row[#row + 1] = {
                text = option[2], checked_func = function() return self.paged == option[1] end,
                callback = action(function() self.on_display_change("paginated", option[1]) end),
            }
        end
        buttons[#buttons + 1] = row
    end
    dialog = ButtonDialog:new{ title = _("Bookshelf"), buttons = buttons }
    dialog.movable[1].radius = 0
    UIManager:show(dialog)
end

function LibraryView:itemStatus(book)
    if self.mode == "public_account" then return book.author or "" end
    local status = ""
    if book.readUpdateTime and book.readUpdateTime > 0 then
        status = os.date("%Y-%m-%d", book.readUpdateTime)
    elseif is_finished(book) then
        status = _("Done")
    end
    if book._cached then
        status = status ~= "" and ("✓  " .. status) or "✓"
    end
    return status
end

function LibraryView:preparePagination()
    local source = self.mode == "public_account"
        and (self.accounts or {}) or (self.books or {})
    self.page_size = math.max(1, math.floor(tonumber(self.page_size) or 10))
    if self.cover_mode then
        local columns = math.max(1, math.floor(tonumber(self.cover_columns) or 3))
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        self.page_size = columns * rows
    end
    if self.paged then
        self.page_count = math.max(1, math.ceil(#source / self.page_size))
        self.page = math.max(
            1,
            math.min(math.floor(tonumber(self.page) or 1), self.page_count)
        )
    end
end

function LibraryView:content()
    local source = self.mode == "public_account"
        and (self.accounts or {}) or (self.books or {})
    local content = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.list_width },
    }
    self._item_rows = {}
    self._focus_item_rows = {}
    if #source == 0 then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = self.keyword and self.keyword ~= "" and _("No shelf matches.") or _("No items."),
            face = Font:getFace("cfont", 20),
            max_width = self.content_width,
        })
        return content
    end
    local first = 1
    local last = #source
    if self.paged then
        first = (self.page - 1) * self.page_size + 1
        last = math.min(#source, first + self.page_size - 1)
    end
    if self.cover_mode then
        local columns = math.max(1, math.floor(tonumber(self.cover_columns) or 3))
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        local cell_width = math.floor(self.content_width / columns)
        local cell_height = math.floor(math.max(
            1,
            tonumber(self.cover_cell_height) or math.floor(self.screen_h * 0.28)
        ))
        local grid_height = math.max(cell_height, tonumber(self.cover_content_height)
            or cell_height * rows)
        local grid_row
        for index = first, last do
            local book = source[index]
            local column = ((index - first) % columns) + 1
            local row = math.floor((index - first) / columns) + 1
            if column == 1 then
                grid_row = {}
                self._focus_item_rows[#self._focus_item_rows + 1] = grid_row
                table.insert(content, HorizontalGroup:new(grid_row))
            end
            local width = column == columns
                and self.content_width - cell_width * (columns - 1)
                or cell_width
            local height = row == rows and grid_height - cell_height * (rows - 1)
                or cell_height
            local cover_cell = CoverCell:new{
                book = book,
                cached = book._cached == true,
                cover_path = self.cover_paths and self.cover_paths[book] or nil,
                cover_loading = self.cover_loading and self.cover_loading[book] == true,
                contain_cover = self.mode == "public_account",
                width = width,
                height = math.max(1, height),
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(book, self.mode) end
                end,
            }
            self._item_rows[#self._item_rows + 1] = cover_cell
            grid_row[#grid_row + 1] = cover_cell
        end
    else
        for index = first, last do
            local book = source[index]
            local shelf_row = ShelfRow:new{
                text = book.title or book.bookId or book.book_id or _("Untitled"),
                status = self:itemStatus(book),
                width = self.list_width,
                font_size = self.mode == "books" and 20 or 22,
                show_parent = self,
                callback = function()
                    if self.on_select then self.on_select(book, self.mode) end
                end,
            }
            self._item_rows[#self._item_rows + 1] = shelf_row
            self._focus_item_rows[#self._focus_item_rows + 1] = { shelf_row }
            table.insert(content, shelf_row)
            table.insert(content, HorizontalGroup:new{
                HorizontalSpan:new{ width = Size.padding.large },
                LineWidget:new{
                    dimen = Geom:new{ w = self.list_width - 2 * Size.padding.large, h = 1 },
                    background = Blitbuffer.COLOR_GRAY,
                },
            })
        end
    end
    return content
end

function LibraryView:pageBar()
    if not self.paged or (self.page_count or 1) <= 1 then return nil end
    local cell_w = math.floor(self.screen_w / 3)
    local button_height = Screen:scaleBySize(54)
    local previous = Button:new{
        text = _("Previous"), width = cell_w, height = button_height,
        text_font_size = 22, text_font_bold = true, radius = 0, margin = 0, padding = 0,
        bordersize = 0, enabled = self.page > 1, show_parent = self,
        callback = after_tap(function()
            if self.page > 1 and self.on_page_changed then
                self.on_page_changed(self.page - 1)
            end
        end),
    }
    local page_text = Button:new{
        text = T(_("%1/%2 pages"), tostring(self.page), tostring(self.page_count)),
        width = cell_w, height = button_height, text_font_size = 18,
        radius = 0, margin = 0, bordersize = 0, padding = 0,
        enabled = false, show_parent = self,
    }
    local next_page = Button:new{
        text = _("Next"), width = self.screen_w - 2 * cell_w,
        height = button_height, text_font_size = 22, text_font_bold = true,
        radius = 0, margin = 0, bordersize = 0, padding = 0,
        enabled = self.page < self.page_count, show_parent = self,
        callback = after_tap(function()
            if self.page < self.page_count and self.on_page_changed then
                self.on_page_changed(self.page + 1)
            end
        end),
    }
    self._page_buttons = { previous, page_text, next_page }
    return HorizontalGroup:new{ previous, page_text, next_page }
end

function LibraryView:init()
    self.ges_events = {}
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true
    self.outer_margin = 0
    self.content_width = self.screen_w
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    local header = self:headerBar()
    self:preparePagination()
    local page_bar = self:pageBar()
    local scroll_h = math.max(1, self.screen_h - header:getSize().h
        - (page_bar and page_bar:getSize().h or 0))
    if self.cover_mode then
        local rows = math.max(1, math.floor(tonumber(self.cover_rows) or 2))
        self.cover_content_height = scroll_h
        self.cover_cell_height = math.max(1, math.floor(scroll_h / rows))
    end
    local content = self:content()
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_h },
        show_parent = self,
        VerticalGroup:new{ align = "left", content },
    }
    self.scroll = scroll
    if self.scroll_offset and not self.paged then scroll:setScrolledOffset(self.scroll_offset) end
    local rows = { self._header_buttons }
    for _i, item_row in ipairs(self._focus_item_rows) do
        rows[#rows + 1] = item_row
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._header_buttons) do outside_scroll[button] = true end
    if self._page_buttons then
        rows[#rows + 1] = self._page_buttons
        for _i, button in ipairs(self._page_buttons) do outside_scroll[button] = true end
    end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    FocusNav.initialFocus(self, 1, #self._focus_item_rows > 0 and 2 or 1)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{
            align = "left", header, scroll,
            page_bar or VerticalSpan:new{ width = 0 },
        },
    }
    if self.paged then
        -- Let horizontal swipes reach the shelf pager, not the inner scroller.
        scroll.onScrollableSwipe = function() return false end
        self.ges_events.ShelfSwipe = {
            GestureRange:new{ ges = "swipe", range = scroll.dimen },
        }
    end
    if self.paged and Device:hasKeys() then
        self.onNextPage = function(view)
            if view.page < view.page_count and view.on_page_changed then
                view.on_page_changed(view.page + 1)
            end
            return true
        end
        self.onPrevPage = function(view)
            if view.page > 1 and view.on_page_changed then
                view.on_page_changed(view.page - 1)
            end
            return true
        end
    end
end

function LibraryView:onShelfSwipe(_, ges)
    if not self.paged then return false end
    local delta = ges.direction == "west" and 1 or ges.direction == "east" and -1
    if not delta then return false end
    local page = self.page + delta
    if page >= 1 and page <= self.page_count and self.on_page_changed then self.on_page_changed(page) end
    return true
end

function LibraryView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function LibraryView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function LibraryView:onClose()
    UIManager:close(self)
    return true
end

local M = {}

-- Measure before fetching covers, so the worker and the visible grid agree.
function M.getLayout(cover_mode, count, mode, welite)
    if welite and cover_mode then return require("weread.ui.welite.shelf_adapter").getLayout() end
    local width, height = Screen:getWidth(), Screen:getHeight()
    local header_height = Screen:scaleBySize(HEADER_SIZE) + Size.border.thin
    local page_bar_height = Screen:scaleBySize(54)
    local function layout(reserved)
        if cover_mode then
            return CoverLayout.calculate{
                width = width, height = height,
                size_scale = Screen:scaleBySize(1000) / 1000,
                reserved_height = reserved,
            }
        end
        local row = ShelfRow:new{ width = width, text = "", font_size = mode == "public_account" and 22 or 20 }
        local row_height = row:getSize().h + 1
        if row.free then row:free() end
        return { page_size = math.max(1, math.floor((height - reserved) / row_height)) }
    end
    local result = layout(header_height)
    if count > result.page_size then result = layout(header_height + page_bar_height) end
    return result
end

function M.show(data, callbacks)
    callbacks = callbacks or {}
    if data.welite and data.cover_mode then return require("weread.ui.welite.shelf_adapter").show(data, callbacks) end
    local view = LibraryView:new{
        mode = data.mode,
        title = data.title,
        wp_enable = data.wp_enable ~= false,
        books = data.books,
        groups = data.groups,
        group_key = data.group_key,
        group_label = data.group_label,
        total_books = data.total_books,
        scroll_offset = data.scroll_offset,
        accounts = data.accounts,
        keyword = data.keyword,
        sort_label = data.sort_label,
        filter_label = data.filter_label,
        paged = data.paged == true,
        page = data.page,
        page_size = data.page_size,
        cover_mode = data.cover_mode == true,
        cover_columns = data.cover_columns,
        cover_rows = data.cover_rows,
        cover_cell_height = data.cover_cell_height,
        cover_paths = data.cover_paths,
        cover_loading = data.cover_loading,
        on_switch = callbacks.on_switch,
        on_select_group = callbacks.on_select_group,
        on_display_change = callbacks.on_display_change,
        on_search = callbacks.on_search,
        on_refresh = callbacks.on_refresh,
        on_sort = callbacks.on_sort,
        on_filter = callbacks.on_filter,
        on_select = callbacks.on_select,
        on_page_changed = callbacks.on_page_changed,
    }
    UIManager:show(view)
    return view
end

function M.showSourceMenu(view) return LibraryView.showSourceMenu(view) end
function M.showOptions(view) return LibraryView.showOptions(view) end
return M
