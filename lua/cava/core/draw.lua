local DRAW = {}

--- ============================================================================
---                              CONFIGURATION
--- ============================================================================

DRAW.config = {
    -- Characters used to represent different amplitude levels.
    levels = {
        "▁",
        "▂",
        "▃",
        "▄",
        "▅",
        "▆",
        "▇",
        "█",
    },

    -- Character used to separate bars.
    separator = "",

    -- Minimum value expected from CAVA.
    min = 0,

    -- Maximum value expected from CAVA.
    max = 100,

    -- Color configuration.
    --
    -- Colors are Neovim highlight groups.
    colors = {
        -- none:
        --     No highlight information is generated.
        --
        -- single:
        --     Every filled character uses the same highlight.
        --
        -- solid:
        --     Every visual column receives a different highlight.
        --
        -- level:
        --     The highlight depends on the amplitude of the column.
        --
        -- gradient:
        --     The highlight depends progressively on the
        --     vertical level / amplitude.
        mode = "gradient",

        -- Used by "single".
        single = "Normal",

        -- Used by "solid".
        column = {
            "Identifier",
            "Function",
            "Statement",
            "Type",
            "Constant",
        },

        -- Used by "level".
        --
        -- Thresholds are expressed using the CAVA value.
        levels = {
            {
                threshold = 0,
                highlight = "DiagnosticInfo",
            },

            {
                threshold = 50,
                highlight = "DiagnosticWarn",
            },

            {
                threshold = 80,
                highlight = "DiagnosticError",
            },
        },

        -- Used by "gradient".
        --
        -- The first color represents the lowest part
        -- and the last color the highest part.
        gradient = {
            "DiagnosticInfo",
            "DiagnosticHint",
            "DiagnosticWarn",
            "DiagnosticError",
        },
    },
}


--- ============================================================================
---                              SETUP
--- ============================================================================

--- Configure DRAW.
---
---@param opts table|nil Configuration options.
function DRAW.setup(opts)
    opts = opts or {}

    DRAW.config = vim.tbl_deep_extend(
        "force",
        DRAW.config,
        opts
    )
end

--- ============================================================================
---                              UTILITIES
--- ============================================================================

--- Clamp a value between two limits.
---
---@param value number
---@param min number
---@param max number
---@return number
local function clamp(value, min, max)
    return math.max(
        min,
        math.min(max, value)
    )
end


--- Normalize a value between 0 and 1.
---
---@param value number
---@return number
local function normalize_value(value)
    local config = DRAW.config

    value = clamp(
        value,
        config.min,
        config.max
    )

    local range =
        config.max - config.min

    if range <= 0 then
        return 0
    end

    return (
        value - config.min
    ) / range
end


--- Normalize CAVA data.
---
---@param data table CAVA frame.
---@return table
local function normalize(data)
    local result = {}

    for _, value in ipairs(data or {}) do
        result[#result + 1] =
            tonumber(value) or 0
    end

    return result
end


--- Convert an amplitude value into a visual character.
---
---@param value number
---@return string
local function get_level(value)
    local config = DRAW.config
    local levels = config.levels

    if #levels == 0 then
        return " "
    end

    local normalized =
        normalize_value(value)

    local index =
        math.floor(
            normalized * (#levels - 1)
        ) + 1

    return levels[index]
end


--- ============================================================================
---                              COLORS
--- ============================================================================

--- Get the highlight for a single color mode.
---
---@return string|nil
local function get_single_highlight()
    return DRAW.config.colors.single
end


--- Get the highlight for a visual column.
---
---@param column number
---@return string|nil
local function get_column_highlight(column)
    local colors = DRAW.config.colors.column

    if not colors or #colors == 0 then
        return nil
    end

    return colors[
    ((column - 1) % #colors) + 1
    ]
end


--- Get the highlight according to amplitude.
---
---@param value number
---@return string|nil
local function get_level_highlight(value)
    local levels = DRAW.config.colors.levels

    if not levels or #levels == 0 then
        return nil
    end

    local selected = nil

    for _, item in ipairs(levels) do
        local threshold =
            tonumber(item.threshold) or 0

        if value >= threshold then
            selected = item.highlight
        else
            break
        end
    end

    return selected
end


--- Get a gradient highlight according to a normalized value.
---
---@param normalized number
---@return string|nil
local function get_gradient_highlight(normalized)
    local gradient = DRAW.config.colors.gradient

    if not gradient or #gradient == 0 then
        return nil
    end

    normalized = clamp(
        normalized,
        0,
        1
    )

    if #gradient == 1 then
        return gradient[1]
    end

    local index =
        math.floor(
            normalized * (#gradient - 1)
        ) + 1

    return gradient[index]
end


--- Get the highlight for a visual cell.
---
---@param mode string
---@param column number
---@param value number
---@param vertical_level number|nil
---@param height number|nil
---@return string|nil
local function get_highlight(
    mode,
    column,
    value,
    vertical_level,
    height
)
    if mode == "none" then
        return nil
    end

    if mode == "single" then
        return get_single_highlight()
    end

    if mode == "solid" then
        return get_column_highlight(column)
    end

    if mode == "level" then
        return get_level_highlight(value)
    end

    if mode == "gradient" then
        if not vertical_level or not height then
            return get_gradient_highlight(
                normalize_value(value)
            )
        end

        local normalized =
            vertical_level / height

        return get_gradient_highlight(
            normalized
        )
    end

    error(
        "cava.nvim: unknown color mode: "
        .. tostring(mode)
    )
end


--- ============================================================================
---                              SCALING
--- ============================================================================

--- Create an exact distribution of visual columns.
---
---@param count number Number of source values.
---@param width number Target width.
---@return table
local function calculate_distribution(count, width)
    local distribution = {}

    if count <= 0 or width <= 0 then
        return distribution
    end

    local ratio = width / count

    local used = 0

    for index = 1, count do
        local target =
            math.floor(index * ratio)

        local previous =
            math.floor((index - 1) * ratio)

        local size =
            target - previous

        size = math.max(size, 1)

        distribution[index] = size
        used = used + size
    end

    local difference = width - used

    while difference ~= 0 do
        if difference > 0 then
            local index =
                ((used - width) % count) + 1

            distribution[index] =
                distribution[index] + 1

            used = used + 1
            difference = difference - 1
        else
            for index = count, 1, -1 do
                if distribution[index] > 1 then
                    distribution[index] =
                        distribution[index] - 1

                    used = used - 1
                    difference = difference + 1

                    break
                end
            end
        end
    end

    return distribution
end


--- Expand source data to exactly the requested width.
---
---@param data table
---@param width number
---@return table
local function expand_data(data, width)
    local count = #data

    if count == 0 then
        return {}
    end

    local distribution =
        calculate_distribution(
            count,
            width
        )

    local result = {}

    for index, value in ipairs(data) do
        local columns =
            distribution[index] or 1

        for _ = 1, columns do
            result[#result + 1] = value
        end
    end

    return result
end


--- Compress source data to exactly the requested width.
---
---@param data table
---@param width number
---@return table
local function compress_data(data, width)
    local count = #data

    if count == 0 then
        return {}
    end

    if width >= count then
        return data
    end

    local result = {}

    local ratio = count / width

    for column = 1, width do
        local start_index =
            math.floor(
                (column - 1) * ratio
            ) + 1

        local end_index =
            math.floor(column * ratio)

        end_index =
            math.min(end_index, count)

        local sum = 0
        local amount = 0

        for index = start_index, end_index do
            sum = sum + data[index]
            amount = amount + 1
        end

        if amount > 0 then
            result[#result + 1] =
                sum / amount
        else
            result[#result + 1] = 0
        end
    end

    return result
end


--- Scale data to exactly occupy the requested width.
---
---@param data table
---@param width number
---@return table
local function scale_to_width(data, width)
    width = math.max(
        math.floor(
            tonumber(width) or #data
        ),
        1
    )

    if #data == 0 then
        return {}
    end

    if width == #data then
        return data
    end

    if width > #data then
        return expand_data(
            data,
            width
        )
    end

    return compress_data(
        data,
        width
    )
end


--- ============================================================================
---                              HIGHLIGHTS
--- ============================================================================

--- Add a highlight instruction.
---
---@param highlights table
---@param line number
---@param start_col number
---@param end_col number
---@param highlight string|nil
local function add_highlight(
    highlights,
    line,
    start_col,
    end_col,
    highlight
)
    if not highlight then
        return
    end

    if start_col >= end_col then
        return
    end

    highlights[#highlights + 1] = {
        line = line,
        start_col = start_col,
        end_col = end_col,
        hl = highlight,
    }
end


--- ============================================================================
---                              HIGHLIGHTS
--- ============================================================================
--- Add a highlight instruction.
---
---@param highlights table
---@param line number
---@param start_col number
---@param end_col number
---@param highlight string|nil
local function add_highlight(
    highlights,
    line,
    start_col,
    end_col,
    highlight
)
    if not highlight then
        return
    end
    if start_col >= end_col then
        return
    end
    highlights[#highlights + 1] = {
        line = line,
        start_col = start_col,
        end_col = end_col,
        hl = highlight,
    }
end

--- Run-length helper: acumula un highlight por celda y sólo lo "confirma"
--- (agrega la instrucción real) cuando la celda siguiente tiene un color
--- distinto o se acaba la línea. Esto colapsa N celdas contiguas del mismo
--- color en una única llamada a `nvim_buf_add_highlight`, en vez de una
--- por celda — crítico en modos "gradient"/"level" donde toda una fila (o
--- gran parte de ella) comparte el mismo color.
---
---@return table run Estado del run: { line, start_col, col, highlight }
local function new_highlight_run(line)
    return { line = line, start_col = nil, col = 0, highlight = nil }
end

---@param run table
---@param highlights table
---@param byte_length number Ancho en bytes de la celda actual.
---@param highlight string|nil
local function push_cell(run, highlights, byte_length, highlight)
    if highlight ~= run.highlight then
        -- Cambió el color: cerramos el run anterior (si tenía color).
        add_highlight(highlights, run.line, run.start_col, run.col, run.highlight)
        run.highlight = highlight
        run.start_col = run.col
    end
    run.col = run.col + byte_length
end

---@param run table
---@param highlights table
local function flush_run(run, highlights)
    add_highlight(highlights, run.line, run.start_col, run.col, run.highlight)
end

-- ============================================================================
--                              HORIZONTAL
-- ============================================================================
--- Draw a horizontal frame.
---
--- Returns both the generated text and the instructions
--- required to color it. Contiguous columns sharing the same highlight are
--- merged into a single highlight instruction (run-length encoding).
---
---@param data table CAVA frame.
---@return table
function DRAW.horizontal(data)
    data = normalize(data)
    local lines = {}
    local highlights = {}
    local line = {}
    local mode = DRAW.config.colors.mode
    local run = new_highlight_run(0)
    for column, value in ipairs(data) do
        local character = get_level(value)
        line[#line + 1] = character
        local byte_length = #character
        local highlight = get_highlight(mode, column, value)
        push_cell(run, highlights, byte_length, highlight)
        if DRAW.config.separator ~= "" then
            local separator = DRAW.config.separator
            line[#line + 1] = separator
            -- El separador no lleva highlight: cierra cualquier run activo.
            push_cell(run, highlights, #separator, nil)
        end
    end
    flush_run(run, highlights)
    lines[1] = table.concat(line)
    return {
        lines = lines,
        highlights = highlights,
    }
end

-- ============================================================================
--                              VERTICAL
-- ============================================================================
--- Draw a vertical frame.
---
--- Each filled cell receives a highlight according to the configured color
--- mode. Contiguous cells sharing the same highlight within a row are
--- merged into a single highlight instruction (run-length encoding) — en
--- modos "gradient"/"level" toda una fila suele compartir un único color,
--- así que esto reduce el número de llamadas de N (ancho) a 1 por fila.
---
---@param data table CAVA frame.
---@param height number Frame height.
---@param opts table|nil Drawing options.
---@return table
function DRAW.vertical(data, height, opts)
    data = normalize(data)
    opts = opts or {}
    height = math.max(
        tonumber(height) or 1,
        1
    )
    if opts.width then
        data = scale_to_width(
            data,
            opts.width
        )
    elseif opts.scale then
        data = expand_data(
            data,
            #data * math.max(
                math.floor(
                    tonumber(opts.scale) or 1
                ),
                1
            )
        )
    end
    local bars = {}
    for index, value in ipairs(data) do
        value = clamp(
            value,
            DRAW.config.min,
            DRAW.config.max
        )
        local normalized =
            normalize_value(value)
        bars[index] =
            math.floor(
                normalized * height
            )
    end
    local lines = {}
    local highlights = {}
    local mode = DRAW.config.colors.mode
    -- Draw from top to bottom.
    for row = height, 1, -1 do
        local line = {}
        local run = new_highlight_run(#lines)
        for column, bar_height in ipairs(bars) do
            local value = data[column]
            if bar_height >= row then
                local character = "█"
                line[#line + 1] = character
                local highlight = get_highlight(mode, column, value, row, height)
                push_cell(run, highlights, #character, highlight)
            else
                line[#line + 1] = " "
                -- Celda vacía: nunca lleva highlight, cierra el run activo.
                push_cell(run, highlights, 1, nil)
            end
        end
        flush_run(run, highlights)
        lines[#lines + 1] = table.concat(line)
    end
    return {
        lines = lines,
        highlights = highlights,
    }
end

--- ============================================================================
---                              FRAME
--- ============================================================================

--- Draw a complete frame.
---
---@param data table CAVA frame.
---@param mode string Drawing mode.
---@param opts table|nil Drawing options.
---@return table
function DRAW.frame(data, mode, opts)
    mode = mode or "horizontal"
    opts = opts or {}

    if mode == "horizontal" then
        return DRAW.horizontal(data)
    end

    if mode == "vertical" then
        return DRAW.vertical(
            data,
            opts.height or 10,
            opts
        )
    end

    error(
        "cava.nvim: unknown draw mode: "
        .. tostring(mode)
    )
end

return DRAW
