-- ============================================================================
-- POLLER
-- ============================================================================
--
-- Este módulo se encarga exclusivamente de la sincronización con el backend:
--
--     SERVER  →  Poller  →  Menu (Player / Cava)
--
-- Hace polling periódico de:
--
--   - metadata de la canción;
--   - artwork principal;
--   - artwork de la tracklist;
--   - frames de CAVA;
--   - información general del reproductor.
--
-- Poller no construye ventanas ni layouts.
-- Solamente obtiene datos, solicita procesamiento y los entrega a los
-- componentes correspondientes.
--
-- La configuración es GLOBAL:
--
--     config.menu
--     config.player
--     config.cava
--     config.poller
--     config.artwork
--     config.tracklist_artwork
--     ...
--
-- Poller únicamente define defaults para `config.poller`.
-- Las demás secciones son propiedad de sus respectivos módulos.
-- ============================================================================
local Poller = {}
Poller.__index = Poller
-- ============================================================================
--                             CONFIGURATION
-- ============================================================================
---@type table
Poller.config = {
    --- Intervalo (ms) entre solicitudes de metadata del reproductor.
    player_interval = 1000,
    --- Intervalo (ms) de reintento.
    retry_interval = 100,
}
-- ============================================================================
--                             HELPERS
-- ============================================================================
--- Compara dos frames CRUDOS de CAVA (arrays de números, tal como llegan
--- del backend, ANTES de pasar por DRAW). Se usa para decidir si vale la
--- pena siquiera generar el frame visual (líneas + highlights): si los
--- datos de entrada no cambiaron, el resultado de DRAW tampoco cambiaría,
--- así que ni se llama a `DRAW.vertical()`.
---
--- Barata: son sólo los N valores crudos que expone CAVA (habitualmente
--- unas pocas decenas), no el grid width x height ya expandido/dibujado.
---
---@param a table|nil
---@param b table|nil
---@return boolean
local function raw_cava_frame_equal(a, b)
    if not a or not b then
        return false
    end
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

-- ============================================================================
--                             DATA VALIDATION
-- ============================================================================

--- Determina si un valor Lua es un valor nulo proveniente de vim.json.
---
---@param value any
---@return boolean
local function is_null(value)
    return value == nil
        or value == vim.NIL
end


--- Determina si una metadata es válida para el Player.
---
---@param metadata any
---@return boolean
local function is_valid_metadata(metadata)
    if is_null(metadata) then
        return false
    end

    if type(metadata) ~= "table" then
        return false
    end

    return true
end


--- Determina si una respuesta contiene una tracklist válida.
---
---@param data any
---@return boolean
local function is_valid_tracklist_response(data)
    if is_null(data) then
        return false
    end

    if type(data) ~= "table" then
        return false
    end

    if is_null(data.tracklist) then
        return false
    end

    if type(data.tracklist) ~= "table" then
        return false
    end

    return #data.tracklist > 0
end

-- ============================================================================
--                             CONSTRUCTOR
-- ============================================================================
--- Crea un nuevo Poller.
---
--- `opts.config` representa la configuración GLOBAL de la aplicación.
---
--- Ejemplo:
---
---     local poller = Poller.new({
---         menu = menu,
---         server = server,
---         draw = draw,
---
---         config = {
---             menu = {...},
---             player = {...},
---             cava = {...},
---             poller = {
---                 player_interval = 500,
---             },
---             artwork = {...},
---             tracklist_artwork = {...},
---         },
---     })
---
---@param opts table
---@return table self
function Poller.new(opts)
    opts = opts or {}
    assert(
        opts.menu,
        "Poller.new: falta 'menu'"
    )
    assert(
        opts.server,
        "Poller.new: falta 'server'"
    )
    assert(
        opts.draw,
        "Poller.new: falta 'draw'"
    )
    local self =
        setmetatable({}, Poller)
    --------------------------------------------------------------------------
    -- Dependencies
    --------------------------------------------------------------------------
    self.menu =
        opts.menu
    self.server =
        opts.server
    self.draw =
        opts.draw
    --------------------------------------------------------------------------
    -- Global configuration
    --------------------------------------------------------------------------
    --
    -- Poller conserva la configuración GLOBAL completa.
    --
    -- Los defaults de Poller viven exclusivamente dentro de:
    --
    --     self.config.poller
    --
    -- Las demás secciones pertenecen a otros módulos.
    --------------------------------------------------------------------------
    self.config =
        vim.tbl_deep_extend(
            "force",
            {
                poller = Poller.config,
            },
            opts.config or {}
        )
    self.config.poller =
        vim.tbl_deep_extend(
            "force",
            Poller.config,
            self.config.poller or {}
        )
    self.running =
        false
    --------------------------------------------------------------------------
    -- Artwork principal
    --------------------------------------------------------------------------
    self.artwork_request =
        0
    self.current_art_url =
        nil
    self.pending_art_url =
        nil
    --------------------------------------------------------------------------
    -- Tracklist
    --------------------------------------------------------------------------
    self.tracklist_signature =
        nil
    self.tracklist_state =
    {}
    --------------------------------------------------------------------------
    -- Tracklist artwork
    --------------------------------------------------------------------------
    self.tracklist_artwork_request =
        0
    self.tracklist_artwork_cache =
    {}
    self.tracklist_artwork_pending =
    {}
    --- Último `path` efectivamente aplicado en cada índice de la tracklist.
    self.tracklist_artwork_applied =
    {}
    --------------------------------------------------------------------------
    -- CAVA
    --------------------------------------------------------------------------
    --- Generación de la sesión actual de CAVA.
    ---
    --- Se utiliza para invalidar callbacks pertenecientes a sesiones
    --- anteriores.
    self._cava_generation =
        0
    --- Número de secuencia del último request.
    self._cava_seq =
        0
    --- Número de peticiones /cava/frame actualmente en vuelo.
    self._cava_inflight =
        0
    --- Buffer de frames recibidos.
    self._cava_buffer =
    {}
    --- Último frame efectivamente mostrado.
    self._cava_last_frame =
        nil
    --- Timer de render de CAVA.
    self._cava_render_timer =
        nil
    --- Throttle del log de debug.
    self._cava_debug_last =
        0
    --------------------------------------------------------------------------
    -- CAVA — cache de datos crudos para evitar llamar a DRAW cuando la
    -- entrada no cambió (ver `raw_cava_frame_equal`).
    --------------------------------------------------------------------------
    --- Últimos datos crudos (amplitudes) efectivamente dibujados.
    self._cava_last_raw_frame =
        nil
    --- Ancho/alto usados para el último dibujado (un cambio de tamaño
    --- obliga a redibujar aunque los datos crudos sean iguales).
    self._cava_last_raw_width =
        nil
    self._cava_last_raw_height =
        nil
    return self
end

-- ============================================================================
--                             STATE
-- ============================================================================
---@return boolean
function Poller:is_running()
    return self.running == true
end

-- ============================================================================
--                             CONFIGURATION
-- ============================================================================
--- Obtiene la configuración propia de Poller.
---
---@return table
function Poller:get_config()
    return self.config.poller
end

-- ============================================================================
--                             CAVA STATE
-- ============================================================================
--- Indica si CAVA está habilitado.
---
--- Poller no posee la configuración de CAVA.
---
--- La decisión pertenece a Menu/Cava.
---
---@return boolean
function Poller:is_cava_enabled()
    if not self.menu then
        return false
    end
    if type(
            self.menu.is_cava_enabled
        ) ~= "function"
    then
        return false
    end
    return self.menu:is_cava_enabled()
end

-- ============================================================================
--                       TRACKLIST ARTWORK STATE RESET
-- ============================================================================
--- Reinicia todo el estado relacionado con la asociación
--- canción <-> artwork de la tracklist.
---
--- NO toca `tracklist_artwork_cache`.
function Poller:_reset_tracklist_artwork_state()
    self.tracklist_artwork_request =
        self.tracklist_artwork_request + 1
    self.tracklist_signature =
        nil
    self.tracklist_state =
    {}
    self.tracklist_artwork_pending =
    {}
    self.tracklist_artwork_applied =
    {}
end

-- ============================================================================
--                             STOP
-- ============================================================================
--- Detiene el polling.
function Poller:stop()
    self.running =
        false
    --------------------------------------------------------------------------
    -- Invalidar artwork principal
    --------------------------------------------------------------------------
    self.artwork_request =
        self.artwork_request + 1
    self.pending_art_url =
        nil
    self.current_art_url =
        nil
    --------------------------------------------------------------------------
    -- Invalidar artwork de tracklist
    --------------------------------------------------------------------------
    self:_reset_tracklist_artwork_state()
    --------------------------------------------------------------------------
    -- CAVA
    --
    -- Incluso si CAVA está deshabilitado, limpiamos su estado para que
    -- cualquier callback perteneciente a una sesión anterior quede
    -- invalidado.
    --------------------------------------------------------------------------
    self._cava_generation =
        self._cava_generation + 1
    self._cava_inflight =
        0
    self._cava_buffer =
    {}
    self._cava_last_frame =
        nil
    self._cava_last_raw_frame =
        nil
    self._cava_last_raw_width =
        nil
    self._cava_last_raw_height =
        nil
    self:_stop_cava_render_timer()
    --------------------------------------------------------------------------
    -- Limpiar artwork de tracklist
    --------------------------------------------------------------------------
    if self.menu.player then
        if type(
                self.menu.player.clear_tracklist_artwork
            ) == "function"
        then
            self.menu.player:clear_tracklist_artwork()
        end
    end
end

-- ============================================================================
--                             RESET PLAYER
-- ============================================================================

--- Regresa el Player al estado vacío/layout inicial.
---
--- Se utiliza cuando:
---
---   - el servidor se desconecta;
---   - no existe un provider compatible;
---   - no existe metadata;
---   - la respuesta del backend no es compatible;
---   - desaparece la fuente de reproducción.
function Poller:reset_player()
    local player = self.menu.player

    if not player then
        return
    end

    --------------------------------------------------------------------------
    -- Invalidar artwork principal
    --------------------------------------------------------------------------

    self.artwork_request =
        self.artwork_request + 1

    self.current_art_url =
        nil

    self.pending_art_url =
        nil

    if type(player.clear_artwork) == "function" then
        player:clear_artwork()
    end

    --------------------------------------------------------------------------
    -- Limpiar metadata
    --------------------------------------------------------------------------

    if type(player.clear_music) == "function" then
        player:clear_music()
    end

    --------------------------------------------------------------------------
    -- Limpiar tracklist
    --------------------------------------------------------------------------

    self:clear_tracklist_artwork()

    if type(player.clear_tracklist) == "function" then
        player:clear_tracklist()
    end

    --------------------------------------------------------------------------
    -- Limpiar selección / estado adicional si existe
    --------------------------------------------------------------------------

    if type(player.set_tracklist_selected) == "function" then
        player:set_tracklist_selected(nil)
    end
end

-- ============================================================================
--                             ARTWORK PRINCIPAL
-- ============================================================================
--- Solicita y aplica el artwork correspondiente a la metadata actual.
---
---@param metadata table|nil
function Poller:sync_artwork(metadata)
    if not self:is_running() then
        return
    end

    local artwork_opts =
        self.config.artwork or {}

    if artwork_opts.enabled == false then
        return
    end

    local player =
        self.menu.player

    if not player then
        return
    end

    --------------------------------------------------------------------------
    -- Metadata inválida
    --------------------------------------------------------------------------

    if not is_valid_metadata(metadata) then
        self.artwork_request =
            self.artwork_request + 1

        self.current_art_url =
            nil

        self.pending_art_url =
            nil

        player:clear_artwork()

        return
    end

    --------------------------------------------------------------------------
    -- Obtener artwork
    --------------------------------------------------------------------------

    local art_url =
        metadata.art_url

    if is_null(art_url)
        or type(art_url) ~= "string"
        or art_url == ""
    then
        self.artwork_request =
            self.artwork_request + 1

        self.current_art_url =
            nil

        self.pending_art_url =
            nil

        player:clear_artwork()

        return
    end

    if art_url == self.current_art_url then
        return
    end

    self.artwork_request =
        self.artwork_request + 1

    local request_id =
        self.artwork_request

    local width, height =
        player:get_artwork_dimensions()

    if width <= 0
        or height <= 0
    then
        return
    end

    local function is_stale()
        return not self:is_running()
            or request_id
            ~= self.artwork_request
    end

    local function request_artwork()
        if is_stale() then
            return
        end

        self.server.get(
            "/player/artwork",
            function(ok, data)
                if is_stale() then
                    return
                end

                if not ok
                    or not data
                    or type(data) ~= "table"
                then
                    vim.defer_fn(
                        request_artwork,
                        self.config.poller.retry_interval
                    )

                    return
                end

                local path =
                    data.path

                if not path
                    and type(data.artwork) == "table"
                then
                    path =
                        data.artwork.path
                end

                if is_null(path)
                    or type(path) ~= "string"
                    or path == ""
                then
                    vim.defer_fn(
                        request_artwork,
                        self.config.poller.retry_interval
                    )

                    return
                end

                self.server.post(
                    "/image/render",
                    {
                        path = path,
                        size = {
                            width = width,
                            height = height,
                        },
                        font_ratio =
                            artwork_opts.font_ratio,
                    },
                    function(
                        render_ok,
                        render_data
                    )
                        if is_stale() then
                            return
                        end

                        if not render_ok then
                            return
                        end

                        if not self.menu:is_open() then
                            return
                        end

                        local render =
                            render_data
                            and render_data.render

                        if type(render) ~= "table"
                            or type(render.lines) ~= "table"
                        then
                            return
                        end

                        player:set_artwork(
                            render.lines,
                            render.highlights or {}
                        )

                        self.current_art_url =
                            art_url
                    end
                )
            end
        )
    end

    request_artwork()
end

-- ============================================================================
--                       TRACKLIST SIGNATURE
-- ============================================================================
--- Genera una firma estable para la tracklist.
---
---@param tracklist table
---@return string
function Poller:get_tracklist_signature(
    tracklist
)
    if type(tracklist) ~= "table" then
        return ""
    end
    local parts = {}
    for position, track in ipairs(tracklist) do
        if type(track) == "table" then
            parts[#parts + 1] =
                table.concat({
                    tostring(position),
                    tostring(track.track_id or ""),
                    tostring(track.title or ""),
                    tostring(track.artist or ""),
                    tostring(track.album or ""),
                    tostring(track.duration or ""),
                    tostring(track.selected or false),
                    tostring(track.artwork_path or ""),
                }, "|")
        end
    end
    return table.concat(
        parts,
        ";;"
    )
end

-- ============================================================================
--                       TRACKLIST STATE
-- ============================================================================
--- Construye el estado actual de la tracklist.
---
--- La información se indexa por track_id y no por posición.
---
---@param tracklist table
---@return table
function Poller:build_tracklist_state(
    tracklist
)
    local state = {}
    if type(tracklist) ~= "table" then
        return state
    end
    for position, track in ipairs(tracklist) do
        if type(track) == "table" then
            local track_id =
                track.track_id
            if track_id == nil then
                track_id =
                    track.index
            end
            if track_id == nil then
                track_id =
                    position
            end
            track_id =
                tostring(track_id)
            state[track_id] = {
                index =
                    position,
                backend_index =
                    track.index,
                artwork_path =
                    track.artwork_path,
            }
        end
    end
    return state
end

--- Busca la posición actual de una canción.
---
---@param track_id string
---@param path string
---@return number|nil
function Poller:find_track_index(
    track_id,
    path
)
    local state =
        self.tracklist_state
    local entry =
        state[track_id]
    if not entry then
        return nil
    end
    if path
        and entry.artwork_path ~= path
    then
        return nil
    end
    return entry.index
end

-- ============================================================================
--                       TRACKLIST ARTWORK CACHE
-- ============================================================================
--- Limpia los renders asociados actualmente a la tracklist.
function Poller:clear_tracklist_artwork()
    self:_reset_tracklist_artwork_state()
    if self.menu.player then
        if type(
                self.menu.player.clear_tracklist_artwork
            ) == "function"
        then
            self.menu.player:clear_tracklist_artwork()
        end
    end
end

--- Obtiene un render de Chafa desde la caché.
---
---@param path string
---@return table|nil
function Poller:get_cached_tracklist_artwork(
    path
)
    if not path
        or path == ""
    then
        return nil
    end
    return self.tracklist_artwork_cache[path]
end

--- Guarda un render de Chafa en la caché.
---
---@param path string
---@param render table
function Poller:set_cached_tracklist_artwork(
    path,
    render
)
    if not path
        or path == ""
    then
        return
    end
    if type(render) ~= "table" then
        return
    end
    if type(render.lines) ~= "table" then
        return
    end
    self.tracklist_artwork_cache[path] = {
        lines =
            render.lines,
        highlights =
            render.highlights or {},
    }
end

--- Comprueba si `path` ya está aplicado en `index`.
---
---@param index number
---@param path string
---@return boolean
function Poller:is_artwork_applied(
    index,
    path
)
    return self.tracklist_artwork_applied[index]
        == path
end

--- Marca `path` como aplicado en `index`.
---
---@param index number
---@param path string
function Poller:mark_artwork_applied(
    index,
    path
)
    self.tracklist_artwork_applied[index] =
        path
end

-- ============================================================================
--                       RENDER TRACKLIST ARTWORK
-- ============================================================================
--- Renderiza una portada de tracklist mediante Chafa.
---
---@param track_id string
---@param path string
---@param request_id number
function Poller:render_tracklist_artwork(
    track_id,
    path,
    request_id
)
    if not self:is_running() then
        return
    end
    if request_id
        ~= self.tracklist_artwork_request
    then
        return
    end
    if not path
        or path == ""
    then
        return
    end
    local player =
        self.menu.player
    if not player then
        return
    end
    --------------------------------------------------------------------------
    -- Revisar caché
    --------------------------------------------------------------------------
    local cached =
        self:get_cached_tracklist_artwork(
            path
        )
    if cached then
        local index =
            self:find_track_index(
                track_id,
                path
            )
        if index == nil then
            return
        end
        if self:is_artwork_applied(
                index,
                path
            )
        then
            return
        end
        player:set_tracklist_artwork(
            index,
            cached.lines,
            cached.highlights
        )
        self:mark_artwork_applied(
            index,
            path
        )
        return
    end
    --------------------------------------------------------------------------
    -- Evitar solicitudes duplicadas
    --------------------------------------------------------------------------
    if self.tracklist_artwork_pending[path] then
        return
    end
    self.tracklist_artwork_pending[path] =
        true
    --------------------------------------------------------------------------
    -- Configuración
    --------------------------------------------------------------------------
    local artwork_opts =
        self.config.tracklist_artwork
        or {}
    local width =
        tonumber(
            artwork_opts.width
        ) or 6
    local height =
        tonumber(
            artwork_opts.height
        ) or 3
    if width <= 0 then
        width = 6
    end
    if height <= 0 then
        height = 3
    end
    --------------------------------------------------------------------------
    -- Solicitar render a Chafa
    --------------------------------------------------------------------------
    self.server.post(
        "/image/render",
        {
            path = path,
            size = {
                width = width,
                height = height,
            },
            font_ratio =
                artwork_opts.font_ratio,
        },
        function(ok, data)
            self.tracklist_artwork_pending[path] =
                nil
            if not self:is_running() then
                return
            end
            if request_id
                ~= self.tracklist_artwork_request
            then
                return
            end
            if not ok then
                return
            end
            if not self.menu:is_open() then
                return
            end
            local render =
                data
                and data.render
            if type(render) ~= "table"
                or type(render.lines) ~= "table"
            then
                return
            end
            self:set_cached_tracklist_artwork(
                path,
                render
            )
            local index =
                self:find_track_index(
                    track_id,
                    path
                )
            if index == nil then
                return
            end
            if self:is_artwork_applied(
                    index,
                    path
                )
            then
                return
            end
            player:set_tracklist_artwork(
                index,
                render.lines,
                render.highlights or {}
            )
            self:mark_artwork_applied(
                index,
                path
            )
        end
    )
end

-- ============================================================================
--                       SYNC TRACKLIST ARTWORK
-- ============================================================================
--- Procesa las imágenes locales proporcionadas por la API.
---
--- La asociación canción <-> artwork ya viene resuelta por el provider.
---
--- Esta función decide exclusivamente cuándo debe reconstruirse la
--- representación visual de la tracklist.
function Poller:sync_tracklist_artwork(
    tracklist
)
    if not self:is_running() then
        return
    end
    local artwork_opts =
        self.config.tracklist_artwork
        or {}
    local player =
        self.menu.player
    if not player then
        return
    end
    --------------------------------------------------------------------------
    -- Artwork deshabilitado o tracklist inválida.
    --------------------------------------------------------------------------
    if artwork_opts.enabled == false
        or type(tracklist) ~= "table"
    then
        if self.tracklist_signature ~= "" then
            self:_reset_tracklist_artwork_state()
            self.tracklist_signature =
            ""
            if type(
                    player.clear_tracklist_artwork
                ) == "function"
            then
                player:clear_tracklist_artwork()
            end
        end
        return
    end
    --------------------------------------------------------------------------
    -- Calcular firma.
    --------------------------------------------------------------------------
    local signature =
        self:get_tracklist_signature(
            tracklist
        )
    local changed =
        signature ~= self.tracklist_signature
    --------------------------------------------------------------------------
    -- Actualizar tracklist cuando cambió.
    --------------------------------------------------------------------------
    if changed then
        self.tracklist_signature =
            signature
        self.tracklist_artwork_request =
            self.tracklist_artwork_request + 1
        self.tracklist_state =
            self:build_tracklist_state(
                tracklist
            )
        player:update_tracklist(
            tracklist
        )
        self.tracklist_artwork_applied =
        {}
        if type(
                player.clear_tracklist_artwork
            ) == "function"
        then
            player:clear_tracklist_artwork()
        end
    else
        self.tracklist_state =
            self:build_tracklist_state(
                tracklist
            )
    end
    --------------------------------------------------------------------------
    -- Identificador de generación.
    --------------------------------------------------------------------------
    local request_id =
        self.tracklist_artwork_request
    --------------------------------------------------------------------------
    -- Procesar artwork.
    --------------------------------------------------------------------------
    for position, track in ipairs(tracklist) do
        if type(track) == "table" then
            local track_id =
                track.track_id
            if track_id == nil then
                track_id =
                    track.index
            end
            if track_id == nil then
                track_id =
                    position
            end
            track_id =
                tostring(track_id)
            local path =
                track.artwork_path
            if type(path) == "string"
                and path ~= ""
            then
                self:render_tracklist_artwork(
                    track_id,
                    path,
                    request_id
                )
            end
        end
    end
end

-- ============================================================================
--                             PLAYER METADATA
-- ============================================================================

function Poller:sync_player()
    if not self:is_running() then
        return
    end

    self.server.get(
        "/player/metadata",
        function(ok, data)
            if not self:is_running() then
                return
            end

            ------------------------------------------------------------------
            -- Servidor desconectado / respuesta inválida
            ------------------------------------------------------------------

            if not ok
                or type(data) ~= "table"
            then
                self:reset_player()

                vim.defer_fn(
                    function()
                        self:sync_player()
                    end,
                    self.config.poller.retry_interval
                )

                return
            end

            ------------------------------------------------------------------
            -- Menú cerrado
            ------------------------------------------------------------------

            if not self.menu:is_open() then
                self:stop()
                return
            end

            ------------------------------------------------------------------
            -- Metadata
            ------------------------------------------------------------------

            local metadata =
                data.metadata

            ------------------------------------------------------------------
            -- No existe fuente compatible / no hay reproducción
            ------------------------------------------------------------------

            if not is_valid_metadata(metadata) then
                self:reset_player()

                if self:is_running() then
                    vim.defer_fn(
                        function()
                            self:sync_player()
                        end,
                        self.config.poller.player_interval
                    )
                end

                return
            end

            ------------------------------------------------------------------
            -- Metadata válida
            ------------------------------------------------------------------

            self.menu.player:update_music(
                metadata
            )

            self:sync_artwork(
                metadata
            )

            ------------------------------------------------------------------
            -- Siguiente actualización
            ------------------------------------------------------------------

            if self:is_running() then
                vim.defer_fn(
                    function()
                        self:sync_player()
                    end,
                    self.config.poller.player_interval
                )
            end
        end
    )
end

-- ============================================================================
--                             PLAYER INFO
-- ============================================================================

function Poller:sync_player_info()
    if not self:is_running() then
        return
    end

    self.server.get(
        "/player",
        function(ok, data)
            if not self:is_running() then
                return
            end

            if ok
                and type(data) == "table"
                and type(data.player) == "table"
            then
                if type(
                        self.menu.player.update_provider
                    ) == "function"
                then
                    self.menu.player:update_provider(
                        data.player.provider
                    )
                end
            end

            if self:is_running() then
                vim.defer_fn(
                    function()
                        self:sync_player_info()
                    end,
                    self.config.poller.player_interval * 2
                )
            end
        end
    )
end

-- ============================================================================
--                             CAVA — FETCH PIPELINE
-- ============================================================================
--- Inserta un frame recibido en el buffer.
---
---@param seq number
---@param dispatched_at number
---@param frame_data table
function Poller:_cava_buffer_insert(
    seq,
    dispatched_at,
    frame_data
)
    local buffer =
        self._cava_buffer
    local index =
        #buffer + 1
    for i = #buffer, 1, -1 do
        if buffer[i].seq < seq then
            break
        end
        index = i
    end
    table.insert(
        buffer,
        index,
        {
            seq =
                seq,
            dispatched_at =
                dispatched_at,
            frame =
                frame_data,
        }
    )
    local cava_opts =
        self.config.cava
        or {}
    local max_frames =
        math.max(
            1,
            tonumber(
                cava_opts.max_buffered_frames
            ) or 12
        )
    while #buffer > max_frames do
        table.remove(
            buffer,
            1
        )
    end
end

--- Dispara una petición de /cava/frame.
function Poller:_cava_dispatch_request()
    if not self:is_running() then
        return
    end
    if not self:is_cava_enabled() then
        return
    end
    local opts =
        self.config.cava
    if type(opts) ~= "table" then
        return
    end
    local max_inflight =
        math.max(
            1,
            tonumber(
                opts.max_inflight
            ) or 1
        )
    if self._cava_inflight
        >= max_inflight
    then
        return
    end
    local generation =
        self._cava_generation
    self._cava_seq =
        self._cava_seq + 1
    local seq =
        self._cava_seq
    self._cava_inflight =
        self._cava_inflight + 1
    local dispatched_at =
        vim.loop.hrtime()
    local function fire()
        if not self:is_running()
            or generation
            ~= self._cava_generation
            or not self:is_cava_enabled()
        then
            self._cava_inflight =
                math.max(
                    0,
                    self._cava_inflight - 1
                )
            return
        end
        self.server.get(
            "/cava/frame",
            function(ok, data)
                self._cava_inflight =
                    math.max(
                        0,
                        self._cava_inflight - 1
                    )
                if self:is_running()
                    and generation
                    == self._cava_generation
                    and self:is_cava_enabled()
                then
                    if ok
                        and type(data) == "table"
                        and type(data.frame) == "table"
                    then
                        self:_cava_buffer_insert(
                            seq,
                            dispatched_at,
                            data.frame
                        )
                    end
                end
                self:_cava_dispatch_request()
            end
        )
    end
    local floor =
        math.max(
            0,
            tonumber(
                opts.min_request_interval
            ) or 0
        )
    if floor > 0 then
        vim.defer_fn(
            fire,
            floor
        )
    else
        fire()
    end
end

-- ============================================================================
--                             CAVA — RENDER TIMER
-- ============================================================================
---@return number
function Poller:_cava_render_interval_ms()
    local opts =
        self.config.cava
        or {}
    local fps =
        math.max(
            1,
            tonumber(
                opts.fps
            ) or 30
        )
    return math.floor(
        1000 / fps
    )
end

--- Log de depuración.
---
---@param now number
function Poller:_cava_debug_log(now)
    local opts =
        self.config.cava
        or {}
    if (now - self._cava_debug_last)
        < 1e9
    then
        return
    end
    self._cava_debug_last =
        now
    print(string.format(
        "CAVA | buffer: %d frames | inflight: %d | fps: %d | delay: %dms",
        #self._cava_buffer,
        self._cava_inflight,
        tonumber(opts.fps) or 30,
        tonumber(opts.delay_ms) or 0
    ))
end

--- Tick del timer de render.
---
--- Antes de generar el frame visual con DRAW, compara los datos CRUDOS
--- (amplitudes) contra los del último tick: si son idénticos y las
--- dimensiones del panel no cambiaron, ni siquiera se llama a
--- `DRAW.vertical()` — no tiene sentido regenerar líneas/highlights que
--- van a salir exactamente iguales. `Cava:draw()` todavía aplicaría su
--- propio filtro de "frame idéntico" más abajo, pero para qué pagar el
--- costo de generarlo si ya sabemos que la entrada no cambió.
function Poller:_cava_render_tick()
    if not self:is_running() then
        return
    end
    if not self:is_cava_enabled() then
        return
    end
    local opts =
        self.config.cava
    if type(opts) ~= "table" then
        return
    end
    local delay_ns =
        (tonumber(
            opts.delay_ms
        ) or 0) * 1e6
    local now =
        vim.loop.hrtime()
    local buffer =
        self._cava_buffer
    local ready =
        nil
    while buffer[1]
        and (
            buffer[1].dispatched_at
            + delay_ns
        ) <= now
    do
        ready =
            table.remove(
                buffer,
                1
            )
    end
    if ready then
        self._cava_last_frame =
            ready.frame
    end
    local frame_data =
        self._cava_last_frame
    if not frame_data then
        return
    end
    if not self.menu:is_open() then
        return
    end
    if not self.menu.cava then
        return
    end
    local width, height =
        self.menu.cava:get_dimensions()
    if width <= 0
        or height <= 0
    then
        return
    end
    --------------------------------------------------------------------------
    -- Pre-check: datos crudos idénticos + mismas dimensiones -> no hay
    -- nada nuevo que dibujar, ni vale la pena generarlo.
    --------------------------------------------------------------------------
    if
        width == self._cava_last_raw_width
        and height == self._cava_last_raw_height
        and raw_cava_frame_equal(frame_data, self._cava_last_raw_frame)
    then
        return
    end
    local frame =
        self.draw.vertical(
            frame_data,
            height,
            {
                width = width,
            }
        )
    self.menu.cava:draw(
        frame
    )
    self._cava_last_raw_frame =
        frame_data
    self._cava_last_raw_width =
        width
    self._cava_last_raw_height =
        height
    if opts.debug then
        self:_cava_debug_log(now)
    end
end

--- Arranca el timer de render de CAVA.
function Poller:_start_cava_render_timer()
    self:_stop_cava_render_timer()
    if not self:is_cava_enabled() then
        return
    end
    local interval =
        self:_cava_render_interval_ms()
    local timer =
        vim.loop.new_timer()
    self._cava_render_timer =
        timer
    timer:start(
        0,
        interval,
        vim.schedule_wrap(function()
            self:_cava_render_tick()
        end)
    )
end

--- Detiene y libera el timer de render.
function Poller:_stop_cava_render_timer()
    if self._cava_render_timer then
        pcall(function()
            self._cava_render_timer:stop()
            self._cava_render_timer:close()
        end)
        self._cava_render_timer =
            nil
    end
end

-- ============================================================================
--                             CAVA — ENTRY POINT
-- ============================================================================
--- Inicia la sincronización de CAVA.
---
--- Si CAVA está deshabilitado, no realiza absolutamente ninguna operación
--- relacionada con el backend ni crea el timer de render.
function Poller:sync_cava()
    if not self:is_running() then
        return
    end
    if not self:is_cava_enabled() then
        self._cava_generation =
            self._cava_generation + 1
        self._cava_buffer =
        {}
        self._cava_inflight =
            0
        self._cava_seq =
            0
        self._cava_last_frame =
            nil
        self._cava_last_raw_frame =
            nil
        self._cava_last_raw_width =
            nil
        self._cava_last_raw_height =
            nil
        self:_stop_cava_render_timer()
        return
    end
    self._cava_generation =
        self._cava_generation + 1
    self._cava_buffer =
    {}
    self._cava_inflight =
        0
    self._cava_seq =
        0
    self._cava_last_frame =
        nil
    self._cava_last_raw_frame =
        nil
    self._cava_last_raw_width =
        nil
    self._cava_last_raw_height =
        nil
    self:_start_cava_render_timer()
    local opts =
        self.config.cava
    if type(opts) ~= "table" then
        return
    end
    local max_inflight =
        math.max(
            1,
            tonumber(
                opts.max_inflight
            ) or 1
        )
    for _ = 1, max_inflight do
        self:_cava_dispatch_request()
    end
end

-- ============================================================================
--                             PLAYER TRACKLIST
-- ============================================================================
--- Solicita el tracklist actual del reproductor.
function Poller:sync_tracklist()
    if not self:is_running() then
        return
    end
    self.server.get(
        "/player/tracklist",
        function(ok, data)
            if not self:is_running() then
                return
            end
            local player =
                self.menu.player
            if not player then
                if self:is_running() then
                    vim.defer_fn(
                        function()
                            self:sync_tracklist()
                        end,
                        self.config.poller.player_interval
                    )
                end
                return
            end
            ------------------------------------------------------------------
            -- Tracklist válida.
            ------------------------------------------------------------------
            if ok
                and type(data) == "table"
                and type(data.tracklist) == "table"
                and #data.tracklist > 0
            then
                self:sync_tracklist_artwork(
                    data.tracklist
                )
            else
                ----------------------------------------------------------------
                -- No hay tracklist.
                ----------------------------------------------------------------
                player:clear_tracklist()
                self:clear_tracklist_artwork()
            end
            ------------------------------------------------------------------
            -- Siguiente actualización.
            ------------------------------------------------------------------
            if self:is_running() then
                vim.defer_fn(
                    function()
                        self:sync_tracklist()
                    end,
                    self.config.poller.player_interval
                )
            end
        end
    )
end

-- ============================================================================
--                             LIFECYCLE
-- ============================================================================
--- Inicia el polling.
function Poller:start()
    if self.running then
        return
    end
    self.running =
        true
    self:sync_player()
    self:sync_player_info()
    self:sync_tracklist()
    --------------------------------------------------------------------------
    -- CAVA es completamente opcional.
    --
    -- La decisión de habilitación pertenece a Menu/Cava.
    --------------------------------------------------------------------------
    if self:is_cava_enabled() then
        self:sync_cava()
    end
end

-- ============================================================================
--                             MODULE
-- ============================================================================
return Poller
