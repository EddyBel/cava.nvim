local PATH = require("cava.utils.paths")


local M = {}


-- =============================================================================
-- CONFIGURATION
-- =============================================================================

M.config = {
    -- -------------------------------------------------------------------------
    -- HTTP server
    -- -------------------------------------------------------------------------

    host = "127.0.0.1",
    port = 9091,

    -- -------------------------------------------------------------------------
    -- Python
    -- -------------------------------------------------------------------------

    python = "python3",

    -- -------------------------------------------------------------------------
    -- Startup
    -- -------------------------------------------------------------------------

    startup_timeout = 5,
    check_interval = 100,

    -- -------------------------------------------------------------------------
    -- Parent process
    -- -------------------------------------------------------------------------

    parent_check_interval = 1.0,

    -- -------------------------------------------------------------------------
    -- Player
    -- -------------------------------------------------------------------------

    player = {
        -- Logical provider.
        --
        -- YoutubeMusic / YoutubeMusic Pear-Desktop API:
        --     YoutubeMusicProvider
        --
        -- Any other value:
        --     playerctl -p <provider>
        --
        provider = "YoutubeMusic",

        -- playerctl executable.
        command = "playerctl",
    },

    -- -------------------------------------------------------------------------
    -- YouTube Music
    -- -------------------------------------------------------------------------

    youtube_music = {
        url = "http://localhost:26538",
    },

    -- -------------------------------------------------------------------------
    -- CAVA
    -- -------------------------------------------------------------------------

    cava = {
        enabled = false,

        framerate = 30,
        bars = 16,
        input_method = "pulse",
        input_source = "auto",
    },
}


-- =============================================================================
-- STATE
-- =============================================================================

M.state = {
    running = false,
    starting = false,
    process = nil,
}


-- =============================================================================
-- URL
-- =============================================================================

local function get_url(path)
    return string.format(
        "http://%s:%d%s",
        M.config.host,
        M.config.port,
        path
    )
end


-- =============================================================================
-- JSON
-- =============================================================================

local function decode_json(data)
    if not data or data == "" then
        return nil
    end

    local ok, result = pcall(
        vim.json.decode,
        data
    )

    if not ok then
        return nil
    end

    return result
end


-- =============================================================================
-- HEALTH CHECK
-- =============================================================================

local function check_server(callback)
    M.get("/", function(ok, data)
        if not ok then
            callback(false, nil)
            return
        end

        if data.status ~= "OK" then
            callback(false, data)
            return
        end

        if data.server ~= "MusicManager" then
            callback(false, data)
            return
        end

        callback(true, data)
    end)
end


-- =============================================================================
-- SERVER STATUS
-- =============================================================================

function M.is_running(callback)
    check_server(function(ok, data)
        M.state.running = ok

        callback(
            ok,
            data
        )
    end)
end

-- =============================================================================
-- SERVER COMMAND
-- =============================================================================

local function get_command()
    local server_path = PATH.get_server_path(
        "server"
    )

    return {
        M.config.python,
        server_path,

        -- ---------------------------------------------------------------------
        -- HTTP
        -- ---------------------------------------------------------------------

        "--host",
        M.config.host,

        "--port",
        tostring(M.config.port),

        -- ---------------------------------------------------------------------
        -- Parent process
        -- ---------------------------------------------------------------------

        "--parent-pid",
        tostring(vim.fn.getpid()),

        "--parent-check-interval",
        tostring(
            M.config.parent_check_interval
        ),

        -- ---------------------------------------------------------------------
        -- Player
        -- ---------------------------------------------------------------------

        "--provider",
        M.config.player.provider,

        "--playerctl",
        M.config.player.command,

        -- ---------------------------------------------------------------------
        -- YouTube Music
        -- ---------------------------------------------------------------------

        "--youtube-music-url",
        M.config.youtube_music.url,

        -- ---------------------------------------------------------------------
        -- CAVA
        -- ---------------------------------------------------------------------

        "--cava",
        M.config.cava.enabled
        and "enabled"
        or "disabled",

        "--cava-framerate",
        tostring(
            M.config.cava.framerate
        ),

        "--cava-bars",
        tostring(
            M.config.cava.bars
        ),

        "--cava-input-method",
        M.config.cava.input_method,

        "--cava-input-source",
        M.config.cava.input_source,
    }
end


-- =============================================================================
-- START
-- =============================================================================

function M.start(callback)
    callback = callback or function() end

    -- -------------------------------------------------------------------------
    -- Already checking / starting
    -- -------------------------------------------------------------------------

    if M.state.starting then
        callback(
            false,
            "Server is already starting."
        )

        return
    end

    -- -------------------------------------------------------------------------
    -- Check whether a server is already running
    -- -------------------------------------------------------------------------

    M.state.starting = true

    check_server(function(ok, data)
        -- ---------------------------------------------------------------------
        -- Correct server already running
        -- ---------------------------------------------------------------------

        if ok then
            M.state.running = true
            M.state.starting = false

            callback(
                true,
                data
            )

            return
        end

        -- ---------------------------------------------------------------------
        -- Start Python server
        -- ---------------------------------------------------------------------

        local command = get_command()

        local process_error = nil
        local process_finished = false

        local process = vim.system(
            command,
            {
                text = true,
            },
            function(result)
                vim.schedule(function()
                    process_finished = true

                    -- ---------------------------------------------------------
                    -- Python process failed
                    -- ---------------------------------------------------------

                    if result.code ~= 0 then
                        process_error =
                            result.stderr

                        if not process_error
                            or process_error == ""
                        then
                            process_error =
                                result.stdout
                        end

                        if not process_error
                            or process_error == ""
                        then
                            process_error =
                                "Python exited with code "
                                .. tostring(result.code)
                        end
                    end
                end)
            end
        )

        M.state.process = process

        -- ---------------------------------------------------------------------
        -- Wait for HTTP server
        -- ---------------------------------------------------------------------

        local elapsed = 0

        local function wait_for_server()
            check_server(function(
                server_ok,
                server_data
            )
                -- -------------------------------------------------------------
                -- Server started successfully
                -- -------------------------------------------------------------

                if server_ok then
                    M.state.running = true
                    M.state.starting = false

                    callback(
                        true,
                        server_data
                    )

                    return
                end

                -- -------------------------------------------------------------
                -- Python process already finished
                -- -------------------------------------------------------------

                if process_finished then
                    M.state.running = false
                    M.state.starting = false
                    M.state.process = nil

                    callback(
                        false,
                        process_error
                        or "MusicManager server exited before starting."
                    )

                    return
                end

                -- -------------------------------------------------------------
                -- Startup timeout
                -- -------------------------------------------------------------

                elapsed = elapsed + (
                    M.config.check_interval / 1000
                )

                if elapsed >= M.config.startup_timeout then
                    M.state.running = false
                    M.state.starting = false
                    M.state.process = nil

                    callback(
                        false,
                        process_error
                        or (
                            "MusicManager server did not "
                            .. "respond within "
                            .. tostring(
                                M.config.startup_timeout
                            )
                            .. " seconds."
                        )
                    )

                    return
                end

                -- -------------------------------------------------------------
                -- Try again
                -- -------------------------------------------------------------

                vim.defer_fn(
                    wait_for_server,
                    M.config.check_interval
                )
            end)
        end

        wait_for_server()
    end)
end

-- =============================================================================
-- ENSURE
-- =============================================================================

function M.ensure(callback)
    callback = callback or function() end

    M.is_running(function(
        running,
        data
    )
        if running then
            callback(
                true,
                data
            )

            return
        end

        M.start(callback)
    end)
end

-- =============================================================================
-- STOP
-- =============================================================================

function M.stop(callback)
    callback = callback or function() end

    M.is_running(function(running)
        if not running then
            M.state.running = false
            M.state.process = nil

            callback(true)

            return
        end

        -- ---------------------------------------------------------------------
        -- Kill only the process managed by this instance.
        -- ---------------------------------------------------------------------

        if M.state.process then
            M.state.process:kill(15)

            M.state.process = nil
            M.state.running = false

            callback(true)

            return
        end

        callback(
            false,
            "MusicManager server is running but is not managed by this instance."
        )
    end)
end

-- =============================================================================
-- HTTP
-- =============================================================================

local function request(method, path, body, callback)
    callback = callback or function() end

    local url = get_url(path)

    local command = {
        "curl",
        "--silent",
        "--show-error",
        "--max-time",
        "5",

        "--request",
        method,
        url,
    }

    -- -------------------------------------------------------------------------
    -- Request body
    -- -------------------------------------------------------------------------

    if body ~= nil then
        table.insert(
            command,
            "--header"
        )

        table.insert(
            command,
            "Content-Type: application/json"
        )

        table.insert(
            command,
            "--data"
        )

        table.insert(
            command,
            vim.json.encode(body)
        )
    end

    vim.system(
        command,
        {
            text = true,
        },
        function(result)
            vim.schedule(function()
                -- -------------------------------------------------------------
                -- curl / connection error
                -- -------------------------------------------------------------

                if result.code ~= 0 then
                    callback(
                        false,
                        result.stderr
                    )

                    return
                end

                -- -------------------------------------------------------------
                -- Decode JSON
                -- -------------------------------------------------------------

                local data = decode_json(
                    result.stdout
                )

                if data == nil then
                    callback(
                        false,
                        "Invalid JSON response."
                    )

                    return
                end

                callback(
                    true,
                    data
                )
            end)
        end
    )
end


function M.get(path, callback)
    request(
        "GET",
        path,
        nil,
        callback
    )
end

function M.post(path, body, callback)
    request(
        "POST",
        path,
        body,
        callback
    )
end

-- =============================================================================
-- GET STATE
-- =============================================================================

function M.get_state()
    return {
        running = M.state.running,
        starting = M.state.starting,

        host = M.config.host,
        port = M.config.port,

        provider = M.config.player.provider,

        cava = {
            enabled = M.config.cava.enabled,
        },
    }
end

-- =============================================================================
-- CONFIGURATION
-- =============================================================================

function M.setup(
    server_options,
    cava_options
)
    -- -------------------------------------------------------------------------
    -- Server configuration
    -- -------------------------------------------------------------------------

    M.config = vim.tbl_deep_extend(
        "force",
        M.config,
        server_options or {}
    )

    -- -------------------------------------------------------------------------
    -- CAVA configuration
    --
    -- CAVA lives outside opts.server, so merge it separately.
    -- -------------------------------------------------------------------------

    M.config.cava = vim.tbl_deep_extend(
        "force",
        M.config.cava,
        cava_options or {}
    )

    return M
end

return M
