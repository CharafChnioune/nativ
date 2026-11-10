from .base import MusicProvider, error


class LocalMusicProvider(MusicProvider):
    def run(self, job, context):
        if self.services.worker is None:
            raise error('runtime_required', 'Install and prepare this isolated music runtime.', status=409)
        # Paths come exclusively from the host's prepared profile configuration.
        prepared = {key: self.config[key] for key in ('model_path', 'checkpoints_dir', 'source_path') if key in self.config}
        payload = dict(provider=self.profile['provider'], request=dict(job['request']),
            profile=dict(job['profile']), prepared=prepared)
        return self.services.worker.run(self.profile['runtime'], payload, context)
