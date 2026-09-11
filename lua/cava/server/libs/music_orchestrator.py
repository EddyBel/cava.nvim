import threading
import time


class MusicOrchestrator:
    """
    Orquestador de los diferentes proveedores de reproducción.

    El orquestador es la única capa que debe conocer cómo seleccionar
    y ejecutar un backend.

    Arquitectura:

        provider_name
             |
             +-------------------------------+
             |                               |
        YoutubeMusic                    cualquier otro
             |                               |
        yt_provider                   playerctl_provider
                                             |
                                      provider = provider_name


    Ejemplos:

        provider_name = "YoutubeMusic"
            -> YoutubeMusicProvider
            -> fallback Playerctl

        provider_name = "Spotify"
            -> Playerctl(provider="Spotify")

        provider_name = "firefox"
            -> Playerctl(provider="firefox")

    El HTTP server no necesita conocer ningún backend.
    """

    # =========================================================================
    # CONSTANTS
    # =========================================================================

    YOUTUBE_MUSIC_ALIASES = {
        "youtubemusic",
        "youtube music",
        "youtube-music",
        "ytmusic",
        "yt-music",
        "yt music",
        "yt",
    }

    # =========================================================================
    # INITIALIZATION
    # =========================================================================

    def __init__(
        self,
        yt_provider=None,
        playerctl_provider=None,
        options=None,
        provider_name=None,
    ):
        """
        Inicializa el orquestador.

        Parameters
        ----------
        yt_provider : object, optional
            Provider de YouTube Music.

        playerctl_provider : object, optional
            Instancia de Playerctl.

        options : dict, optional
            Configuración.

            {
                "provider_name": "YoutubeMusic",
                "poll_interval": 1.0,
                "playerctl": {
                    "provider": "firefox"
                }
            }

        provider_name : str, optional
            Provider lógico seleccionado.

            Tiene prioridad sobre options["provider_name"].
        """

        options = options or {}

        self.yt_provider = yt_provider
        self.playerctl_provider = playerctl_provider

        # =====================================================================
        # PROVIDER
        # =====================================================================

        if provider_name is not None:
            self.provider_name = str(
                provider_name
            ).strip()

        else:
            configured_provider = options.get(
                "provider_name"
            )

            self.provider_name = (
                str(configured_provider).strip()
                if configured_provider
                else None
            )

        # =====================================================================
        # PLAYERCTL OPTIONS
        # =====================================================================

        self.playerctl_options = (
            options.get(
                "playerctl",
                {}
            )
            or {}
        )

        # =====================================================================
        # OPTIONS
        # =====================================================================

        self.poll_interval = options.get(
            "poll_interval",
            1.0,
        )

        # =====================================================================
        # STATE
        # =====================================================================

        self.current = None

        self._lock = threading.Lock()

        self.running = False
        self._thread = None

        self._active_backend = None

        # Configuración inicial de Playerctl.
        self._configure_playerctl()

    def is_available(self):
        """
    Return whether the currently selected provider is available.
        """
        try:
            get_active = getattr(
            self,
            "_get_active_provider",
            None,
        )

            if callable(get_active):
                provider = get_active()
            else:
                provider = None

                if self._is_youtube_music_provider(
                self.provider_name
            ):
                    provider = self.yt_provider
                else:
                    provider = self.playerctl_provider

            if provider is None:
                return False

            method = getattr(
            provider,
            "is_available",
            None,
        )

            if callable(method):
                return bool(method())

            method = getattr(
            provider,
            "available",
            None,
        )

            if callable(method):
                return bool(method())

            return True

        except Exception:
            return False

    # =========================================================================
    # PROVIDER NORMALIZATION
    # =========================================================================

    @staticmethod
    def _normalize_provider_name(provider):
        """
        Normaliza un nombre de provider.
        """

        if provider is None:
            return ""

        return " ".join(
            str(provider)
            .strip()
            .lower()
            .split()
        )

    # =========================================================================
    # YOUTUBE MUSIC
    # =========================================================================

    def _get_yt_provider_name(self):
        """
        Obtiene el nombre configurado para YouTube Music.
        """

        if not self.yt_provider:
            return "YoutubeMusic"

        return getattr(
            self.yt_provider,
            "provider",
            "YoutubeMusic",
        )

    def _is_youtube_music_provider(
        self,
        provider=None,
    ):
        """
        Determina si un provider corresponde a YouTube Music.
        """

        if provider is None:
            provider = self.provider_name

        normalized = (
            self._normalize_provider_name(
                provider
            )
        )

        if not normalized:
            return False

        yt_name = (
            self._normalize_provider_name(
                self._get_yt_provider_name()
            )
        )

        if normalized == yt_name:
            return True

        return normalized in self.YOUTUBE_MUSIC_ALIASES

    # =========================================================================
    # PLAYERCTL CONFIGURATION
    # =========================================================================

    def _configure_playerctl(self):
        """
        Configura inicialmente Playerctl.

        Si existe un provider explícito en options["playerctl"], se utiliza
        solamente cuando no existe provider_name.
        """

        if not self.playerctl_provider:
            return False

        provider = None

        if self.provider_name:
            if not self._is_youtube_music_provider():
                provider = self.provider_name

        if not provider:
            provider = self.playerctl_options.get(
                "provider"
            )

        if not provider:
            return False

        return self._set_playerctl_provider(
            provider
        )

    def _set_playerctl_provider(
        self,
        provider,
    ):
        """
        Cambia el provider interno de Playerctl.
        """

        if not self.playerctl_provider:
            return False

        if not provider:
            return False

        provider = str(
            provider
        ).strip()

        if not provider:
            return False

        try:

            current = getattr(
                self.playerctl_provider,
                "provider",
                None,
            )

            if current == provider:
                return True

            # Intentamos utilizar la API pública.
            set_provider = getattr(
                self.playerctl_provider,
                "set_provider",
                None,
            )

            if callable(set_provider):

                try:

                    result = set_provider(
                        provider
                    )

                    if result:
                        return True

                except Exception:
                    pass

            # Fallback directo.
            self.playerctl_provider.provider = (
                provider
            )

            return True

        except Exception:
            return False

    def _get_playerctl_provider_name(self):
        """
        Obtiene el provider que debe utilizar Playerctl.

        provider_name tiene prioridad porque representa la selección
        del usuario.
        """

        if (
            self.provider_name
            and not self._is_youtube_music_provider()
        ):
            return self.provider_name

        configured = self.playerctl_options.get(
            "provider"
        )

        if configured:
            return configured

        if self.playerctl_provider:
            return getattr(
                self.playerctl_provider,
                "provider",
                None,
            )

        return None

    def _configure_playerctl_provider(self):
        """
        Sincroniza el provider lógico con Playerctl.
        """

        provider = (
            self._get_playerctl_provider_name()
        )

        if not provider:
            return False

        return self._set_playerctl_provider(
            provider
        )

    # =========================================================================
    # BACKEND RESOLUTION
    # =========================================================================

    def _resolve_primary_backend(self):
        """
        Resuelve el backend principal.

        Returns
        -------
        tuple
            ("yt", provider)
            ("playerctl", provider)
            (None, None)
        """

        # ---------------------------------------------------------------------
        # No provider explícito
        # ---------------------------------------------------------------------

        if not self.provider_name:

            if self.yt_provider:
                return (
                    "yt",
                    self.yt_provider,
                )

            if self.playerctl_provider:

                self._configure_playerctl_provider()

                return (
                    "playerctl",
                    self.playerctl_provider,
                )

            return (
                None,
                None,
            )

        # ---------------------------------------------------------------------
        # YoutubeMusic
        # ---------------------------------------------------------------------

        if self._is_youtube_music_provider():

            if self.yt_provider:
                return (
                    "yt",
                    self.yt_provider,
                )

            # Si no existe YT provider, usamos Playerctl como fallback.
            if self.playerctl_provider:

                self._configure_playerctl_provider()

                return (
                    "playerctl",
                    self.playerctl_provider,
                )

            return (
                None,
                None,
            )

        # ---------------------------------------------------------------------
        # Playerctl
        # ---------------------------------------------------------------------

        if self.playerctl_provider:

            self._configure_playerctl_provider()

            return (
                "playerctl",
                self.playerctl_provider,
            )

        return (
            None,
            None,
        )

    def _resolve_fallback_backend(
        self,
        primary_backend,
    ):
        """
        Resuelve el backend de fallback.

        Actualmente:

            YoutubeMusic -> Playerctl

        Para un provider MPRIS no existe fallback alternativo.
        """

        if (
            primary_backend == "yt"
            and self.playerctl_provider
        ):

            self._configure_playerctl_provider()

            return (
                "playerctl",
                self.playerctl_provider,
            )

        return (
            None,
            None,
        )

    # =========================================================================
    # AVAILABILITY
    # =========================================================================

    @staticmethod
    def _provider_available(
        provider,
    ):
        """
        Comprueba disponibilidad de un provider.
        """

        if not provider:
            return False

        method = getattr(
            provider,
            "is_available",
            None,
        )

        if not callable(method):
            return True

        try:
            return bool(
                method()
            )

        except Exception:
            return False

    # =========================================================================
    # ACTIVE BACKEND
    # =========================================================================

    def _set_active_provider(
        self,
        provider,
    ):
        """
        Marca un provider como activo.
        """

        if not provider:
            return

        name = getattr(
            provider,
            "provider",
            None,
        )

        if not name:
            name = self.provider_name

        with self._lock:
            self._active_backend = name

    def get_active_provider(self):
        """
        Devuelve la instancia del provider activo.
        """

        with self._lock:
            active = self._active_backend

        if not active:
            return None

        normalized = (
            self._normalize_provider_name(
                active
            )
        )

        # YouTube Music.
        if self.yt_provider:

            yt_name = (
                self._normalize_provider_name(
                    getattr(
                        self.yt_provider,
                        "provider",
                        "YoutubeMusic",
                    )
                )
            )

            if normalized == yt_name:
                return self.yt_provider

            if normalized in self.YOUTUBE_MUSIC_ALIASES:
                return self.yt_provider

        # Playerctl.
        if self.playerctl_provider:

            player_name = (
                self._normalize_provider_name(
                    getattr(
                        self.playerctl_provider,
                        "provider",
                        "",
                    )
                )
            )

            if normalized == player_name:
                return self.playerctl_provider

        return None

    def get_active_backend_name(self):
        """
        Devuelve el nombre del backend activo.
        """

        with self._lock:
            return self._active_backend

    # =========================================================================
    # GENERIC METHOD CALL
    # =========================================================================

    def _call_method(
        self,
        provider,
        methods,
        *args,
        **kwargs,
    ):
        """
        Busca y ejecuta un método del provider.

        Returns
        -------
        tuple
            (handled, success, result)

        handled:
            El método existe.

        success:
            El método se ejecutó correctamente.

        result:
            Resultado original del método.
        """

        if not provider:
            return (
                False,
                False,
                None,
            )

        for method_name in methods:

            method = getattr(
                provider,
                method_name,
                None,
            )

            if not callable(method):
                continue

            try:

                result = method(
                    *args,
                    **kwargs,
                )

                return (
                    True,
                    result is not False,
                    result,
                )

            except Exception:
                return (
                    True,
                    False,
                    None,
                )

        return (
            False,
            False,
            None,
        )

    # =========================================================================
    # METADATA
    # =========================================================================

    def metadata(self):
        """
        Obtiene metadata.

        YoutubeMusic:
            yt_provider -> Playerctl fallback.

        Playerctl:
            playerctl_provider.
        """

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return None

        # ---------------------------------------------------------------------
        # Primary
        # ---------------------------------------------------------------------

        if self._provider_available(provider):

            try:

                metadata_method = getattr(
                    provider,
                    "metadata",
                    None,
                )

                if callable(metadata_method):

                    metadata = metadata_method()

                    if metadata:

                        self._set_active_provider(
                            provider
                        )

                        with self._lock:
                            self.current = metadata

                        return metadata

            except Exception:
                pass

        # ---------------------------------------------------------------------
        # Fallback
        # ---------------------------------------------------------------------

        fallback_backend, fallback = (
            self._resolve_fallback_backend(
                backend
            )
        )

        if fallback:

            if self._provider_available(
                fallback
            ):

                try:

                    metadata_method = getattr(
                        fallback,
                        "metadata",
                        None,
                    )

                    if callable(
                        metadata_method
                    ):

                        metadata = (
                            metadata_method()
                        )

                        if metadata:

                            self._set_active_provider(
                                fallback
                            )

                            with self._lock:
                                self.current = metadata

                            return metadata

                except Exception:
                    pass

        return None

    # =========================================================================
    # CURRENT STATE
    # =========================================================================

    def get_current(self):
        """
        Devuelve la última metadata conocida.
        """

        with self._lock:

            if self.current is None:
                return None

            if isinstance(
                self.current,
                dict,
            ):
                return self.current.copy()

            return self.current

    def status(self):
        """
        Devuelve el estado actual.
        """

        current = self.get_current()

        if not current:
            return None

        if isinstance(
            current,
            dict,
        ):
            return current.get(
                "status"
            )

        return None

    # =========================================================================
    # CONTROL EXECUTION
    # =========================================================================

    def _execute_control(
        self,
        methods,
        *args,
        **kwargs,
    ):
        """
        Ejecuta una operación sobre el provider principal y, si corresponde,
        utiliza Playerctl como fallback.

        Esto es importante porque el HTTP server nunca debe decidir
        qué provider utilizar.
        """

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return False

        # ---------------------------------------------------------------------
        # Primary
        # ---------------------------------------------------------------------

        handled, success, result = (
            self._call_method(
                provider,
                methods,
                *args,
                **kwargs,
            )
        )

        if handled and success:

            self._set_active_provider(
                provider
            )

            return result

        # ---------------------------------------------------------------------
        # Fallback
        # ---------------------------------------------------------------------

        fallback_backend, fallback = (
            self._resolve_fallback_backend(
                backend
            )
        )

        if fallback:

            handled, success, result = (
                self._call_method(
                    fallback,
                    methods,
                    *args,
                    **kwargs,
                )
            )

            if handled and success:

                self._set_active_provider(
                    fallback
                )

                return result

        return False

    # =========================================================================
    # PLAYERCTL DIRECT COMMAND
    # =========================================================================

    def _playerctl_command(
        self,
        args,
    ):
        """
        Ejecuta un comando de Playerctl.

        Utiliza preferentemente Playerctl._run(), ya que esa clase
        conoce cómo construir el comando con -p provider.
        """

        provider = self.playerctl_provider

        if not provider:
            return False

        self._configure_playerctl_provider()

        # ---------------------------------------------------------------------
        # Public API
        # ---------------------------------------------------------------------

        method = getattr(
            provider,
            "_run",
            None,
        )

        if callable(method):

            try:

                result = method(
                    list(args)
                )

                if result is None:
                    return False

                return (
                    getattr(
                        result,
                        "returncode",
                        1,
                    )
                    == 0
                )

            except Exception:
                pass

        # ---------------------------------------------------------------------
        # Fallback subprocess
        # ---------------------------------------------------------------------

        try:

            import subprocess

            command = getattr(
                provider,
                "command",
                "playerctl",
            )

            player = getattr(
                provider,
                "provider",
                None,
            )

            if not player:
                return False

            result = subprocess.run(
                [
                    command,
                    "-p",
                    player,
                    *args,
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            return (
                result.returncode == 0
            )

        except Exception:
            return False

    # =========================================================================
    # PLAY
    # =========================================================================

    def play(self):
        """
        Inicia la reproducción.
        """

        return self._execute_control(
            (
                "play",
                "resume",
            )
        )

    # =========================================================================
    # PAUSE
    # =========================================================================

    def pause(self):
        """
        Pausa la reproducción.
        """

        return self._execute_control(
            (
                "pause",
            )
        )

    # =========================================================================
    # PLAY / PAUSE
    # =========================================================================

    def play_pause(self):
        """
        Alterna reproducción/pausa.
        """

        return self._execute_control(
            (
                "play_pause",
                "toggle_playback",
                "toggle",
            )
        )

    # =========================================================================
    # STOP PLAYBACK
    # =========================================================================

    def stop_playback(self):
        """
        Detiene la reproducción.

        Importante:
            Esto NO llama provider.stop().

        provider.stop() pertenece al ciclo de vida del monitor.
        """

        return self._execute_control(
            (
                "stop_playback",
                "stop",
            )
        )

    # =========================================================================
    # NEXT
    # =========================================================================

    def next(self):
        """
        Siguiente canción.
        """

        return self._execute_control(
            (
                "next",
                "next_track",
                "skip_next",
                "play_next",
            )
        )

    # =========================================================================
    # PREVIOUS
    # =========================================================================

    def previous(self):
        """
        Canción anterior.
        """

        return self._execute_control(
            (
                "previous",
                "previous_track",
                "skip_previous",
                "play_previous",
            )
        )

    # =========================================================================
    # SEEK
    # =========================================================================

    def seek(self, seconds):
        """
        Seek relativo.

        Positivo:
            Adelantar.

        Negativo:
            Retroceder.
        """

        try:

            seconds = float(
                seconds
            )

        except (
            TypeError,
            ValueError,
        ):
            return False

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return False

        # ---------------------------------------------------------------------
        # Provider API
        # ---------------------------------------------------------------------

        if backend == "yt":

            handled, success, result = (
                self._call_method(
                    provider,
                    (
                        "seek",
                        "seek_relative",
                        "seek_by",
                    ),
                    seconds,
                )
            )

            if handled and success:

                self._set_active_provider(
                    provider
                )

                return result

            # Forward/backward separados.
            if seconds >= 0:

                handled, success, result = (
                    self._call_method(
                        provider,
                        (
                            "seek_forward",
                            "forward",
                            "fast_forward",
                        ),
                        abs(seconds),
                    )
                )

            else:

                handled, success, result = (
                    self._call_method(
                        provider,
                        (
                            "seek_backward",
                            "backward",
                            "rewind",
                        ),
                        abs(seconds),
                    )
                )

            if handled and success:

                self._set_active_provider(
                    provider
                )

                return result

        # ---------------------------------------------------------------------
        # Fallback Playerctl
        # ---------------------------------------------------------------------

        if backend == "yt":

            fallback = (
                self.playerctl_provider
            )

            if fallback:

                self._configure_playerctl_provider()

                result = self._playerctl_command([
                    "position",
                    str(seconds),
                ])

                if result:

                    self._set_active_provider(
                        fallback
                    )

                return result

        # ---------------------------------------------------------------------
        # Playerctl
        # ---------------------------------------------------------------------

        result = self._playerctl_command([
            "position",
            str(seconds),
        ])

        if result:
            self._set_active_provider(
                self.playerctl_provider
            )

        return result

    def seek_forward(
        self,
        seconds=10,
    ):
        """
        Adelanta N segundos.
        """

        try:
            seconds = abs(
                float(seconds)
            )

        except (
            TypeError,
            ValueError,
        ):
            return False

        return self.seek(
            seconds
        )

    def seek_backward(
        self,
        seconds=10,
    ):
        """
        Retrocede N segundos.
        """

        try:
            seconds = abs(
                float(seconds)
            )

        except (
            TypeError,
            ValueError,
        ):
            return False

        return self.seek(
            -seconds
        )

    # =========================================================================
    # POSITION
    # =========================================================================

    def get_position(self):
        """
        Obtiene la posición actual.
        """

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return None

        # ---------------------------------------------------------------------
        # Provider API
        # ---------------------------------------------------------------------

        handled, success, result = (
            self._call_method(
                provider,
                (
                    "get_position",
                    "position",
                ),
            )
        )

        if handled and success:

            self._set_active_provider(
                provider
            )

            try:
                return float(
                    result
                )

            except (
                TypeError,
                ValueError,
            ):
                return result

        # ---------------------------------------------------------------------
        # Playerctl fallback
        # ---------------------------------------------------------------------

        if backend == "yt":

            fallback = (
                self.playerctl_provider
            )

            if fallback:

                self._configure_playerctl_provider()

                method = getattr(
                    fallback,
                    "get_position",
                    None,
                )

                if callable(method):

                    try:

                        position = method()

                        self._set_active_provider(
                            fallback
                        )

                        return position

                    except Exception:
                        pass

                # Último fallback: playerctl position.
                try:

                    if hasattr(
                        fallback,
                        "_run",
                    ):

                        result = fallback._run([
                            "position",
                        ])

                        if (
                            result
                            and result.returncode == 0
                        ):

                            position = float(
                                result.stdout.strip()
                            )

                            self._set_active_provider(
                                fallback
                            )

                            return position

                except Exception:
                    pass

        return None

    def set_position(
        self,
        position,
    ):
        """
        Establece una posición absoluta en segundos.
        """

        try:

            position = float(
                position
            )

        except (
            TypeError,
            ValueError,
        ):
            return False

        if position < 0:
            position = 0.0

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return False

        # ---------------------------------------------------------------------
        # Provider API
        # ---------------------------------------------------------------------

        handled, success, result = (
            self._call_method(
                provider,
                (
                    "set_position",
                    "setPosition",
                ),
                position,
            )
        )

        if handled and success:

            self._set_active_provider(
                provider
            )

            return result

        # ---------------------------------------------------------------------
        # Playerctl
        # ---------------------------------------------------------------------

        if backend == "playerctl":

            result = self._playerctl_command([
                "position",
                str(position),
            ])

            if result:

                self._set_active_provider(
                    provider
                )

            return result

        # ---------------------------------------------------------------------
        # YoutubeMusic fallback
        # ---------------------------------------------------------------------

        fallback = (
            self.playerctl_provider
        )

        if fallback:

            self._configure_playerctl_provider()

            result = self._playerctl_command([
                "position",
                str(position),
            ])

            if result:

                self._set_active_provider(
                    fallback
                )

            return result

        return False

    # =========================================================================
    # VOLUME
    # =========================================================================

    def get_volume(self):
        """
        Obtiene el volumen actual.

        Retorna normalmente:
            0.0 - 1.0
        """

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return None

        handled, success, result = (
            self._call_method(
                provider,
                (
                    "get_volume",
                ),
            )
        )

        if handled and success:

            self._set_active_provider(
                provider
            )

            try:

                value = float(
                    result
                )

                if value > 1:
                    value /= 100

                return max(
                    0.0,
                    min(
                        1.0,
                        value,
                    ),
                )

            except (
                TypeError,
                ValueError,
            ):
                return result

        # ---------------------------------------------------------------------
        # Playerctl fallback
        # ---------------------------------------------------------------------

        if backend == "yt":

            fallback = (
                self.playerctl_provider
            )

            if fallback:

                self._configure_playerctl_provider()

                method = getattr(
                    fallback,
                    "get_volume",
                    None,
                )

                if callable(method):

                    try:

                        value = method()

                        if value is not None:

                            self._set_active_provider(
                                fallback
                            )

                            value = float(
                                value
                            )

                            if value > 1:
                                value /= 100

                            return max(
                                0.0,
                                min(
                                    1.0,
                                    value,
                                ),
                            )

                    except Exception:
                        pass

        return None

    def set_volume(
        self,
        volume,
    ):
        """
        Establece el volumen.

        Parameters
        ----------
        volume : float
            0.0 - 1.0
        """

        try:

            volume = float(
                volume
            )

        except (
            TypeError,
            ValueError,
        ):
            return False

        volume = max(
            0.0,
            min(
                1.0,
                volume,
            ),
        )

        return self._execute_control(
            (
                "set_volume",
                "setVolume",
            ),
            volume,
        )

    def volume_up(
        self,
        step=0.05,
    ):
        """
        Incrementa el volumen.
        """

        try:
            step = abs(
                float(step)
            )

        except (
            TypeError,
            ValueError,
        ):
            return False

        result = self._execute_control(
            (
                "volume_up",
                "increase_volume",
                "increaseVolume",
            ),
            step,
        )

        if result is not False:
            return result

        current = self.get_volume()

        if current is None:
            return False

        return self.set_volume(
            current + step
        )

    def volume_down(
        self,
        step=0.05,
    ):
        """
        Reduce el volumen.
        """

        try:
            step = abs(
                float(step)
            )

        except (
            TypeError,
            ValueError,
        ):
            return False

        result = self._execute_control(
            (
                "volume_down",
                "decrease_volume",
                "decreaseVolume",
            ),
            step,
        )

        if result is not False:
            return result

        current = self.get_volume()

        if current is None:
            return False

        return self.set_volume(
            current - step
        )

    # =========================================================================
    # SHUFFLE
    # =========================================================================

    def get_shuffle(self):
        """
        Obtiene el estado de shuffle.
        """

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return None

        handled, success, result = (
            self._call_method(
                provider,
                (
                    "get_shuffle",
                    "shuffle",
                ),
            )
        )

        if handled and success:

            self._set_active_provider(
                provider
            )

            return result

        # Playerctl directo.
        if backend == "playerctl":

            return self._get_playerctl_property(
                "shuffle"
            )

        # YT fallback.
        if backend == "yt":

            fallback = (
                self.playerctl_provider
            )

            if fallback:

                self._configure_playerctl_provider()

                result = self._get_playerctl_property(
                    "shuffle"
                )

                if result is not None:

                    self._set_active_provider(
                        fallback
                    )

                return result

        return None

    def set_shuffle(
        self,
        enabled,
    ):
        """
        Activa/desactiva shuffle.
        """

        if not isinstance(
            enabled,
            bool,
        ):
            return False

        return self._execute_control(
            (
                "set_shuffle",
                "setShuffle",
            ),
            enabled,
        )

    def toggle_shuffle(self):
        """
        Alterna shuffle.
        """

        result = self._execute_control(
            (
                "toggle_shuffle",
                "shuffle_toggle",
            )
        )

        if result is not False:
            return result

        current = self.get_shuffle()

        if current is None:
            return False

        return self.set_shuffle(
            not bool(current)
        )

    # =========================================================================
    # LOOP
    # =========================================================================

    def get_loop_status(self):
        """
        Obtiene el modo de repetición.

        Valores esperados:

            None
            "None"
            "Track"
            "Playlist"
        """

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return None

        handled, success, result = (
            self._call_method(
                provider,
                (
                    "get_loop_status",
                    "get_loop",
                    "loop_status",
                ),
            )
        )

        if handled and success:

            self._set_active_provider(
                provider
            )

            return result

        if backend == "playerctl":

            return self._get_playerctl_property(
                "loop"
            )

        if backend == "yt":

            fallback = (
                self.playerctl_provider
            )

            if fallback:

                self._configure_playerctl_provider()

                result = (
                    self._get_playerctl_property(
                        "loop"
                    )
                )

                if result is not None:

                    self._set_active_provider(
                        fallback
                    )

                return result

        return None

    def set_loop_status(
        self,
        status,
    ):
        """
        Establece el modo de repetición.

        Valores:

            None
            Track
            Playlist
        """

        if status is None:
            status = "None"

        status = str(
            status
        ).strip()

        if not status:
            return False

        return self._execute_control(
            (
                "set_loop_status",
                "set_loop",
                "setLoop",
            ),
            status,
        )

    def toggle_loop(self):
        """
        Alterna:

            None
              ↓
            Track
              ↓
            Playlist
              ↓
            None
        """

        result = self._execute_control(
            (
                "toggle_loop",
                "loop_toggle",
            )
        )

        if result is not False:
            return result

        current = self.get_loop_status()

        if current is None:
            return False

        normalized = (
            self._normalize_provider_name(
                current
            )
        )

        if normalized in {
            "",
            "none",
            "off",
        }:

            next_status = "Track"

        elif normalized == "track":

            next_status = "Playlist"

        else:

            next_status = "None"

        return self.set_loop_status(
            next_status
        )

    # =========================================================================
    # PLAYERCTL PROPERTY
    # =========================================================================

    def _get_playerctl_property(
        self,
        property_name,
    ):
        """
        Obtiene una propiedad utilizando playerctl.

        Se utiliza como fallback cuando el provider no expone
        una API Python equivalente.
        """

        provider = self.playerctl_provider

        if not provider:
            return None

        self._configure_playerctl_provider()

        try:

            if hasattr(
                provider,
                "_run",
            ):

                result = provider._run([
                    "get",
                    f"{{{property_name}}}",
                ])

                if (
                    result
                    and result.returncode == 0
                ):

                    value = (
                        result.stdout
                        .strip()
                    )

                    if property_name == "shuffle":

                        return (
                            value.lower()
                            in {
                                "true",
                                "yes",
                                "on",
                                "1",
                            }
                        )

                    return value

        except Exception:
            pass

        return None

    # =========================================================================
    # ARTWORK
    # =========================================================================

    def get_local_artwork(self):
        """
        Obtiene el artwork local del provider activo.
        """

        provider = (
            self.get_active_provider()
        )

        if not provider:
            return None

        for method_name in (
            "get_artwork",
            "get_local_artwork",
        ):

            method = getattr(
                provider,
                method_name,
                None,
            )

            if not callable(method):
                continue

            try:

                result = method()

                if result:
                    return result

            except Exception:
                pass

        current = self.get_current()

        if isinstance(
            current,
            dict,
        ):

            for key in (
                "artwork_path",
                "local_artwork",
                "local_path",
                "art_path",
                "path",
            ):

                if current.get(key):
                    return current.get(key)

        return None

    # =========================================================================
    # TRACKLIST
    # =========================================================================

    def tracklist(self):
        """
        Obtiene la tracklist.
        """

        backend, provider = (
            self._resolve_primary_backend()
        )

        if not provider:
            return None

        # ---------------------------------------------------------------------
        # Primary
        # ---------------------------------------------------------------------

        if self._provider_available(provider):

            method = getattr(
                provider,
                "tracklist",
                None,
            )

            if callable(method):

                try:

                    result = method()

                    if result is not None:

                        self._set_active_provider(
                            provider
                        )

                        return result

                except Exception:
                    pass

        # ---------------------------------------------------------------------
        # Fallback
        # ---------------------------------------------------------------------

        fallback_backend, fallback = (
            self._resolve_fallback_backend(
                backend
            )
        )

        if fallback:

            method = getattr(
                fallback,
                "tracklist",
                None,
            )

            if callable(method):

                try:

                    result = method()

                    if result is not None:

                        self._set_active_provider(
                            fallback
                        )

                        return result

                except Exception:
                    pass

        return None

    # =========================================================================
    # PROVIDERS
    # =========================================================================

    def get_providers(self):
        """
        Obtiene los providers disponibles.

        Incluye:

            YoutubeMusic
            + providers MPRIS
        """

        providers = []

        if self.yt_provider:

            yt_name = getattr(
                self.yt_provider,
                "provider",
                "YoutubeMusic",
            )

            providers.append(
                yt_name
            )

        if self.playerctl_provider:

            method = getattr(
                self.playerctl_provider,
                "get_providers",
                None,
            )

            if callable(method):

                try:

                    result = method()

                    if result:

                        for provider in result:

                            if provider not in providers:

                                providers.append(
                                    provider
                                )

                except Exception:
                    pass

        return providers

    # =========================================================================
    # SET PROVIDER
    # =========================================================================

    def set_provider(
        self,
        provider,
    ):
        """
        Cambia el provider lógico.

        YoutubeMusic:
            usa yt_provider.

        Cualquier otro:
            usa Playerctl.
        """

        if not provider:
            return False

        provider = str(
            provider
        ).strip()

        if not provider:
            return False

        self.provider_name = provider

        # ---------------------------------------------------------------------
        # YoutubeMusic
        # ---------------------------------------------------------------------

        if self._is_youtube_music_provider(
            provider
        ):

            if not self.yt_provider:
                return False

            try:

                if self._provider_available(
                    self.yt_provider
                ):

                    self._set_active_provider(
                        self.yt_provider
                    )

                    return True

            except Exception:
                pass

            # El provider lógico queda seleccionado aunque
            # en este momento no esté disponible.
            #
            # Esto permite que metadata()/play()/etc. intenten
            # posteriormente el fallback.
            return False

        # ---------------------------------------------------------------------
        # Playerctl
        # ---------------------------------------------------------------------

        if not self.playerctl_provider:
            return False

        if not self._set_playerctl_provider(
            provider
        ):
            return False

        try:

            if self._provider_available(
                self.playerctl_provider
            ):

                self._set_active_provider(
                    self.playerctl_provider
                )

                return True

        except Exception:
            pass

        return False

    # =========================================================================
    # AUTO PROVIDER
    # =========================================================================

    def auto_provider(self):
        """
        Selecciona automáticamente un provider disponible.

        Prioridad:

            YoutubeMusic
                ↓
            Playerctl
        """

        # ---------------------------------------------------------------------
        # YoutubeMusic
        # ---------------------------------------------------------------------

        if self.yt_provider:

            try:

                if self._provider_available(
                    self.yt_provider
                ):

                    self.provider_name = getattr(
                        self.yt_provider,
                        "provider",
                        "YoutubeMusic",
                    )

                    self._set_active_provider(
                        self.yt_provider
                    )

                    return self.provider_name

            except Exception:
                pass

        # ---------------------------------------------------------------------
        # Playerctl
        # ---------------------------------------------------------------------

        if self.playerctl_provider:

            try:

                method = getattr(
                    self.playerctl_provider,
                    "auto_provider",
                    None,
                )

                if callable(method):

                    provider = method()

                    if provider:

                        self.provider_name = (
                            provider
                        )

                        self._set_active_provider(
                            self.playerctl_provider
                        )

                        return provider

            except Exception:
                pass

        return None

    # =========================================================================
    # NEXT PROVIDER
    # =========================================================================

    def next_provider(self):
        """
        Selecciona el siguiente provider MPRIS.
        """

        if not self.playerctl_provider:
            return None

        method = getattr(
            self.playerctl_provider,
            "next_provider",
            None,
        )

        if not callable(method):
            return None

        try:

            provider = method()

            if provider:

                self.provider_name = (
                    provider
                )

                self._set_playerctl_provider(
                    provider
                )

                self._set_active_provider(
                    self.playerctl_provider
                )

                return provider

        except Exception:
            pass

        return None

    # =========================================================================
    # PREVIOUS PROVIDER
    # =========================================================================

    def previous_provider(self):
        """
        Selecciona el provider MPRIS anterior.
        """

        if not self.playerctl_provider:
            return None

        method = getattr(
            self.playerctl_provider,
            "previous_provider",
            None,
        )

        if not callable(method):
            return None

        try:

            provider = method()

            if provider:

                self.provider_name = (
                    provider
                )

                self._set_playerctl_provider(
                    provider
                )

                self._set_active_provider(
                    self.playerctl_provider
                )

                return provider

        except Exception:
            pass

        return None

    # =========================================================================
    # MONITOR
    # =========================================================================

    def _monitor(self):
        """
        Monitor de metadata.
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
        Inicia el orquestador y los providers.
        """

        if self.running:
            return False

        self.running = True

        # ---------------------------------------------------------------------
        # Configure Playerctl
        # ---------------------------------------------------------------------

        self._configure_playerctl_provider()

        # ---------------------------------------------------------------------
        # YoutubeMusic
        # ---------------------------------------------------------------------

        if self.yt_provider:

            method = getattr(
                self.yt_provider,
                "start",
                None,
            )

            if callable(method):

                try:
                    method()

                except Exception:
                    pass

        # ---------------------------------------------------------------------
        # Playerctl
        # ---------------------------------------------------------------------

        if self.playerctl_provider:

            method = getattr(
                self.playerctl_provider,
                "start",
                None,
            )

            if callable(method):

                try:
                    method()

                except Exception:
                    pass

        # ---------------------------------------------------------------------
        # Orchestrator monitor
        # ---------------------------------------------------------------------

        self._thread = threading.Thread(
            target=self._monitor,
            daemon=True,
            name="MusicOrchestrator",
        )

        self._thread.start()

        return True

    # =========================================================================
    # STOP
    # =========================================================================

    def stop(self):
        """
        Detiene el orquestador.

        NO detiene la reproducción.
        """

        self.running = False

        thread = self._thread
        self._thread = None

        # ---------------------------------------------------------------------
        # Providers
        # ---------------------------------------------------------------------

        if self.yt_provider:

            method = getattr(
                self.yt_provider,
                "stop",
                None,
            )

            if callable(method):

                try:
                    method()

                except Exception:
                    pass

        if self.playerctl_provider:

            method = getattr(
                self.playerctl_provider,
                "stop",
                None,
            )

            if callable(method):

                try:
                    method()

                except Exception:
                    pass

        # No hacemos join() porque stop() puede ser llamado
        # desde el propio monitor.

        return True

    # =========================================================================
    # RUNNING
    # =========================================================================

    def is_running(self):
        """
        Indica si el orquestador está ejecutándose.
        """

        return self.running
