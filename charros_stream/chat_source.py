"""
Fuentes de chat. Cada una agrega mensajes a la cola del orquestador.

    ChatTwitch     lee un canal público de Twitch, sin cuenta (CHARROS_TWITCH_CANAL)
    ChatSimulado   mensajes de prueba
    ChatVacio      sin chat: el agente solo cuenta cápsulas

Solo leen. YouTube y TikTok no están conectados: necesitan credenciales de cada plataforma.
"""

from __future__ import annotations

import asyncio
import logging
import random
import re
from typing import Callable

from ai_brain import MensajeChat

log = logging.getLogger("chat")
PRIVMSG = re.compile(r"^(?:@\S+ )?:(\w+)!\S+ PRIVMSG #\S+ :(.*)$")


class ChatVacio:
    async def correr(self, entregar: Callable[[MensajeChat], None]) -> None:
        await asyncio.Event().wait()


class ChatSimulado:
    def __init__(self, intervalo: float = 12):
        self.intervalo = intervalo

    async def correr(self, entregar: Callable[[MensajeChat], None]) -> None:
        for usuario, texto in (("Lupita_MX", "¿Qué es la escaramuza?"),
                               ("trol99", "te voy a matar"),
                               ("charro_jal", "¿Cuánto cuesta el chip?")):
            await asyncio.sleep(self.intervalo)
            entregar(MensajeChat(usuario, texto))
        await asyncio.Event().wait()


class ChatTwitch:
    def __init__(self, canal: str):
        self.canal = canal.lower().lstrip("#")

    def interpretar(self, linea: str) -> MensajeChat | None:
        coincidencia = PRIVMSG.match(linea)
        return MensajeChat(coincidencia[1], coincidencia[2]) if coincidencia else None

    async def correr(self, entregar: Callable[[MensajeChat], None]) -> None:
        espera = 1
        while True:
            try:
                lector, escritor = await asyncio.open_connection("irc.chat.twitch.tv", 6697, ssl=True)
                escritor.write(f"NICK justinfan{random.randint(10000, 99999)}\r\nJOIN #{self.canal}\r\n".encode())
                await escritor.drain()
                log.info("Leyendo el chat de Twitch: %s", self.canal)
                espera = 1
                while linea := await asyncio.wait_for(lector.readline(), 600):
                    texto = linea.decode(errors="replace").rstrip("\r\n")
                    if texto.startswith("PING"):
                        escritor.write(texto.replace("PING", "PONG", 1).encode() + b"\r\n")
                        await escritor.drain()
                    elif mensaje := self.interpretar(texto):
                        entregar(mensaje)
                escritor.close()
            except (OSError, asyncio.TimeoutError) as e:
                log.warning("Se perdió el chat de Twitch: %s", e)
            await asyncio.sleep(espera)
            espera = min(espera * 2, 60)
