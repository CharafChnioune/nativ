from nativ_generation.contracts import GenerationError
from .base import BaseVideoProvider

class LocalVideoProvider(BaseVideoProvider):
    def run(self,job,context):
        if self.services.worker is None:
            raise GenerationError('runtime_unavailable','Install and qualify the isolated video runtime before generating.',status=409)
        cfg=self.services.configuration.get(self.profile['id'],{})
        if self.profile['provider']=='minimax_h3_mlx' and not cfg.get('separate_license_approved'):
            raise GenerationError('license_required','MiniMax H3 requires verified territorial or separate license eligibility.',status=409)
        prepared={key:cfg[key] for key in ('model_path','codec_paths','model_revision','profile_id','separate_license_approved') if key in cfg}
        prepared.update(cfg.get('prepared',{}))
        prepared.setdefault('profile_id',self.profile['id'])
        prepared.setdefault('model_revision',self.profile.get('model_revision'))
        # Paths are supplied only by the canonical input resolver, never the request.
        prepared['inputs']={ref['role']:str(context.input_path(ref['input_id'],ref['role'])) for ref in job['request'].get('inputs',[])}
        payload={'protocol':1,'type':'generate','provider':self.profile['provider'],
                 'request':job['request'],'profile':dict(job['profile']),'prepared':prepared,'output_dir':str(context.output_dir),
                 'job_id':job['job_id'],'attempt_id':job['attempt_id']}
        context.begin_dispatch()
        return self.services.worker.run(self.profile['runtime'],payload,context)
