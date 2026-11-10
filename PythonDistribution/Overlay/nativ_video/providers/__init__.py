"""Lazy adapter factory. Listing video models cannot import an inference runtime."""
def build_provider(profile, services):
    kind=profile['provider']
    if kind=='ltx_mlx':
        from .ltx_mlx import LTXMLXProvider
        return LTXMLXProvider(profile,services)
    if kind=='wan_mlx':
        from .wan_mlx import WanMLXProvider
        return WanMLXProvider(profile,services)
    if kind=='minimax_h3_mlx':
        from .minimax_h3_mlx import MiniMaxH3MLXProvider
        return MiniMaxH3MLXProvider(profile,services)
    if kind=='ltx_cloud':
        from .ltx_cloud import LTXCloudProvider
        return LTXCloudProvider(profile,services)
    if kind=='runway':
        from .runway import RunwayVideoProvider
        return RunwayVideoProvider(profile,services)
    raise ValueError('Unsupported video adapter')
