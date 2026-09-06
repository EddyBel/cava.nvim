"""
Playerctl integration.

This module provides an interface for communicating with
MPRIS players through playerctl.
"""

import hashlib
import os
import shutil
import subprocess
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request


class Playerctl:
    """
    Manage a playerctl MPRIS player.
    """

    DEFAULT_FORMAT = "|".join([
        "{{xesam:title}}",
        "{{xesam:artist}}",
        "{{xesam:album}}",
        "{{xesam:url}}",
        "{{mpris:artUrl}}",
        "{{mpris:trackid}}",
        "{{status}}",
        "{{position}}",
        "{{mpris:length}}",
    ])

    ARTWORK_MAX_SIZE = 50 * 1024 * 1024
    ARTWORK_CHUNK_SIZE = 64 * 1024
    ARTWORK_TIMEOUT = 15

    def __init__(self, options=None):
        """
        Initialize Playerctl.

        Parameters
        ----------
        options : dict, optional
            Playerctl configuration.
        """

        options = options or {}

        self.provider = options.get(
            "provider",
            "YoutubeMusic",
        )

        self.command = options.get(
            "command",
            "playerctl",
        )

        # =====================================================================
        # PLAYERCTL PROCESS
        # =====================================================================

        self.process = None
        self.thread = None

        self.running = False

        self.current = None

        self._lock = threading.Lock()

        # =====================================================================
        # ARTWORK CACHE
        # =====================================================================

        self.artwork_directory = tempfile.mkdtemp(
            prefix="music-manager-artwork-"
        )

        self.artwork_url = None
        self.artwork_path = None

        self._artwork_thread = None
        self._artwork_generation = 0

        self._artwork_lock = threading.Lock()

    # =========================================================================
    # AVAILABILITY
    # =========================================================================

    def is_installed(self):
        """
        Check whether playerctl is installed.

        Returns
        -------
        bool
        """

        return shutil.which(
            self.command
        ) is not None

    def get_players(self):
        """
        Get available MPRIS players.

        Returns
        -------
        list[str]
        """

        if not self.is_installed():
            return []

        try:
            result = subprocess.run(
                [
                    self.command,
                    "-l",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        except OSError:
            return []

        if result.returncode != 0:
            return []

        players = []

        for line in result.stdout.splitlines():
            line = line.strip()

            if line:
                players.append(line)

        return players

    def is_available(self):
        """
        Check whether the configured provider exists.

        Returns
        -------
        bool
        """

        return self.provider in self.get_players()

    # =========================================================================
    # COMMAND
    # =========================================================================

    def _command(self, args):
        """
        Build a playerctl command.

        Parameters
        ----------
        args : list[str]
            Command arguments.

        Returns
        -------
        list[str]
        """

        return [
            self.command,
            "-p",
            self.provider,
            *args,
        ]

    def _run(self, args):
        """
        Execute a playerctl command.

        Returns
        -------
        subprocess.CompletedProcess
        """

        return subprocess.run(
            self._command(args),
            capture_output=True,
            text=True,
            check=False,
        )

    # =========================================================================
    # PARSING
    # =========================================================================

    @staticmethod
    def _normalize_string(value):
        """
        Normalize a string value.

        Parameters
        ----------
        value : str or None

        Returns
        -------
        str or None
        """

        if value is None:
            return None

        value = value.strip()

        if not value:
            return None

        return value

    @staticmethod
    def _microseconds_to_seconds(value):
        """
        Convert MPRIS microseconds to seconds.

        Parameters
        ----------
        value : str or int or None

        Returns
        -------
        float or None
        """

        if value is None:
            return None

        try:
            return int(value) / 1_000_000

        except (ValueError, TypeError):
            return None

    def _parse_metadata(self, line):
        """
        Parse playerctl metadata.

        Expected format:

            title|artist|album|url|art_url|track_id|status|position|duration

        Returns
        -------
        dict
        """

        fields = line.rstrip(
            "\r\n"
        ).split("|")

        while len(fields) < 9:
            fields.append("")

        return {
            "provider": self.provider,

            "title": self._normalize_string(
                fields[0]
            ),

            "artist": self._normalize_string(
                fields[1]
            ),

            "album": self._normalize_string(
                fields[2]
            ),

            "url": self._normalize_string(
                fields[3]
            ),

            "art_url": self._normalize_string(
                fields[4]
            ),

            "track_id": self._normalize_string(
                fields[5]
            ),

            "status": self._normalize_string(
                fields[6]
            ),

            "position": self._microseconds_to_seconds(
                fields[7]
            ),

            "duration": self._microseconds_to_seconds(
                fields[8]
            ),
        }

    # =========================================================================
    # METADATA
    # =========================================================================

    def _set_metadata(self, metadata):
        """
        Update current metadata and request artwork synchronization.

        Artwork downloads are performed asynchronously.
        """

        self._request_artwork(
            metadata.get("art_url")
        )

        with self._lock:
            self.current = metadata

    def metadata(self):
        """
        Get the current player metadata.

        Returns
        -------
        dict or None
        """

        result = self._run([
            "metadata",
            "--format",
            self.DEFAULT_FORMAT,
        ])

        if result.returncode != 0:
            return None

        line = result.stdout.strip()

        if not line:
            return None

        metadata = self._parse_metadata(
            line
        )

        self._set_metadata(
            metadata
        )

        return metadata

    def get_current(self):
        """
        Get the last known metadata.

        This does not execute playerctl.

        Returns
        -------
        dict or None
        """

        with self._lock:
            if self.current is None:
                return None

            return self.current.copy()

    # =========================================================================
    # MONITOR
    # =========================================================================

    def _monitor(self):
        """
        Consume the persistent playerctl metadata stream.
        """

        if not self.process:
            return

        try:
            for line in self.process.stdout:

                if not line:
                    continue

                line = line.strip()

                if not line:
                    continue

                metadata = self._parse_metadata(
                    line
                )

                self._set_metadata(
                    metadata
                )

        except (
            ValueError,
            OSError,
        ):
            pass

        finally:
            self.running = False

    def start(self):
        """
        Start the persistent playerctl monitor.

        Returns
        -------
        bool
            True if the monitor was started.
        """

        if self.running:
            return False

        if not self.is_installed():
            return False

        try:
            self.process = subprocess.Popen(
                self._command([
                    "metadata",
                    "--follow",
                    "--format",
                    self.DEFAULT_FORMAT,
                ]),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )

        except OSError:
            self.process = None
            return False

        self.running = True

        self.thread = threading.Thread(
            target=self._monitor,
            daemon=True,
        )

        self.thread.start()

        return True

    def stop(self):
        """
        Stop the playerctl monitor.
        """

        self.running = False

        if self.process:
            try:
                self.process.terminate()

                self.process.wait(
                    timeout=1
                )

            except subprocess.TimeoutExpired:
                self.process.kill()

            except OSError:
                pass

            self.process = None

        self.thread = None

        self._cleanup_artwork()

    def is_running(self):
        """
        Check whether the monitor is running.

        Returns
        -------
        bool
        """

        return (
            self.running
            and self.process is not None
        )

    # =========================================================================
    # ARTWORK
    # =========================================================================

    @staticmethod
    def _artwork_cache_name(url):
        """
        Generate a stable cache filename from an artwork URL.

        The URL itself is used as the cache key.
        """

        digest = hashlib.sha256(
            url.encode("utf-8")
        ).hexdigest()

        extension = ""

        try:
            parsed = urllib.parse.urlparse(
                url
            )

            extension = os.path.splitext(
                parsed.path
            )[1].lower()

        except ValueError:
            pass

        allowed_extensions = {
            ".jpg",
            ".jpeg",
            ".png",
            ".gif",
            ".webp",
            ".bmp",
        }

        if extension not in allowed_extensions:
            extension = ".img"

        return (
            f"{digest}{extension}"
        )

    def _download_artwork(self, url):
        """
        Download artwork to the local cache.

        If the artwork already exists in the cache,
        no network request is performed.

        Parameters
        ----------
        url : str

        Returns
        -------
        str or None
            Local artwork path.
        """

        if not url:
            return None

        filename = self._artwork_cache_name(
            url
        )

        path = os.path.join(
            self.artwork_directory,
            filename,
        )

        # =====================================================================
        # CACHE HIT
        # =====================================================================

        if os.path.isfile(path):
            return path

        temporary_path = (
            f"{path}.tmp"
        )

        try:
            request = urllib.request.Request(
                url,
                headers={
                    "User-Agent": (
                        "MusicManager/1.0"
                    )
                },
            )

            with urllib.request.urlopen(
                request,
                timeout=self.ARTWORK_TIMEOUT,
            ) as response:

                content_length = response.headers.get(
                    "Content-Length"
                )

                if content_length:

                    try:
                        if (
                            int(content_length)
                            > self.ARTWORK_MAX_SIZE
                        ):
                            return None

                    except ValueError:
                        pass

                total = 0

                with open(
                    temporary_path,
                    "wb",
                ) as file:

                    while True:

                        chunk = response.read(
                            self.ARTWORK_CHUNK_SIZE
                        )

                        if not chunk:
                            break

                        total += len(chunk)

                        if (
                            total
                            > self.ARTWORK_MAX_SIZE
                        ):
                            raise ValueError(
                                "Artwork exceeds maximum size."
                            )

                        file.write(chunk)

            # =================================================================
            # ATOMIC CACHE UPDATE
            # =================================================================

            os.replace(
                temporary_path,
                path,
            )

            return path

        except (
            OSError,
            ValueError,
            urllib.error.URLError,
            urllib.error.HTTPError,
        ):

            try:
                os.remove(
                    temporary_path
                )

            except OSError:
                pass

            return None

    def _request_artwork(self, art_url):
        """
        Request an artwork update asynchronously.

        A new artwork immediately invalidates the previous
        artwork path. This prevents consumers from receiving
        the previous track's artwork while the new artwork
        is being downloaded.
        """

        # =====================================================================
        # NO ARTWORK
        # =====================================================================

        if not art_url:

            with self._artwork_lock:

                self.artwork_url = None
                self.artwork_path = None

                self._artwork_generation += 1

            return

        # =====================================================================
        # ARTWORK STATE
        # =====================================================================

        with self._artwork_lock:

            # Same artwork is already available.
            if (
                self.artwork_url == art_url
                and self.artwork_path
                and os.path.isfile(
                    self.artwork_path
                )
            ):
                return

            # ---------------------------------------------------------------
            # New artwork.
            #
            # Invalidate the previous artwork immediately.
            # ---------------------------------------------------------------

            self._artwork_generation += 1

            generation = (
                self._artwork_generation
            )

            self.artwork_url = art_url
            self.artwork_path = None

            # ---------------------------------------------------------------
            # Check cache.
            # ---------------------------------------------------------------

            cache_path = os.path.join(
                self.artwork_directory,
                self._artwork_cache_name(
                    art_url
                ),
            )

            if os.path.isfile(
                cache_path
            ):
                self.artwork_path = cache_path
                return

        # =====================================================================
        # ASYNCHRONOUS DOWNLOAD
        # =====================================================================

        thread = threading.Thread(
            target=self._artwork_worker,
            args=(
                art_url,
                generation,
            ),
            daemon=True,
        )

        self._artwork_thread = thread

        thread.start()

    def _artwork_worker(
        self,
        art_url,
        generation,
    ):
        """
        Download artwork asynchronously.
        """

        path = self._download_artwork(
            art_url
        )

        if path is None:
            return

        with self._artwork_lock:

            # A newer artwork request already exists.
            if (
                generation
                != self._artwork_generation
            ):
                return

            self.artwork_url = art_url
            self.artwork_path = path

    def get_artwork(self):
        """
        Return the currently cached artwork path.

        This method never performs network I/O.

        Returns
        -------
        str or None
        """

        with self._artwork_lock:

            if (
                self.artwork_path
                and os.path.isfile(
                    self.artwork_path
                )
            ):
                return self.artwork_path

            return None

    def get_artwork_info(self):
        """
        Return information about the current artwork.

        Returns
        -------
        dict
        """

        with self._artwork_lock:

            cached = (
                self.artwork_path is not None
                and os.path.isfile(
                    self.artwork_path
                )
            )

            return {
                "url": self.artwork_url,
                "path": self.artwork_path,
                "cached": cached,
            }

    def _cleanup_artwork(self):
        """
        Remove the artwork cache directory.
        """

        with self._artwork_lock:

            self.artwork_url = None
            self.artwork_path = None

            self._artwork_generation += 1

        if not self.artwork_directory:
            return

        try:
            shutil.rmtree(
                self.artwork_directory,
                ignore_errors=True,
            )

        except OSError:
            pass

        self.artwork_directory = None

    # =========================================================================
    # PLAYBACK STATE
    # =========================================================================

    def status(self):
        """
        Get the current playback status.

        Returns
        -------
        str or None
        """

        result = self._run([
            "status",
        ])

        if result.returncode != 0:
            return None

        return self._normalize_string(
            result.stdout
        )

    # =========================================================================
    # PLAYBACK CONTROLS
    # =========================================================================

    def play(self):
        """
        Start playback.

        Returns
        -------
        bool
        """

        return self._execute_action(
            "play"
        )

    def pause(self):
        """
        Pause playback.

        Returns
        -------
        bool
        """

        return self._execute_action(
            "pause"
        )

    def play_pause(self):
        """
        Toggle playback.

        Returns
        -------
        bool
        """

        return self._execute_action(
            "play-pause"
        )

    def next(self):
        """
        Skip to the next track.
        """

        return self._execute_action(
            "next"
        )

    def previous(self):
        """
        Go to the previous track.
        """

        return self._execute_action(
            "previous"
        )

    def _execute_action(self, action):
        """
        Execute a playback action.

        Returns
        -------
        bool
            True when playerctl successfully
            executed the action.
        """

        result = self._run([
            action,
        ])

        return result.returncode == 0

    # =========================================================================
    # CONFIGURATION
    # =========================================================================

    def get_config(self):
        """
        Return the current Playerctl configuration.

        Returns
        -------
        dict
        """

        return {
            "provider": self.provider,
            "command": self.command,
        }

    # =========================================================================
    # DESTRUCTOR
    # =========================================================================

    def __del__(self):
        """
        Cleanup resources.
        """

        try:
            self._cleanup_artwork()

        except Exception:
            pass
