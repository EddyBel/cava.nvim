-- ============================================================================
-- BUFFER
-- ============================================================================
--
-- Este módulo administra la interfaz visual completa de Music Manager.
--
-- La interfaz está compuesta por dos buffers especiales:
--
--     ┌──────────────────────────────┐
--     │        Music Manager         │
--     │                              │
--     │       Información musical    │
--     │       Artwork                 │
--     │       Progreso                │
--     │       Controles               │
--     ├──────────────────────────────┤
--     │            CAVA              │
--     │      Visualizador de audio   │
--     └──────────────────────────────┘
--
-- El módulo NO se encarga de:
--
--   - obtener información de Playerctl;
--   - ejecutar CAVA;
--   - ejecutar Chafa;
--   - realizar peticiones HTTP;
--   - descargar artwork.
--
-- Su responsabilidad es exclusivamente la representación visual:
--
--   datos → layout → buffer → highlights → ventana
--
-- Por ejemplo:
--
--     BUFFER:update_music(metadata)
--
-- recibe metadata proveniente de Playerctl, construye el layout y actualiza
-- el buffer del Music Manager.
--
-- Mientras que:
--
--     BUFFER:draw(frame)
--
-- recibe un frame producido por CAVA/Chafa/DRAW y lo representa directamente
-- en el buffer correspondiente.
-- ============================================================================


local BUFFER = {}

BUFFER.__index = BUFFER


--- ============================================================================
---                              CONFIGURATION
--- ============================================================================

--- Configuración por defecto del Music Manager.
---
--- La configuración puede sobrescribirse al crear una instancia mediante:
---
---     local buffer = BUFFER.new({
---         max_width = 50,
---         music = {
---             artwork = {
---                 max_width = 35,
---             },
---         },
---     })
---
--- Se utiliza `vim.tbl_deep_extend()` para combinar la configuración del
--- usuario con esta configuración por defecto.
---
---@type table
BUFFER.config = {

    --------------------------------------------------------------------------
    -- Manager
    --------------------------------------------------------------------------

    --- Nombre del buffer del Music Manager.
    manager_name = "Music Manager",

    --- Ancho máximo permitido para el panel.
    max_width = 40,

    --- Ancho mínimo permitido para el panel.
    min_width = 20,

    --- Porcentaje del ancho total del editor que se intenta utilizar.
    ---
    --- Por ejemplo:
    ---
    ---     width = 30
    ---
    --- significa aproximadamente el 30% del ancho del editor.
    width = 30,


    --------------------------------------------------------------------------
    -- Manager buffer
    --------------------------------------------------------------------------

    --- Opciones específicas del buffer del Music Manager.
    manager = {
        --- Buffer que no pertenece a un archivo normal.
        buftype = "nofile",

        --- Ocultar el buffer en lugar de eliminarlo cuando desaparece
        --- temporalmente de una ventana.
        bufhidden = "hide",

        --- No crear archivo .swp.
        swapfile = false,
    },


    --------------------------------------------------------------------------
    -- CAVA buffer
    --------------------------------------------------------------------------

    --- Nombre del buffer de CAVA.
    cava_name = "CAVA",

    --- Opciones específicas del buffer de CAVA.
    cava = {
        buftype = "nofile",

        --- El buffer de CAVA puede eliminarse al cerrarse.
        bufhidden = "wipe",

        swapfile = false,

        --- Altura máxima del visualizador.
        max_height = 15,
    },


    --------------------------------------------------------------------------
    -- Music information
    --------------------------------------------------------------------------

    music = {

        ----------------------------------------------------------------------
        -- Header
        ----------------------------------------------------------------------

        --- Texto mostrado como encabezado.
        title = "MUSIC",

        --- Valores utilizados cuando no existe metadata.
        empty_title = "No music playing",
        empty_artist = "Unknown artist",
        empty_album = "Unknown album",


        ----------------------------------------------------------------------
        -- Layout
        ----------------------------------------------------------------------

        --- Espaciado horizontal entre el borde de la ventana y el contenido.
        padding = 1,

        --- Número de líneas vacías entre secciones.
        spacing = 1,


        ----------------------------------------------------------------------
        -- Controls
        ----------------------------------------------------------------------

        --- Representación textual de los controles.
        controls = {
            previous = "[<<]",
            play = "[>]",
            pause = "[||]",
            next = "[>>]",
        },


        ----------------------------------------------------------------------
        -- Status
        ----------------------------------------------------------------------

        --- Iconos asociados a cada estado de reproducción.
        status_icons = {
            Playing = "●",
            Paused = "Ⅱ",
            Stopped = "■",
        },


        ----------------------------------------------------------------------
        -- Progress bar
        ----------------------------------------------------------------------

        --- Configuración de la barra de progreso.
        progress = {

            --- Carácter utilizado para la parte reproducida.
            filled = "█",

            --- Carácter utilizado para la parte restante.
            empty = "░",

            --- Delimitadores de la barra.
            left = "[",
            right = "]",
        },


        ----------------------------------------------------------------------
        -- Artwork
        ----------------------------------------------------------------------

        --- Configuración del artwork.
        artwork = {

            --- Activa o desactiva el área del artwork.
            enabled = true,

            --- Carácter utilizado mientras no existe artwork.
            placeholder = "█",

            --- Highlight utilizado por el placeholder.
            highlight = "CavaArtwork",

            --- Ancho máximo del artwork en celdas de terminal.
            max_width = 28,

            --- Alto máximo del artwork en líneas.
            max_height = 18,
        },
    },


    --------------------------------------------------------------------------
    -- Window
    --------------------------------------------------------------------------

    --- Desactiva wrapping.
    wrap = false,

    --- Oculta números de línea.
    number = false,

    --- Oculta números de línea relativos.
    relativenumber = false,

    --- No resalta la línea actual.
    cursorline = false,

    --- No resalta la columna actual.
    cursorcolumn = false,

    --- Oculta la sign column.
    signcolumn = "no",

    --- No muestra colorcolumn.
    colorcolumn = "",


    --------------------------------------------------------------------------
    -- Behaviour
    --------------------------------------------------------------------------

    --- Recalcular dimensiones cuando cambia el tamaño del editor.
    resize = true,

    --- Indica si el manager debe mantenerse visible al cambiar de buffer.
    persistent = true,
}


--- ============================================================================
---                              CONSTRUCTOR
--- ============================================================================

--- Crea una nueva instancia de BUFFER.
---
--- La instancia mantiene todo el estado relacionado con:
---
---   - buffers;
---   - ventanas;
---   - artwork;
---   - highlights;
---   - autocmds;
---   - callbacks;
---   - estado de inicialización.
---
--- La configuración proporcionada por el usuario se combina con
--- `BUFFER.config`.
---
--- Ejemplo:
---
---     local buffer = BUFFER.new()
---
--- Ejemplo con configuración:
---
---     local buffer = BUFFER.new({
---         max_width = 50,
---         music = {
---             spacing = 2,
---             artwork = {
---                 enabled = true,
---                 max_width = 30,
---             },
---         },
---     })
---
---@param opts table|nil Configuración personalizada.
---@return table self Nueva instancia de BUFFER.
function BUFFER.new(opts)
    local self =
        setmetatable({}, BUFFER)

    --------------------------------------------------------------------------
    -- Merge configuration
    --------------------------------------------------------------------------

    self.config =
        vim.tbl_deep_extend(
            "force",
            BUFFER.config,
            opts or {}
        )


    --------------------------------------------------------------------------
    -- Artwork state
    --------------------------------------------------------------------------

    -- Líneas renderizadas por Chafa.
    --
    -- Ejemplo:
    --
    --     {
    --         "██████",
    --         "██░░██",
    --         "██████",
    --     }
    self.artwork_lines = nil

    -- Instrucciones de color asociadas al artwork.
    self.artwork_highlights = nil

    -- Cache de grupos highlight generados dinámicamente.
    --
    -- La clave está basada en los colores FG/BG.
    self.artwork_highlight_cache = {}


    --------------------------------------------------------------------------
    -- Buffers
    --------------------------------------------------------------------------

    self.manager_bufnr = nil
    self.cava_bufnr = nil


    --------------------------------------------------------------------------
    -- Windows
    --------------------------------------------------------------------------

    self.manager_winid = nil
    self.cava_winid = nil


    --------------------------------------------------------------------------
    -- General state
    --------------------------------------------------------------------------

    self.initialized = false

    -- Se utiliza durante close() para evitar que los autocmds respondan
    -- mientras el módulo está destruyendo sus recursos.
    self.closing = false


    --------------------------------------------------------------------------
    -- Namespace
    --------------------------------------------------------------------------

    -- Namespace utilizado para aplicar y limpiar highlights.
    self.namespace =
        vim.api.nvim_create_namespace(
            "cava.nvim.buffer"
        )


    --------------------------------------------------------------------------
    -- Autocommands
    --------------------------------------------------------------------------

    self.autocmd_group = nil

    self.music_metadata = nil


    --------------------------------------------------------------------------
    -- Resize callback
    --------------------------------------------------------------------------

    -- Callback ejecutado cuando cambian las dimensiones del panel.
    --
    -- Firma:
    --
    --     callback(cava_width, cava_height)
    self.on_resize_callback = nil


    return self
end

--- ============================================================================
---                              STATE
--- ============================================================================

--- Comprueba si el buffer del Music Manager sigue siendo válido.
---
---@return boolean `true` si el buffer existe y es válido.
function BUFFER:is_manager_valid()
    return self.manager_bufnr ~= nil
        and vim.api.nvim_buf_is_valid(
            self.manager_bufnr
        )
end

--- Comprueba si el buffer de CAVA sigue siendo válido.
---
---@return boolean `true` si el buffer existe y es válido.
function BUFFER:is_cava_valid()
    return self.cava_bufnr ~= nil
        and vim.api.nvim_buf_is_valid(
            self.cava_bufnr
        )
end

--- Comprueba si la ventana del Music Manager sigue siendo válida.
---
---@return boolean `true` si la ventana existe y es válida.
function BUFFER:is_manager_window_valid()
    return self.manager_winid ~= nil
        and vim.api.nvim_win_is_valid(
            self.manager_winid
        )
end

--- Comprueba si la ventana de CAVA sigue siendo válida.
---
---@return boolean `true` si la ventana existe y es válida.
function BUFFER:is_cava_window_valid()
    return self.cava_winid ~= nil
        and vim.api.nvim_win_is_valid(
            self.cava_winid
        )
end

--- Comprueba si toda la interfaz está abierta.
---
--- El Music Manager se considera abierto únicamente cuando ambas ventanas
--- existen:
---
---     Music Manager + CAVA
---
---@return boolean `true` si ambas ventanas son válidas.
function BUFFER:is_open()
    return self:is_manager_window_valid()
        and self:is_cava_window_valid()
end

--- ============================================================================
---                              DIMENSIONS
--- ============================================================================

--- Obtiene el ancho actual del Music Manager.
---
--- Si la ventana no existe devuelve `0`.
---
---@return number width Ancho actual en celdas.
function BUFFER:get_width()
    if not self:is_manager_window_valid() then
        return 0
    end

    return vim.api.nvim_win_get_width(
        self.manager_winid
    )
end

--- Obtiene el alto actual del Music Manager.
---
---@return number height Alto actual en líneas.
function BUFFER:get_height()
    if not self:is_manager_window_valid() then
        return 0
    end

    return vim.api.nvim_win_get_height(
        self.manager_winid
    )
end

--- Obtiene el ancho actual de CAVA.
---
---@return number width Ancho de CAVA.
function BUFFER:get_cava_width()
    if not self:is_cava_window_valid() then
        return 0
    end

    return vim.api.nvim_win_get_width(
        self.cava_winid
    )
end

--- Obtiene el alto actual de CAVA.
---
---@return number height Alto de CAVA.
function BUFFER:get_cava_height()
    if not self:is_cava_window_valid() then
        return 0
    end

    return vim.api.nvim_win_get_height(
        self.cava_winid
    )
end

--- Obtiene simultáneamente las dimensiones de CAVA.
---
--- Ejemplo:
---
---     local width, height =
---         buffer:get_cava_dimensions()
---
---@return number width Ancho de CAVA.
---@return number height Alto de CAVA.
function BUFFER:get_cava_dimensions()
    return
        self:get_cava_width(),
        self:get_cava_height()
end

--- ============================================================================
---                              CAVA HEIGHT
--- ============================================================================

--- Calcula la altura máxima permitida para CAVA.
---
--- La altura se obtiene de:
---
---     config.cava.max_height
---
--- Siempre devuelve como mínimo `1`.
---
---@return number height Altura máxima permitida.
function BUFFER:calculate_cava_height()
    local max_height =
        tonumber(
            self.config.cava.max_height
        ) or 15

    return math.max(
        1,
        math.floor(max_height)
    )
end

--- Aplica la altura máxima de CAVA.
---
--- La altura final está limitada por dos valores:
---
---     1. max_height configurado.
---     2. altura disponible del Music Manager.
---
--- Esto evita que CAVA crezca más allá del panel que lo contiene.
function BUFFER:apply_cava_height()
    if not self:is_cava_window_valid() then
        return
    end

    local manager_height =
        self:get_height()

    local max_height =
        self:calculate_cava_height()

    local height =
        math.min(
            max_height,
            math.max(
                manager_height - 1,
                1
            )
        )

    pcall(
        vim.api.nvim_win_set_height,
        self.cava_winid,
        height
    )
end

--- ============================================================================
---                              BUFFER CREATION
--- ============================================================================

--- Configura el buffer del Music Manager.
---
--- Establece:
---
---   - nombre;
---   - buftype;
---   - bufhidden;
---   - swapfile;
---   - modifiable.
function BUFFER:configure_manager_buffer()
    if not self:is_manager_valid() then
        return
    end

    local bufnr =
        self.manager_bufnr

    local config =
        self.config.manager

    vim.api.nvim_buf_set_name(
        bufnr,
        self.config.manager_name
    )

    vim.api.nvim_set_option_value(
        "buftype",
        config.buftype,
        {
            buf = bufnr,
        }
    )

    vim.api.nvim_set_option_value(
        "bufhidden",
        config.bufhidden,
        {
            buf = bufnr,
        }
    )

    vim.api.nvim_set_option_value(
        "swapfile",
        config.swapfile,
        {
            buf = bufnr,
        }
    )

    vim.api.nvim_set_option_value(
        "modifiable",
        true,
        {
            buf = bufnr,
        }
    )
end

--- Configura el buffer de CAVA.
---
--- A diferencia del Music Manager, CAVA comienza bloqueado (`modifiable=false`)
--- porque el usuario nunca debe editar directamente sus frames.
function BUFFER:configure_cava_buffer()
    if not self:is_cava_valid() then
        return
    end

    local bufnr =
        self.cava_bufnr

    local config =
        self.config.cava

    vim.api.nvim_buf_set_name(
        bufnr,
        self.config.cava_name
    )

    vim.api.nvim_set_option_value(
        "buftype",
        config.buftype,
        {
            buf = bufnr,
        }
    )

    vim.api.nvim_set_option_value(
        "bufhidden",
        config.bufhidden,
        {
            buf = bufnr,
        }
    )

    vim.api.nvim_set_option_value(
        "swapfile",
        config.swapfile,
        {
            buf = bufnr,
        }
    )

    vim.api.nvim_set_option_value(
        "modifiable",
        false,
        {
            buf = bufnr,
        }
    )
end

--- ============================================================================
---                              WINDOW CONFIGURATION
--- ============================================================================

--- Configura las opciones visuales de una ventana.
---
--- Este método es genérico y puede utilizarse tanto para el Music Manager
--- como para CAVA.
---
---@param winid number ID de la ventana a configurar.
function BUFFER:configure_window(winid)
    if not winid
        or not vim.api.nvim_win_is_valid(winid)
    then
        return
    end

    local config =
        self.config

    local options = {
        wrap = config.wrap,
        number = config.number,
        relativenumber = config.relativenumber,
        cursorline = config.cursorline,
        cursorcolumn = config.cursorcolumn,
        signcolumn = config.signcolumn,
        colorcolumn = config.colorcolumn,
    }

    for option, value in pairs(options) do
        pcall(
            vim.api.nvim_set_option_value,
            option,
            value,
            {
                win = winid,
            }
        )
    end
end

--- Configura específicamente la ventana del Music Manager.
function BUFFER:configure_manager_window()
    self:configure_window(
        self.manager_winid
    )
end

--- Configura específicamente la ventana de CAVA.
function BUFFER:configure_cava_window()
    self:configure_window(
        self.cava_winid
    )
end

--- ============================================================================
---                              WIDTH
--- ============================================================================

--- Calcula el ancho deseado del panel.
---
--- La fórmula es:
---
---     ancho = columnas_del_editor * porcentaje / 100
---
--- Posteriormente se limita entre:
---
---     min_width <= width <= max_width
---
--- Ejemplo:
---
---     editor = 120 columnas
---     width  = 30%
---
---     120 * 0.30 = 36
---
--- Si:
---
---     min_width = 20
---     max_width = 40
---
--- el resultado final será `36`.
---
---@return number width Ancho calculado.
function BUFFER:calculate_width()
    local editor_width =
        vim.o.columns

    local percentage =
        math.floor(
            editor_width
            * (
                self.config.width / 100
            )
        )

    return math.max(
        self.config.min_width,
        math.min(
            percentage,
            self.config.max_width
        )
    )
end

--- Aplica el ancho calculado a la ventana del Music Manager.
function BUFFER:apply_width()
    if not self:is_manager_window_valid() then
        return
    end

    local width =
        self:calculate_width()

    pcall(
        vim.api.nvim_win_set_width,
        self.manager_winid,
        width
    )
end

--- Agrega líneas vacías a una lista de líneas.
---
--- Se utiliza para separar visualmente las diferentes secciones del layout.
---
--- Ejemplo:
---
---     local lines = {"MUSIC"}
---
---     buffer:add_music_spacing(lines, 2)
---
--- Resultado:
---
---     {
---         "MUSIC",
---         "",
---         "",
---     }
---
---@param lines table Lista de líneas que será modificada.
---@param count number Cantidad de líneas vacías.
function BUFFER:add_music_spacing(lines, count)
    count =
        math.max(
            0,
            tonumber(count) or 0
        )

    for _ = 1, count do
        lines[#lines + 1] = ""
    end
end

--- ============================================================================
---                              CREATION
--- ============================================================================

--- Crea toda la interfaz del Music Manager.
---
--- La creación sigue esta secuencia:
---
---     1. Comprobar si ya está abierto.
---     2. Limpiar referencias inválidas.
---     3. Guardar la ventana original.
---     4. Crear buffer Music Manager.
---     5. Crear split vertical a la derecha.
---     6. Colocar el Music Manager.
---     7. Crear buffer CAVA.
---     8. Crear split horizontal.
---     9. Colocar CAVA.
---    10. Restaurar el foco.
---    11. Ajustar dimensiones.
---    12. Registrar autocmds.
---
--- El buffer actual del usuario nunca es reemplazado permanentemente.
---
---@return boolean `true` si la interfaz fue creada o ya estaba abierta.
function BUFFER:create()
    if self.closing then
        return false
    end


    --------------------------------------------------------------------------
    -- Already open
    --------------------------------------------------------------------------

    if self:is_open() then
        self:focus()
        return true
    end


    --------------------------------------------------------------------------
    -- Clean stale state
    --------------------------------------------------------------------------

    self:cleanup_invalid_state()


    --------------------------------------------------------------------------
    -- Save current window
    --------------------------------------------------------------------------

    local original_win =
        vim.api.nvim_get_current_win()

    if not vim.api.nvim_win_is_valid(
            original_win
        )
    then
        return false
    end


    --------------------------------------------------------------------------
    -- Create manager buffer
    --------------------------------------------------------------------------

    self.manager_bufnr =
        vim.api.nvim_create_buf(
            false,
            true
        )

    if not self.manager_bufnr then
        return false
    end

    self:configure_manager_buffer()


    --------------------------------------------------------------------------
    -- Create manager split
    --------------------------------------------------------------------------

    vim.cmd("botright vsplit")

    self.manager_winid =
        vim.api.nvim_get_current_win()


    --------------------------------------------------------------------------
    -- Attach manager buffer
    --------------------------------------------------------------------------

    vim.api.nvim_win_set_buf(
        self.manager_winid,
        self.manager_bufnr
    )

    self:configure_manager_window()

    self:apply_width()


    --------------------------------------------------------------------------
    -- Create CAVA buffer
    --------------------------------------------------------------------------

    self.cava_bufnr =
        vim.api.nvim_create_buf(
            false,
            true
        )

    if not self.cava_bufnr then
        self:close()
        return false
    end

    self:configure_cava_buffer()


    --------------------------------------------------------------------------
    -- Create CAVA split
    --------------------------------------------------------------------------
    --
    -- La ventana del Music Manager:
    --
    --     ┌──────────────┐
    --     │ Music Manager│
    --     └──────────────┘
    --
    -- se convierte en:
    --
    --     ┌──────────────┐
    --     │ Music Manager│
    --     ├──────────────┤
    --     │ CAVA         │
    --     └──────────────┘
    --
    --------------------------------------------------------------------------

    vim.cmd("split")

    self.cava_winid =
        vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(
        self.cava_winid,
        self.cava_bufnr
    )

    self:configure_cava_window()


    --------------------------------------------------------------------------
    -- Restore original focus
    --------------------------------------------------------------------------

    if vim.api.nvim_win_is_valid(
            original_win
        )
    then
        vim.api.nvim_set_current_win(
            original_win
        )
    end


    --------------------------------------------------------------------------
    -- Resize
    --------------------------------------------------------------------------

    self:resize()

    self.initialized = true


    --------------------------------------------------------------------------
    -- Lifecycle
    --------------------------------------------------------------------------

    self:setup_autocmds()

    return true
end

--- ============================================================================
---                              STATE RECOVERY
--- ============================================================================

--- Limpia referencias a buffers y ventanas que ya no existen.
---
--- Neovim puede eliminar una ventana o buffer externamente:
---
---     :q
---     :bd
---     :only
---     :tabclose
---
--- En esos casos las referencias Lua permanecen apuntando a IDs que ya no
--- son válidos.
---
--- Este método elimina esas referencias obsoletas.
function BUFFER:cleanup_invalid_state()
    if self.manager_winid
        and not vim.api.nvim_win_is_valid(
            self.manager_winid
        )
    then
        self.manager_winid = nil
    end

    if self.cava_winid
        and not vim.api.nvim_win_is_valid(
            self.cava_winid
        )
    then
        self.cava_winid = nil
    end

    if self.manager_bufnr
        and not vim.api.nvim_buf_is_valid(
            self.manager_bufnr
        )
    then
        self.manager_bufnr = nil
    end

    if self.cava_bufnr
        and not vim.api.nvim_buf_is_valid(
            self.cava_bufnr
        )
    then
        self.cava_bufnr = nil
    end
end

--- ============================================================================
---                              RESIZE
--- ============================================================================

--- Recalcula las dimensiones del Music Manager.
---
--- Actualiza:
---
---     - ancho del panel;
---     - altura máxima de CAVA;
---     - callback externo.
---
--- El callback permite que otra parte del plugin, por ejemplo CAVA/DRAW,
--- sepa cuál es el nuevo espacio disponible.
function BUFFER:resize()
    if self.closing then
        return
    end

    if not self:is_open() then
        return
    end


    --------------------------------------------------------------------------
    -- Panel width
    --------------------------------------------------------------------------

    self:apply_width()


    --------------------------------------------------------------------------
    -- CAVA height
    --------------------------------------------------------------------------

    self:apply_cava_height()


    --------------------------------------------------------------------------
    -- Notify owner
    --------------------------------------------------------------------------

    if self.on_resize_callback then
        self.on_resize_callback(
            self:get_cava_width(),
            self:get_cava_height()
        )
    end
end

--- Registra el callback ejecutado después de un resize.
---
--- Ejemplo:
---
---     buffer:on_resize_callback_set(
---         function(width, height)
---             print(width, height)
---         end
---     )
---
---@param callback function|nil Callback `(width, height)`.
function BUFFER:on_resize_callback_set(callback)
    self.on_resize_callback =
        callback
end

--- ============================================================================
---                              AUTOCMDS
--- ============================================================================

--- Crea los autocmds necesarios para mantener el estado sincronizado.
---
--- Se registran tres grupos principales:
---
---     VimResized / WinResized
---         ↓
---     recalcular dimensiones
---
---     WinClosed
---         ↓
---     comprobar si alguna ventana del manager desapareció
---
---     BufWipeout
---         ↓
---     limpiar referencias al buffer eliminado
function BUFFER:setup_autocmds()
    if self.autocmd_group then
        return
    end


    --------------------------------------------------------------------------
    -- Create augroup
    --------------------------------------------------------------------------

    self.autocmd_group =
        vim.api.nvim_create_augroup(
            "CavaMusicManager",
            {
                clear = true,
            }
        )


    --------------------------------------------------------------------------
    -- Editor resize
    --------------------------------------------------------------------------

    if self.config.resize then
        vim.api.nvim_create_autocmd(
            {
                "VimResized",
                "WinResized",
            },
            {
                group = self.autocmd_group,

                callback = function()
                    if self.closing then
                        return
                    end

                    vim.schedule(function()
                        if not self.closing then
                            self:resize()
                        end
                    end)
                end,
            }
        )
    end


    --------------------------------------------------------------------------
    -- Window closed
    --------------------------------------------------------------------------

    vim.api.nvim_create_autocmd(
        "WinClosed",
        {
            group = self.autocmd_group,

            callback = function(args)
                if self.closing then
                    return
                end

                local closed =
                    tonumber(args.match)

                if closed == self.manager_winid
                    or closed == self.cava_winid
                then
                    vim.schedule(function()
                        if self.closing then
                            return
                        end

                        self:validate_windows()
                    end)
                end
            end,
        }
    )


    --------------------------------------------------------------------------
    -- Manager buffer wiped
    --------------------------------------------------------------------------

    if self.manager_bufnr then
        vim.api.nvim_create_autocmd(
            "BufWipeout",
            {
                group = self.autocmd_group,

                buffer = self.manager_bufnr,

                callback = function()
                    if self.closing then
                        return
                    end

                    self.manager_bufnr = nil
                    self.manager_winid = nil
                end,
            }
        )
    end


    --------------------------------------------------------------------------
    -- CAVA buffer wiped
    --------------------------------------------------------------------------

    if self.cava_bufnr then
        vim.api.nvim_create_autocmd(
            "BufWipeout",
            {
                group = self.autocmd_group,

                buffer = self.cava_bufnr,

                callback = function()
                    if self.closing then
                        return
                    end

                    self.cava_bufnr = nil
                    self.cava_winid = nil
                end,
            }
        )
    end
end

--- Comprueba que las ventanas necesarias continúen existiendo.
---
--- Si una de las dos ventanas desapareció, se considera que la interfaz
--- quedó incompleta y se ejecuta `close()` para limpiar el resto.
function BUFFER:validate_windows()
    if self.closing then
        return
    end

    if not self:is_manager_window_valid()
        or not self:is_cava_window_valid()
    then
        self:close()
    end
end

--- ============================================================================
---                         ARTWORK HIGHLIGHTS
--- ============================================================================

--- Obtiene o crea un highlight dinámico para un color RGB.
---
--- Chafa puede devolver instrucciones como:
---
---     {
---         fg = "#ffffff",
---         bg = "#ff0000",
---     }
---
--- Neovim necesita un grupo highlight para representar esos colores.
---
--- Por eso este método transforma:
---
---     FG + BG
---
--- en:
---
---     CavaArtwork_ffffff_ff0000
---
--- Los grupos se almacenan en cache para evitar crearlos repetidamente.
---
---@param fg string|nil Color foreground hexadecimal.
---@param bg string|nil Color background hexadecimal.
---@return string|nil Nombre del highlight generado.
function BUFFER:get_artwork_highlight(fg, bg)
    --------------------------------------------------------------------------
    -- Normalize vim.NIL
    --------------------------------------------------------------------------

    if fg == vim.NIL then
        fg = nil
    end

    if bg == vim.NIL then
        bg = nil
    end

    if not fg and not bg then
        return nil
    end


    --------------------------------------------------------------------------
    -- Generate deterministic name
    --------------------------------------------------------------------------

    local fg_name =
        fg
        and fg:gsub("#", "")
        or "none"

    local bg_name =
        bg
        and bg:gsub("#", "")
        or "none"

    local name =
        "CavaArtwork_"
        .. fg_name
        .. "_"
        .. bg_name


    --------------------------------------------------------------------------
    -- Reuse cached highlight
    --------------------------------------------------------------------------

    if self.artwork_highlight_cache[name] then
        return name
    end


    --------------------------------------------------------------------------
    -- Build definition
    --------------------------------------------------------------------------

    local definition = {}

    if fg then
        definition.fg = fg
    end

    if bg then
        definition.bg = bg
    end


    --------------------------------------------------------------------------
    -- Register highlight
    --------------------------------------------------------------------------

    vim.api.nvim_set_hl(
        0,
        name,
        definition
    )

    self.artwork_highlight_cache[name] = true

    return name
end

--- ============================================================================
---                              MUSIC ARTWORK
--- ============================================================================

--- Calcula el área máxima disponible para el artwork.
---
--- El resultado NO representa necesariamente las dimensiones finales de la
--- imagen.
---
--- Representa un bounding box:
---
---     ┌─────────────────────┐
---     │                     │
---     │       artwork       │
---     │                     │
---     └─────────────────────┘
---
--- Chafa posteriormente adapta la imagen real para caber dentro de ese espacio
--- manteniendo su relación de aspecto.
---
---@param width number Ancho disponible.
---@param height number Alto disponible.
---@return number width Ancho máximo del artwork.
---@return number height Alto máximo del artwork.
function BUFFER:calculate_artwork_size(width, height)
    local config =
        self.config.music.artwork

    if not config.enabled then
        return 0, 0
    end


    local max_width =
        tonumber(config.max_width)
        or 15

    local max_height =
        tonumber(config.max_height)
        or 8


    max_width =
        math.max(
            1,
            math.floor(max_width)
        )

    max_height =
        math.max(
            1,
            math.floor(max_height)
        )


    width =
        math.max(
            1,
            math.floor(
                tonumber(width) or 1
            )
        )

    height =
        math.max(
            1,
            math.floor(
                tonumber(height) or 1
            )
        )


    return
        math.min(max_width, width),
        math.min(max_height, height)
end

--- Genera el artwork temporal utilizado como placeholder.
---
--- Se utiliza cuando todavía no existe una imagen renderizada.
---
--- Ejemplo conceptual:
---
---     ██████████
---     ██████████
---     ██████████
---
---@param width number Ancho del placeholder.
---@param height number Alto del placeholder.
---@return table lines Líneas del placeholder.
---@return table highlights Highlights correspondientes.
function BUFFER:build_artwork_placeholder(width, height)
    local config =
        self.config.music.artwork

    local lines = {}
    local highlights = {}


    for line = 0, height - 1 do
        lines[#lines + 1] =
            string.rep(
                config.placeholder,
                width
            )


        highlights[#highlights + 1] = {

            line = line,

            start_col = 0,

            end_col =
                self:display_width(
                    lines[#lines]
                ),

            hl = config.highlight,
        }
    end


    return lines, highlights
end

--- Construye la sección visual del artwork.
---
--- Si existe `self.artwork_lines`, utiliza el artwork producido por Chafa.
---
--- Si todavía no existe, genera un placeholder.
---
--- El resultado se centra horizontalmente dentro del ancho disponible.
---
---@param width number Ancho disponible.
---@return table lines Líneas del artwork.
---@return table highlights Highlights asociados.
function BUFFER:build_music_artwork(width)
    local artwork_width,
    artwork_height =
        self:calculate_artwork_size(
            width,
            self:get_height()
        )


    if artwork_width <= 0
        or artwork_height <= 0
    then
        return {}, {}
    end


    local artwork_lines
    local artwork_highlights


    --------------------------------------------------------------------------
    -- Use rendered artwork if available.
    --------------------------------------------------------------------------

    if self.artwork_lines then
        artwork_lines =
            self.artwork_lines

        artwork_highlights =
            self.artwork_highlights or {}
    else
        artwork_lines,
        artwork_highlights =
            self:build_artwork_placeholder(
                artwork_width,
                artwork_height
            )
    end


    --------------------------------------------------------------------------
    -- Center artwork
    --------------------------------------------------------------------------

    local lines = {}
    local highlights = {}


    for index, line in ipairs(artwork_lines) do
        local line_width =
            self:display_width(line)

        local remaining =
            math.max(
                width - line_width,
                0
            )

        local offset =
            math.floor(
                remaining / 2
            )


        local centered =
            string.rep(
                " ",
                offset
            )
            .. line
            .. string.rep(
                " ",
                remaining - offset
            )


        lines[#lines + 1] =
            centered


        ----------------------------------------------------------------------
        -- Move highlight coordinates together with the artwork.
        ----------------------------------------------------------------------

        for _, highlight in ipairs(
            artwork_highlights
        ) do
            if highlight.line == index - 1 then
                highlights[#highlights + 1] = {

                    line =
                        #lines - 1,

                    start_col =
                        highlight.start_col
                        + offset,

                    end_col =
                        highlight.end_col
                        + offset,

                    hl = highlight.hl,

                    fg = highlight.fg,
                    bg = highlight.bg,
                }
            end
        end
    end


    return lines, highlights
end

--- ============================================================================
---                              MUSIC LAYOUT
--- ============================================================================

--- Obtiene el ancho visual de una cadena.
---
--- No se utiliza `#text` porque en una terminal un carácter Unicode puede
--- ocupar más de un byte y, además, algunos caracteres ocupan dos celdas.
---
--- Neovim proporciona `strdisplaywidth()` precisamente para este propósito.
---
---@param text string Texto.
---@return number width Ancho visual en celdas.
function BUFFER:display_width(text)
    return vim.fn.strdisplaywidth(
        text or ""
    )
end

--- Repite un texto mientras no supere un ancho visual determinado.
---
--- Es diferente de `string.rep()` porque trabaja con ancho visual.
---
--- Ejemplo:
---
---     buffer:repeat_display("█", 5)
---
--- devuelve:
---
---     "█████"
---
---@param text string Texto que se repetirá.
---@param width number Ancho máximo.
---@return string result Texto repetido.
function BUFFER:repeat_display(text, width)
    text =
        tostring(text or "")

    if text == ""
        or width <= 0
    then
        return ""
    end


    local text_width =
        self:display_width(text)

    if text_width <= 0 then
        return ""
    end


    local result = ""
    local current_width = 0


    while current_width + text_width <= width do
        result =
            result .. text

        current_width =
            current_width + text_width
    end


    return result
end

--- Recorta texto para que quepa dentro de un ancho visual.
---
--- Cuando el texto supera el límite se utilizan tres caracteres:
---
---     ...
---
--- Ejemplo:
---
---     buffer:truncate("A very long title", 10)
---
--- podría producir:
---
---     "A very ..."
---
---@param text string Texto original.
---@param width number Ancho máximo.
---@return string Texto ajustado.
function BUFFER:truncate(text, width)
    text =
        tostring(text or "")

    if width <= 0 then
        return ""
    end


    if self:display_width(text) <= width then
        return text
    end


    if width <= 3 then
        return vim.fn.strcharpart(
            text,
            0,
            width
        )
    end


    return vim.fn.strcharpart(
        text,
        0,
        width - 3
    ) .. "..."
end

--- Construye un título visual con bordes redondeados.
---
--- Utiliza los caracteres:
---
---      texto 
---
--- El método únicamente construye la cadena.
---
--- El parámetro `hl` se mantiene como parte de la API, pero el color debe
--- aplicarse posteriormente mediante highlights/extmarks.
---
---@param text string Texto del título.
---@param width number Ancho disponible.
---@param hl string Highlight asociado.
---@return string Línea construida.
function BUFFER:rounded_title(
    text,
    width,
    hl
)
    text =
        self:truncate(
            text or "",
            width - 2
        )


    local text_width =
        self:display_width(text)

    local content =
        " " .. text .. " "

    local content_width =
        self:display_width(content)


    local remaining =
        math.max(
            width
            - content_width
            - 2,
            0
        )


    local left =
        math.floor(
            remaining / 2
        )

    local right =
        remaining - left


    return string.rep(
            " ",
            left
        )
        .. ""
        .. content
        .. ""
        .. string.rep(
            " ",
            right
        )
end

--- Centra texto dentro de un ancho determinado.
---
--- Ejemplo:
---
---     buffer:center("MUSIC", 20)
---
--- produce una cadena de ancho 20 con `MUSIC` centrado.
---
---@param text string Texto.
---@param width number Ancho total.
---@return string Texto centrado.
function BUFFER:center(text, width)
    text =
        self:truncate(
            text or "",
            width
        )


    local text_width =
        self:display_width(text)

    local remaining =
        math.max(
            width - text_width,
            0
        )


    local left =
        math.floor(
            remaining / 2
        )

    local right =
        remaining - left


    return string.rep(
            " ",
            left
        )
        .. text
        .. string.rep(
            " ",
            right
        )
end

--- Crea una línea separadora.
---
--- Actualmente la implementación utiliza espacios, por lo que funciona como
--- una zona vacía de separación.
---
---@param width number Ancho de la línea.
---@return string Línea separadora.
function BUFFER:music_separator(width)
    return string.rep(
        " ",
        width
    )
end

--- Construye la barra de progreso de la canción.
---
--- La lógica es:
---
---     ratio = position / duration
---
--- Después:
---
---     ratio = clamp(ratio, 0, 1)
---
--- Finalmente el ancho disponible se divide entre la parte reproducida y
--- restante.
---
--- Ejemplo:
---
---     position = 30
---     duration = 120
---
---     ratio = 0.25
---
--- Aproximadamente el 25% de la barra aparecerá como `filled`.
---
---@param position number|nil Posición actual en segundos.
---@param duration number|nil Duración total en segundos.
---@param width number Ancho total de la barra.
---@return string Barra de progreso.
function BUFFER:music_progress(
    position,
    duration,
    width
)
    local config =
        self.config.music.progress

    position =
        tonumber(position) or 0

    duration =
        tonumber(duration) or 0


    local left_width =
        self:display_width(
            config.left
        )

    local right_width =
        self:display_width(
            config.right
        )


    local available =
        width
        - left_width
        - right_width


    if available <= 0 then
        return ""
    end


    --------------------------------------------------------------------------
    -- Calculate ratio
    --------------------------------------------------------------------------

    local ratio = 0

    if duration > 0 then
        ratio =
            position / duration
    end


    ratio =
        math.max(
            0,
            math.min(
                ratio,
                1
            )
        )


    --------------------------------------------------------------------------
    -- Calculate filled/empty widths
    --------------------------------------------------------------------------

    local filled_width =
        math.floor(
            available * ratio
        )

    local empty_width =
        available - filled_width


    --------------------------------------------------------------------------
    -- Build bar
    --------------------------------------------------------------------------

    local filled =
        self:repeat_display(
            config.filled,
            filled_width
        )

    local empty =
        self:repeat_display(
            config.empty,
            empty_width
        )


    return config.left
        .. filled
        .. empty
        .. config.right
end

--- Convierte segundos a formato MM:SS.
---
--- Ejemplo:
---
---     buffer:format_time(125)
---
--- devuelve:
---
---     "02:05"
---
---@param seconds number|nil Tiempo en segundos.
---@return string Tiempo formateado.
function BUFFER:format_time(seconds)
    seconds =
        tonumber(seconds) or 0

    seconds =
        math.max(
            0,
            math.floor(seconds)
        )


    local minutes =
        math.floor(
            seconds / 60
        )

    local remaining =
        seconds % 60


    return string.format(
        "%02d:%02d",
        minutes,
        remaining
    )
end

--- Obtiene el icono correspondiente al estado de reproducción.
---
--- Ejemplo:
---
---     buffer:music_status_icon("Playing")
---
--- devuelve:
---
---     "●"
---
---@param status string|nil Estado de reproducción.
---@return string Icono.
function BUFFER:music_status_icon(status)
    return self.config.music.status_icons[
    status
    ] or "?"
end

--- ============================================================================
---                              MUSIC LAYOUT
--- ============================================================================

--- Construye todo el contenido visual del Music Manager.
---
--- IMPORTANTE:
---
--- Este método NO modifica ningún buffer.
---
--- Solamente transforma:
---
---     metadata
---         ↓
---     líneas
---         +
---     highlights
---
--- Esto permite separar la lógica de presentación de la escritura real
--- en Neovim.
---
--- Estructura aproximada:
---
---     MUSIC
---
---     [ ARTWORK ]
---
---     ● Playing  YoutubeMusic
---
---     Song title
---     Artist
---     Album
---
---     [████████░░░░]
---       01:20 / 03:20
---
---     [<<]  [||]  [>>]
---
--- La metadata esperada puede tener:
---
---     {
---         provider = "YoutubeMusic",
---         status = "Playing",
---         title = "Fantasy",
---         artist = "Kidd Manny y Birat Bitz",
---         album = "Fantasy",
---         position = 20,
---         duration = 150,
---     }
---
---@param metadata table|nil Metadata de la canción.
---@return table lines Líneas del layout.
---@return table highlights Highlights asociados.
function BUFFER:build_music_layout(metadata)
    metadata =
        metadata or {}

    local config =
        self.config.music


    --------------------------------------------------------------------------
    -- Calculate available width
    --------------------------------------------------------------------------

    local window_width =
        self:get_width()

    if window_width <= 0 then
        window_width =
            self.config.max_width
    end


    local padding =
        math.max(
            0,
            tonumber(
                self.config.music.padding
            ) or 0
        )


    local width =
        math.max(
            window_width
            - (padding * 2),
            1
        )


    --------------------------------------------------------------------------
    -- Metadata
    --------------------------------------------------------------------------

    local provider =
        metadata.provider
        or "Unknown"

    local status =
        metadata.status
        or "Stopped"

    local title =
        metadata.title
        or config.empty_title

    local artist =
        metadata.artist
        or config.empty_artist

    local album =
        metadata.album
        or config.empty_album

    local position =
        tonumber(metadata.position)
        or 0

    local duration =
        tonumber(metadata.duration)
        or 0


    --------------------------------------------------------------------------
    -- Result containers
    --------------------------------------------------------------------------

    local lines = {}
    local highlights = {}


    --------------------------------------------------------------------------
    -- Header
    --------------------------------------------------------------------------

    lines[#lines + 1] =
        self:center(
            config.title,
            width
        )

    lines[#lines + 1] =
        self:music_separator(
            width
        )


    --------------------------------------------------------------------------
    -- Artwork
    --------------------------------------------------------------------------

    local artwork_lines,
    artwork_highlights =
        self:build_music_artwork(
            width
        )


    local artwork_start =
        #lines


    for _, line in ipairs(
        artwork_lines
    ) do
        lines[#lines + 1] =
            self:center(
                line,
                width
            )
    end


    for _, highlight in ipairs(
        artwork_highlights
    ) do
        highlights[#highlights + 1] = {

            line =
                artwork_start
                + highlight.line,

            start_col =
                highlight.start_col,

            end_col =
                highlight.end_col,

            hl =
                highlight.hl,

            fg =
                highlight.fg,

            bg =
                highlight.bg,
        }
    end


    self:add_music_spacing(
        lines,
        config.spacing
    )


    --------------------------------------------------------------------------
    -- Provider / status
    --------------------------------------------------------------------------

    local status_icon =
        self:music_status_icon(
            status
        )


    local status_line =
        status_icon
        .. " "
        .. status
        .. "  "
        .. provider


    lines[#lines + 1] =
        self:center(
            status_line,
            width
        )


    self:add_music_spacing(
        lines,
        config.spacing
    )


    --------------------------------------------------------------------------
    -- Song title
    --------------------------------------------------------------------------

    lines[#lines + 1] =
        self:center(
            self:truncate(
                title,
                width
            ),
            width
        )


    --------------------------------------------------------------------------
    -- Artist
    --------------------------------------------------------------------------

    lines[#lines + 1] =
        self:center(
            self:truncate(
                artist,
                width
            ),
            width
        )


    --------------------------------------------------------------------------
    -- Album
    --------------------------------------------------------------------------

    if album ~= "" then
        lines[#lines + 1] =
            self:center(
                self:truncate(
                    album,
                    width
                ),
                width
            )
    end


    self:add_music_spacing(
        lines,
        config.spacing
    )


    --------------------------------------------------------------------------
    -- Progress
    --------------------------------------------------------------------------

    local progress =
        self:music_progress(
            position,
            duration,
            width
        )


    if progress ~= "" then
        lines[#lines + 1] =
            self:center(
                progress,
                width
            )
    end


    --------------------------------------------------------------------------
    -- Time
    --------------------------------------------------------------------------

    local time_line =
        self:format_time(position)
        .. " / "
        .. self:format_time(duration)


    lines[#lines + 1] =
        self:center(
            time_line,
            width
        )


    self:add_music_spacing(
        lines,
        config.spacing
    )


    --------------------------------------------------------------------------
    -- Controls
    --------------------------------------------------------------------------

    local play_control

    if status == "Playing" then
        play_control =
            config.controls.pause
    else
        play_control =
            config.controls.play
    end


    local controls =
        table.concat(
            {
                config.controls.previous,
                play_control,
                config.controls.next,
            },
            "  "
        )


    lines[#lines + 1] =
        self:center(
            controls,
            width
        )


    --------------------------------------------------------------------------
    -- Bottom separator
    --------------------------------------------------------------------------

    lines[#lines + 1] =
        self:music_separator(
            width
        )


    --------------------------------------------------------------------------
    -- Horizontal padding
    --------------------------------------------------------------------------

    local horizontal_padding =
        string.rep(
            " ",
            padding
        )


    for index, line in ipairs(lines) do
        lines[index] =
            horizontal_padding
            .. line
            .. horizontal_padding
    end


    return lines, highlights
end

--- ============================================================================
---                              MUSIC RENDER
--- ============================================================================

--- Renderiza la metadata actual en el buffer del Music Manager.
---
--- Flujo:
---
---     self.music_metadata
---             ↓
---     build_music_layout()
---             ↓
---     lines + highlights
---             ↓
---     nvim_buf_set_lines()
---             ↓
---     nvim_buf_add_highlight()
---
--- El buffer se hace temporalmente modificable durante la actualización y
--- posteriormente vuelve a bloquearse.
function BUFFER:render_music()
    if not self:is_manager_valid() then
        return
    end


    local lines,
    highlights =
        self:build_music_layout(
            self.music_metadata
        )


    --------------------------------------------------------------------------
    -- Unlock buffer
    --------------------------------------------------------------------------

    vim.api.nvim_set_option_value(
        "modifiable",
        true,
        {
            buf = self.manager_bufnr,
        }
    )


    --------------------------------------------------------------------------
    -- Write layout
    --------------------------------------------------------------------------

    vim.api.nvim_buf_set_lines(
        self.manager_bufnr,
        0,
        -1,
        false,
        lines
    )


    --------------------------------------------------------------------------
    -- Clear previous highlights
    --------------------------------------------------------------------------

    vim.api.nvim_buf_clear_namespace(
        self.manager_bufnr,
        self.namespace,
        0,
        -1
    )


    --------------------------------------------------------------------------
    -- Apply new highlights
    --------------------------------------------------------------------------

    for _, highlight in ipairs(
        highlights
    ) do
        local highlight_name =
            highlight.hl


        ----------------------------------------------------------------------
        -- Chafa RGB highlight
        ----------------------------------------------------------------------

        if (
                highlight.fg
                and highlight.fg ~= vim.NIL
            )
            or (
                highlight.bg
                and highlight.bg ~= vim.NIL
            )
        then
            highlight_name =
                self:get_artwork_highlight(
                    highlight.fg,
                    highlight.bg
                )
        end


        ----------------------------------------------------------------------
        -- Apply highlight
        ----------------------------------------------------------------------

        if highlight_name then
            vim.api.nvim_buf_add_highlight(
                self.manager_bufnr,
                self.namespace,
                highlight_name,
                highlight.line,
                highlight.start_col,
                highlight.end_col
            )
        end
    end


    --------------------------------------------------------------------------
    -- Lock buffer again
    --------------------------------------------------------------------------

    vim.api.nvim_set_option_value(
        "modifiable",
        false,
        {
            buf = self.manager_bufnr,
        }
    )
end

--- Actualiza la metadata y vuelve a renderizar el Music Manager.
---
--- Ejemplo:
---
---     buffer:update_music({
---         provider = "YoutubeMusic",
---         status = "Playing",
---         title = "Fantasy",
---         artist = "Kidd Manny y Birat Bitz",
---         album = "Fantasy",
---         position = 30,
---         duration = 150,
---     })
---
---@param metadata table|nil Nueva metadata.
function BUFFER:update_music(metadata)
    if metadata ~= nil
        and type(metadata) ~= "table"
    then
        return
    end


    self.music_metadata =
        metadata


    self:render_music()
end

--- Elimina la metadata actual y muestra el estado vacío.
function BUFFER:clear_music()
    self.music_metadata = nil

    self:render_music()
end

--- ============================================================================
---                              ARTWORK API
--- ============================================================================

--- Obtiene el espacio máximo disponible para el artwork.
---
--- Se utiliza normalmente antes de solicitar a Chafa el renderizado de una
--- imagen.
---
--- Ejemplo:
---
---     local width, height =
---         buffer:get_artwork_dimensions()
---
---     -- enviar estas dimensiones a /image/render
---
---@return number width Ancho máximo.
---@return number height Alto máximo.
function BUFFER:get_artwork_dimensions()
    local width =
        self:get_width()

    local height =
        self:get_height()


    if width <= 0
        or height <= 0
    then
        return 0, 0
    end


    local padding =
        math.max(
            0,
            tonumber(
                self.config.music.padding
            ) or 0
        )


    local content_width =
        math.max(
            width
            - (padding * 2),
            1
        )


    return
        self:calculate_artwork_size(
            content_width,
            height
        )
end

--- Establece un artwork previamente renderizado.
---
--- El módulo BUFFER no descarga ni transforma la imagen.
---
--- Espera recibir directamente las líneas producidas por Chafa.
---
--- Ejemplo:
---
---     buffer:set_artwork(
---         {
---             "██████",
---             "██░░██",
---             "██████",
---         },
---         {
---             {
---                 line = 0,
---                 start_col = 0,
---                 end_col = 6,
---                 fg = "#ffffff",
---                 bg = "#ff0000",
---             },
---         }
---     )
---
---@param lines table|nil Líneas ANSI ya convertidas a texto.
---@param highlights table|nil Instrucciones de color.
function BUFFER:set_artwork(
    lines,
    highlights
)
    if lines ~= nil
        and type(lines) ~= "table"
    then
        return
    end

    if highlights ~= nil
        and type(highlights) ~= "table"
    then
        return
    end


    self.artwork_lines =
        lines

    self.artwork_highlights =
        highlights or {}


    self:render_music()
end

--- Elimina el artwork actual.
---
--- Después de ejecutar este método se mostrará nuevamente el placeholder.
function BUFFER:clear_artwork()
    self.artwork_lines = nil

    self.artwork_highlights = nil

    self:render_music()
end

--- ============================================================================
---                              CAVA DRAWING
--- ============================================================================

--- Elimina todos los highlights actualmente aplicados a CAVA.
function BUFFER:clear_highlights()
    if not self:is_cava_valid() then
        return
    end

    vim.api.nvim_buf_clear_namespace(
        self.cava_bufnr,
        self.namespace,
        0,
        -1
    )
end

--- Aplica las instrucciones de highlight producidas por DRAW.
---
--- Cada elemento esperado tiene:
---
---     {
---         line = 0,
---         start_col = 0,
---         end_col = 10,
---         hl = "SomeHighlight",
---     }
---
---@param highlights table|nil Lista de highlights.
function BUFFER:apply_highlights(highlights)
    if not self:is_cava_valid() then
        return
    end

    if not highlights then
        return
    end


    for _, highlight in ipairs(
        highlights
    ) do
        if highlight.hl
            and highlight.line
            and highlight.start_col
            and highlight.end_col
        then
            vim.api.nvim_buf_add_highlight(
                self.cava_bufnr,
                self.namespace,
                highlight.hl,
                highlight.line,
                highlight.start_col,
                highlight.end_col
            )
        end
    end
end

--- Dibuja un frame de CAVA.
---
--- Se espera que `frame` tenga una estructura similar a:
---
---     {
---         lines = {
---             "▁▂▃▄▅▆▇█",
---             "▁▃▅▇█▆▄▂",
---         },
---
---         highlights = {
---             {
---                 line = 0,
---                 start_col = 0,
---                 end_col = 4,
---                 hl = "CavaBar",
---             },
---         },
---     }
---
--- El método:
---
---     1. Comprueba que la interfaz esté abierta.
---     2. Hace writable el buffer.
---     3. Elimina highlights anteriores.
---     4. Escribe el nuevo frame.
---     5. Bloquea nuevamente el buffer.
---     6. Aplica los nuevos highlights.
---
---@param frame table Frame producido por DRAW.
function BUFFER:draw(frame)
    if self.closing then
        return
    end


    --------------------------------------------------------------------------
    -- Do not implicitly create the manager.
    --------------------------------------------------------------------------

    if not self:is_open() then
        return
    end


    if type(frame) ~= "table" then
        return
    end


    local lines =
        frame.lines or {}

    local highlights =
        frame.highlights or {}


    --------------------------------------------------------------------------
    -- Unlock CAVA buffer
    --------------------------------------------------------------------------

    vim.api.nvim_set_option_value(
        "modifiable",
        true,
        {
            buf = self.cava_bufnr,
        }
    )


    --------------------------------------------------------------------------
    -- Clear previous frame
    --------------------------------------------------------------------------

    self:clear_highlights()


    --------------------------------------------------------------------------
    -- Write frame
    --------------------------------------------------------------------------

    vim.api.nvim_buf_set_lines(
        self.cava_bufnr,
        0,
        -1,
        false,
        lines
    )


    --------------------------------------------------------------------------
    -- Lock buffer
    --------------------------------------------------------------------------

    vim.api.nvim_set_option_value(
        "modifiable",
        false,
        {
            buf = self.cava_bufnr,
        }
    )


    --------------------------------------------------------------------------
    -- Apply colors
    --------------------------------------------------------------------------

    self:apply_highlights(
        highlights
    )
end

--- ============================================================================
---                              MANAGER CONTENT
--- ============================================================================

--- Reemplaza directamente el contenido del buffer del Music Manager.
---
--- Este método es una API de bajo nivel.
---
--- Normalmente se recomienda utilizar:
---
---     update_music()
---
--- en lugar de modificar directamente las líneas.
---
--- Sin embargo, `set_manager_lines()` resulta útil si otro componente necesita
--- dibujar contenido personalizado.
---
---@param lines table Lista de líneas.
function BUFFER:set_manager_lines(lines)
    if not self:is_manager_valid() then
        return
    end


    vim.api.nvim_set_option_value(
        "modifiable",
        true,
        {
            buf = self.manager_bufnr,
        }
    )


    vim.api.nvim_buf_set_lines(
        self.manager_bufnr,
        0,
        -1,
        false,
        lines or {}
    )


    vim.api.nvim_set_option_value(
        "modifiable",
        false,
        {
            buf = self.manager_bufnr,
        }
    )
end

--- ============================================================================
---                              FOCUS
--- ============================================================================

--- Coloca el foco en la ventana del Music Manager.
function BUFFER:focus_manager()
    if not self:is_manager_window_valid() then
        return
    end

    vim.api.nvim_set_current_win(
        self.manager_winid
    )
end

--- Coloca el foco en la ventana de CAVA.
function BUFFER:focus_cava()
    if not self:is_cava_window_valid() then
        return
    end

    vim.api.nvim_set_current_win(
        self.cava_winid
    )
end

--- Coloca el foco en el Music Manager.
---
--- Actualmente es equivalente a `focus_manager()`.
function BUFFER:focus()
    self:focus_manager()
end

--- ============================================================================
---                              CLOSE
--- ============================================================================

--- Elimina todos los autocmds creados por la instancia.
function BUFFER:cleanup_autocmds()
    if not self.autocmd_group then
        return
    end


    pcall(
        vim.api.nvim_del_augroup_by_id,
        self.autocmd_group
    )


    self.autocmd_group = nil
end

--- Cierra completamente el Music Manager.
---
--- A diferencia de `hide()`, este método:
---
---     - cierra ambas ventanas;
---     - elimina ambos buffers;
---     - elimina autocmds;
---     - limpia todas las referencias.
---
--- Es una destrucción completa de la interfaz.
function BUFFER:close()
    if self.closing then
        return
    end

    self.closing = true


    --------------------------------------------------------------------------
    -- Save references
    --------------------------------------------------------------------------

    local manager_bufnr =
        self.manager_bufnr

    local cava_bufnr =
        self.cava_bufnr

    local manager_winid =
        self.manager_winid

    local cava_winid =
        self.cava_winid


    --------------------------------------------------------------------------
    -- Stop callbacks/autocmds first
    --------------------------------------------------------------------------

    self:cleanup_autocmds()


    --------------------------------------------------------------------------
    -- Clear state immediately
    --------------------------------------------------------------------------

    self.manager_bufnr = nil
    self.cava_bufnr = nil

    self.manager_winid = nil
    self.cava_winid = nil

    self.initialized = false


    --------------------------------------------------------------------------
    -- Close CAVA window
    --------------------------------------------------------------------------

    if cava_winid
        and vim.api.nvim_win_is_valid(
            cava_winid
        )
    then
        pcall(
            vim.api.nvim_win_close,
            cava_winid,
            true
        )
    end


    --------------------------------------------------------------------------
    -- Close manager window
    --------------------------------------------------------------------------

    if manager_winid
        and vim.api.nvim_win_is_valid(
            manager_winid
        )
    then
        pcall(
            vim.api.nvim_win_close,
            manager_winid,
            true
        )
    end


    --------------------------------------------------------------------------
    -- Delete CAVA buffer
    --------------------------------------------------------------------------

    if cava_bufnr
        and vim.api.nvim_buf_is_valid(
            cava_bufnr
        )
    then
        pcall(
            vim.api.nvim_buf_delete,
            cava_bufnr,
            {
                force = true,
            }
        )
    end


    --------------------------------------------------------------------------
    -- Delete manager buffer
    --------------------------------------------------------------------------

    if manager_bufnr
        and vim.api.nvim_buf_is_valid(
            manager_bufnr
        )
    then
        pcall(
            vim.api.nvim_buf_delete,
            manager_bufnr,
            {
                force = true,
            }
        )
    end


    self.closing = false
end

--- Oculta temporalmente el Music Manager.
---
--- A diferencia de `close()`, no elimina los buffers.
---
--- Esto permite posteriormente volver a mostrar la interfaz sin reconstruir
--- necesariamente todo su estado.
---
--- IMPORTANTE:
---
--- Los IDs de las ventanas dejan de ser utilizables después de `nvim_win_hide`,
--- por lo que `is_open()` devolverá `false`.
---
--- La creación de nuevas ventanas y la reconexión de los buffers debe ser
--- responsabilidad del componente superior (`Menu`).
--- Oculta las ventanas del Music Manager sin eliminar sus buffers.
---
--- Los buffers permanecen vivos y pueden volver a mostrarse posteriormente.
---
---@return boolean
function BUFFER:hide()
    local hidden = false

    --------------------------------------------------------------------------
    -- Hide manager window.
    --------------------------------------------------------------------------

    if self.manager_winid
        and vim.api.nvim_win_is_valid(
            self.manager_winid
        )
    then
        vim.api.nvim_win_hide(
            self.manager_winid
        )

        hidden = true
    end

    --------------------------------------------------------------------------
    -- Hide CAVA window.
    --------------------------------------------------------------------------

    if self.cava_winid
        and vim.api.nvim_win_is_valid(
            self.cava_winid
        )
    then
        vim.api.nvim_win_hide(
            self.cava_winid
        )

        hidden = true
    end

    return hidden
end

--- ============================================================================
---                              MODULE
--- ============================================================================

return BUFFER
