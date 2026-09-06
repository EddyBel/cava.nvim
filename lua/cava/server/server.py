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

from libs.cava import Cava
from libs.playerctl import Playerctl
from libs.chafa import Chafa

from endpoints.cava_routes import (
    get_frame,
    get_info as get_cava_info,
    get_status as get_cava_status,
)

from endpoints.playerctl_routes import (
    get_artwork,
    get_info as get_player_info,
    get_metadata,
    get_status as get_player_status,
    next_track,
    pause,
    play,
    play_pause,
    previous_track,
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

    The monitored PID is intentionally stored instead of using os.getppid(),
    because the server can be re-parented if the original parent dies.
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

    # =========================================================================
    # PROCESS
    # =========================================================================

    def _process_exists(self):
        """
        Check whether the monitored process still exists.
        """

        try:
            os.kill(
                self.parent_pid,
                0,
            )

        except ProcessLookupError:
            return False

        except PermissionError:
            # The process exists, but we do not have permission
            # to signal it.
            return True

        except OSError:
            return False

        return True

    # =========================================================================
    # MONITOR
    # =========================================================================

    def _monitor(self):
        """
        Monitor the parent process.
        """

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

    # =========================================================================
    # START
    # =========================================================================

    def start(self):
        """
        Start the parent process monitor.
        """

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

    # =========================================================================
    # STOP
    # =========================================================================

    def stop(self):
        """
        Stop the parent process monitor.
        """

        self.running = False

        self.thread = None


# =============================================================================
# HTTP HANDLER
# =============================================================================

class MusicManagerHandler(BaseHTTPRequestHandler):
    """HTTP request handler for MusicManager."""

    cava = None
    playerctl = None
    chafa = None

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
            self._send_json(
                200,
                get_cava_info(
                    self.cava
                ),
            )

            return

        if path == "/cava/frame":
            self._send_json(
                200,
                get_frame(
                    self.cava
                ),
            )

            return

        if path == "/cava/status":
            self._send_json(
                200,
                get_cava_status(
                    self.cava
                ),
            )

            return

        # ---------------------------------------------------------------------
        # Playerctl
        # ---------------------------------------------------------------------

        if path == "/player":
            self._send_json(
                200,
                get_player_info(
                    self.playerctl
                ),
            )

            return

        if path == "/player/metadata":
            self._send_json(
                200,
                get_metadata(
                    self.playerctl
                ),
            )

            return

        if path == "/player/status":
            self._send_json(
                200,
                get_player_status(
                    self.playerctl
                ),
            )

            return

        if path == "/player/artwork":
            self._send_json(
                200,
                get_artwork(
                    self.playerctl
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
                        "message": (
                            "Missing image path"
                        ),
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

        # ---------------------------------------------------------------------
        # Read request body
        # ---------------------------------------------------------------------

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
        # Playback controls
        # ---------------------------------------------------------------------

        if self.path == "/player/play":
            self._send_json(
                200,
                play(
                    self.playerctl
                ),
            )

            return

        if self.path == "/player/pause":
            self._send_json(
                200,
                pause(
                    self.playerctl
                ),
            )

            return

        if self.path == "/player/play-pause":
            self._send_json(
                200,
                play_pause(
                    self.playerctl
                ),
            )

            return

        if self.path == "/player/next":
            self._send_json(
                200,
                next_track(
                    self.playerctl
                ),
            )

            return

        if self.path == "/player/previous":
            self._send_json(
                200,
                previous_track(
                    self.playerctl
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
                        "message": (
                            "Missing image path"
                        ),
                    },
                )

                return

            if not size:
                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": (
                            "Missing image size"
                        ),
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
                        "message": (
                            "Missing image path"
                        ),
                    },
                )

                return

            if not size:
                self._send_json(
                    400,
                    {
                        "status": "BAD_REQUEST",
                        "message": (
                            "Missing image size"
                        ),
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
    # PLAYERCTL
    # =========================================================================

    parser.add_argument(
        "--player",
        default="YoutubeMusic",
        help=(
            "MPRIS player provider "
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
        "provider": args.player,
        "command": args.playerctl,
    })

    if not playerctl.start():

        cava.stop()

        raise RuntimeError(
            "Unable to start Playerctl"
        )

    # =========================================================================
    # CHAFA
    # =========================================================================

    chafa = Chafa()

    # =========================================================================
    # HANDLER STATE
    # =========================================================================

    MusicManagerHandler.cava = cava
    MusicManagerHandler.playerctl = playerctl
    MusicManagerHandler.chafa = chafa

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

    print(
        f"CAVA: {args.cava_bars} bars @ "
        f"{args.cava_framerate} FPS"
    )

    print(
        f"Player: {args.player}"
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
        cava.stop()

        server.server_close()

        print(
            "MusicManager server stopped."
        )


if __name__ == "__main__":
    main()
