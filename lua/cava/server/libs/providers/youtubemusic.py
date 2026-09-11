"""
YouTube Music (Pear Desktop companion API) integration.

This module talks to the local HTTP API exposed by YouTube Music
desktop apps built on the "Pear Desktop" companion server.

The provider normalizes YouTube Music responses into a common
MusicManager metadata structure and exposes playback controls.
"""

import hashlib
import json
import os
import shutil
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class YoutubeMusicProvider:
    """
    Query and control the local YouTube Music (Pear Desktop) HTTP API.
    """

    DEFAULT_BASE_URL = "http://localhost:26538"

    # =========================================================================
    # API PATHS
    # =========================================================================

    QUEUE_PATH = "/api/v1/queue"
    SONG_PATH = "/api/v1/song"

    # Playback control endpoints.
    #
    # These are configurable because Pear Desktop companion builds may
    # expose slightly different routes.
    PLAY_PATH = "/api/v1/play"
    PAUSE_PATH = "/api/v1/pause"
    PLAY_PAUSE_PATH = "/api/v1/play-pause"
    STOP_PATH = "/api/v1/stop"
    NEXT_PATH = "/api/v1/next"
    PREVIOUS_PATH = "/api/v1/previous"

    SEEK_PATH = "/api/v1/seek"
    POSITION_PATH = "/api/v1/position"

    VOLUME_PATH = "/api/v1/volume"

    SHUFFLE_PATH = "/api/v1/shuffle"
    LOOP_PATH = "/api/v1/loop"

    REQUEST_TIMEOUT = 2

    # is_available() is called frequently by the orchestrator.
    AVAILABILITY_TIMEOUT = 0.4

    # Artwork limits.
    ARTWORK_MAX_SIZE = 50 * 1024 * 1024
    ARTWORK_CHUNK_SIZE = 64 * 1024
    ARTWORK_TIMEOUT = 15

    # =========================================================================
    # INITIALIZATION
    # =========================================================================

    def __init__(self, options=None):
        """
        Initialize YoutubeMusicProvider.

        Parameters
        ----------
        options : dict, optional
            provider:
                Label stored in normalized metadata.

            base_url:
                Pear Desktop API base URL.

            queue_path:
                Endpoint used to read the queue.

            song_path:
                Optional endpoint used to refine playback state.

            poll_interval:
                Seconds between background metadata polls.

            play_path:
                Playback endpoint.

            pause_path:
                Pause endpoint.

            play_pause_path:
                Toggle playback endpoint.

            stop_path:
                Stop playback endpoint.

            next_path:
                Next track endpoint.

            previous_path:
                Previous track endpoint.

            seek_path:
                Relative seek endpoint.

            position_path:
                Absolute position endpoint.

            volume_path:
                Volume endpoint.

            shuffle_path:
                Shuffle endpoint.

            loop_path:
                Loop endpoint.
        """
        options = options or {}

        # =====================================================================
        # PROVIDER
        # =====================================================================

        self.provider = options.get(
            "provider",
            "YoutubeMusic",
        )

        # =====================================================================
        # HTTP CONFIGURATION
        # =====================================================================

        self.base_url = options.get(
            "base_url",
            self.DEFAULT_BASE_URL,
        ).rstrip("/")

        self.queue_path = options.get(
            "queue_path",
            self.QUEUE_PATH,
        )

        self.song_path = options.get(
            "song_path",
            self.SONG_PATH,
        )

        self.poll_interval = options.get(
            "poll_interval",
            1.0,
        )

        # =====================================================================
        # CONTROL ENDPOINTS
        # =====================================================================

        self.play_path = options.get(
            "play_path",
            self.PLAY_PATH,
        )

        self.pause_path = options.get(
            "pause_path",
            self.PAUSE_PATH,
        )

        self.play_pause_path = options.get(
            "play_pause_path",
            self.PLAY_PAUSE_PATH,
        )

        self.stop_path = options.get(
            "stop_path",
            self.STOP_PATH,
        )

        self.next_path = options.get(
            "next_path",
            self.NEXT_PATH,
        )

        self.previous_path = options.get(
            "previous_path",
            self.PREVIOUS_PATH,
        )

        self.seek_path = options.get(
            "seek_path",
            self.SEEK_PATH,
        )

        self.position_path = options.get(
            "position_path",
            self.POSITION_PATH,
        )

        self.volume_path = options.get(
            "volume_path",
            self.VOLUME_PATH,
        )

        self.shuffle_path = options.get(
            "shuffle_path",
            self.SHUFFLE_PATH,
        )

        self.loop_path = options.get(
            "loop_path",
            self.LOOP_PATH,
        )

        # =====================================================================
        # STATE
        # =====================================================================

        self.current = None

        self._lock = threading.Lock()

        self.running = False
        self._thread = None

        # =====================================================================
        # ARTWORK CACHE
        # =====================================================================

        self.artwork_directory = tempfile.mkdtemp(
            prefix="music-manager-ytmusic-"
        )

        self.artwork_url = None
        self.artwork_path = None

        # URI -> local path
        self._artwork_cache = {}

        # track_id -> {
        #     "url": "...",
        #     "path": "..."
        # }
        self._tracklist_artwork = {}

        # track_id -> art_url
        self._tracklist_artwork_pending = {}

        self._artwork_generation = 0

        self._artwork_lock = threading.Lock()

    # =========================================================================
    # HTTP
    # =========================================================================

    def _get_json(self, path, timeout=None):
        """
        Perform a GET request and parse the JSON response.

        Returns
        -------
        dict or list or None
        """
        if not path:
            return None

        url = f"{self.base_url}{path}"

        try:
            request = urllib.request.Request(
                url,
                headers={
                    "Accept": "application/json",
                },
            )

            with urllib.request.urlopen(
                request,
                timeout=timeout or self.REQUEST_TIMEOUT,
            ) as response:
                body = response.read()

        except (
            OSError,
            urllib.error.URLError,
            urllib.error.HTTPError,
        ):
            return None

        try:
            return json.loads(body)
        except (
            ValueError,
            TypeError,
        ):
            return None

    def _request_control(
        self,
        path,
        method="POST",
        params=None,
        timeout=None,
    ):
        """
        Execute an HTTP request used by playback controls.

        Parameters
        ----------
        path : str
            API endpoint.

        method : str
            HTTP method.

        params : dict, optional
            Query/body parameters.

        timeout : float, optional
            Request timeout.

        Returns
        -------
        bool
            True when the HTTP request completed successfully.
        """
        if not path:
            return False

        url = f"{self.base_url}{path}"

        params = params or {}

        try:
            if method.upper() == "GET":
                if params:
                    query = urllib.parse.urlencode(
                        params
                    )

                    separator = (
                        "&"
                        if "?" in url
                        else "?"
                    )

                    url = (
                        f"{url}"
                        f"{separator}"
                        f"{query}"
                    )

                request = urllib.request.Request(
                    url,
                    method="GET",
                    headers={
                        "Accept": "application/json",
                    },
                )

            else:
                body = json.dumps(
                    params
                ).encode("utf-8")

                request = urllib.request.Request(
                    url,
                    data=body,
                    method=method.upper(),
                    headers={
                        "Accept": "application/json",
                        "Content-Type": "application/json",
                    },
                )

            with urllib.request.urlopen(
                request,
                timeout=(
                    timeout
                    or self.REQUEST_TIMEOUT
                ),
            ) as response:

                # Any 2xx response is considered successful.
                status = getattr(
                    response,
                    "status",
                    200,
                )

                return 200 <= status < 300

        except (
            OSError,
            urllib.error.URLError,
            urllib.error.HTTPError,
        ):
            return False

    # =========================================================================
    # AVAILABILITY
    # =========================================================================

    def is_available(self):
        """
        Check whether the Pear Desktop API is currently available.

        Returns
        -------
        bool
        """
        return (
            self._get_json(
                self.queue_path,
                timeout=self.AVAILABILITY_TIMEOUT,
            )
            is not None
        )

    # =========================================================================
    # PARSING HELPERS
    # =========================================================================

    @staticmethod
    def _join_runs(node):
        """
        Join a YouTube Music text node.

        Returns
        -------
        str
        """
        if not isinstance(node, dict):
            return ""

        runs = node.get("runs")

        if not isinstance(runs, list):
            return ""

        return "".join(
            str(run.get("text", ""))
            for run in runs
            if isinstance(run, dict)
        )

    @staticmethod
    def _normalize_string(value):
        """
        Normalize a value into a clean string.

        Returns
        -------
        str or None
        """
        if value is None:
            return None

        value = str(value).strip()

        return value or None

    @staticmethod
    def _parse_duration(text):
        """
        Convert a duration such as:

            3:34
            1:03:42

        into seconds.

        Returns
        -------
        float or None
        """
        if not text:
            return None

        parts = text.strip().split(":")

        if not parts:
            return None

        if not all(
            part.isdigit()
            for part in parts
        ):
            return None

        parts = [
            int(part)
            for part in parts
        ]

        while len(parts) < 3:
            parts.insert(0, 0)

        hours, minutes, seconds = parts[-3:]

        return float(
            hours * 3600
            + minutes * 60
            + seconds
        )

    @classmethod
    def _best_thumbnail(cls, renderer):
        """
        Select the highest-resolution thumbnail available.

        Returns
        -------
        str or None
        """
        thumbnail = renderer.get("thumbnail")

        if not isinstance(
            thumbnail,
            dict,
        ):
            return None

        thumbnails = thumbnail.get(
            "thumbnails"
        )

        if not isinstance(
            thumbnails,
            list,
        ):
            return None

        if not thumbnails:
            return None

        for thumbnail in reversed(
            thumbnails
        ):
            if not isinstance(
                thumbnail,
                dict,
            ):
                continue

            url = cls._normalize_string(
                thumbnail.get("url")
            )

            if url:
                return url

        return None

    @classmethod
    def _find_current_item(cls, items):
        """
        Find the queue item marked as currently selected.

        Returns
        -------
        dict or None
        """
        for item in items:
            if not isinstance(
                item,
                dict,
            ):
                continue

            renderer = item.get(
                "playlistPanelVideoRenderer"
            )

            if (
                isinstance(
                    renderer,
                    dict,
                )
                and renderer.get("selected")
            ):
                return renderer

        for item in items:
            if not isinstance(
                item,
                dict,
            ):
                continue

            renderer = item.get(
                "playlistPanelVideoRenderer"
            )

            if isinstance(
                renderer,
                dict,
            ):
                return renderer

        return None

    @classmethod
    def _parse_byline(cls, renderer):
        """
        Extract artist and album from YouTube's longBylineText.
        """
        text = cls._join_runs(
            renderer.get("longBylineText")
        )

        if not text:
            return None, None

        segments = [
            segment.strip()
            for segment in text.split("•")
        ]

        artist = (
            cls._normalize_string(
                segments[0]
            )
            if segments
            else None
        )

        album = (
            cls._normalize_string(
                segments[1]
            )
            if len(segments) > 1
            else None
        )

        return artist, album

    @classmethod
    def _parse_year(cls, renderer):
        """
        Extract the release year from longBylineText.
        """
        text = cls._join_runs(
            renderer.get("longBylineText")
        )

        if not text:
            return None

        segments = [
            segment.strip()
            for segment in text.split("•")
        ]

        if len(segments) < 3:
            return None

        year = segments[2]

        if not year.isdigit():
            return None

        year = int(year)

        if year < 0:
            return None

        return year

    @classmethod
    def _is_explicit(cls, renderer):
        """
        Detect whether the track contains YouTube Music's
        explicit-content badge.
        """
        badges = renderer.get("badges")

        if not isinstance(
            badges,
            list,
        ):
            return False

        for badge in badges:
            if not isinstance(
                badge,
                dict,
            ):
                continue

            inline_badge = badge.get(
                "musicInlineBadgeRenderer"
            )

            if not isinstance(
                inline_badge,
                dict,
            ):
                continue

            icon = inline_badge.get(
                "icon"
            )

            if not isinstance(
                icon,
                dict,
            ):
                continue

            if (
                icon.get("iconType")
                == "MUSIC_EXPLICIT_BADGE"
            ):
                return True

        return False

    @classmethod
    def _get_watch_index(
        cls,
        renderer,
        fallback,
    ):
        """
        Extract the queue index from the watch endpoint.
        """
        navigation_endpoint = renderer.get(
            "navigationEndpoint"
        )

        if not isinstance(
            navigation_endpoint,
            dict,
        ):
            return fallback

        watch_endpoint = navigation_endpoint.get(
            "watchEndpoint"
        )

        if not isinstance(
            watch_endpoint,
            dict,
        ):
            return fallback

        index = watch_endpoint.get(
            "index"
        )

        if isinstance(
            index,
            int,
        ):
            return index

        return fallback

    @classmethod
    def _renderer_to_metadata(
        cls,
        renderer,
        status=None,
        position=None,
    ):
        """
        Convert a playlistPanelVideoRenderer into the common
        MusicManager metadata structure.
        """
        title = cls._normalize_string(
            cls._join_runs(
                renderer.get("title")
            )
        )

        artist, album = cls._parse_byline(
            renderer
        )

        video_id = cls._normalize_string(
            renderer.get("videoId")
        )

        art_url = cls._normalize_string(
            cls._best_thumbnail(renderer)
        )

        duration = cls._parse_duration(
            cls._join_runs(
                renderer.get("lengthText")
            )
        )

        url = (
            f"https://music.youtube.com/watch?v={video_id}"
            if video_id
            else None
        )

        return {
            "title": title,
            "artist": artist,
            "album": album,
            "url": url,
            "art_url": art_url,
            "track_id": video_id,
            "status": status,
            "position": position,
            "duration": duration,
        }

    # =========================================================================
    # CURRENT TRACK
    # =========================================================================

    def _parse_queue(self, data):
        """
        Extract normalized metadata for the currently selected track.
        """
        if not isinstance(
            data,
            dict,
        ):
            return None

        items = data.get("items")

        if not isinstance(
            items,
            list,
        ):
            return None

        if not items:
            return None

        renderer = self._find_current_item(
            items
        )

        if not renderer:
            return None

        metadata = self._renderer_to_metadata(
            renderer,
            status="Playing",
            position=None,
        )

        metadata["provider"] = self.provider

        return metadata

    def _enrich_with_song_state(
        self,
        metadata,
    ):
        """
        Refine playback information using /api/v1/song.
        """
        data = self._get_json(
            self.song_path
        )

        if not isinstance(
            data,
            dict,
        ):
            return metadata

        is_paused = data.get(
            "isPaused"
        )

        if isinstance(
            is_paused,
            bool,
        ):
            metadata["status"] = (
                "Paused"
                if is_paused
                else "Playing"
            )

        elapsed = data.get(
            "elapsedSeconds"
        )

        if isinstance(
            elapsed,
            (int, float),
        ):
            metadata["position"] = float(
                elapsed
            )

        song_duration = data.get(
            "songDuration"
        )

        if isinstance(
            song_duration,
            (int, float),
        ):
            metadata["duration"] = float(
                song_duration
            )

        image_src = self._normalize_string(
            data.get("imageSrc")
        )

        if image_src:
            metadata["art_url"] = image_src

        return metadata

    # =========================================================================
    # METADATA API
    # =========================================================================

    def _set_metadata(
        self,
        metadata,
    ):
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
        Fetch and normalize the currently playing track.
        """
        data = self._get_json(
            self.queue_path
        )

        metadata = self._parse_queue(
            data
        )

        if metadata is None:
            return None

        if self.song_path:
            metadata = self._enrich_with_song_state(
                metadata
            )

        self._set_metadata(
            metadata
        )

        return metadata

    def get_current(self):
        """
        Return the last known metadata without making
        a network request.
        """
        with self._lock:
            if self.current is None:
                return None

            return self.current.copy()

    def status(self):
        """
        Return the last known playback status.
        """
        current = self.get_current()

        if not current:
            return None

        return current.get("status")

    # =========================================================================
    # PLAYBACK CONTROLS
    # =========================================================================

    def play(self):
        """
        Start/resume playback.

        Returns
        -------
        bool
        """
        result = self._request_control(
            self.play_path
        )

        if result:
            self._refresh_metadata_async()

        return result

    def pause(self):
        """
        Pause playback.

        Returns
        -------
        bool
        """
        result = self._request_control(
            self.pause_path
        )

        if result:
            self._refresh_metadata_async()

        return result

    def play_pause(self):
        """
        Toggle playback.

        Returns
        -------
        bool
        """
        result = self._request_control(
            self.play_pause_path
        )

        if result:
            self._refresh_metadata_async()

        return result

    def stop_playback(self):
        """
        Stop playback.

        This is intentionally different from stop(), which stops
        the provider's background monitor.

        Returns
        -------
        bool
        """
        result = self._request_control(
            self.stop_path
        )

        if result:
            self._refresh_metadata_async()

        return result

    def next(self):
        """
        Skip to the next track.

        Returns
        -------
        bool
        """
        result = self._request_control(
            self.next_path
        )

        if result:
            self._refresh_metadata_async()

        return result

    def previous(self):
        """
        Skip to the previous track.

        Returns
        -------
        bool
        """
        result = self._request_control(
            self.previous_path
        )

        if result:
            self._refresh_metadata_async()

        return result

    # =========================================================================
    # SEEK / POSITION
    # =========================================================================

    def seek(self, seconds):
        """
        Seek relative to the current playback position.

        Positive values move forward.
        Negative values move backward.

        Examples
        --------
        seek(10)
        seek(-10)

        Parameters
        ----------
        seconds : float
            Relative offset in seconds.

        Returns
        -------
        bool
        """
        try:
            seconds = float(seconds)
        except (
            TypeError,
            ValueError,
        ):
            return False

        if seconds == 0:
            return True

        result = self._request_control(
            self.seek_path,
            params={
                "seconds": seconds,
            },
        )

        if result:
            self._refresh_metadata_async()

        return result

    def seek_forward(self, seconds=10):
        """
        Move forward by the specified number of seconds.
        """
        try:
            seconds = abs(float(seconds))
        except (
            TypeError,
            ValueError,
        ):
            return False

        return self.seek(seconds)

    def seek_backward(self, seconds=10):
        """
        Move backward by the specified number of seconds.
        """
        try:
            seconds = abs(float(seconds))
        except (
            TypeError,
            ValueError,
        ):
            return False

        return self.seek(-seconds)

    def get_position(self):
        """
        Return the current playback position in seconds.

        Returns
        -------
        float or None
        """
        current = self.get_current()

        if current:
            position = current.get(
                "position"
            )

            if isinstance(
                position,
                (int, float),
            ):
                return float(position)

        metadata = self.metadata()

        if not metadata:
            return None

        position = metadata.get(
            "position"
        )

        if isinstance(
            position,
            (int, float),
        ):
            return float(position)

        return None

    def set_position(self, seconds):
        """
        Set an absolute playback position.

        Parameters
        ----------
        seconds : float
            Position in seconds from the beginning.

        Returns
        -------
        bool
        """
        try:
            seconds = max(
                0.0,
                float(seconds),
            )
        except (
            TypeError,
            ValueError,
        ):
            return False

        result = self._request_control(
            self.position_path,
            params={
                "seconds": seconds,
            },
        )

        if result:
            self._refresh_metadata_async()

        return result

    # =========================================================================
    # VOLUME
    # =========================================================================

    @staticmethod
    def _parse_volume(value):
        """
        Normalize a volume value.

        Accepts either:

            0.0 - 1.0

        or:

            0 - 100

        Returns
        -------
        float or None
        """
        if value is None:
            return None

        try:
            value = float(value)
        except (
            TypeError,
            ValueError,
        ):
            return None

        if value > 1.0:
            value /= 100.0

        return max(
            0.0,
            min(1.0, value),
        )

    def get_volume(self):
        """
        Return current volume as a normalized value from 0.0 to 1.0.

        Returns
        -------
        float or None
        """
        data = self._get_json(
            self.volume_path
        )

        if isinstance(
            data,
            dict,
        ):
            for key in (
                "volume",
                "value",
                "level",
            ):
                if key in data:
                    return self._parse_volume(
                        data[key]
                    )

        if isinstance(
            data,
            (int, float),
        ):
            return self._parse_volume(
                data
            )

        return None

    def set_volume(self, volume):
        """
        Set volume.

        Parameters
        ----------
        volume : float
            Normalized volume from 0.0 to 1.0.

        Returns
        -------
        bool
        """
        volume = self._parse_volume(
            volume
        )

        if volume is None:
            return False

        return self._request_control(
            self.volume_path,
            params={
                "volume": volume,
            },
        )

    def volume_up(self, step=0.05):
        """
        Increase volume by step.

        Parameters
        ----------
        step : float
            Amount from 0.0 to 1.0.
        """
        try:
            step = abs(float(step))
        except (
            TypeError,
            ValueError,
        ):
            return False

        current = self.get_volume()

        if current is None:
            return False

        return self.set_volume(
            current + step
        )

    def volume_down(self, step=0.05):
        """
        Decrease volume by step.

        Parameters
        ----------
        step : float
            Amount from 0.0 to 1.0.
        """
        try:
            step = abs(float(step))
        except (
            TypeError,
            ValueError,
        ):
            return False

        current = self.get_volume()

        if current is None:
            return False

        return self.set_volume(
            current - step
        )

    # =========================================================================
    # SHUFFLE
    # =========================================================================

    @staticmethod
    def _parse_bool(value):
        """
        Convert common API boolean representations into bool.
        """
        if isinstance(
            value,
            bool,
        ):
            return value

        if isinstance(
            value,
            (int, float),
        ):
            return bool(value)

        if isinstance(
            value,
            str,
        ):
            return value.strip().lower() in {
                "true",
                "1",
                "yes",
                "on",
            }

        return None

    def get_shuffle(self):
        """
        Return current shuffle state.

        Returns
        -------
        bool or None
        """
        data = self._get_json(
            self.shuffle_path
        )

        if isinstance(
            data,
            dict,
        ):
            for key in (
                "shuffle",
                "enabled",
                "value",
            ):
                if key in data:
                    return self._parse_bool(
                        data[key]
                    )

        return self._parse_bool(
            data
        )

    def set_shuffle(self, enabled):
        """
        Enable or disable shuffle.

        Returns
        -------
        bool
        """
        enabled = self._parse_bool(
            enabled
        )

        if enabled is None:
            return False

        return self._request_control(
            self.shuffle_path,
            params={
                "shuffle": enabled,
            },
        )

    def toggle_shuffle(self):
        """
        Toggle shuffle state.

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
    # LOOP
    # =========================================================================

    @staticmethod
    def _normalize_loop_status(value):
        """
        Normalize loop status.

        Supported values:

            None
            Track
            Playlist

        Also accepts:

            none
            track
            playlist
            off
        """
        if value is None:
            return None

        value = str(value).strip().lower()

        mapping = {
            "none": "None",
            "off": "None",
            "false": "None",
            "track": "Track",
            "one": "Track",
            "playlist": "Playlist",
            "all": "Playlist",
        }

        return mapping.get(
            value
        )

    def get_loop_status(self):
        """
        Return current loop mode.

        Returns
        -------
        str or None
        """
        data = self._get_json(
            self.loop_path
        )

        if isinstance(
            data,
            dict,
        ):
            for key in (
                "loop",
                "loopStatus",
                "status",
                "value",
            ):
                if key in data:
                    return self._normalize_loop_status(
                        data[key]
                    )

        return self._normalize_loop_status(
            data
        )

    def set_loop_status(self, status):
        """
        Set loop mode.

        Supported values:

            None
            Track
            Playlist

        Returns
        -------
        bool
        """
        status = self._normalize_loop_status(
            status
        )

        if status is None:
            # "None" is a valid MPRIS-style loop status,
            # so send it explicitly instead of treating it
            # as a missing value.
            status = "None"

        return self._request_control(
            self.loop_path,
            params={
                "loop": status,
            },
        )

    def toggle_loop(self):
        """
        Cycle through loop modes:

            None -> Track -> Playlist -> None

        Returns
        -------
        bool
        """
        current = self.get_loop_status()

        if current == "None":
            next_status = "Track"

        elif current == "Track":
            next_status = "Playlist"

        elif current == "Playlist":
            next_status = "None"

        else:
            return False

        return self.set_loop_status(
            next_status
        )

    # =========================================================================
    # ASYNC METADATA REFRESH
    # =========================================================================

    def _refresh_metadata_async(self):
        """
        Refresh metadata without blocking the caller.

        Playback controls should return immediately instead of waiting
        for the next polling interval.
        """

        def worker():
            try:
                self.metadata()
            except Exception:
                pass

        threading.Thread(
            target=worker,
            daemon=True,
        ).start()

    # =========================================================================
    # TRACKLIST PARSING
    # =========================================================================

    def _parse_tracklist(self, data):
        """
        Convert the raw YouTube Music queue into a normalized
        MusicManager tracklist.
        """
        if not isinstance(
            data,
            dict,
        ):
            return []

        items = data.get(
            "items"
        )

        if not isinstance(
            items,
            list,
        ):
            return []

        tracklist = []

        for item_index, item in enumerate(
            items
        ):
            if not isinstance(
                item,
                dict,
            ):
                continue

            renderer = item.get(
                "playlistPanelVideoRenderer"
            )

            if not isinstance(
                renderer,
                dict,
            ):
                continue

            selected = bool(
                renderer.get("selected")
            )

            status = (
                "Playing"
                if selected
                else None
            )

            metadata = self._renderer_to_metadata(
                renderer,
                status=status,
                position=None,
            )

            metadata["provider"] = (
                self.provider
            )

            metadata["index"] = (
                self._get_watch_index(
                    renderer,
                    item_index,
                )
            )

            metadata["selected"] = selected

            metadata["explicit"] = (
                self._is_explicit(
                    renderer
                )
            )

            metadata["year"] = (
                self._parse_year(
                    renderer
                )
            )

            metadata["artwork_path"] = None

            tracklist.append(
                metadata
            )

        if self.song_path:
            for track in tracklist:
                if not track.get(
                    "selected"
                ):
                    continue

                self._enrich_with_song_state(
                    track
                )

                break

        return tracklist

    # =========================================================================
    # TRACKLIST ARTWORK
    # =========================================================================

    def _get_cached_track_artwork(
        self,
        track_id,
        art_url,
    ):
        """
        Return cached artwork for a track.
        """
        track_id = self._normalize_string(
            track_id
        )

        art_url = self._normalize_string(
            art_url
        )

        if not track_id or not art_url:
            return None

        with self._artwork_lock:
            cached = (
                self._tracklist_artwork.get(
                    track_id
                )
            )

            if not isinstance(
                cached,
                dict,
            ):
                return None

            if cached.get(
                "url"
            ) != art_url:
                return None

            path = cached.get(
                "path"
            )

            if (
                not path
                or not os.path.isfile(
                    path
                )
            ):
                return None

            return path

    def _resolve_track_artwork_worker(
        self,
        track_id,
        art_url,
        generation,
    ):
        """
        Resolve a single track's artwork in the background.
        """
        path = None

        try:
            path = self.download_image(
                art_url
            )
        except Exception:
            path = None

        with self._artwork_lock:

            if (
                generation
                != self._artwork_generation
            ):
                self._tracklist_artwork_pending.pop(
                    track_id,
                    None,
                )
                return

            self._tracklist_artwork_pending.pop(
                track_id,
                None,
            )

            if not path:
                return

            self._tracklist_artwork[
                track_id
            ] = {
                "url": art_url,
                "path": path,
            }

    def _resolve_tracklist_artwork_async(
        self,
        tracklist,
    ):
        """
        Start asynchronous artwork resolution for all tracks
        that are not already cached.
        """
        if not isinstance(
            tracklist,
            list,
        ):
            return

        workers = []

        with self._artwork_lock:
            generation = (
                self._artwork_generation
            )

            for track in tracklist:
                if not isinstance(
                    track,
                    dict,
                ):
                    continue

                track_id = (
                    self._normalize_string(
                        track.get(
                            "track_id"
                        )
                    )
                )

                art_url = (
                    self._normalize_string(
                        track.get(
                            "art_url"
                        )
                    )
                )

                if not track_id or not art_url:
                    continue

                cached = (
                    self._tracklist_artwork.get(
                        track_id
                    )
                )

                if (
                    isinstance(
                        cached,
                        dict,
                    )
                    and cached.get(
                        "url"
                    ) == art_url
                    and cached.get(
                        "path"
                    )
                    and os.path.isfile(
                        cached["path"]
                    )
                ):
                    continue

                pending_url = (
                    self._tracklist_artwork_pending.get(
                        track_id
                    )
                )

                if pending_url == art_url:
                    continue

                self._tracklist_artwork_pending[
                    track_id
                ] = art_url

                workers.append(
                    (
                        track_id,
                        art_url,
                        generation,
                    )
                )

        for (
            track_id,
            art_url,
            generation,
        ) in workers:

            thread = threading.Thread(
                target=(
                    self._resolve_track_artwork_worker
                ),
                args=(
                    track_id,
                    art_url,
                    generation,
                ),
                daemon=True,
            )

            thread.start()

    def _attach_tracklist_artwork(
        self,
        tracklist,
    ):
        """
        Attach currently available local artwork paths.
        """
        if not isinstance(
            tracklist,
            list,
        ):
            return tracklist

        for track in tracklist:
            if not isinstance(
                track,
                dict,
            ):
                continue

            track_id = (
                self._normalize_string(
                    track.get(
                        "track_id"
                    )
                )
            )

            art_url = (
                self._normalize_string(
                    track.get(
                        "art_url"
                    )
                )
            )

            if not track_id or not art_url:
                track[
                    "artwork_path"
                ] = None
                continue

            path = (
                self._get_cached_track_artwork(
                    track_id,
                    art_url,
                )
            )

            track[
                "artwork_path"
            ] = path

        return tracklist

    def get_tracklist_artwork(
        self,
        tracklist,
    ):
        """
        Return currently available local artwork paths.
        """
        if not isinstance(
            tracklist,
            list,
        ):
            return {}

        result = {}

        for track in tracklist:
            if not isinstance(
                track,
                dict,
            ):
                continue

            track_id = (
    self._normalize_string(
        track.get(
            "track_id"
        )
    ))

            artwork_path = (
                self._normalize_string(
                    track.get(
                        "artwork_path"
                    )
                )
            )

            if not track_id or not artwork_path:
                continue

            result[
                track_id
            ] = artwork_path

        return result

    def tracklist(self):
        """
        Fetch and normalize the current YouTube Music queue.

        Artwork resolution is asynchronous.
        """
        data = self._get_json(
            self.queue_path
        )

        tracklist = self._parse_tracklist(
            data
        )

        self._attach_tracklist_artwork(
            tracklist
        )

        self._resolve_tracklist_artwork_async(
            tracklist
        )

        return tracklist

    # =========================================================================
    # MONITOR
    # =========================================================================

    def _monitor(self):
        """
        Poll the API while the provider is running.
        """
        while self.running:
            try:
                self.metadata()
            except Exception:
                pass

            time.sleep(
                self.poll_interval
            )

    def start(self):
        """
        Start background polling.

        Returns
        -------
        bool
        """
        if self.running:
            return False

        self._ensure_artwork_directory()

        self.running = True

        self._thread = threading.Thread(
            target=self._monitor,
            daemon=True,
        )

        self._thread.start()

        return True

    def stop(self):
        """
        Stop background polling and cleanup artwork.
        """
        self.running = False

        self._thread = None

        self._cleanup_artwork()

    def is_running(self):
        """
        Check whether background polling is running.

        Returns
        -------
        bool
        """
        return self.running

    # =========================================================================
    # IMAGE / ARTWORK
    # =========================================================================

    def _ensure_artwork_directory(self):
        """
        Ensure the temporary artwork directory exists.

        This is necessary because stop() destroys the previous directory.
        """
        if (
            self.artwork_directory
            and os.path.isdir(
                self.artwork_directory
            )
        ):
            return

        self.artwork_directory = (
            tempfile.mkdtemp(
                prefix="music-manager-ytmusic-"
            )
        )

    @staticmethod
    def _artwork_cache_name(url):
        """
        Generate a stable cache filename from an artwork URI.
        """
        digest = hashlib.sha256(
            url.encode("utf-8")
        ).hexdigest()

        return f"{digest}.img"

    def download_image(self, uri):
        """
        Download an image from a URI into the temporary image cache.
        """
        uri = self._normalize_string(
            uri
        )

        if not uri:
            return None

        self._ensure_artwork_directory()

        path = os.path.join(
            self.artwork_directory,
            self._artwork_cache_name(uri),
        )

        with self._artwork_lock:
            cached_path = (
                self._artwork_cache.get(
                    uri
                )
            )

            if (
                cached_path
                and os.path.isfile(
                    cached_path
                )
            ):
                return cached_path

            if os.path.isfile(
                path
            ):
                self._artwork_cache[
                    uri
                ] = path

                return path

        temporary_path = (
            f"{path}.tmp"
        )

        try:
            request = urllib.request.Request(
                uri,
                headers={
                    "User-Agent": (
                        "MusicManager/1.0"
                    ),
                },
            )

            with urllib.request.urlopen(
                request,
                timeout=self.ARTWORK_TIMEOUT,
            ) as response:

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
                                "Image exceeds maximum size."
                            )

                        file.write(chunk)

            os.replace(
                temporary_path,
                path,
            )

            with self._artwork_lock:
                self._artwork_cache[
                    uri
                ] = path

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

    # =========================================================================
    # ASYNC MAIN ARTWORK
    # =========================================================================

    def _request_artwork(
        self,
        art_url,
    ):
        """
        Request artwork synchronization asynchronously.
        """
        art_url = self._normalize_string(
            art_url
        )

        if not art_url:
            with self._artwork_lock:
                self.artwork_url = None
                self.artwork_path = None
                self._artwork_generation += 1

            return

        self._ensure_artwork_directory()

        with self._artwork_lock:

            if (
                self.artwork_url == art_url
                and self.artwork_path
                and os.path.isfile(
                    self.artwork_path
                )
            ):
                return

            cached_path = (
                self._artwork_cache.get(
                    art_url
                )
            )

            if (
                cached_path
                and os.path.isfile(
                    cached_path
                )
            ):
                self.artwork_url = art_url
                self.artwork_path = cached_path

                return

            self._artwork_generation += 1

            generation = (
                self._artwork_generation
            )

            self.artwork_url = art_url
            self.artwork_path = None

        thread = threading.Thread(
            target=self._artwork_worker,
            args=(
                art_url,
                generation,
            ),
            daemon=True,
        )

        thread.start()

    def _artwork_worker(
        self,
        art_url,
        generation,
    ):
        """
        Download artwork asynchronously.
        """
        path = self.download_image(
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

    # =========================================================================
    # ARTWORK ACCESS
    # =========================================================================

    def get_artwork(self):
        """
        Return the currently cached artwork path.
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

    # =========================================================================
    # CLEANUP
    # =========================================================================

    def _cleanup_artwork(self):
        """
        Remove the temporary artwork cache.
        """
        with self._artwork_lock:

            self.artwork_url = None
            self.artwork_path = None

            self._artwork_cache.clear()

            self._tracklist_artwork.clear()

            self._tracklist_artwork_pending.clear()

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
    # CONFIGURATION
    # =========================================================================

    def get_config(self):
        """
        Return the current provider configuration.
        """
        return {
            "provider": self.provider,
            "base_url": self.base_url,

            "queue_path": self.queue_path,
            "song_path": self.song_path,

            "play_path": self.play_path,
            "pause_path": self.pause_path,
            "play_pause_path": self.play_pause_path,
            "stop_path": self.stop_path,
            "next_path": self.next_path,
            "previous_path": self.previous_path,

            "seek_path": self.seek_path,
            "position_path": self.position_path,

            "volume_path": self.volume_path,

            "shuffle_path": self.shuffle_path,
            "loop_path": self.loop_path,

            "poll_interval": self.poll_interval,
        }

    # =========================================================================
    # DESTRUCTOR
    # =========================================================================

    def __del__(self):
        """
        Cleanup resources when the provider is destroyed.
        """
        try:
            self._cleanup_artwork()
        except Exception:
            pass
