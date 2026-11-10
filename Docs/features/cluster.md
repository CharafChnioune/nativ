# Cluster: one chat model across several Macs

Nativ can split a chat model's layers across several Macs that each run Nativ, so a model can use their combined memory. The Macs talk over plain TCP inside your tailnet, so Thunderbolt is not required. Cluster traffic (the API token and the MLX ring) is unencrypted by itself, so Nativ only allows Tailscale addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) or loopback. Over plain http the node address must be such a literal IP; hostnames such as `*.ts.net` need https. A plain LAN address is refused with `cluster_untrusted_network`.

The host Mac keeps serving the normal APIs (Chat, Responses, Chat Completions, tools). Each decoder step on the host is mirrored to the nodes, which run their own layers in lockstep (MLX ring backend, pipeline parallel). Tokens are only sampled on the host.

## When it helps

Splitting buys memory, not speed. Every token crosses the network once per node, so a split model generates more slowly than the same model on one Mac. Use the cluster for models that do not fit on the host alone.

Measured on 2026-11-10 (M3 Max 128 GB host, MacBook Air M5 16 GB node, Tailscale direct path, 25 ms round trip):

| Model | One Mac | Host + Air over Tailscale |
|---|---|---|
| GLM-4.7-Flash 4-bit (mlx-vlm, this feature) | ~75 tok/s | 12.5–14.3 tok/s, output token-identical to one Mac |
| Qwen3.8-27B 8-bit (mlx-lm probe, 52+12 layers) | 12.85 tok/s | 6.72 tok/s |

When the Air was stopped mid-generation, the request failed within a second with `cluster_node_lost`. The host stayed up, and loading the model again reconnects the nodes.

## Setup

Every Mac needs the same Nativ build: the node checks the protocol, MLX and mlx-vlm versions. Every Mac also needs the same server API token.

1. **On every Mac:** Developer → Server API token: set the same token everywhere.
2. **On each node (for example the Air):**
   - Developer → Host: `0.0.0.0` or the Mac's Tailscale address (for example `100.81.146.84`).
   - Developer → Cluster: turn on *Accept model layers from other Macs*.
   - The server restarts and answers `GET /v1/cluster/status`.
3. **On the host:**
   - Developer → Cluster: add each node as `http://<tailscale-address>:<port>`. The panel shows each node's state and free memory.
   - Then choose the chat model as usual. It loads split by free memory: the host takes the most layers, and every Mac also holds the embeddings and output head.

Nodes download only the safetensors files that contain their layers, directly from Hugging Face. The model must therefore come from the Hub, and each node needs internet access on the first load.

## Limits

- **Model families:** only those with pipeline support in the bundled mlx-vlm 0.7.12. That includes DeepSeek V2/V3/V3.2/V4, GLM4-MoE (including GLM-4.7-Flash), GLM-MoE-DSA, Kimi K2.5, Ministral 3 (text), Muse Spark and Xing4. Qwen, Gemma, Llama and the Mistral 3 vision models are not supported yet; loading one fails with `cluster_model_unsupported`.
- **One request at a time:** the host runs with `--max-num-seqs 1`, without prefix caching, KV quantization or draft models. Nodes can only replay that cache lifecycle, and every replayed call checks that the cache offsets agree (`cluster_desync` otherwise).
- **Node GPU:** while a node serves, it holds its Mac's compute lease, so local generation and Live Translate on that Mac wait.
- **Lost node:** if a node drops out, requests fail with `cluster_node_lost`. Load the model again to reconnect the remaining Macs; there is no silent fallback to one Mac.

## Security

- The node routes (`/v1/cluster/status`, `/join`, `/leave`) need cluster node mode and the server API token.
- The ring connections (ports 32400 and up) have no authentication of their own. Tailscale authenticates and encrypts them, which is why only tailnet and loopback addresses are accepted. Nodes also refuse arrays with an unknown dtype or more than 2^28 elements.
- Binding the server to `0.0.0.0` also exposes it to the local network, protected by the token.

## Implementation

- `PythonDistribution/Overlay/nativ_cluster.py`: planning (memory-weighted split, shard file selection), node routes, the worker process, and the host-side decoder mirror. Unit tests are in `scripts/tests/test_cluster_planning.py`.
- `Sources/Nativ/NativSettings.swift`: `clusterNodeEnabled` and `clusterNodeURLs`, and cluster mode in the launch arguments, environment and runtime settings.
- `Sources/Nativ/Features/Developer/ClusterPanel.swift`: the Developer card.
