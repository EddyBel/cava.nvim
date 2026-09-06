local M = {}

----------------------------------------------------------------------
-- User options
--
-- This module does not define defaults.
-- Each subsystem owns its own defaults.
----------------------------------------------------------------------

M.opts = {}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

M.state = {
    running = false,
    buffer = nil,

    artwork_request = 0,
    current_art_url = nil,
}

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

--- Configure Music Manager.
---
--- This module does not define configuration defaults. It only keeps
--- the user-provided options required by the coordinator and forwards
--- subsystem-specific options to their respective modules.
---
---@param opts table|nil User configuration.
---@return nil
function M.setup(opts)
    M.opts = opts or {}

    ------------------------------------------------------------------
    -- Server owns its own configuration.
    ------------------------------------------------------------------

    local SERVER =
        require("cava.core.server")

    SERVER.setup(
        M.opts.server
    )
end

----------------------------------------------------------------------
-- Close
----------------------------------------------------------------------

--- Close and destroy the Music Manager interface.
---
---@return boolean
function M.close()
    M.state.running = false

    M.state.artwork_request =
        M.state.artwork_request + 1

    M.state.current_art_url = nil

    local buffer =
        M.state.buffer

    if not buffer then
        return false
    end

    buffer:close()

    M.state.buffer = nil

    return true
end

----------------------------------------------------------------------
-- Hide
----------------------------------------------------------------------

--- Hide the Music Manager without destroying its buffers.
---
---@return boolean
function M.hide()
    M.state.running = false

    local buffer =
        M.state.buffer

    if not buffer then
        return false
    end

    return buffer:hide()
end

----------------------------------------------------------------------
-- Toggle
----------------------------------------------------------------------

--- Toggle the Music Manager interface.
---
---@return boolean|table|nil
function M.toggle()
    local buffer =
        M.state.buffer

    if not buffer then
        return M.start()
    end

    if buffer:is_open() then
        return M.close()
    end

    if buffer.show then
        local shown =
            buffer:show()

        if shown then
            M.state.running = true
        end

        return shown
    end

    M.close()

    return M.start()
end

----------------------------------------------------------------------
-- Start
----------------------------------------------------------------------

--- Start the Music Manager.
---
---@return table|nil Controller object.
function M.start()
    ------------------------------------------------------------------
    -- Prevent duplicate instances.
    ------------------------------------------------------------------

    if M.state.running then
        return {
            stop = M.close,
            close = M.close,
            hide = M.hide,
            toggle = M.toggle,
        }
    end

    ------------------------------------------------------------------
    -- Dependencies.
    ------------------------------------------------------------------

    local SERVER =
        require("cava.core.server")

    local DRAW =
        require("cava.core.draw")

    local BUFFER =
        require("cava.core.buffer")

    ------------------------------------------------------------------
    -- User options.
    ------------------------------------------------------------------

    local opts =
        M.opts or {}

    ------------------------------------------------------------------
    -- Create buffer.
    --
    -- BUFFER owns all buffer defaults.
    -- We only pass the user's overrides.
    ------------------------------------------------------------------

    local buffer =
        BUFFER.new(
            opts.buffer
        )

    M.state.buffer =
        buffer

    M.state.running = true

    ------------------------------------------------------------------
    -- Local helper.
    ------------------------------------------------------------------

    local function is_running()
        return M.state.running
            and M.state.buffer == buffer
    end

    ------------------------------------------------------------------
    -- Stop polling.
    ------------------------------------------------------------------

    local function stop()
        M.state.running = false

        M.state.artwork_request =
            M.state.artwork_request + 1
    end

    ------------------------------------------------------------------
    -- Artwork
    ------------------------------------------------------------------

    local function update_artwork(metadata)
        if not is_running() then
            return
        end

        local artwork_opts =
            opts.artwork or {}

        if artwork_opts.enabled == false then
            return
        end

        local art_url =
            metadata
            and metadata.art_url

        --------------------------------------------------------------
        -- No artwork.
        --------------------------------------------------------------

        if not art_url or art_url == "" then
            M.state.artwork_request =
                M.state.artwork_request + 1

            M.state.current_art_url = nil

            buffer:clear_artwork()

            return
        end

        --------------------------------------------------------------
        -- Already displayed.
        --------------------------------------------------------------

        if art_url == M.state.current_art_url then
            return
        end

        --------------------------------------------------------------
        -- New artwork request.
        --------------------------------------------------------------

        M.state.artwork_request =
            M.state.artwork_request + 1

        local request_id =
            M.state.artwork_request

        --------------------------------------------------------------
        -- Calculate artwork dimensions.
        --------------------------------------------------------------

        local width, height =
            buffer:get_artwork_dimensions()

        if width <= 0 or height <= 0 then
            return
        end

        --------------------------------------------------------------
        -- Request artwork.
        --------------------------------------------------------------

        local function request_artwork()
            if not is_running() then
                return
            end

            if request_id ~= M.state.artwork_request then
                return
            end

            SERVER.get(
                "/player/artwork",
                function(ok, data)
                    if not is_running() then
                        return
                    end

                    if request_id
                        ~= M.state.artwork_request
                    then
                        return
                    end

                    if not ok then
                        vim.defer_fn(
                            request_artwork,
                            100
                        )

                        return
                    end

                    local artwork =
                        data.artwork

                    if not artwork then
                        vim.defer_fn(
                            request_artwork,
                            100
                        )

                        return
                    end

                    local path =
                        artwork.path

                    if not path or path == "" then
                        vim.defer_fn(
                            request_artwork,
                            100
                        )

                        return
                    end

                    --------------------------------------------------
                    -- Render artwork.
                    --------------------------------------------------

                    SERVER.post(
                        "/image/render",
                        {
                            path = path,

                            size = {
                                width = width,
                                height = height,
                            },

                            font_ratio =
                                artwork_opts.font_ratio
                                or "1/2",
                        },

                        function(
                            render_ok,
                            render_data
                        )
                            if not is_running() then
                                return
                            end

                            if request_id
                                ~= M.state.artwork_request
                            then
                                return
                            end

                            if not render_ok then
                                return
                            end

                            if not buffer:is_open() then
                                return
                            end

                            local render =
                                render_data.render

                            if type(render) ~= "table" then
                                return
                            end

                            if type(render.lines) ~= "table" then
                                return
                            end

                            buffer:set_artwork(
                                render.lines,
                                render.highlights or {}
                            )

                            M.state.current_art_url =
                                art_url
                        end
                    )
                end
            )
        end

        request_artwork()
    end

    ------------------------------------------------------------------
    -- Player metadata.
    ------------------------------------------------------------------

    local function update_player()
        if not is_running() then
            return
        end

        SERVER.get(
            "/player/metadata",
            function(ok, data)
                if not is_running() then
                    return
                end

                if not ok then
                    vim.defer_fn(
                        update_player,
                        (opts.playerctl
                            and opts.playerctl.interval)
                        or 500
                    )

                    return
                end

                if not buffer:is_open() then
                    stop()
                    return
                end

                local metadata =
                    data.metadata

                if metadata then
                    buffer:update_music(
                        metadata
                    )

                    update_artwork(
                        metadata
                    )
                end

                if is_running() then
                    vim.defer_fn(
                        update_player,
                        (opts.playerctl
                            and opts.playerctl.interval)
                        or 500
                    )
                end
            end
        )
    end

    ------------------------------------------------------------------
    -- CAVA.
    ------------------------------------------------------------------

    local function update_cava()
        if not is_running() then
            return
        end

        SERVER.get(
            "/cava/frame",
            function(ok, data)
                if not is_running() then
                    return
                end

                if not ok then
                    return
                end

                if not buffer:is_open() then
                    return
                end

                local frame_data =
                    data.frame

                if type(frame_data) ~= "table" then
                    return
                end

                local width =
                    buffer:get_cava_width()

                local height =
                    buffer:get_cava_height()

                if width <= 0
                    or height <= 0
                then
                    return
                end

                local frame =
                    DRAW.vertical(
                        frame_data,
                        height,
                        {
                            width = width,
                        }
                    )

                buffer:draw(frame)
            end
        )

        if is_running() then
            vim.defer_fn(
                update_cava,
                (opts.cava
                    and opts.cava.interval)
                or 33
            )
        end
    end

    ------------------------------------------------------------------
    -- Create UI.
    ------------------------------------------------------------------

    if not buffer:create() then
        M.state.buffer = nil
        M.state.running = false

        return nil
    end

    ------------------------------------------------------------------
    -- Start backend.
    --
    -- SERVER already received its options through setup().
    ------------------------------------------------------------------

    SERVER.ensure(function(ok, data)
        if not is_running() then
            return
        end

        if not ok then
            vim.notify(
                "MusicManager: "
                .. tostring(data),
                vim.log.levels.ERROR
            )

            stop()

            return
        end

        if not buffer:is_open() then
            stop()
            return
        end

        --------------------------------------------------------------
        -- Initial player request.
        --------------------------------------------------------------

        update_player()

        --------------------------------------------------------------
        -- Start CAVA polling.
        --------------------------------------------------------------

        update_cava()
    end)

    ------------------------------------------------------------------
    -- Return controller.
    ------------------------------------------------------------------

    return {
        stop = stop,
        close = M.close,
        hide = M.hide,
        toggle = M.toggle,
    }
end

return M
