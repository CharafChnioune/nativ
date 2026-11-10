import importlib.util
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay/nativ_cluster.py"
spec = importlib.util.spec_from_file_location("nativ_cluster", MODULE)
cluster = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cluster)
GB = 1 << 30


class ClusterPlanningTests(unittest.TestCase):
    def test_only_language_layers_are_split(self):
        self.assertEqual(cluster.layer_of("language_model.model.layers.12.mlp.weight"), 12)
        self.assertIsNone(cluster.layer_of("vision_tower.encoder.layers.3.attn.weight"))
        self.assertIsNone(cluster.layer_of("model.embed_tokens.weight"))
        per, shared = cluster.layer_bytes({"model.layers.0.w": 5, "model.layers.0.b": 1, "lm_head.weight": 7})
        self.assertEqual((per, shared), ({0: 6}, 7))

    def test_split_follows_memory_and_covers_every_layer_once(self):
        per = {i: GB // 2 for i in range(64)}
        split = cluster.weighted_split(64, per, 2 * GB, [120 * GB, 12 * GB])
        self.assertEqual(sum(split), 64)
        self.assertGreater(split[0], split[1] * 4)
        ranges = sorted(cluster.layer_range(split, r) for r in range(2))
        self.assertEqual(ranges[0][0], 0); self.assertEqual(ranges[0][1], ranges[1][0]); self.assertEqual(ranges[1][1], 64)
        # Rank 0 (the host) runs the last layers.
        self.assertEqual(cluster.layer_range(split, 0)[1], 64)

    def test_odd_layer_count_keeps_every_layer(self):
        # mlx-vlm 0.7.12's own pipeline() drops layer 23 for 47 layers on 2 equal ranks.
        split = cluster.weighted_split(47, {i: 1 for i in range(47)}, 0, [100, 100])
        self.assertEqual(sorted(split), [23, 24])
        self.assertEqual(sorted(cluster.layer_range(split, r) for r in range(2)), [(0, split[1]), (split[1], 47)])

    def test_every_rank_gets_at_least_one_layer_and_overflow_is_refused(self):
        split = cluster.weighted_split(4, {i: 1 for i in range(4)}, 0, [1000, 1, 1])
        self.assertTrue(all(count >= 1 for count in split)); self.assertEqual(sum(split), 4)
        with self.assertRaises(cluster.ClusterError):
            cluster.weighted_split(10, {i: GB for i in range(10)}, 0, [3 * GB, 3 * GB])
        with self.assertRaises(cluster.ClusterError):
            cluster.weighted_split(10, {i: 1 for i in range(10)}, 5 * GB, [4 * GB, 64 * GB])

    def test_shard_files_keep_shared_weights(self):
        weight_map = {"model.embed_tokens.weight": "a", "model.layers.0.w": "a", "model.layers.5.w": "b",
                      "model.layers.9.w": "c", "lm_head.weight": "d"}
        self.assertEqual(cluster.shard_files(weight_map, 0, 6), {"a", "b", "d"})
        self.assertEqual(cluster.shard_files(weight_map, 6, 10), {"a", "c", "d"})

    def test_control_messages_round_trip_and_are_bounded(self):
        message = {"op": "forward", "arrays": {"x": [[1, 8], "int32"]}, "cache": None}
        encoded = cluster.encode(message)
        self.assertEqual(len(encoded), cluster.HEADER_BYTES)
        self.assertEqual(cluster.decode(encoded), message)
        with self.assertRaises(cluster.ClusterError):
            cluster.encode({"x": "y" * cluster.HEADER_BYTES})

    def test_only_tailscale_or_loopback_carries_the_ring_and_token(self):
        for address in ("100.81.146.84", "100.64.0.1", "127.0.0.1", "fd7a:115c:a1e0::1"):
            self.assertTrue(cluster.trusted_address(address), address)
        for address in ("192.168.178.96", "10.0.0.2", "8.8.8.8", "100.128.0.1", "nonsense"):
            self.assertFalse(cluster.trusted_address(address), address)
        with self.assertRaises(cluster.ClusterError):
            cluster.require_trusted("192.168.178.96")

    def test_ring_hostfile_and_hub_models(self):
        self.assertEqual(cluster.ring_hostfile(["100.99.9.11", "100.81.146.84"]),
                         [["100.99.9.11:32400"], ["100.81.146.84:32401"]])
        rev = "a" * 40
        self.assertEqual(cluster.repo_and_revision(f"/x/hub/models--mlx-community--GLM-4.7-Flash-4bit/snapshots/{rev}/"),
                         ("mlx-community/GLM-4.7-Flash-4bit", rev))
        self.assertEqual(cluster.repo_and_revision("mlx-community/GLM-4.7-Flash-4bit"), ("mlx-community/GLM-4.7-Flash-4bit", None))
        with self.assertRaises(cluster.ClusterError):
            cluster.repo_and_revision("/Users/me/converted-model")


if __name__ == "__main__":
    unittest.main()
