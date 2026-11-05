"""
La voz de Citlali: convierte texto en audio con la API de ElevenLabs.

Variables de entorno (modo real):
    ELEVENLABS_API_KEY    llave de la API
    ELEVENLABS_VOICE_ID   voz elegida en tu cuenta. El acento depende de esa voz: elige una mexicana
                          con licencia. No clones la voz de una persona sin su permiso.
    ELEVENLABS_MODELO     por defecto eleven_multilingual_v2

El audio se guarda un momento en un archivo temporal, se convierte al formato de la transmisión
(PCM de 16 bits, estéreo, 44.1 kHz) y se borra.
"""

from __future__ import annotations

import asyncio
import json
import math
import os
import struct
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

FRECUENCIA = 44100
CANALES = 2
BYTES_POR_SEGUNDO = FRECUENCIA * CANALES * 2


class ErrorVoz(Exception):
    """Falló la generación de audio. El orquestador lo registra y sigue."""


class Voz:
    def __init__(self) -> None:
        self._llave = os.getenv("ELEVENLABS_API_KEY")
        self.voz_id = os.getenv("ELEVENLABS_VOICE_ID")
        if not self._llave or not self.voz_id:
            raise ErrorVoz("Faltan ELEVENLABS_API_KEY o ELEVENLABS_VOICE_ID.")
        self.modelo = os.getenv("ELEVENLABS_MODELO", "eleven_multilingual_v2")

    def __repr__(self) -> str:  # un log del objeto no debe mostrar la llave
        return f"Voz({self.modelo!r})"

    def _pedir_mp3(self, texto: str) -> bytes:
        cuerpo = json.dumps({
            "text": texto,
            "model_id": self.modelo,
            "voice_settings": {"stability": 0.45, "similarity_boost": 0.8, "style": 0.35},
        }).encode()
        peticion = urllib.request.Request(
            f"https://api.elevenlabs.io/v1/text-to-speech/{self.voz_id}?output_format=mp3_44100_128",
            data=cuerpo, method="POST",
            headers={"xi-api-key": self._llave, "Content-Type": "application/json", "Accept": "audio/mpeg"})
        try:
            with urllib.request.urlopen(peticion, timeout=30) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            raise ErrorVoz(f"ElevenLabs respondió {e.code}") from None
        except (urllib.error.URLError, TimeoutError) as e:
            raise ErrorVoz(f"No se pudo hablar con ElevenLabs: {e}") from None

    async def sintetizar(self, texto: str) -> bytes:
        mp3 = await asyncio.to_thread(self._pedir_mp3, texto)
        return await mp3_a_pcm(mp3)


async def mp3_a_pcm(mp3: bytes) -> bytes:
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        f.write(mp3)
        ruta = Path(f.name)
    try:
        proceso = await asyncio.create_subprocess_exec(
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(ruta),
            "-f", "s16le", "-ar", str(FRECUENCIA), "-ac", str(CANALES), "-",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        pcm, errores = await asyncio.wait_for(proceso.communicate(), 30)
        if proceso.returncode != 0 or not pcm:
            raise ErrorVoz(f"ffmpeg no pudo leer el audio: {errores.decode(errors='replace')[:120]}")
        return pcm
    finally:
        ruta.unlink(missing_ok=True)


class VozSimulada:
    """Un tono suave cuya duración depende del texto: no usa la red ni tiene costo."""

    async def sintetizar(self, texto: str) -> bytes:
        muestras = int(FRECUENCIA * min(max(len(texto) / 40, 0.5), 3))
        tono = (int(3000 * math.sin(2 * math.pi * 330 * i / FRECUENCIA)) for i in range(muestras))
        return b"".join(struct.pack("<hh", v, v) for v in tono)
