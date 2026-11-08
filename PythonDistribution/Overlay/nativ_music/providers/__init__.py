from nativ_generation.contracts import GenerationError
from .acestep import ACEStepProvider
from .minimax_mlx import MiniMaxMusic3MLXProvider
from .stable_audio_mlx import StableAudio3MLXProvider
from .minimax_remote import MiniMaxMusic3RemoteProvider
from .minimax_cloud import MiniMaxCloudProvider
from .lyria import LyriaProvider
from .stable_audio_cloud import StableAudioCloudProvider


def build_provider(profile, services):
    implementations = dict(acestep=ACEStepProvider, minimax_mlx=MiniMaxMusic3MLXProvider,
        stable_audio_mlx=StableAudio3MLXProvider, minimax_remote=MiniMaxMusic3RemoteProvider,
        minimax_cloud=MiniMaxCloudProvider, lyria=LyriaProvider, stable_audio_cloud=StableAudioCloudProvider)
    cls = implementations.get(profile['provider'])
    if cls is None: raise GenerationError('unknown_provider', 'Unknown music provider.')
    return cls(profile, services)
