from .local import LocalMusicProvider


class ACEStepProvider(LocalMusicProvider):
    """Dedicated Python 3.12 native ACE-Step worker; no public ACE HTTP service."""
