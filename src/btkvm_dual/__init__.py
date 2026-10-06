"""Protocol primitives and runtime support for btkvm's optional dual mode."""

from .protocol import MessageType, PacketCodec, ProtocolError

__all__ = ["MessageType", "PacketCodec", "ProtocolError"]
