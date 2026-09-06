import subprocess
import threading


class Cava:
    """
    Manage a CAVA process and expose audio visualization frames.
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

        Example:
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
    # PROCESS
    # =========================================================================

    def _read_output(self):
        """
        Read frames from CAVA stdout.
        """

        if not self.process:
            return

        buffer = ""

        try:
            for data in self.process.stdout:
                if not data:
                    continue

                buffer += data

                while "\n" in buffer:
                    frame, buffer = buffer.split(
                        "\n",
                        1,
                    )

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

    # =========================================================================
    # FRAME
    # =========================================================================

    def get_frame(self):
        """
        Get the latest CAVA frame.

        Returns
        -------
        list[int]
        """

        with self._lock:
            return self.current_frame.copy()

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
