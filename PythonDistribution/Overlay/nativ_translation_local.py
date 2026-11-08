"""Request-scoped local asset loading for explicitly selected translation speech.

No process-wide environment change: normal model-management requests retain their
existing behavior. The MLX audio worker calls its synchronous TTS function in one
thread, so the ContextVar covers both model loading and generation in that request.
"""
from __future__ import annotations

from contextvars import ContextVar
from functools import wraps
from pathlib import Path

_LOCAL_ASSETS: ContextVar[bool] = ContextVar("nativ_translation_local_assets", default=False)
_SPEECH_TOKENIZER: ContextVar[str | None] = ContextVar("nativ_translation_speech_tokenizer", default=None)


def install_local_assets_policy(hub, audio) -> None:
    if getattr(audio, "_nativ_local_assets_installed", False):
        return

    def constrain_download(original, *, snapshot=False):
        @wraps(original)
        def download(*args, **kwargs):
            if _LOCAL_ASSETS.get():
                repository = kwargs.get("repo_id", args[0] if args else None)
                tokenizer = _SPEECH_TOKENIZER.get()
                if repository == "mlx-community/S3TokenizerV2" and tokenizer:
                    if snapshot:
                        return tokenizer
                    filename = kwargs.get("filename", args[1] if len(args) > 1 else None)
                    if filename not in ("config.json", "model.safetensors", "README.md"):
                        raise ValueError("The selected tokenizer file was not prepared.")
                    file = Path(tokenizer) / filename
                    if not file.is_file():
                        raise ValueError("The selected tokenizer file was not prepared.")
                    return str(file)
                kwargs["local_files_only"] = True
            return original(*args, **kwargs)
        return download

    # Chatterbox imports these functions inside its post-load hook. Existing
    # clients outside this worker context are unaffected by the wrappers.
    hub.snapshot_download = constrain_download(hub.snapshot_download, snapshot=True)
    hub.hf_hub_download = constrain_download(hub.hf_hub_download)
    original_run = audio._run_tts_request

    @wraps(original_run)
    def run(request):
        speech = request.payload.request
        if getattr(speech, "nativ_local_only", False) is not True:
            return original_run(request)
        model = Path(speech.model)
        if not model.is_absolute() or not model.is_dir():
            raise ValueError("Translation speech requires a prepared absolute model folder.")
        reference = getattr(speech, "ref_audio", None)
        if reference and (not Path(reference).is_absolute() or not Path(reference).is_file()):
            raise ValueError("Translation speech requires a local reference recording.")
        tokenizer = getattr(speech, "nativ_speech_tokenizer_path", None)
        if tokenizer:
            path = Path(tokenizer)
            if not path.is_absolute() or not all((path / name).is_file() for name in ("config.json", "model.safetensors")):
                raise ValueError("Translation speech tokenizer assets must be prepared locally.")
        token = _LOCAL_ASSETS.set(True)
        tokenizer_token = _SPEECH_TOKENIZER.set(tokenizer)
        try:
            return original_run(request)
        finally:
            _SPEECH_TOKENIZER.reset(tokenizer_token)
            _LOCAL_ASSETS.reset(token)

    audio._run_tts_request = run
    audio._nativ_local_assets_installed = True


def install(base) -> None:
    import huggingface_hub
    import mlx_vlm.server.audio as audio
    from fastapi import Request

    install_local_assets_policy(huggingface_hub, audio)
    if getattr(base.app.state, "nativ_translation_local_assets", False):
        return

    # A preflight before sending speech prevents older runtimes silently
    # ignoring the opt-in request field and attempting auxiliary downloads.
    def capabilities(request):
        authorize = getattr(base, "_require_management_api_key", None)
        if authorize is not None:
            authorize(request)
        return {"local_speech_assets_policy": 1, "pinned_speech_assets_policy": 1}

    capabilities.__annotations__["request"] = Request
    base.app.get("/nativ/translation-capabilities", include_in_schema=False)(capabilities)
    base.app.state.nativ_translation_local_assets = True
