-- ============================================================================
-- CAVA
-- ============================================================================
--
-- Este módulo administra exclusivamente el buffer/ventana encargado de
-- mostrar el visualizador de espectro de audio (frames producidos por
-- CAVA/Chafa/DRAW):
--
--     ┌──────────────────────────────┐
--     │            CAVA              │
--     │      Visualizador de audio   │
--     └──────────────────────────────┘
--
-- El módulo NO se encarga de:
--
--   - crear splits ni decidir el orden de las ventanas (eso es de Menu);
--   - ejecutar CAVA;
--   - producir los frames (eso lo hace DRAW).
--
-- Su responsabilidad es exclusivamente:
--
--     frame → buffer → highlights
--
-- Menu es quien crea la ventana (`vim.cmd("split")`, etc.) y le entrega el
-- winid mediante `Cava:attach_window(winid)`.
--
-- ============================================================================
--                    RENDERIZADO INCREMENTAL (draw())
-- ============================================================================
--
-- CAVA se dibuja a alto FPS (potencialmente 15-30 veces por segundo), así
-- que el costo de tocar el buffer en cada tick es el más alto de todo el
-- plugin si no se controla. `draw()` aplica dos niveles de "no hacer nada
-- innecesario", en este orden:
--
--   1. IDÉNTICO AL ANTERIOR (caso más común: silencio, o un nivel que ya
--      saturó el carácter más alto/bajo): se compara el frame nuevo
--      (líneas + highlights) contra el último efectivamente pintado. Si
--      son iguales, `draw()` retorna sin llamar a NINGUNA API de Neovim
--      (ni `set_lines`, ni `clear_namespace`, ni `add_highlight`).
--
--   2. CAMBIÓ ALGO, PERO NO TODO: si hay diferencia, se calcula el
--      prefijo y sufijo de líneas comunes con el frame anterior (mismo
--      algoritmo que usa `Player`) y sólo se reescribe — y sólo se
--      re-highlightea — el rango intermedio que realmente difiere.
--      Normalmente son pocas filas cerca de la base o la punta de las
--      barras, no las `height` filas completas.
--
-- La comparación de líneas es barata: Lua interna (interning) las cadenas,
-- así que comparar dos strings iguales es esencialmente una comparación de
-- puntero, no un recorrido carácter a carácter. Comparar highlights es
-- igual de barato porque `DRAW` ya los entrega "run-length encoded" (unas
-- pocas decenas de entradas como mucho, no una por celda).
-- ============================================================================
local Cava = {}
Cava.__index = Cava
-- ============================================================================
--                              CONFIGURATION
-- ============================================================================
---@type table
Cava.config = {
    --------------------------------------------------------------------------
    -- Buffer
    --------------------------------------------------------------------------
    --- Nombre del buffer.
    name = "CAVA",
    buftype = "nofile",
    --- El buffer de CAVA puede eliminarse al cerrarse.
    bufhidden = "wipe",
    swapfile = false,

    background = {
        enabled = true,
        darken = 0.15,
        highlight_group = "CavaVisualizerNormal",
    },
    --------------------------------------------------------------------------
    -- Window options
    --------------------------------------------------------------------------
    window = {
        wrap = false,
        number = false,
        relativenumber = false,
        cursorline = false,
        cursorcolumn = false,
        signcolumn = "no",
        colorcolumn = "",
    },
    --------------------------------------------------------------------------
    -- Sizing
    --------------------------------------------------------------------------
    --- Altura máxima del visualizador.
    max_height = 15,
}
-- ============================================================================
--                              CONSTRUCTOR
-- ============================================================================
---@param opts table|nil Configuración personalizada.
---@return table self Nueva instancia de Cava.
function Cava.new(opts)
    local self = setmetatable({}, Cava)
    self.config = vim.tbl_deep_extend("force", Cava.config, opts or {})
    --- Buffer/ventana de CAVA.
    self.bufnr = nil
    self.winid = nil
    --- Namespace utilizado para aplicar y limpiar highlights del frame.
    self.namespace = vim.api.nvim_create_namespace("cava.nvim.cava")
    --------------------------------------------------------------------------
    -- Estado de dibujo incremental (ver comentario de arriba).
    --------------------------------------------------------------------------
    --- Últimas líneas efectivamente escritas en el buffer.
    self._last_lines = nil
    --- Últimos highlights efectivamente aplicados (mismo orden/estructura
    --- que produce DRAW, ya run-length encoded).
    self._last_highlights = nil
    return self
end

-- ============================================================================
--                              STATE
-- ============================================================================
---@return boolean `true` si el buffer existe y es válido.
function Cava:is_valid()
    return self.bufnr ~= nil and vim.api.nvim_buf_is_valid(self.bufnr)
end

---@return boolean `true` si la ventana existe y es válida.
function Cava:is_window_valid()
    return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

--- Limpia referencias a buffer/ventana que ya no existen.
function Cava:cleanup_invalid_state()
    if self.winid and not vim.api.nvim_win_is_valid(self.winid) then
        self.winid = nil
    end
    if self.bufnr and not vim.api.nvim_buf_is_valid(self.bufnr) then
        self.bufnr = nil
    end
end

-- ============================================================================
--                              DIMENSIONS
-- ============================================================================
---@return number width Ancho actual de CAVA (0 si la ventana no existe).
function Cava:get_width()
    if not self:is_window_valid() then
        return 0
    end
    return vim.api.nvim_win_get_width(self.winid)
end

---@return number height Alto actual de CAVA (0 si la ventana no existe).
function Cava:get_height()
    if not self:is_window_valid() then
        return 0
    end
    return vim.api.nvim_win_get_height(self.winid)
end

--- Obtiene simultáneamente las dimensiones de CAVA.
---
---@return number width
---@return number height
function Cava:get_dimensions()
    return self:get_width(), self:get_height()
end

-- ============================================================================
--                              BUFFER CREATION
-- ============================================================================
--- Crea el buffer de CAVA (sin ventana todavía).
---
---@return number|nil bufnr Buffer creado, o `nil` si falló.
function Cava:create_buffer()
    self.bufnr = vim.api.nvim_create_buf(false, true)
    if not self.bufnr then
        return nil
    end
    self:configure_buffer()
    --------------------------------------------------------------------------
    -- Buffer nuevo: cualquier estado "último frame" que tuviéramos
    -- cacheado ya no corresponde a lo que hay realmente en pantalla (el
    -- buffer anterior, si existía, fue destruido). Sin este reset, el
    -- primer draw() tras recrear el buffer podría creer -incorrectamente-
    -- que el contenido ya coincide y dejar el buffer nuevo en blanco.
    --------------------------------------------------------------------------
    self._last_lines = nil
    self._last_highlights = nil
    return self.bufnr
end

--- Configura nombre/opciones del buffer de CAVA.
---
--- A diferencia del Music Manager, CAVA comienza bloqueado
--- (`modifiable=false`) porque el usuario nunca debe editar directamente
--- sus frames.
function Cava:configure_buffer()
    if not self:is_valid() then
        return
    end
    local bufnr = self.bufnr
    vim.api.nvim_buf_set_name(bufnr, self.config.name)
    vim.api.nvim_set_option_value("buftype", self.config.buftype, { buf = bufnr })
    vim.api.nvim_set_option_value("bufhidden", self.config.bufhidden, { buf = bufnr })
    vim.api.nvim_set_option_value("swapfile", self.config.swapfile, { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

-- ============================================================================
--                              WINDOW
-- ============================================================================
--- Asocia una ventana (creada por Menu) a este buffer y aplica sus opciones.
---
---@param winid number ID de la ventana ya creada por Menu (p.ej. vía split).
function Cava:attach_window(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end
    self.winid = winid
    if self:is_valid() then
        vim.api.nvim_win_set_buf(winid, self.bufnr)
    end
    self:configure_window()
end

function Cava:configure_window()
    if not self:is_window_valid() then
        return
    end
    for option, value in pairs(self.config.window) do
        pcall(vim.api.nvim_set_option_value, option, value, { win = self.winid })
    end
    self:apply_background()
end

--- Ver Player:apply_background() — mismo mecanismo.
function Cava:apply_background()
    if not self:is_window_valid() then
        return
    end
    local bg = self.config.background or {}
    if not bg.enabled then
        pcall(vim.api.nvim_set_option_value, "winhighlight", "", { win = self.winid })
        return
    end
    local Theme = require("cava.core.menu.theme")
    local group = bg.highlight_group or "CavaVisualizerNormal"
    if not Theme.setup_darker_normal(group, bg.darken) then
        return
    end
    local winhighlight = table.concat({
        "Normal:" .. group,
        "NormalNC:" .. group,
        "EndOfBuffer:" .. group,
        "SignColumn:" .. group,
    }, ",")
    pcall(vim.api.nvim_set_option_value, "winhighlight", winhighlight, { win = self.winid })
end

-- ============================================================================
--                              HEIGHT
-- ============================================================================
--- Calcula la altura máxima permitida para CAVA (config.max_height).
---
---@return number height Altura máxima permitida (mínimo 1).
function Cava:calculate_height()
    local max_height = tonumber(self.config.max_height) or 15
    return math.max(1, math.floor(max_height))
end

--- Aplica la altura de CAVA, limitada por `max_height` y por el alto
--- disponible del panel que la contiene (p.ej. el alto del Music Manager).
---
---@param available_height number Alto disponible para repartir (p.ej. altura
---  del panel que contiene a CAVA).
function Cava:apply_height(available_height)
    if not self:is_window_valid() then
        return
    end
    local max_height = self:calculate_height()
    local height = math.min(
        max_height,
        math.max((tonumber(available_height) or 0) - 1, 1)
    )
    pcall(vim.api.nvim_win_set_height, self.winid, height)
end

-- ============================================================================
--                              HIGHLIGHTS
-- ============================================================================
--- Aplica una única instrucción de highlight.
---
---@param highlight table `{ line, start_col, end_col, hl }`.
function Cava:_apply_highlight(highlight)
    if highlight.hl and highlight.line and highlight.start_col and highlight.end_col then
        vim.api.nvim_buf_add_highlight(
            self.bufnr,
            self.namespace,
            highlight.hl,
            highlight.line,
            highlight.start_col,
            highlight.end_col
        )
    end
end

--- Elimina todos los highlights actualmente aplicados a CAVA.
function Cava:clear_highlights()
    if not self:is_valid() then
        return
    end
    vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, 0, -1)
end

--- Aplica las instrucciones de highlight producidas por DRAW.
---
--- Cada elemento esperado tiene:
---
---     { line = 0, start_col = 0, end_col = 10, hl = "SomeHighlight" }
---
---@param highlights table|nil Lista de highlights.
function Cava:apply_highlights(highlights)
    if not self:is_valid() then
        return
    end
    if not highlights then
        return
    end
    for _, highlight in ipairs(highlights) do
        self:_apply_highlight(highlight)
    end
end

-- ============================================================================
--                              DIFFING
-- ============================================================================
--- Compara dos listas de líneas de texto.
---
--- Barato: la igualdad de strings en Lua compara primero por identidad de
--- objeto (las cadenas están internadas), así que dos líneas idénticas se
--- detectan casi en O(1) en vez de recorrer carácter a carácter.
---
---@param a table
---@param b table
---@return boolean
local function lines_equal(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end
--- Compara dos listas de highlights (formato `{line,start_col,end_col,hl}`).
---
--- Barato porque DRAW ya entrega highlights "run-length encoded": son
--- decenas de entradas como mucho, no una por celda.
---
---@param a table
---@param b table
---@return boolean
local function highlights_equal(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if
            x.line ~= y.line
            or x.start_col ~= y.start_col
            or x.end_col ~= y.end_col
            or x.hl ~= y.hl
        then
            return false
        end
    end
    return true
end
--- Escribe `lines`/`highlights` reescribiendo TODO el buffer (usado sólo
--- para el primer frame, cuando no hay nada previo con qué diffear).
---
---@param lines table
---@param highlights table
function Cava:_write_full_frame(lines, highlights)
    vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, 0, -1)
    for _, highlight in ipairs(highlights) do
        self:_apply_highlight(highlight)
    end
    vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })
end

--- Escribe únicamente el rango de líneas que difiere respecto al frame
--- anterior (`self._last_lines`), calculando el prefijo/sufijo común igual
--- que `Player`. Los highlights sólo se limpian y reaplican dentro de ese
--- mismo rango; el resto del buffer no se toca.
---
---@param lines table Líneas nuevas.
---@param highlights table Highlights nuevos.
function Cava:_write_partial_frame(lines, highlights)
    local old = self._last_lines
    local old_len, new_len = #old, #lines
    local max_common = math.min(old_len, new_len)
    local prefix = 0
    while prefix < max_common and old[prefix + 1] == lines[prefix + 1] do
        prefix = prefix + 1
    end
    if prefix == old_len and prefix == new_len then
        -- Las líneas de texto son idénticas pero los highlights no (caso
        -- posible en modo "level", donde el color depende del valor crudo
        -- y no sólo de la altura de la barra): no tocamos el texto, sólo
        -- reaplicamos highlights.
        vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, 0, -1)
        for _, highlight in ipairs(highlights) do
            self:_apply_highlight(highlight)
        end
        return
    end
    local max_suffix = max_common - prefix
    local suffix = 0
    while suffix < max_suffix and old[old_len - suffix] == lines[new_len - suffix] do
        suffix = suffix + 1
    end
    local replace_start = prefix             -- 0-indexed, inclusive
    local replace_end_old = old_len - suffix -- 0-indexed, exclusive (buffer viejo)
    local new_slice = {}
    for i = prefix + 1, new_len - suffix do
        new_slice[#new_slice + 1] = lines[i]
    end
    local replace_end_new = prefix + #new_slice -- exclusivo, ya en el buffer nuevo
    vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
    vim.api.nvim_buf_set_lines(self.bufnr, replace_start, replace_end_old, false, new_slice)
    -- Sólo limpiamos highlights en el rango que efectivamente cambió.
    vim.api.nvim_buf_clear_namespace(self.bufnr, self.namespace, replace_start, replace_end_new)
    for _, highlight in ipairs(highlights) do
        if highlight.line >= replace_start and highlight.line < replace_end_new then
            self:_apply_highlight(highlight)
        end
    end
    vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })
end

-- ============================================================================
--                              DRAWING
-- ============================================================================
--- Dibuja un frame de CAVA de forma incremental.
---
--- Se espera que `frame` tenga una estructura similar a:
---
---     {
---         lines = { "▁▂▃▄▅▆▇█", "▁▃▅▇█▆▄▂" },
---         highlights = {
---             { line = 0, start_col = 0, end_col = 4, hl = "CavaBar" },
---         },
---     }
---
--- Si el frame es idéntico al último efectivamente pintado (líneas Y
--- highlights), no se toca el buffer en absoluto. Si sólo cambió una
--- parte, sólo se reescribe/re-highlightea esa parte.
---
---@param frame table Frame producido por DRAW.
function Cava:draw(frame)
    if not self:is_window_valid() then
        return
    end
    if type(frame) ~= "table" then
        return
    end
    local lines = frame.lines or {}
    local highlights = frame.highlights or {}
    --------------------------------------------------------------------------
    -- Nada cambió respecto al último frame realmente pintado: no tocamos
    -- el buffer, no llamamos ninguna API de Neovim.
    --------------------------------------------------------------------------
    if
        self._last_lines
        and self._last_highlights
        and lines_equal(lines, self._last_lines)
        and highlights_equal(highlights, self._last_highlights)
    then
        return
    end
    if not self:is_valid() then
        return
    end
    if self._last_lines then
        self:_write_partial_frame(lines, highlights)
    else
        self:_write_full_frame(lines, highlights)
    end
    self._last_lines = lines
    self._last_highlights = highlights
end

-- ============================================================================
--                              FOCUS / LIFECYCLE
-- ============================================================================
--- Coloca el foco en la ventana de CAVA.
function Cava:focus()
    if not self:is_window_valid() then
        return
    end
    vim.api.nvim_set_current_win(self.winid)
end

--- Oculta la ventana sin eliminar el buffer.
---
---@return boolean `true` si se ocultó una ventana.
function Cava:hide()
    if not self:is_window_valid() then
        return false
    end
    vim.api.nvim_win_hide(self.winid)
    return true
end

--- Cierra la ventana (si existe) y elimina el buffer.
function Cava:close()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        pcall(vim.api.nvim_win_close, self.winid, true)
    end
    if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
    end
    self.winid = nil
    self.bufnr = nil
    -- El próximo buffer partirá de cero.
    self._last_lines = nil
    self._last_highlights = nil
end

-- ============================================================================
--                              MODULE
-- ============================================================================
return Cava
