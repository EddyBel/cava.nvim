import subprocess
import threading
import time


class Cava:
    """
    Manage a CAVA process and expose processed audio visualization frames.

    Cava is responsible for:
        - Reading raw CAVA data.
        - Converting raw values into renderable buffer heights.
        - Maintaining the render cache.
        - Reporting only changed columns.
    """

    DEFAULT_CONFIG = {
        "framerate": 30,
        "bars": 16,

        "input_method": "pulse",
        "input_source": "auto",

        "ascii_max_range": 100,
        "bar_delimiter": 59,
        "frame_delimiter": 10,

        "channels": "mono",
        "mono_option": "average",
    }

    def __init__(self, options=None):
        """
        Initialize CAVA.

        Parameters
        ----------
        options : dict, optional
            CAVA configuration overrides.
        """

        self.config = self.DEFAULT_CONFIG.copy()

        if options:
            self.config.update(options)

        self.process = None
        self.thread = None

        self.running = False
        self.current_frame = []

        # -----------------------------------------------------------------
        # RENDER CACHE
        # -----------------------------------------------------------------
        #
        # Cache de la última representación que fue entregada al cliente.
        #
        # Ejemplo:
        # [2, 4, 7, 7, 10, 8, 4, 2]
        #
        self._render_cache = []

        # Configuración utilizada para construir el cache.
        #
        # Si cambia el tamaño del buffer o el número de columnas,
        # el cache deja de ser válido.
        self._render_dimensions = None

        self._lock = threading.Lock()

    # =========================================================================
    # CONFIGURATION
    # =========================================================================

    def _create_config(self):
        """
        Build the CAVA configuration.
        """

        config = self.config

        return f"""[general]

framerate = {config["framerate"]}

bars = {config["bars"]}

[input]

method = {config["input_method"]}

source = {config["input_source"]}

[output]

method = raw

data_format = ascii

ascii_max_range = {config["ascii_max_range"]}

bar_delimiter = {config["bar_delimiter"]}

frame_delimiter = {config["frame_delimiter"]}

channels = {config["channels"]}

mono_option = {config["mono_option"]}

"""

    # =========================================================================
    # FRAME PARSING
    # =========================================================================

    @staticmethod
    def _parse_frame(frame):
        """
        Parse a raw CAVA frame.

        Example
        -------
        "10;25;43;80;100"

        Returns
        -------
        list[int]
        """

        values = []

        for value in frame.split(";"):
            value = value.strip()

            if not value:
                continue

            try:
                values.append(int(value))

            except ValueError:
                continue

        return values

    # =========================================================================
    # FRAME PROCESSING
    # =========================================================================

    @staticmethod
    def _resize_frame(frame, columns):
        """
        Resize a CAVA frame to the requested number of columns.

        If CAVA produces more values than requested, values are grouped.

        If CAVA produces fewer values, the available values are distributed
        across the requested columns.

        Parameters
        ----------
        frame : list[int]
            Raw CAVA values.

        columns : int
            Number of columns requested.

        Returns
        -------
        list[int]
        """

        if columns <= 0:
            return []

        if not frame:
            return [0] * columns

        source_size = len(frame)

        # Exact size.
        if source_size == columns:
            return frame.copy()

        result = []

        # -----------------------------------------------------------------
        # Downsampling
        # -----------------------------------------------------------------
        #
        # Example:
        #
        # 16 CAVA bars -> 8 visual columns
        #
        # Each visual column receives el máximo de su grupo.
        #
        if source_size > columns:

            for index in range(columns):

                start = int(index * source_size / columns)
                end = int((index + 1) * source_size / columns)

                if end <= start:
                    end = start + 1

                group = frame[start:end]

                result.append(max(group))

            return result

        # -----------------------------------------------------------------
        # Upsampling
        # -----------------------------------------------------------------
        #
        # Example:
        #
        # 8 CAVA bars -> 16 visual columns
        #
        # Repetimos/distribuimos las barras existentes.
        #
        for index in range(columns):

            source_index = int(index * source_size / columns)

            if source_index >= source_size:
                source_index = source_size - 1

            result.append(frame[source_index])

        return result

    @staticmethod
    def _scale_frame(frame, height, max_value=100):
        """
        Convert CAVA values into buffer heights.

        CAVA values are expected to be in the range 0..max_value.

        Example
        -------
        CAVA value 50 with height 20 -> 10

        Returns
        -------
        list[int]
        """

        if height <= 0:
            return [0] * len(frame)

        if max_value <= 0:
            max_value = 100

        result = []

        for value in frame:

            value = max(0, min(value, max_value))

            scaled = round(
                (value / max_value) * height
            )

            scaled = max(
                0,
                min(scaled, height)
            )

            result.append(scaled)

        return result

    def _process_frame(self, frame, width, height, columns):
        """
        Convert a raw CAVA frame into a renderable frame.

        Parameters
        ----------
        frame : list[int]
            Raw CAVA data.

        width : int
            Buffer width.

        height : int
            Buffer height.

        columns : int
            Number of columns to generate.

        Returns
        -------
        list[int]
            Render-ready column heights.
        """

        # Width is intentionally accepted as part of the rendering contract.
        #
        # Normally columns <= width, but we don't force this here because
        # the caller may use a custom rendering layout.
        del width

        frame = self._resize_frame(
            frame,
            columns,
        )

        frame = self._scale_frame(
            frame,
            height,
            self.config["ascii_max_range"],
        )

        return frame

    # =========================================================================
    # RENDER CACHE
    # =========================================================================

    def _calculate_changes(self, frame):
        """
    Compare a processed frame against the render cache.

    Returns
    -------
    list[dict]
        Changed columns including the previous value, new value
        and delta.

    Example
    -------
    [
        {
            "column": 2,
            "from": 5,
            "to": 8,
            "delta": 3,
        },
        {
            "column": 5,
            "from": 12,
            "to": 7,
            "delta": -5,
        },
    ]
        """

        changes = []

        for column, value in enumerate(frame):

            # -------------------------------------------------------------
            # Column does not exist in the previous cache.
            #
            # This normally happens on the first frame or after the
            # render dimensions changed.
            # -------------------------------------------------------------
            if column >= len(self._render_cache):

                previous = 0

                changes.append({
                "column": column,
                "from": previous,
                "to": value,
                "delta": value - previous,
            })

                continue

            previous = self._render_cache[column]

            # -------------------------------------------------------------
            # Column changed.
            # -------------------------------------------------------------
            if previous != value:

                changes.append({
                "column": column,
                "from": previous,
                "to": value,
                "delta": value - previous,
            })

            return changes


    def _update_render_cache(self, frame):
        """
    Replace the render cache with the current processed frame.
        """

        self._render_cache = list(frame)

    def clear_render_cache(self):
        """
        Clear the render cache.

        The next call to get_render_frame() will consider every column
        as changed.
        """

        with self._lock:
            self._render_cache = []
            self._render_dimensions = None

    # =========================================================================
    # PROCESS
    # =========================================================================

    def _read_output(self):
        """
        Read frames from CAVA stdout.
        """

        if not self.process:
            return

        try:
            for frame in iter(
                self.process.stdout.readline,
                "",
            ):

                frame = frame.strip()

                if not frame:
                    continue

                parsed = self._parse_frame(frame)

                with self._lock:
                    self.current_frame = parsed

        finally:
            self.running = False

    def start(self):
        """
        Start CAVA.

        Returns
        -------
        bool
            True if CAVA was started.
        """

        if self.running:
            return False

        command = [
            "cava",
            "-p",
            "/dev/stdin",
        ]

        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )

        except OSError:
            self.process = None
            return False

        config = self._create_config()

        try:
            self.process.stdin.write(config)
            self.process.stdin.close()

        except (BrokenPipeError, OSError):
            self.process.kill()
            self.process = None
            return False

        self.running = True

        self.thread = threading.Thread(
            target=self._read_output,
            daemon=True,
        )

        self.thread.start()

        return True

    def stop(self):
        """
        Stop CAVA.
        """

        if not self.process:
            return

        self.running = False

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

        with self._lock:
            self.current_frame = []
            self._render_cache = []
            self._render_dimensions = None

    # =========================================================================
    # FRAME
    # =========================================================================

    def get_frame(self):
        """
        Get the latest raw CAVA frame.

        This method is kept for low-level access and backwards compatibility.
        """

        with self._lock:
            return self.current_frame.copy()

    def get_render_frame(self, width, height, columns):
        """
        Get a render-ready frame for Neovim.

        Parameters
        ----------
        width : int
            Width of the Neovim buffer.

        height : int
            Height of the Neovim buffer.

        columns : int
            Number of visualization columns to generate.

        Returns
        -------
        dict

        Example
        -------
        {
            "frame": [2, 5, 8, 8, 12, 9],
            "change": [
                {"column": 2, "value": 8},
                {"column": 4, "value": 12}
            ]
        }
        """

        width = max(0, int(width))
        height = max(0, int(height))
        columns = max(0, int(columns))

        dimensions = (
            width,
            height,
            columns,
        )

        with self._lock:

            # -------------------------------------------------------------
            # Copy raw frame while holding the lock.
            # -------------------------------------------------------------
            raw_frame = self.current_frame.copy()

            # -------------------------------------------------------------
            # A change in dimensions invalidates the cache.
            # -------------------------------------------------------------
            if self._render_dimensions != dimensions:

                self._render_cache = []
                self._render_dimensions = dimensions

            # -------------------------------------------------------------
            # Transform raw CAVA data into render-ready values.
            # -------------------------------------------------------------
            frame = self._process_frame(
                raw_frame,
                width,
                height,
                columns,
            )

            # -------------------------------------------------------------
            # Calculate only changed columns.
            # -------------------------------------------------------------
            changes = self._calculate_changes(
                frame
            )

            # -------------------------------------------------------------
            # The new frame becomes the render cache.
            # -------------------------------------------------------------
            self._update_render_cache(frame)

            return {
                "frame": frame,
                "change": changes,
            }

    # =========================================================================
    # STATE
    # =========================================================================

    def is_running(self):
        """
        Return whether CAVA is currently running.
        """

        return self.running

    def get_config(self):
        """
        Return the current CAVA configuration.
        """

        return self.config.copy()
