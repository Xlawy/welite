-- Pure geometry for a readable, screen-filling bookshelf cover grid.

local CoverLayout = {}

local function positive(value, fallback)
    value = tonumber(value)
    if not value or value <= 0 then return fallback end
    return value
end

local function nonnegative(value, fallback)
    value = tonumber(value)
    if not value or value < 0 then return fallback end
    return value
end

function CoverLayout.calculate(options)
    options = options or {}
    local width = positive(options.width, 600)
    local height = positive(options.height, 800)
    local size_scale = positive(options.size_scale, 1)
    -- KOReader scales normal UI elements linearly with the screen's short edge.
    -- Doing that to cover cards would keep the same 3x2 grid at every
    -- resolution. Sublinear scaling keeps cards readable while allowing larger
    -- and more capable screens to display more of the shelf at once.
    local card_scale = positive(options.card_scale, math.sqrt(size_scale))
    local min_cell_width = math.max(1, positive(
        options.min_cell_width, math.ceil(170 * card_scale)
    ))
    local min_cell_height = math.max(1, positive(
        options.min_cell_height, math.ceil(210 * card_scale)
    ))
    -- Title, tabs, two action rows, and the page bar occupy roughly this fixed
    -- UI-height budget. Scaling it keeps the result stable across device DPI.
    local reserved_height = nonnegative(
        options.reserved_height, math.ceil(225 * size_scale)
    )
    local content_height = math.max(1, height - math.min(reserved_height, height - 1))
    -- Four columns keep covers readable on large e-ink panels. Smaller
    -- screens still fall back to fewer columns when their physical width
    -- cannot accommodate four cards.
    local max_columns = math.max(1, math.floor(positive(options.max_columns, 4)))
    local columns = math.min(max_columns, math.max(1, math.floor(width / min_cell_width)))
    local max_rows = math.max(1, math.floor(positive(options.max_rows, 3)))
    local rows = math.min(max_rows, math.max(1, math.floor(content_height / min_cell_height)))
    return {
        columns = columns,
        rows = rows,
        page_size = columns * rows,
        cell_width = math.max(1, math.floor(width / columns)),
        cell_height = math.max(1, math.floor(content_height / rows)),
        content_height = content_height,
    }
end

-- Geometry inside one shelf slot. Keeping the card smaller than its slot
-- leaves a consistent gutter, while the right-and-bottom shadow stays inside
-- the same footprint and cannot overlap a neighboring book.
function CoverLayout.card(options)
    options = options or {}
    local width = positive(options.width, 1)
    local height = positive(options.height, 1)
    local size_scale = positive(options.size_scale, 1)
    local gutter = math.max(1, math.floor(6 * size_scale))
    local requested_shadow = math.max(1, math.floor(3 * size_scale))
    local title_gap = math.max(1, math.floor(4 * size_scale))
    local title_height = math.max(1, math.floor(22 * size_scale))
    local max_cover_width = math.max(1, width - 2 * gutter)
    local max_cover_height = math.max(1, height - 2 * gutter - title_gap - title_height)
    local shadow = math.min(requested_shadow,
        math.max(0, math.min(max_cover_width - 1, max_cover_height - 1)))
    local max_card_width = math.max(1, max_cover_width - shadow)
    local max_card_height = math.max(1, max_cover_height - shadow)
    -- Most WeRead covers are close to 2:3. Constraining the card to that
    -- portrait proportion makes the border hug the artwork instead of framing
    -- a wide empty box around it.
    local aspect = positive(options.aspect, 0.68)
    local card_width, card_height
    if max_card_width / max_card_height > aspect then
        card_height = max_card_height
        card_width = math.max(1, math.floor(card_height * aspect))
    else
        card_width = max_card_width
        card_height = math.max(1, math.floor(card_width / aspect))
    end
    return {
        gutter = gutter,
        shadow = shadow,
        title_gap = title_gap,
        title_height = title_height,
        cover_width = card_width + shadow,
        cover_height = card_height + shadow,
        card_width = card_width,
        card_height = card_height,
        -- A small shared radius is large enough to read as a smooth cover on
        -- e-ink, but small enough to retain the bookshelf's compact feel.
        radius = math.min(math.max(2, math.floor(5 * size_scale)),
            math.floor(math.min(card_width, card_height) / 2)),
    }
end

-- Scale a source cover until it fully covers a target card, then describe the
-- centered crop. This preserves every source aspect ratio while guaranteeing
-- that no letterbox pixels remain inside the frame.
function CoverLayout.centerCrop(source_width, source_height, target_width, target_height)
    source_width = positive(source_width, 1)
    source_height = positive(source_height, 1)
    target_width = positive(target_width, 1)
    target_height = positive(target_height, 1)
    local factor = math.max(target_width / source_width, target_height / source_height)
    local scaled_width = math.max(target_width, math.ceil(source_width * factor))
    local scaled_height = math.max(target_height, math.ceil(source_height * factor))
    return {
        width = scaled_width,
        height = scaled_height,
        offset_x = math.floor((scaled_width - target_width) / 2),
        offset_y = math.floor((scaled_height - target_height) / 2),
    }
end

return CoverLayout
