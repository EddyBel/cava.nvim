"""
Playerctl integration.

This module provides an interface for communicating with
MPRIS players through playerctl and the user D-Bus.
"""

import hashlib
import os
import shlex
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

    # =========================================================================
    # INITIALIZATION
    # =========================================================================

    def __init__(self, options=None):
        """
        Initialize Playerctl.

        Parameters
        ----------
        options : dict, optional
            Playerctl configuration.

            Supported options:

                provider
                    MPRIS/playerctl provider name.

                command
                    playerctl executable.
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

        self.artwork_directory = None

        self.artwork_url = None
        self.artwork_path = None

        self._artwork_thread = None
        self._artwork_generation = 0

        self._artwork_lock = threading.Lock()

        self._ensure_artwork_directory()

    # =========================================================================
    # ARTWORK DIRECTORY
    # =========================================================================

    def _ensure_artwork_directory(self):
        """
        Ensure that the artwork cache directory exists.
        """

        with self._artwork_lock:

            if self.artwork_directory:
                if os.path.isdir(
                    self.artwork_directory
                ):
                    return

            self.artwork_directory = tempfile.mkdtemp(
                prefix="music-manager-artwork-"
            )

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

    def get_providers(self):
        """
        Get all available MPRIS providers detected by playerctl.

        Returns
        -------
        list[str]
            Available provider names.
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

        providers = []

        for line in result.stdout.splitlines():

            provider = line.strip()

            if not provider:
                continue

            providers.append(
                provider
            )

        return providers

    def get_players(self):
        """
        Get available MPRIS players.

        Compatibility alias for get_providers().

        Returns
        -------
        list[str]
        """

        return self.get_providers()

    def is_available(self):
        """
        Check whether the configured provider exists.

        Returns
        -------
        bool
        """

        return self.provider in self.get_providers()

    # =========================================================================
    # PROVIDER MANAGEMENT
    # =========================================================================

    def set_provider(self, provider):
        """
        Change the current MPRIS provider.

        If the Playerctl monitor is currently running,
        it is restarted using the new provider.

        Parameters
        ----------
        provider : str
            Provider name.

        Returns
        -------
        bool
            True when the provider was selected successfully.
        """

        if not provider:
            return False

        providers = self.get_providers()

        if provider not in providers:
            return False

        if self.provider == provider:
            return True

        was_running = self.is_running()

        if was_running:
            self.stop()

        self.provider = provider

        if was_running:
            return self.start()

        return True

    def auto_provider(self):
        """
        Automatically select an available provider.

        If the current provider is available, it is kept.

        Returns
        -------
        str or None
            Selected provider.
        """

        providers = self.get_providers()

        if not providers:
            return None

        if self.provider in providers:
            return self.provider

        provider = providers[0]

        if not self.set_provider(
            provider
        ):
            return None

        return self.provider

    def next_provider(self):
        """
        Select the next provider.

        The order is determined by playerctl.

        Returns
        -------
        str or None
            Selected provider.
        """

        providers = self.get_providers()

        if not providers:
            return None

        if len(providers) == 1:

            self.set_provider(
                providers[0]
            )

            return self.provider

        try:
            index = providers.index(
                self.provider
            )

        except ValueError:
            index = -1

        next_index = (
            index + 1
        ) % len(providers)

        provider = providers[
            next_index
        ]

        if not self.set_provider(
            provider
        ):
            return None

        return self.provider

    def previous_provider(self):
        """
        Select the previous provider.

        Returns
        -------
        str or None
            Selected provider.
        """

        providers = self.get_providers()

        if not providers:
            return None

        if len(providers) == 1:

            self.set_provider(
                providers[0]
            )

            return self.provider

        try:
            index = providers.index(
                self.provider
            )

        except ValueError:
            index = 0

        previous_index = (
            index - 1
        ) % len(providers)

        provider = providers[
            previous_index
        ]

        if not self.set_provider(
            provider
        ):
            return None

        return self.provider

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
    # MPRIS / D-BUS
    # =========================================================================

    def _dbus_service(self):
        """
        Return the D-Bus service name for the current provider.

        Returns
        -------
        str
        """

        return (
            f"org.mpris.MediaPlayer2."
            f"{self.provider}"
        )

    def _dbus_call(
        self,
        interface,
        method,
        signature="",
        arguments=None,
    ):
        """
        Execute a method through the user D-Bus.

        Returns
        -------
        subprocess.CompletedProcess or None
        """

        arguments = arguments or []

        command = [
            "busctl",
            "--user",
            "call",
            self._dbus_service(),
            "/org/mpris/MediaPlayer2",
            interface,
            method,
        ]

        if signature:
            command.append(signature)

        command.extend(
            arguments
        )

        try:
            return subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
            )

        except OSError:
            return None

    def _dbus_get_property(
        self,
        interface,
        property_name,
    ):
        """
        Read an MPRIS property through D-Bus.

        Returns
        -------
        str or None
        """

        try:
            result = subprocess.run(
                [
                    "busctl",
                    "--user",
                    "get-property",
                    self._dbus_service(),
                    "/org/mpris/MediaPlayer2",
                    interface,
                    property_name,
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        except OSError:
            return None

        if result.returncode != 0:
            return None

        return result.stdout.strip()

    def get_mpris_property(
        self,
        interface,
        property_name,
    ):
        """
        Get an MPRIS property.

        Returns
        -------
        str or None
        """

        return self._dbus_get_property(
            interface,
            property_name,
        )

    # =========================================================================
    # PARSING
    # =========================================================================

    @staticmethod
    def _normalize_string(value):
        """
        Normalize a string value.

        Returns
        -------
        str or None
        """

        if value is None:
            return None

        value = str(value).strip()

        if not value:
            return None

        return value

    @staticmethod
    def _microseconds_to_seconds(value):
        """
        Convert MPRIS microseconds to seconds.

        Returns
        -------
        float or None
        """

        if value is None:
            return None

        try:
            return int(value) / 1_000_000

        except (
            ValueError,
            TypeError,
        ):
            return None

    def _parse_metadata(self, line):
        """
        Parse playerctl metadata.

        Expected format:

            title|artist|album|url|art_url|track_id|
            status|position|duration

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

    def _parse_track(self, metadata):
        """
        Convert MPRIS TrackList metadata into normalized
        track representation.

        Returns
        -------
        dict
        """

        title = metadata.get(
            "xesam:title"
        )

        artist = metadata.get(
            "xesam:artist"
        )

        album = metadata.get(
            "xesam:album"
        )

        url = metadata.get(
            "xesam:url"
        )

        track_id = metadata.get(
            "mpris:trackid"
        )

        duration = metadata.get(
            "mpris:length"
        )

        if isinstance(
            artist,
            list,
        ):
            artist = ", ".join(
                str(value)
                for value in artist
                if value
            )

        return {
            "provider": self.provider,

            "title": self._normalize_string(
                title
            ),

            "artist": self._normalize_string(
                artist
            ),

            "album": self._normalize_string(
                album
            ),

            "url": self._normalize_string(
                url
            ),

            "track_id": self._normalize_string(
                track_id
            ),

            "duration": self._microseconds_to_seconds(
                duration
            ),
        }

    # =========================================================================
    # MPRIS VALUE PARSING
    # =========================================================================

    @staticmethod
    def _parse_busctl_value(
        tokens,
        index,
        signature,
    ):
        """
        Parse a value from busctl tokenized output.

        Returns
        -------
        tuple
            (value, next_index)
        """

        if index >= len(tokens):
            return None, index

        if signature == "s":
            return (
                tokens[index],
                index + 1,
            )

        if signature == "o":
            return (
                tokens[index],
                index + 1,
            )

        if signature == "b":

            value = tokens[index].lower()

            return (
                value == "true",
                index + 1,
            )

        if signature in {
            "i",
            "x",
            "u",
            "t",
            "n",
            "q",
        }:

            try:
                return (
                    int(tokens[index]),
                    index + 1,
                )

            except ValueError:
                return (
                    None,
                    index + 1,
                )

        if signature == "d":

            try:
                return (
                    float(tokens[index]),
                    index + 1,
                )

            except ValueError:
                return (
                    None,
                    index + 1,
                )

        if signature == "as":

            try:
                count = int(
                    tokens[index]
                )

            except ValueError:
                return (
                    None,
                    index + 1,
                )

            index += 1

            values = tokens[
                index:index + count
            ]

            return (
                values,
                index + count,
            )

        return (
            tokens[index],
            index + 1,
        )

    @classmethod
    def _parse_track_metadata(cls, output):
        """
        Parse MPRIS GetTracksMetadata output.

        Returns
        -------
        list[dict]
        """

        if not output:
            return []

        try:
            tokens = shlex.split(
                output
            )

        except ValueError:
            return []

        if not tokens:
            return []

        index = 0

        if tokens[index] != "a{sv}":
            return []

        index += 1

        try:
            track_count = int(
                tokens[index]
            )

        except (
            ValueError,
            IndexError,
        ):
            return []

        index += 1

        tracks = []

        for _ in range(track_count):

            metadata = {}

            try:
                entry_count = int(
                    tokens[index]
                )

            except (
                ValueError,
                IndexError,
            ):
                break

            index += 1

            for _ in range(entry_count):

                if index >= len(tokens):
                    break

                key = tokens[index]
                index += 1

                if (
                    index >= len(tokens)
                    or tokens[index] != "v"
                ):
                    break

                index += 1

                if index >= len(tokens):
                    break

                value_signature = tokens[
                    index
                ]

                index += 1

                value, index = cls._parse_busctl_value(
                    tokens,
                    index,
                    value_signature,
                )

                metadata[key] = value

            tracks.append(
                metadata
            )

        return tracks

    # =========================================================================
    # METADATA
    # =========================================================================

    def _set_metadata(self, metadata):
        """
        Update current metadata and synchronize artwork.
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

        try:
            result = self._run([
                "metadata",
                "--format",
                self.DEFAULT_FORMAT,
            ])

        except OSError:
            return None

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
    # TRACKLIST
    # =========================================================================

    def has_tracklist(self):
        """
        Check whether the current MPRIS provider exposes
        the optional TrackList interface.

        Returns
        -------
        bool
        """

        if not self.is_available():
            return False

        value = self._dbus_get_property(
            "org.mpris.MediaPlayer2",
            "HasTrackList",
        )

        if value is None:
            return False

        return value.strip() == "b true"

    def _get_track_paths(self):
        """
        Get object paths of the current MPRIS TrackList.

        Returns
        -------
        list[str]
        """

        output = self._dbus_get_property(
            "org.mpris.MediaPlayer2.TrackList",
            "Tracks",
        )

        if output is None:
            return []

        try:
            tokens = shlex.split(
                output
            )

        except ValueError:
            return []

        if not tokens:
            return []

        if tokens[0] != "ao":
            return []

        try:
            count = int(
                tokens[1]
            )

        except (
            ValueError,
            IndexError,
        ):
            return []

        return tokens[
            2:2 + count
        ]

    def _get_tracks_metadata(
        self,
        track_paths,
    ):
        """
        Request metadata for MPRIS tracks.

        Returns
        -------
        list[dict]
        """

        if not track_paths:
            return []

        arguments = [
            str(len(track_paths)),
            *track_paths,
        ]

        result = self._dbus_call(
            "org.mpris.MediaPlayer2.TrackList",
            "GetTracksMetadata",
            "ao",
            arguments,
        )

        if result is None:
            return []

        if result.returncode != 0:
            return []

        return self._parse_track_metadata(
            result.stdout
        )

    def tracklist_info(self):
        """
        Get TrackList availability information.

        Returns
        -------
        dict
        """

        available = self.has_tracklist()

        if not available:
            return {
                "available": False,
                "tracks": [],
            }

        track_paths = self._get_track_paths()

        if not track_paths:
            return {
                "available": True,
                "tracks": [],
            }

        metadata = self._get_tracks_metadata(
            track_paths
        )

        tracks = []

        for item in metadata:

            tracks.append(
                self._parse_track(
                    item
                )
            )

        return {
            "available": True,
            "tracks": tracks,
        }

    def tracklist(self):
        """
        Get the current player's TrackList.

        Returns
        -------
        list[dict]
        """

        return self.tracklist_info()[
            "tracks"
        ]

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
        """

        if self.running:
            return False

        if not self.is_installed():
            return False

        if not self.is_available():
            return False

        self._ensure_artwork_directory()

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

                try:
                    self.process.kill()

                except OSError:
                    pass

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
        Generate a stable cache filename from artwork URL.

        Returns
        -------
        str
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
        Download artwork to local cache.

        Returns
        -------
        str or None
        """

        if not url:
            return None

        self._ensure_artwork_directory()

        filename = self._artwork_cache_name(
            url
        )

        path = os.path.join(
            self.artwork_directory,
            filename,
        )

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

                        file.write(
                            chunk
                        )

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

        A new artwork invalidates the previous artwork path.
        """

        self._ensure_artwork_directory()

        if not art_url:

            with self._artwork_lock:

                self.artwork_url = None
                self.artwork_path = None

                self._artwork_generation += 1

            return

        with self._artwork_lock:

            if (
                self.artwork_url == art_url
                and self.artwork_path
                and os.path.isfile(
                    self.artwork_path
                )
            ):
                return

            self._artwork_generation += 1

            generation = (
                self._artwork_generation
            )

            self.artwork_url = art_url
            self.artwork_path = None

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

            if (
                generation
                != self._artwork_generation
            ):
                return

            self.artwork_url = art_url
            self.artwork_path = path

    def get_artwork(self):
        """
        Return currently cached artwork path.

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
        Return information about current artwork.

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

            directory = (
                self.artwork_directory
            )

            self.artwork_directory = None

        if not directory:
            return

        try:

            shutil.rmtree(
                directory,
                ignore_errors=True,
            )

        except OSError:
            pass

    # =========================================================================
    # PLAYBACK STATE
    # =========================================================================

    def status(self):
        """
        Get current playback status.

        Returns
        -------
        str or None
        """

        try:
            result = self._run([
                "status",
            ])

        except OSError:
            return None

        if result.returncode != 0:
            return None

        return self._normalize_string(
            result.stdout
        )

    def get_position(self):
        """
        Get current playback position.

        Returns
        -------
        float or None
            Position in seconds.
        """

        try:
            result = self._run([
                "position",
            ])

        except OSError:
            return None

        if result.returncode != 0:
            return None

        value = self._normalize_string(
            result.stdout
        )

        if value is None:
            return None

        try:
            return float(value)

        except ValueError:
            return None

    def get_length(self):
        """
        Get current track duration.

        Returns
        -------
        float or None
            Duration in seconds.
        """

        try:
            result = self._run([
                "metadata",
                "--format",
                "{{mpris:length}}",
            ])

        except OSError:
            return None

        if result.returncode != 0:
            return None

        value = self._normalize_string(
            result.stdout
        )

        if value is None:
            return None

        return self._microseconds_to_seconds(
            value
        )

    # =========================================================================
    # PLAYBACK CONTROLS
    # =========================================================================

    def _execute_action(self, action):
        """
        Execute a playback action.

        Returns
        -------
        bool
        """

        if not self.is_available():
            return False

        try:
            result = self._run([
                action,
            ])

        except OSError:
            return False

        return result.returncode == 0

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

    def stop_playback(self):
        """
        Stop playback.

        Returns
        -------
        bool
        """

        return self._execute_action(
            "stop"
        )

    def next(self):
        """
        Skip to the next track.

        Returns
        -------
        bool
        """

        return self._execute_action(
            "next"
        )

    def previous(self):
        """
        Go to the previous track.

        Returns
        -------
        bool
        """

        return self._execute_action(
            "previous"
        )

    # =========================================================================
    # SEEK / POSITION
    # =========================================================================

    def seek(self, seconds):
        """
        Seek relative to the current position.

        Positive values move forward.
        Negative values move backward.

        Parameters
        ----------
        seconds : float
            Number of seconds to seek.

        Returns
        -------
        bool
        """

        try:
            seconds = float(seconds)

        except (
            ValueError,
            TypeError,
        ):
            return False

        if seconds == 0:
            return True

        try:
            result = self._run([
                "position",
                str(seconds),
            ])

        except OSError:
            return False

        # playerctl seek uses a signed relative time.
        #
        # Example:
        #
        #     playerctl seek 10
        #     playerctl seek -10

        if result.returncode == 0:
            return True

        # Fallback to explicit seek command.
        try:
            result = self._run([
                "seek",
                str(seconds),
            ])

        except OSError:
            return False

        return result.returncode == 0

    def set_position(self, seconds):
        """
        Set the absolute playback position.

        Parameters
        ----------
        seconds : float
            Absolute position in seconds.

        Returns
        -------
        bool
        """

        try:
            seconds = float(seconds)

        except (
            ValueError,
            TypeError,
        ):
            return False

        if seconds < 0:
            seconds = 0

        metadata = self.get_current()

        if not metadata:
            return False

        track_id = metadata.get(
            "track_id"
        )

        if not track_id:
            return False

        microseconds = int(
            seconds * 1_000_000
        )

        result = self._dbus_call(
            "org.mpris.MediaPlayer2.Player",
            "SetPosition",
            "ox",
            [
                track_id,
                str(microseconds),
            ],
        )

        if result is None:
            return False

        return result.returncode == 0

    # =========================================================================
    # VOLUME
    # =========================================================================

    def get_volume(self):
        """
        Get current volume.

        Returns
        -------
        float or None
            Volume between 0.0 and 1.0.
        """

        value = self._dbus_get_property(
            "org.mpris.MediaPlayer2.Player",
            "Volume",
        )

        if value is None:
            return None

        try:
            tokens = shlex.split(
                value
            )

        except ValueError:
            return None

        if len(tokens) < 2:
            return None

        try:
            return float(
                tokens[-1]
            )

        except ValueError:
            return None

    def set_volume(self, volume):
        """
        Set volume.

        Parameters
        ----------
        volume : float
            Volume between 0.0 and 1.0.

        Returns
        -------
        bool
        """

        try:
            volume = float(volume)

        except (
            ValueError,
            TypeError,
        ):
            return False

        volume = max(
            0.0,
            min(1.0, volume),
        )

        result = self._dbus_call(
            "org.freedesktop.DBus.Properties",
            "Set",
            "ssv",
            [
                "org.mpris.MediaPlayer2.Player",
                "Volume",
                "d",
                str(volume),
            ],
        )

        if result is None:
            return False

        return result.returncode == 0

    def increase_volume(self, amount=0.05):
        """
        Increase volume.

        Parameters
        ----------
        amount : float
            Amount between 0.0 and 1.0.

        Returns
        -------
        bool
        """

        current = self.get_volume()

        if current is None:
            return False

        return self.set_volume(
            current + float(amount)
        )

    def decrease_volume(self, amount=0.05):
        """
        Decrease volume.

        Parameters
        ----------
        amount : float
            Amount between 0.0 and 1.0.

        Returns
        -------
        bool
        """

        current = self.get_volume()

        if current is None:
            return False

        return self.set_volume(
            current - float(amount)
        )

    # =========================================================================
    # LOOP STATUS
    # =========================================================================

    def get_loop_status(self):
        """
        Get current loop status.

        Returns
        -------
        str or None

        Possible values:

            None
            Track
            Playlist
            None
        """

        value = self._dbus_get_property(
            "org.mpris.MediaPlayer2.Player",
            "LoopStatus",
        )

        if value is None:
            return None

        try:
            tokens = shlex.split(
                value
            )

        except ValueError:
            return None

        if len(tokens) < 2:
            return None

        return tokens[-1]

    def set_loop_status(self, status):
        """
        Set loop status.

        Parameters
        ----------
        status : str
            One of:

                None
                Track
                Playlist

        Returns
        -------
        bool
        """

        valid = {
            "None",
            "Track",
            "Playlist",
        }

        if status not in valid:
            return False

        result = self._dbus_call(
            "org.freedesktop.DBus.Properties",
            "Set",
            "ssv",
            [
                "org.mpris.MediaPlayer2.Player",
                "LoopStatus",
                "s",
                status,
            ],
        )

        if result is None:
            return False

        return result.returncode == 0

    # =========================================================================
    # SHUFFLE
    # =========================================================================

    def get_shuffle(self):
        """
        Get shuffle state.

        Returns
        -------
        bool or None
        """

        value = self._dbus_get_property(
            "org.mpris.MediaPlayer2.Player",
            "Shuffle",
        )

        if value is None:
            return None

        try:
            tokens = shlex.split(
                value
            )

        except ValueError:
            return None

        if len(tokens) < 2:
            return None

        return tokens[-1].lower() == "true"

    def set_shuffle(self, enabled):
        """
        Enable or disable shuffle.

        Parameters
        ----------
        enabled : bool

        Returns
        -------
        bool
        """

        value = (
            "true"
            if enabled
            else "false"
        )

        result = self._dbus_call(
            "org.freedesktop.DBus.Properties",
            "Set",
            "ssv",
            [
                "org.mpris.MediaPlayer2.Player",
                "Shuffle",
                "b",
                value,
            ],
        )

        if result is None:
            return False

        return result.returncode == 0

    def toggle_shuffle(self):
        """
        Toggle shuffle.

        Returns
        -------
        bool
        """

        current = self.get_shuffle()

        if current is None:
            return False

        return self.set_shuffle(
            not current
        )

    # =========================================================================
    # PLAYER CAPABILITIES
    # =========================================================================

    def _get_capability(self, property_name):
        """
        Read an MPRIS boolean capability.

        Returns
        -------
        bool or None
        """

        value = self._dbus_get_property(
            "org.mpris.MediaPlayer2.Player",
            property_name,
        )

        if value is None:
            return None

        try:
            tokens = shlex.split(
                value
            )

        except ValueError:
            return None

        if len(tokens) < 2:
            return None

        return tokens[-1].lower() == "true"

    def can_control(self):
        """
        Check whether the player can be controlled.

        Returns
        -------
        bool or None
        """

        return self._get_capability(
            "CanControl"
        )

    def can_play(self):
        """
        Check whether the player supports Play.
        """

        return self._get_capability(
            "CanPlay"
        )

    def can_pause(self):
        """
        Check whether the player supports Pause.
        """

        return self._get_capability(
            "CanPause"
        )

    def can_go_next(self):
        """
        Check whether the player supports Next.
        """

        return self._get_capability(
            "CanGoNext"
        )

    def can_go_previous(self):
        """
        Check whether the player supports Previous.
        """

        return self._get_capability(
            "CanGoPrevious"
        )

    def can_seek(self):
        """
        Check whether the player supports seeking.
        """

        return self._get_capability(
            "CanSeek"
        )

    # =========================================================================
    # PLAYER APPLICATION
    # =========================================================================

    def raise_player(self):
        """
        Ask the player application to raise/focus itself.

        Returns
        -------
        bool
        """

        result = self._dbus_call(
            "org.mpris.MediaPlayer2",
            "Raise",
        )

        if result is None:
            return False

        return result.returncode == 0

    def quit_player(self):
        """
        Ask the player application to quit.

        Returns
        -------
        bool
        """

        result = self._dbus_call(
            "org.mpris.MediaPlayer2",
            "Quit",
        )

        if result is None:
            return False

        return result.returncode == 0

    # =========================================================================
    # PLAYBACK INFORMATION
    # =========================================================================

    def playback_info(self):
        """
        Return a normalized snapshot of playback state.

        Returns
        -------
        dict
        """

        metadata = self.get_current()

        if metadata is None:
            metadata = self.metadata()

        return {
            "provider": self.provider,

            "status": (
                metadata.get("status")
                if metadata
                else self.status()
            ),

            "position": (
                metadata.get("position")
                if metadata
                else self.get_position()
            ),

            "duration": (
                metadata.get("duration")
                if metadata
                else self.get_length()
            ),

            "volume": self.get_volume(),

            "loop_status": (
                self.get_loop_status()
            ),

            "shuffle": (
                self.get_shuffle()
            ),
        }

    # =========================================================================
    # CONFIGURATION
    # =========================================================================

    def get_config(self):
        """
        Return current Playerctl configuration.

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

            if self.process:
                self.running = False

                try:
                    self.process.terminate()

                except OSError:
                    pass

        except Exception:
            pass

        try:
            self._cleanup_artwork()

        except Exception:
            pass
