#!/usr/bin/env python3

import argparse
import json
import os
import threading
import time

from http.server import BaseHTTPRequestHandler
from http.server import HTTPServer

from urllib.parse import parse_qs
from urllib.parse import urlparse

from libs.music_orchestrator import MusicOrchestrator
from libs.chafa import Chafa
from libs.providers.playerctl import Playerctl
from libs.providers.youtubemusic import YoutubeMusicProvider

from endpoints.cava_routes import (
    get_frame,
    get_info as get_cava_info,
    get_render_frame as get_cava_render_frame,
    get_status as get_cava_status,
)

from endpoints.playerctl_routes import (
    auto_provider,
    get_artwork,
    get_info as get_player_info,
    get_metadata,
    get_providers,
    get_status as get_player_status,
    get_tracklist,
    next_provider,
    next_track,
    pause,
    play,
    play_pause,
    previous_provider,
    previous_track,
    set_provider,

    # Playback
    stop_playback,
    seek,
    seek_forward,
    seek_backward,
    get_position,
    set_position,

    # Volume
    get_volume,
    set_volume,
    volume_up,
    volume_down,

    # Shuffle
    get_shuffle,
    set_shuffle,
    toggle_shuffle,

    # Loop
    get_loop_status,
    set_loop_status,
    toggle_loop,
)

from endpoints.image_routes import (
    get_info as get_image_info,
    get_size as get_image_size,
    render as render_image,
)


SERVER_NAME = "MusicManager"


# =============================================================================
# PARENT PROCESS MONITOR
# =============================================================================

class ParentProcessMonitor:
    """
    Monitor a parent process and shutdown the server when it exits.
    """

    def __init__(
        self,
        parent_pid,
        server,
        interval=1.0,
    ):
        self.parent_pid = parent_pid
        self.server = server
        self.interval = interval

        self.running = False
        self.thread = None

    def _process_exists(self):
        """Check whether the monitored process still exists."""

        try:
            os.kill(
                self.parent_pid,
                0,
            )

        except ProcessLookupError:
            return False

        except PermissionError:
            return True

        except OSError:
            return False

        return True

    def _monitor(self):
        """Monitor the parent process."""

        while self.running:

            if not self._process_exists():

                print(
                    "[MusicManager] "
                    f"Parent process {self.parent_pid} "
                    "no longer exists."
                )

                print(
                    "[MusicManager] "
                    "Shutting down server..."
                )

                self.running = False

                self.server.shutdown()

                return

            time.sleep(
                self.interval
            )

    def start(self):
        """Start the parent process monitor."""

        if self.running:
            return False

        if not self.parent_pid:
            return False

        self.running = True

        self.thread = threading.Thread(
            target=self._monitor,
            daemon=True,
            name="ParentProcessMonitor",
        )

        self.thread.start()

        return True

    def stop(self):
        """Stop the parent process monitor."""

        self.running = False
        self.thread = None


# =============================================================================
# HTTP HANDLER
# =============================================================================

class MusicManagerHandler(BaseHTTPRequestHandler):
    """HTTP request handler for MusicManager."""

    cava = None
    cava_enabled = False

    playerctl = None
    chafa = None
    orchestrator = None

    # =========================================================================
    # RESPONSE
    # =========================================================================

    def _send_json(self, status_code, data):
        """Send a JSON response."""

        body = json.dumps(
            data,
            ensure_ascii=False,
        ).encode("utf-8")

        self.send_response(
            status_code
        )

        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8",
        )

        self.send_header(
            "Content-Length",
            str(len(body)),
        )

        self.end_headers()

        self.wfile.write(body)

    # =========================================================================
    # REQUEST
    # =========================================================================

    def _read_json(self):
        """Read and decode a JSON request body."""

        try:
            content_length = int(
                self.headers.get(
                    "Content-Length",
                    0,
                )
            )

        except ValueError:
            raise ValueError(
                "Invalid Content-Length"
            )

        if content_length <= 0:
            raise ValueError(
                "Request body is empty"
            )

        body = self.rfile.read(
            content_length
        )

        if not body:
            raise ValueError(
                "Request body is empty"
            )

        try:
            return json.loads(
                body.decode("utf-8")
            )

        except (
            UnicodeDecodeError,
            json.JSONDecodeError,
        ) as error:

            raise ValueError(
                "Invalid JSON body"
            ) from error

    # =========================================================================
    # GET
    # =========================================================================

    def do_GET(self):
        """Handle GET requests."""

        parsed = urlparse(
            self.path
        )

        path = parsed.path

        query = parse_qs(
            parsed.query
        )

        # ---------------------------------------------------------------------
        # Server
        # ---------------------------------------------------------------------

        if path == "/":

            self._send_json(
                200,
                {
                    "status": "OK",
                    "server": SERVER_NAME,
                },
            )

            return

        # ---------------------------------------------------------------------
        # CAVA
        # ---------------------------------------------------------------------

        if path == "/cava":

            if not self.cava_enabled:

                self._send_json(
                    200,
                    {
                        "enabled": False,
                        "frame": None,
                    },
                )

                return

            self._send_json(
                200,
                get_cava_info(
                    self.cava
                ),
            )

            return

        if path == "/cava/frame":

            if not self.cava_enabled:

                self._send_json(
                    200,
                    {
                        "frame": None,
                    },
                )

                return

            self._send_json(
                200,
                get_frame(
                    self.cava
                ),
            )

            return

        if path == "/cava/status":

            if not self.cava_enabled:

                self._send_json(
                    200,
                    {
                        "enabled": False,
                        "running": False,
                        "available": False,
                    },
                )

                return

            self._send_json(
                200,
                get_cava_status(
                    self.cava
                ),
            )

            return

        if path == "/cava/render":

            try:

                width = int(
                    query.get(
                        "width",
                        [80],
                    )[0]
                )

                height = int(
                    query.get(
                        "height",
                        [20],
                    )[0]
                )

                columns = int(
                    query.get(
                        "columns",
                        [width],
                    )[0]
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": (
                            "width, height and columns "
                            "must be integers"
                        ),
                    },
                )

                return

            if (
                width < 0
                or height < 0
                or columns < 0
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": (
                            "width, height and columns "
                            "must be greater than or equal to zero"
                        ),
                    },
                )

                return

            if not self.cava_enabled:

                self._send_json(
                    200,
                    {
                        "frame": None,
                    },
                )

                return

            self._send_json(
                200,
                get_cava_render_frame(
                    self.cava,
                    width=width,
                    height=height,
                    columns=columns,
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Player
        # ---------------------------------------------------------------------

        if path == "/player":

            self._send_json(
                200,
                get_player_info(
                    self.orchestrator
                ),
            )

            return

        if path == "/player/metadata":

            self._send_json(
                200,
                get_metadata(
                    self.orchestrator
                ),
            )

            return

        if path == "/player/status":

            self._send_json(
                200,
                get_player_status(
                    self.orchestrator
                ),
            )

            return

        if path == "/player/artwork":

            self._send_json(
                200,
                get_artwork(
                    self.orchestrator
                ),
            )

            return

        if path == "/player/providers":

            self._send_json(
                200,
                get_providers(
                    self.orchestrator
                ),
            )

            return

        if path == "/player/tracklist":

            self._send_json(
                200,
                get_tracklist(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Position
        # ---------------------------------------------------------------------

        if path == "/player/position":

            self._send_json(
                200,
                get_position(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Volume
        # ---------------------------------------------------------------------

        if path == "/player/volume":

            self._send_json(
                200,
                get_volume(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Shuffle
        # ---------------------------------------------------------------------

        if path == "/player/shuffle":

            self._send_json(
                200,
                get_shuffle(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Loop
        # ---------------------------------------------------------------------

        if path == "/player/loop":

            self._send_json(
                200,
                get_loop_status(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Image
        # ---------------------------------------------------------------------

        if path == "/image/info":

            image_path = query.get(
                "path",
                [None],
            )[0]

            if not image_path:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing image path",
                    },
                )

                return

            try:

                result = get_image_info(
                    image_path
                )

                self._send_json(
                    200,
                    result,
                )

            except (
                FileNotFoundError,
                ValueError,
                TypeError,
            ) as error:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": str(error),
                    },
                )

            return

        # ---------------------------------------------------------------------
        # Not found
        # ---------------------------------------------------------------------

        self._send_json(
            404,
            {
                "status": "NOT_FOUND",
                "server": SERVER_NAME,
            },
        )

    # =========================================================================
    # POST
    # =========================================================================

    def do_POST(self):
        """Handle POST requests."""

        try:

            data = self._read_json()

        except ValueError as error:

            self._send_json(
                400,
                {
                    "status": "BAD_REQUEST",
                    "message": str(error),
                },
            )

            return

        # ---------------------------------------------------------------------
        # Provider
        # ---------------------------------------------------------------------

        if self.path == "/player/provider":

            provider = data.get(
                "provider"
            )

            if not provider:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing provider",
                    },
                )

                return

            self._send_json(
                200,
                set_provider(
                    self.orchestrator,
                    provider,
                ),
            )

            return

        if self.path == "/player/provider/auto":

            self._send_json(
                200,
                auto_provider(
                    self.orchestrator
                ),
            )

            return

        if self.path == "/player/provider/next":

            self._send_json(
                200,
                next_provider(
                    self.orchestrator
                ),
            )

            return

        if self.path == "/player/provider/previous":

            self._send_json(
                200,
                previous_provider(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Playback
        # ---------------------------------------------------------------------

        if self.path == "/player/play":

            self._send_json(
                200,
                play(
                    self.orchestrator
                ),
            )

            return

        if self.path == "/player/pause":

            self._send_json(
                200,
                pause(
                    self.orchestrator
                ),
            )

            return

        if self.path == "/player/play-pause":

            self._send_json(
                200,
                play_pause(
                    self.orchestrator
                ),
            )

            return

        if self.path == "/player/stop":

            self._send_json(
                200,
                stop_playback(
                    self.orchestrator
                ),
            )

            return

        if self.path == "/player/next":

            self._send_json(
                200,
                next_track(
                    self.orchestrator
                ),
            )

            return

        if self.path == "/player/previous":

            self._send_json(
                200,
                previous_track(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Seek
        # ---------------------------------------------------------------------

        if self.path == "/player/seek":

            seconds = data.get(
                "seconds"
            )

            if seconds is None:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing seconds",
                    },
                )

                return

            try:

                seconds = float(
                    seconds
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "seconds must be a number",
                    },
                )

                return

            self._send_json(
                200,
                seek(
                    self.orchestrator,
                    seconds,
                ),
            )

            return

        if self.path == "/player/seek/forward":

            seconds = data.get(
                "seconds",
                10,
            )

            try:

                seconds = float(
                    seconds
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "seconds must be a number",
                    },
                )

                return

            self._send_json(
                200,
                seek_forward(
                    self.orchestrator,
                    seconds,
                ),
            )

            return

        if self.path == "/player/seek/backward":

            seconds = data.get(
                "seconds",
                10,
            )

            try:

                seconds = float(
                    seconds
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "seconds must be a number",
                    },
                )

                return

            self._send_json(
                200,
                seek_backward(
                    self.orchestrator,
                    seconds,
                ),
            )

            return

        if self.path == "/player/position":

            position = data.get(
                "position"
            )

            if position is None:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing position",
                    },
                )

                return

            try:

                position = float(
                    position
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "position must be a number",
                    },
                )

                return

            self._send_json(
                200,
                set_position(
                    self.orchestrator,
                    position,
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Volume
        # ---------------------------------------------------------------------

        if self.path == "/player/volume":

            volume = data.get(
                "volume"
            )

            if volume is None:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing volume",
                    },
                )

                return

            try:

                volume = float(
                    volume
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "volume must be a number",
                    },
                )

                return

            self._send_json(
                200,
                set_volume(
                    self.orchestrator,
                    volume,
                ),
            )

            return

        if self.path == "/player/volume/up":

            step = data.get(
                "step",
                0.05,
            )

            try:

                step = float(
                    step
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "step must be a number",
                    },
                )

                return

            self._send_json(
                200,
                volume_up(
                    self.orchestrator,
                    step,
                ),
            )

            return

        if self.path == "/player/volume/down":

            step = data.get(
                "step",
                0.05,
            )

            try:

                step = float(
                    step
                )

            except (
                TypeError,
                ValueError,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "step must be a number",
                    },
                )

                return

            self._send_json(
                200,
                volume_down(
                    self.orchestrator,
                    step,
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Shuffle
        # ---------------------------------------------------------------------

        if self.path == "/player/shuffle":

            enabled = data.get(
                "enabled"
            )

            if enabled is None:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing enabled",
                    },
                )

                return

            if not isinstance(
                enabled,
                bool,
            ):

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "enabled must be a boolean",
                    },
                )

                return

            self._send_json(
                200,
                set_shuffle(
                    self.orchestrator,
                    enabled,
                ),
            )

            return

        if self.path == "/player/shuffle/toggle":

            self._send_json(
                200,
                toggle_shuffle(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Loop
        # ---------------------------------------------------------------------

        if self.path == "/player/loop":

            status = data.get(
                "status"
            )

            if not status:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing loop status",
                    },
                )

                return

            self._send_json(
                200,
                set_loop_status(
                    self.orchestrator,
                    status,
                ),
            )

            return

        if self.path == "/player/loop/toggle":

            self._send_json(
                200,
                toggle_loop(
                    self.orchestrator
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Image size
        # ---------------------------------------------------------------------

        if self.path == "/image/size":

            image_path = data.get(
                "path"
            )

            size = data.get(
                "size"
            )

            font_ratio = data.get(
                "font_ratio",
                "1/2",
            )

            if not image_path:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing image path",
                    },
                )

                return

            if not size:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing image size",
                    },
                )

                return

            try:

                result = get_image_size(
                    image_path,
                    size,
                    font_ratio,
                )

                self._send_json(
                    200,
                    result,
                )

            except (
                FileNotFoundError,
                ValueError,
                TypeError,
            ) as error:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": str(error),
                    },
                )

            return

        # ---------------------------------------------------------------------
        # Image render
        # ---------------------------------------------------------------------

        if self.path == "/image/render":

            image_path = data.get(
                "path"
            )

            size = data.get(
                "size"
            )

            font_ratio = data.get(
                "font_ratio",
                "1/2",
            )

            if not image_path:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing image path",
                    },
                )

                return

            if not size:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": "Missing image size",
                    },
                )

                return

            try:

                result = render_image(
                    image_path,
                    size,
                    self.chafa,
                    font_ratio,
                )

                self._send_json(
                    200,
                    result,
                )

            except (
                FileNotFoundError,
                ValueError,
                TypeError,
                OSError,
            ) as error:

                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": str(error),
                    },
                )

            return

        # ---------------------------------------------------------------------
        # Not found
        # ---------------------------------------------------------------------

        self._send_json(
            404,
            {
                "status": "NOT_FOUND",
                "server": SERVER_NAME,
            },
        )

    # =========================================================================
    # LOGGING
    # =========================================================================

    def log_message(self, format, *args):
        """Keep the default HTTP log format."""

        print(
            "[MusicManager]",
            format % args,
        )


# =============================================================================
# ARGUMENTS
# =============================================================================

def parse_args():
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(
        description="MusicManager backend server",
    )

    # =========================================================================
    # SERVER
    # =========================================================================

    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Server host (default: 127.0.0.1)",
    )

    parser.add_argument(
        "--port",
        type=int,
        default=9091,
        help="Server port (default: 9091)",
    )

    parser.add_argument(
        "--parent-pid",
        type=int,
        default=None,
        help=(
            "PID of the parent process. "
            "The server shuts down automatically "
            "when this process exits."
        ),
    )

    parser.add_argument(
        "--parent-check-interval",
        type=float,
        default=1.0,
        help=(
            "Parent process check interval in seconds "
            "(default: 1.0)"
        ),
    )

    # =========================================================================
    # CAVA
    # =========================================================================

    parser.add_argument(
        "--cava",
        choices=(
            "enabled",
            "disabled",
        ),
        default="enabled",
        help=(
            "Enable or disable CAVA "
            "(default: enabled)"
        ),
    )

    parser.add_argument(
        "--cava-framerate",
        type=int,
        default=30,
        help="CAVA framerate (default: 30)",
    )

    parser.add_argument(
        "--cava-bars",
        type=int,
        default=16,
        help="Number of CAVA bars (default: 16)",
    )

    parser.add_argument(
        "--cava-input-method",
        default="pulse",
        help="CAVA input method (default: pulse)",
    )

    parser.add_argument(
        "--cava-input-source",
        default="auto",
        help="CAVA input source (default: auto)",
    )

    # =========================================================================
    # PLAYER
    # =========================================================================

    parser.add_argument(
        "--provider",
        "--player",
        dest="provider",
        default="YoutubeMusic",
        help=(
            "Logical music provider. "
            "YoutubeMusic/YoutubeMusic Pear-Desktop API "
            "uses the YouTube Music provider. "
            "Any other value is used as the playerctl provider "
            "(for example: firefox, spotify, chromium). "
            "(default: YoutubeMusic)"
        ),
    )

    parser.add_argument(
        "--playerctl",
        default="playerctl",
        help=(
            "playerctl executable "
            "(default: playerctl)"
        ),
    )

    # =========================================================================
    # YOUTUBE MUSIC
    # =========================================================================

    parser.add_argument(
        "--youtube-music-url",
        default="http://localhost:26538",
        help=(
            "YouTube Music / Pear Desktop API URL "
            "(default: http://localhost:26538)"
        ),
    )

    return parser.parse_args()


# =============================================================================
# SERVER
# =============================================================================

def main():
    """Start the MusicManager server."""

    args = parse_args()

    # =========================================================================
    # CAVA
    # =========================================================================
    #
    # CAVA se importa e instancia solamente cuando está habilitado.
    #
    # Esto es importante porque la creación de Cava() puede iniciar
    # recursos/procesos en segundo plano.
    #
    # =========================================================================

    cava = None

    cava_enabled = (
        args.cava == "enabled"
    )

    if cava_enabled:

        from libs.cava import Cava

        cava = Cava({
            "framerate": args.cava_framerate,
            "bars": args.cava_bars,
            "input_method": args.cava_input_method,
            "input_source": args.cava_input_source,
        })

        if not cava.start():

            raise RuntimeError(
                "Unable to start CAVA"
            )

    # =========================================================================
    # PLAYERCTL
    # =========================================================================

    playerctl = Playerctl({
        "provider": args.provider,
        "command": args.playerctl,
    })

    # =========================================================================
    # YOUTUBE MUSIC
    # =========================================================================

    youtubemusic = YoutubeMusicProvider({
        "provider": "YoutubeMusic",
        "base_url": args.youtube_music_url,
    })

    # =========================================================================
    # PLAYERCTL START
    # =========================================================================

    if not playerctl.start():

        if cava_enabled and cava is not None:
            cava.stop()

        raise RuntimeError(
            "Unable to start Playerctl"
        )

    # =========================================================================
    # CHAFA
    # =========================================================================

    chafa = Chafa()

    # =========================================================================
    # MUSIC ORCHESTRATOR
    # =========================================================================
    #
    # El provider recibido por --provider / --player es la fuente de verdad.
    #
    # Ejemplos:
    #
    #   --provider YoutubeMusic
    #       -> YoutubeMusicProvider
    #
    #   --provider "YoutubeMusic Pear-Desktop API"
    #       -> YoutubeMusicProvider
    #
    #   --provider firefox
    #       -> playerctl -p firefox
    #
    #   --provider spotify
    #       -> playerctl -p spotify
    #
    # =========================================================================

    orchestrator = MusicOrchestrator(
        yt_provider=youtubemusic,
        playerctl_provider=playerctl,
        provider_name=args.provider,
    )

    # =========================================================================
    # HANDLER STATE
    # =========================================================================

    MusicManagerHandler.cava = cava
    MusicManagerHandler.cava_enabled = cava_enabled
    MusicManagerHandler.playerctl = playerctl
    MusicManagerHandler.chafa = chafa
    MusicManagerHandler.orchestrator = orchestrator

    # =========================================================================
    # HTTP SERVER
    # =========================================================================

    server = HTTPServer(
        (
            args.host,
            args.port,
        ),
        MusicManagerHandler,
    )

    # =========================================================================
    # PARENT PROCESS MONITOR
    # =========================================================================

    parent_monitor = None

    if args.parent_pid is not None:

        if args.parent_pid <= 0:

            playerctl.stop()

            if cava_enabled and cava is not None:
                cava.stop()

            raise ValueError(
                "Parent PID must be greater than zero"
            )

        parent_monitor = ParentProcessMonitor(
            parent_pid=args.parent_pid,
            server=server,
            interval=args.parent_check_interval,
        )

        parent_monitor.start()

        print(
            f"Parent process: {args.parent_pid}"
        )

        print(
            "Parent monitoring: enabled"
        )

    else:

        print(
            "Parent monitoring: disabled"
        )

    # =========================================================================
    # INFORMATION
    # =========================================================================

    print(
        f"MusicManager server running on "
        f"http://{args.host}:{args.port}"
    )

    if cava_enabled:

        print(
            f"CAVA: enabled "
            f"({args.cava_bars} bars @ "
            f"{args.cava_framerate} FPS)"
        )

    else:

        print(
            "CAVA: disabled"
        )

    print(
        f"Provider: {args.provider}"
    )

    print(
        f"playerctl: {args.playerctl}"
    )

    print(
        f"YouTube Music API: {args.youtube_music_url}"
    )

    print(
        "Image: Image + Chafa"
    )

    # =========================================================================
    # RUN
    # =========================================================================

    try:

        server.serve_forever()

    except KeyboardInterrupt:

        print(
            "\nStopping MusicManager server..."
        )

    finally:

        if parent_monitor:
            parent_monitor.stop()

        playerctl.stop()

        if cava_enabled and cava is not None:
            cava.stop()

        server.server_close()

        print(
            "MusicManager server stopped."
        )


if __name__ == "__main__":
    main()
