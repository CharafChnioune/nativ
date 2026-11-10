"""Run one model across several Macs with Nativ (pipeline parallel over the MLX ring backend).

The ring backend speaks plain TCP, so any reachable address works (e.g. Tailscale).
Rank 0 is the host's normal server: every API keeps working there. Each decoder
forward call on the host is mirrored to the node workers, which run their own
layers in lockstep; tokens are only sampled on the host. Nodes download only the
weight files of their layers. Cluster mode needs one sequence at a time and no
prefix cache or drafter, so the cache lifecycle is creation + forward updates only;
every mirrored call checks that cache offsets still agree.
"""
from __future__ import annotations

import inspect
import ipaddress
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

PROTOCOL = 1
CONFIG_ENV = "NATIV_CLUSTER_CONFIG"
NODE_ENV = "NATIV_CLUSTER_NODE"
BASE_PORT = 32400
HEADER_BYTES = 1 << 16
RESERVE_BYTES = 4 << 30
CONNECT_TIMEOUT = 1800
_LAYER = re.compile(r"(?:^|\.)layers\.(\d+)\.")
_NOT_LANGUAGE = re.compile(r"vision|visual|image|audio|mm_projector|multi_modal")
_TRUSTED_NETWORKS = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48"))
_ARRAY_DTYPES = {"int32", "uint32", "int64", "float16", "bfloat16", "float32"}
MAX_ARRAY_ELEMENTS = 1 << 28


class ClusterError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


# ---- planning (pure, unit tested) -------------------------------------------------

def layer_of(key: str) -> int | None:
    """Decoder layer index of a weight, or None for shared (embeddings, head, vision...)."""
    m = _LAYER.search(key)
    return None if m is None or _NOT_LANGUAGE.search(key) else int(m.group(1))


def layer_bytes(tensor_sizes: dict[str, int]) -> tuple[dict[int, int], int]:
    per, shared = {}, 0
    for key, size in tensor_sizes.items():
        layer = layer_of(key)
        if layer is None:
            shared += size
        else:
            per[layer] = per.get(layer, 0) + size
    return per, shared


def weighted_split(num_layers: int, per: dict[int, int], shared: int, capacities: list[int]) -> list[int]:
    """Layers per rank, proportional to usable memory. Rank 0 runs the last layers, so
    ranks take the first layers in reverse order (rank n-1 first)."""
    usable = [c - shared for c in capacities]
    if num_layers < len(capacities) or min(usable) <= 0:
        raise ClusterError("cluster_insufficient_memory", "A Mac in the cluster cannot hold the shared model weights.")
    sizes = [per.get(i, 0) for i in range(num_layers)]
    total = sum(sizes)
    order = list(range(len(capacities)))[::-1]
    split = [0] * len(capacities)
    layer, used = 0, 0
    for position, rank in enumerate(order):
        remaining_ranks = len(order) - position - 1
        target = total * sum(usable[r] for r in order[: position + 1]) / sum(usable)
        while layer < num_layers - remaining_ranks and (split[rank] == 0 or used + sizes[layer] / 2 <= target):
            used += sizes[layer]; split[rank] += 1; layer += 1
    split[0] += num_layers - layer
    for rank, count in enumerate(split):
        start, end = layer_range(split, rank)
        if sum(sizes[start:end]) > usable[rank]:
            raise ClusterError("cluster_insufficient_memory", "The model does not fit in the combined memory of these Macs.")
    return split


def layer_range(split: list[int], rank: int) -> tuple[int, int]:
    start = sum(split[rank + 1:])
    return start, start + split[rank]


def shard_files(weight_map: dict[str, str], start: int, end: int) -> set[str]:
    return {f for k, f in weight_map.items() if (layer := layer_of(k)) is None or start <= layer < end}


def trusted_address(address: str) -> bool:
    """The ring and the bearer token travel unencrypted: only Tailscale (WireGuard) or loopback carry them."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    return ip.is_loopback or any(ip in network for network in _TRUSTED_NETWORKS)


def require_trusted(address: str) -> None:
    if not trusted_address(address):
        raise ClusterError("cluster_untrusted_network", f"{address} is not a Tailscale or loopback address; cluster traffic is unencrypted.")


def ring_hostfile(addresses: list[str]) -> list[list[str]]:
    return [[f"{address}:{BASE_PORT + rank}"] for rank, address in enumerate(addresses)]


def encode(message: dict) -> bytes:
    data = json.dumps(message, separators=(",", ":")).encode()
    if len(data) + 4 > HEADER_BYTES:
        raise ClusterError("cluster_message_too_large", "A cluster control message exceeded its buffer.")
    return struct.pack("<I", len(data)) + data + bytes(HEADER_BYTES - 4 - len(data))


def decode(buffer: bytes) -> dict:
    (length,) = struct.unpack("<I", buffer[:4])
    return json.loads(buffer[4:4 + length])


def repo_and_revision(path: str) -> tuple[str, str | None]:
    """'org/name' stays a repo id; an HF cache snapshot path maps back to its repo and revision."""
    m = re.search(r"models--([^/]+)--([^/]+)/snapshots/([0-9a-f]{40})", str(path))
    if m:
        return f"{m.group(1)}/{m.group(2)}", m.group(3)
    if re.fullmatch(r"[\w.-]+/[\w.-]+", str(path)) and not Path(path).exists():
        return str(path), None
    raise ClusterError("cluster_model_not_on_hub", "Cluster models must come from Hugging Face so every Mac can download its part.")


# ---- MLX side ----------------------------------------------------------------------

def _mx():
    import mlx.core as mx
    return mx


def capacity_bytes() -> int:
    mx = _mx()
    info = mx.device_info() if hasattr(mx, "device_info") else mx.metal.device_info()
    return int(info.get("max_recommended_working_set_size", info["memory_size"])) - RESERVE_BYTES


def versions() -> dict:
    import importlib.metadata as m
    return {"protocol": PROTOCOL, "mlx": m.version("mlx"), "mlx-vlm": m.version("mlx-vlm")}


def remote_tensor_sizes(repo: str, revision: str | None) -> tuple[dict[str, str], dict[str, int]]:
    """Weight map and tensor byte sizes from the hub's safetensors headers, without downloading weights."""
    from huggingface_hub import get_safetensors_metadata
    meta = get_safetensors_metadata(repo, revision=revision)
    sizes = {}
    for file_meta in meta.files_metadata.values():
        for name, info in file_meta.tensors.items():
            sizes[name] = info.data_offsets[1] - info.data_offsets[0]
    return dict(meta.weight_map), sizes


def install_pipeline_split(split: list[int]) -> None:
    from mlx_vlm.models.pipeline import PipelineMixin

    def pipeline(self, group):  # mlx-vlm 0.7.12 drops a layer on uneven splits; use an explicit one
        self.pipeline_rank, self.pipeline_size = group.rank(), group.size()
        self.start_idx, self.end_idx = layer_range(split, self.pipeline_rank)
        self.layers = self.layers[: self.end_idx]
        self.layers[: self.start_idx] = [None] * self.start_idx

    PipelineMixin.pipeline = pipeline


def load_shard(repo: str, revision: str | None, split: list[int], group):
    """Download only this rank's files, then load the pipelined model like mlx-vlm's sharded_load."""
    from mlx_vlm.utils import get_model_path, load_image_processor, load_model, load_processor
    mx = _mx()
    weight_map, _ = remote_tensor_sizes(repo, revision)
    start, end = layer_range(split, group.rank())
    patterns = ["*.json", "*.py", "*.txt", "*.model", "*.tiktoken", "*.jinja", "*.jsonl", *sorted(shard_files(weight_map, start, end))]
    model_path = get_model_path(repo, revision=revision, allow_patterns=patterns)
    install_pipeline_split(split)
    model = load_model(model_path, lazy=True, strict=False)
    lm = model.language_model
    inner = lm.model if hasattr(lm, "model") else lm
    if not hasattr(inner, "pipeline"):
        raise ClusterError("cluster_model_unsupported", "This model family cannot be split across Macs yet.")
    inner.pipeline(group)
    processor = load_processor(model_path, True, eos_token_ids=model.config.to_dict().get("eos_token_id"))
    image_processor = load_image_processor(model_path)
    if image_processor is not None:
        processor.image_processor = image_processor
    mx.eval(lm.parameters())
    model.eval()
    mx.eval(mx.distributed.all_sum(mx.array(1.0), group=group, stream=mx.cpu))
    return model, processor, inner


class Mirror:
    """Broadcasts each decoder call from rank 0 and replays it on the other ranks."""

    def __init__(self, inner, group):
        self.inner, self.group, self.mx = inner, group, _mx()
        self.original = type(inner).__call__
        self.signature = inspect.signature(self.original)
        self.cache_key, self.caches, self.pending = None, None, None

    def _send(self, message: dict) -> dict:
        mx = self.mx
        import numpy as np
        if self.group.rank() == 0:
            payload = mx.array(np.frombuffer(encode(message), dtype=np.uint8))
        else:
            payload = mx.zeros((HEADER_BYTES,), dtype=mx.uint8)
        out = mx.distributed.all_sum(payload, group=self.group, stream=mx.cpu)
        mx.eval(out)
        return decode(bytes(memoryview(out)))

    def _array(self, value=None, shape=None, dtype=None):
        mx = self.mx
        local = value if value is not None else mx.zeros(shape, dtype=getattr(mx, dtype))
        out = mx.distributed.all_sum(local, group=self.group)
        mx.eval(out)
        return out

    @staticmethod
    def _cache_state(cache) -> dict | None:
        if not cache:
            return None
        first = cache[0]
        def plain(value):
            return value.tolist() if hasattr(value, "tolist") else value
        return {"cls": type(first).__name__, "offset": plain(getattr(first, "offset", 0)),
                "left_padding": plain(getattr(first, "left_padding", None))}

    def host_call(self, *args, **kwargs):
        try:
            return self._host_call(*args, **kwargs)
        except RuntimeError as error:
            if "[ring]" not in str(error):
                raise
            raise ClusterError("cluster_node_lost", "A Mac left the cluster. Load the model again to reconnect the Macs.") from None

    def _host_call(self, *args, **kwargs):
        mx = self.mx
        bound = self.signature.bind(self.inner, *args, **kwargs)
        params = dict(list(bound.arguments.items())[1:])
        cache = params.pop("cache", None)
        arrays = {k: v for k, v in params.items() if isinstance(v, mx.array)}
        scalars = {k: v for k, v in params.items() if k not in arrays}
        if any(not isinstance(v, (int, float, bool, str, type(None))) for v in scalars.values()):
            raise ClusterError("cluster_call_unsupported", "This model passes values the cluster cannot mirror.")
        # Collectives must run in the same order on every rank. The batcher builds call k+1
        # before call k ran (prefill chunks, lazy next-token inputs): finish call k first.
        mx.eval(*arrays.values(), *([self.pending] if self.pending is not None else []))
        self.pending = None
        state = self._cache_state(cache)
        if state is not None:
            state["key"] = id(cache)
        self._send({"op": "forward", "cache": state, "scalars": scalars,
                    "arrays": {k: [list(v.shape), str(v.dtype).split(".")[-1]] for k, v in arrays.items()}})
        for value in arrays.values():
            self._array(value)
        self.pending = self.original(self.inner, **arrays, **scalars, cache=cache)
        return self.pending

    def _worker_caches(self, state: dict):
        from mlx_vlm.generate.ar import _make_cache
        from mlx_vlm.models import cache as cache_module
        lm = self.model.language_model
        if state["cls"].startswith("Batch"):
            return _make_cache(lm, state["left_padding"] or [0])
        return cache_module.make_prompt_cache(lm)

    def serve(self, model) -> None:
        mx = self.mx
        self.model = model
        while True:
            message = self._send({})
            if message.get("op") == "stop":
                return
            state = message.get("cache")
            if state is None:
                cache = None
            else:
                fresh = state["key"] != self.cache_key or (state["offset"] in (0, [0]) and self._cache_state(self.caches)["offset"] not in (0, [0]))
                if fresh:
                    self.caches, self.cache_key = self._worker_caches(state), state["key"]
                mine = self._cache_state(self.caches)
                if mine["cls"] != state["cls"] or mine["offset"] != state["offset"]:
                    raise ClusterError("cluster_desync", f"Cache state diverged from the host ({mine} vs {state}).")
                cache = self.caches
            for shape, dtype in message["arrays"].values():
                count = 1
                for size in shape:
                    count *= int(size)
                if dtype not in _ARRAY_DTYPES or count > MAX_ARRAY_ELEMENTS or min(shape, default=1) < 0:
                    raise ClusterError("cluster_invalid_message", "The host sent an array the node will not allocate.")
            arrays = {k: self._array(shape=shape, dtype=dtype) for k, (shape, dtype) in message["arrays"].items()}
            out = self.original(self.inner, **arrays, **message["scalars"], cache=cache)
            mx.eval(out)

    def stop(self) -> None:
        self._send({"op": "stop"})


def mirror_on_host(inner, group) -> Mirror:
    mirror = Mirror(inner, group)
    inner.__class__ = type(type(inner).__name__, (type(inner),), {"__call__": lambda self, *a, **k: mirror.host_call(*a, **k)})
    return mirror


# ---- host orchestration ----------------------------------------------------------

def _request(url: str, key: str | None, body: dict | None = None, timeout: float = 30) -> dict:
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="GET" if body is None else "POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        raise ClusterError("cluster_node_refused", f"{url} answered {error.code}: {detail}") from None
    except OSError as error:
        raise ClusterError("cluster_node_unreachable", f"{url} is unreachable: {error}") from None


def _local_address_towards(host: str) -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((socket.gethostbyname(host), 9))
        return s.getsockname()[0]


def plan(config: dict, model_path: str) -> dict:
    """Ask every node for its capacity and versions, then split the layers by memory."""
    repo, revision = repo_and_revision(model_path)
    key = os.environ.get("MLX_VLM_SERVER_API_KEY")
    nodes = [n.rstrip("/") for n in config["nodes"]]
    from urllib.parse import urlparse
    for node in nodes:
        parsed = urlparse(node)
        # Plain http carries the token: only a literal Tailscale/loopback IP, never a name that DNS could re-point.
        if parsed.scheme != "https" and parsed.hostname != "localhost":
            require_trusted(parsed.hostname or "")
    statuses = [_request(f"{n}/v1/cluster/status", key) for n in nodes]
    mine = versions()
    for node, status in zip(nodes, statuses):
        if status.get("versions") != mine:
            raise ClusterError("cluster_version_mismatch", f"{node} runs a different Nativ cluster build ({status.get('versions')} vs {mine}).")
    weight_map, sizes = remote_tensor_sizes(repo, revision)
    per, shared = layer_bytes(sizes)
    capacities = [capacity_bytes()] + [int(s["capacity_bytes"]) for s in statuses]
    split = weighted_split(len(per), per, shared, capacities)
    node_hosts = [urlparse(n).hostname for n in nodes]
    addresses = [_local_address_towards(node_hosts[0])] + [socket.gethostbyname(h) for h in node_hosts]
    for address in addresses:
        require_trusted(address)
    return {"repo": repo, "revision": revision, "split": split, "hostfile": ring_hostfile(addresses), "nodes": nodes, "key": key}


def host_load(config: dict, model_path: str):
    """Join every node, connect the ring as rank 0 and load the host's layers."""
    mx = _mx()
    p = plan(config, model_path)
    for rank, node in enumerate(p["nodes"], start=1):
        _request(f"{node}/v1/cluster/join", p["key"], {"rank": rank, "size": len(p["split"]), "split": p["split"],
                 "hostfile": p["hostfile"], "repo": p["repo"], "revision": p["revision"], "versions": versions()})
    deadline = time.time() + CONNECT_TIMEOUT
    while True:
        states = [_request(f"{n}/v1/cluster/status", p["key"]).get("state") for n in p["nodes"]]
        if all(s == "connecting" for s in states):
            break
        if any(s == "failed" for s in states) or time.time() > deadline:
            raise ClusterError("cluster_node_failed", f"A node could not prepare its part of the model ({states}).")
        time.sleep(2)
    hostfile = Path(os.environ.get("TMPDIR", "/tmp")) / f"nativ-cluster-{os.getpid()}.json"
    hostfile.write_text(json.dumps(p["hostfile"]))
    os.environ["MLX_HOSTFILE"], os.environ["MLX_RANK"] = str(hostfile), "0"
    group = mx.distributed.init(backend="ring", strict=True)
    model, processor, inner = load_shard(p["repo"], p["revision"], p["split"], group)
    mirror_on_host(inner, group)
    return model, processor


# ---- node side -------------------------------------------------------------------

class NodeState:
    def __init__(self):
        self.process: subprocess.Popen | None = None
        self.lock = threading.Lock()
        self.status_file = Path(os.environ.get("TMPDIR", "/tmp")) / f"nativ-cluster-node-{os.getpid()}.state"

    def state(self) -> str:
        if self.process is None:
            return "idle"
        if self.process.poll() is not None:
            return "failed" if self.process.returncode else "idle"
        return self.status_file.read_text().strip() if self.status_file.exists() else "starting"

    def join(self, body: dict) -> None:
        if body.get("versions") != versions():
            raise ClusterError("cluster_version_mismatch", "The host runs a different Nativ cluster build.")
        for entry in body["hostfile"]:
            for endpoint in entry:
                require_trusted(endpoint.rsplit(":", 1)[0].strip("[]"))
        with self.lock:
            self.leave()
            hostfile = self.status_file.with_suffix(".hosts.json")
            hostfile.write_text(json.dumps(body["hostfile"]))
            env = dict(os.environ, MLX_HOSTFILE=str(hostfile), MLX_RANK=str(int(body["rank"])),
                       NATIV_CLUSTER_STATE_FILE=str(self.status_file),
                       NATIV_CLUSTER_WORKER=json.dumps({k: body[k] for k in ("repo", "revision", "split")}))
            self.status_file.write_text("downloading")
            self.process = subprocess.Popen([sys.executable, "-m", "nativ_cluster"], env=env)

    def leave(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None


def worker_main() -> None:
    """Node worker process: download this rank's files, connect the ring, then replay host calls."""
    mx = _mx()
    job = json.loads(os.environ["NATIV_CLUSTER_WORKER"])
    state_file = Path(os.environ["NATIV_CLUSTER_STATE_FILE"])
    rank = int(os.environ["MLX_RANK"])
    # The node's GPU belongs to this worker while it serves: local generation and Translate wait.
    from nativ_generation.resources import ComputeAdmission
    lease_path = os.environ.get("NATIV_COMPUTE_LEASE_PATH", "~/Library/Application Support/io.github.charafchnioune.nativ/compute-admission.lock")
    lease = ComputeAdmission(Path(lease_path).expanduser()).try_acquire("cluster-node")
    if lease is None:
        state_file.write_text("failed")
        raise SystemExit("compute_busy: this Mac is running another generation or Live Translate")
    weight_map, _ = remote_tensor_sizes(job["repo"], job["revision"])
    start, end = layer_range(job["split"], rank)
    from huggingface_hub import snapshot_download
    snapshot_download(job["repo"], revision=job["revision"],
                      allow_patterns=["*.json", "*.py", "*.txt", "*.model", "*.tiktoken", "*.jinja", "*.jsonl", *sorted(shard_files(weight_map, start, end))])
    state_file.write_text("connecting")
    group = mx.distributed.init(backend="ring", strict=True)
    model, _, inner = load_shard(job["repo"], job["revision"], job["split"], group)
    state_file.write_text("serving")
    Mirror(inner, group).serve(model)


def install(base, base_generation) -> None:
    """Add the node routes and, on a host, load configured models across the cluster."""
    from fastapi import HTTPException, Request
    globals()["Request"] = Request  # FastAPI resolves the string annotations against module globals
    require = getattr(base, "_require_management_api_key", None)
    node = NodeState()

    def authorize(request: Request) -> None:
        if os.environ.get(NODE_ENV) != "1":
            raise HTTPException(404, "This Nativ is not a cluster node.")
        if not os.environ.get("MLX_VLM_SERVER_API_KEY") or require is None:
            raise HTTPException(403, "A cluster node requires the server API key.")
        require(request)

    @base.app.get("/v1/cluster/status", include_in_schema=False)
    async def status(request: Request):
        authorize(request)
        return {"state": node.state(), "capacity_bytes": capacity_bytes(), "versions": versions()}

    @base.app.post("/v1/cluster/join", include_in_schema=False)
    async def join(request: Request):
        authorize(request)
        try:
            node.join(await request.json())
        except ClusterError as error:
            raise HTTPException(409, f"{error.code}: {error}") from None
        return {"state": node.state()}

    @base.app.post("/v1/cluster/leave", include_in_schema=False)
    async def leave(request: Request):
        authorize(request)
        node.leave()
        return {"state": node.state()}

    raw = os.environ.get(CONFIG_ENV)
    if not raw:
        return
    config = json.loads(raw)
    original_load = base_generation.load

    def load(model_path, *args, **kwargs):
        if not config.get("nodes"):
            return original_load(model_path, *args, **kwargs)
        return host_load(config, str(model_path))

    base_generation.load = load


if __name__ == "__main__":
    worker_main()
