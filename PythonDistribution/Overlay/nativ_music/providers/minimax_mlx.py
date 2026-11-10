from .local import LocalMusicProvider


class MiniMaxMusic3MLXProvider(LocalMusicProvider):
    """Pinned mlx-audio music code in an owned process, separate from TTS."""
