"""
Image utilities.

Provides image metadata extraction and aspect-ratio-aware
size calculation without external Python dependencies.
"""

import os
import struct


class Image:
    """
    Inspect local images and calculate their optimal
    terminal dimensions.

    The class does not download images or resolve URLs.
    The source must be a local filesystem path.
    """

    def __init__(self, path):
        if not isinstance(path, str):
            raise TypeError(
                "Image path must be a string"
            )

        path = path.strip()

        if not path:
            raise ValueError(
                "Image path cannot be empty"
            )

        self.path = os.path.abspath(
            os.path.expanduser(path)
        )

        self.width = None
        self.height = None
        self.format = None

    # ========================================================================
    # FILE
    # ========================================================================

    def _validate_path(self):
        """
        Validate that the image exists and is a regular file.
        """

        if not os.path.isfile(self.path):
            raise FileNotFoundError(
                f"Image not found: {self.path}"
            )

    @staticmethod
    def _read(path, size):
        """
        Read the first `size` bytes of a file.
        """

        with open(
            path,
            "rb",
        ) as file:
            return file.read(size)

    # ========================================================================
    # IMAGE FORMAT
    # ========================================================================

    def _detect_format(self):
        """
        Detect the image format from its magic bytes.
        """

        header = self._read(
            self.path,
            32,
        )

        # --------------------------------------------------------------------
        # PNG
        # --------------------------------------------------------------------

        if header.startswith(
            b"\x89PNG\r\n\x1a\n"
        ):
            return "PNG"

        # --------------------------------------------------------------------
        # JPEG
        # --------------------------------------------------------------------

        if header.startswith(
            b"\xff\xd8\xff"
        ):
            return "JPEG"

        # --------------------------------------------------------------------
        # GIF
        # --------------------------------------------------------------------

        if (
            header.startswith(b"GIF87a")
            or header.startswith(b"GIF89a")
        ):
            return "GIF"

        # --------------------------------------------------------------------
        # BMP
        # --------------------------------------------------------------------

        if header.startswith(
            b"BM"
        ):
            return "BMP"

        # --------------------------------------------------------------------
        # WebP
        # --------------------------------------------------------------------

        if (
            len(header) >= 12
            and header[0:4] == b"RIFF"
            and header[8:12] == b"WEBP"
        ):
            return "WEBP"

        return None

    # ========================================================================
    # DIMENSIONS
    # ========================================================================

    def _read_dimensions(self, image_format):
        """
        Read image dimensions from its header.
        """

        if image_format == "PNG":
            return self._png_dimensions()

        if image_format == "JPEG":
            return self._jpeg_dimensions()

        if image_format == "GIF":
            return self._gif_dimensions()

        if image_format == "BMP":
            return self._bmp_dimensions()

        if image_format == "WEBP":
            return self._webp_dimensions()

        raise ValueError(
            f"Unsupported image format: {image_format}"
        )

    # ========================================================================
    # PNG
    # ========================================================================

    def _png_dimensions(self):
        """
        Read dimensions from the PNG IHDR chunk.
        """

        data = self._read(
            self.path,
            24,
        )

        if len(data) < 24:
            raise ValueError(
                "Invalid PNG image"
            )

        width, height = struct.unpack(
            ">II",
            data[16:24],
        )

        return width, height

    # ========================================================================
    # GIF
    # ========================================================================

    def _gif_dimensions(self):
        """
        Read dimensions from the GIF header.
        """

        data = self._read(
            self.path,
            10,
        )

        if len(data) < 10:
            raise ValueError(
                "Invalid GIF image"
            )

        width, height = struct.unpack(
            "<HH",
            data[6:10],
        )

        return width, height

    # ========================================================================
    # BMP
    # ========================================================================

    def _bmp_dimensions(self):
        """
        Read dimensions from the BMP header.
        """

        data = self._read(
            self.path,
            26,
        )

        if len(data) < 26:
            raise ValueError(
                "Invalid BMP image"
            )

        width, height = struct.unpack(
            "<ii",
            data[18:26],
        )

        return (
            abs(width),
            abs(height),
        )

    # ========================================================================
    # JPEG
    # ========================================================================

    def _jpeg_dimensions(self):
        """
        Find the JPEG SOF marker containing image dimensions.
        """

        with open(
            self.path,
            "rb",
        ) as file:

            if file.read(2) != b"\xff\xd8":
                raise ValueError(
                    "Invalid JPEG image"
                )

            while True:
                byte = file.read(1)

                if not byte:
                    break

                if byte != b"\xff":
                    continue

                marker = file.read(1)

                while marker == b"\xff":
                    marker = file.read(1)

                if not marker:
                    break

                marker_value = marker[0]

                # Standalone markers.
                if marker_value in {
                    0x01,
                    *range(0xD0, 0xD9),
                }:
                    continue

                length_data = file.read(2)

                if len(length_data) != 2:
                    break

                segment_length = struct.unpack(
                    ">H",
                    length_data,
                )[0]

                if segment_length < 2:
                    raise ValueError(
                        "Invalid JPEG segment"
                    )

                # SOF markers.
                if marker_value in {
                    0xC0,
                    0xC1,
                    0xC2,
                    0xC3,
                    0xC5,
                    0xC6,
                    0xC7,
                    0xC9,
                    0xCA,
                    0xCB,
                    0xCD,
                    0xCE,
                    0xCF,
                }:
                    data = file.read(5)

                    if len(data) != 5:
                        break

                    height, width = struct.unpack(
                        ">HH",
                        data[1:5],
                    )

                    return width, height

                file.seek(
                    segment_length - 2,
                    os.SEEK_CUR,
                )

        raise ValueError(
            "Unable to determine JPEG dimensions"
        )

    # ========================================================================
    # WEBP
    # ========================================================================

    def _webp_dimensions(self):
        """
        Read dimensions from WebP headers.

        Supports:
            VP8
            VP8L
            VP8X
        """

        data = self._read(
            self.path,
            64,
        )

        if len(data) < 16:
            raise ValueError(
                "Invalid WebP image"
            )

        chunk = data[12:16]

        # --------------------------------------------------------------------
        # Lossy VP8
        # --------------------------------------------------------------------

        if chunk == b"VP8 ":

            offset = 20

            while offset + 7 <= len(data):

                if (
                    data[offset] == 0x9D
                    and data[offset + 1] == 0x01
                    and data[offset + 2] == 0x2A
                ):
                    width, height = struct.unpack(
                        "<HH",
                        data[offset + 3:offset + 7],
                    )

                    return (
                        width & 0x3FFF,
                        height & 0x3FFF,
                    )

                offset += 1

        # --------------------------------------------------------------------
        # Lossless VP8L
        # --------------------------------------------------------------------

        elif chunk == b"VP8L":

            if len(data) < 25:
                raise ValueError(
                    "Invalid WebP VP8L image"
                )

            if data[20] != 0x2F:
                raise ValueError(
                    "Invalid WebP VP8L image"
                )

            bits = int.from_bytes(
                data[21:25],
                "little",
            )

            width = (
                bits & 0x3FFF
            ) + 1

            height = (
                (bits >> 14) & 0x3FFF
            ) + 1

            return width, height

        # --------------------------------------------------------------------
        # Extended WebP
        # --------------------------------------------------------------------

        elif chunk == b"VP8X":

            if len(data) < 30:
                raise ValueError(
                    "Invalid WebP VP8X image"
                )

            width = (
                int.from_bytes(
                    data[24:27],
                    "little",
                )
                + 1
            )

            height = (
                int.from_bytes(
                    data[27:30],
                    "little",
                )
                + 1
            )

            return width, height

        raise ValueError(
            "Unable to determine WebP dimensions"
        )

    # ========================================================================
    # INSPECT
    # ========================================================================

    def inspect(self):
        """
        Inspect the image without decoding it.
        """

        self._validate_path()

        image_format = self._detect_format()

        if image_format is None:
            raise ValueError(
                "Unsupported image format"
            )

        width, height = (
            self._read_dimensions(
                image_format
            )
        )

        if (
            width <= 0
            or height <= 0
        ):
            raise ValueError(
                "Invalid image dimensions"
            )

        self.width = width
        self.height = height
        self.format = image_format

        return {
            "path": self.path,
            "width": width,
            "height": height,
            "aspect_ratio": width / height,
            "format": image_format,
        }

    # ========================================================================
    # DIMENSIONS
    # ========================================================================

    def get_dimensions(self):
        """
        Return the original image dimensions.
        """

        if (
            self.width is None
            or self.height is None
        ):
            self.inspect()

        return {
            "width": self.width,
            "height": self.height,
        }

    def get_aspect_ratio(self):
        """
        Return the original image aspect ratio.
        """

        if (
            self.width is None
            or self.height is None
        ):
            self.inspect()

        return self.width / self.height

    # ========================================================================
    # FONT RATIO
    # ========================================================================

    @staticmethod
    def _parse_font_ratio(font_ratio):
        """
        Parse a terminal character aspect ratio.

        Examples:

            "1/2" -> 0.5
            "0.5" -> 0.5
            0.5   -> 0.5

        Represents:

            character_width / character_height
        """

        if isinstance(
            font_ratio,
            (int, float),
        ):
            value = float(font_ratio)

        elif isinstance(
            font_ratio,
            str,
        ):
            value = font_ratio.strip()

            if "/" in value:
                numerator, denominator = (
                    value.split("/", 1)
                )

                value = (
                    float(numerator)
                    / float(denominator)
                )
            else:
                value = float(value)

        else:
            raise ValueError(
                "Invalid font ratio"
            )

        if value <= 0:
            raise ValueError(
                "Font ratio must be greater than zero"
            )

        return value

    # ========================================================================
    # SIZE
    # ========================================================================

    def calculate_size(
        self,
        size,
        font_ratio="1/2",
    ):
        """
        Calculate the largest terminal size that fits
        inside the requested dimensions while preserving
        the image aspect ratio.

        The terminal character aspect ratio is taken into
        account.

        Example:

            image:
                1920 x 1080

            maximum:
                40 x 20

            font ratio:
                1/2

        Result:

            {
                "width": 40,
                "height": 11,
                "aspect_ratio": 1.777...,
                "target_ratio": 3.555...,
                "font_ratio": 0.5
            }
        """

        if not isinstance(
            size,
            dict,
        ):
            raise ValueError(
                "Invalid size"
            )

        try:
            max_width = int(
                size["width"]
            )

            max_height = int(
                size["height"]
            )

        except (
            KeyError,
            TypeError,
            ValueError,
        ) as error:

            raise ValueError(
                "Invalid image size"
            ) from error

        if (
            max_width <= 0
            or max_height <= 0
        ):
            raise ValueError(
                "Image size must be greater than zero"
            )

        image_ratio = (
            self.get_aspect_ratio()
        )

        cell_ratio = (
            self._parse_font_ratio(
                font_ratio
            )
        )

        # Ratio represented by the terminal grid.
        #
        #     columns
        #     -------
        #      rows
        #
        # must compensate for the physical aspect ratio
        # of terminal characters.

        target_ratio = (
            image_ratio
            / cell_ratio
        )

        # Candidate constrained by width.
        width = max_width

        height = (
            width
            / target_ratio
        )

        # If the resulting height is too large,
        # constrain the image by height instead.

        if height > max_height:
            height = max_height
            width = (
                height
                * target_ratio
            )

        width = max(
            1,
            min(
                max_width,
                int(width),
            ),
        )

        height = max(
            1,
            min(
                max_height,
                int(height),
            ),
        )

        return {
            "width": width,
            "height": height,
            "aspect_ratio": image_ratio,
            "target_ratio": target_ratio,
            "font_ratio": cell_ratio,
        }

    # ========================================================================
    # INFORMATION
    # ========================================================================

    def get_info(self):
        """
        Return complete image information.
        """

        metadata = self.inspect()

        return {
            "path": metadata["path"],
            "width": metadata["width"],
            "height": metadata["height"],
            "aspect_ratio": metadata["aspect_ratio"],
            "format": metadata["format"],
        }
