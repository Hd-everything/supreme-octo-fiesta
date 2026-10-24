import os
import unittest
from pathlib import Path

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-only-not-a-secret")

import worker


def read_worker_source():
    return Path(worker.__file__).read_text(encoding="utf-8")


class RenderLimitsTests(unittest.TestCase):
    def test_status_hd_defaults_to_three_minutes_and_fifty_mib(self):
        self.assertEqual(worker.MAX_DURATION, 180)
        self.assertEqual(worker.MAX_INPUT_BYTES, 50 * 1024 * 1024)

    def test_oneshot_is_off_by_default(self):
        self.assertFalse(worker.ONESHOT)


class CloudEditingFeatureTests(unittest.TestCase):
    def test_transition_filter_graph_uses_real_xfade_and_audio_crossfade(self):
        source = read_worker_source()
        self.assertIn("xfade=transition=", source)
        self.assertIn("acrossfade=d=", source)

    def test_freeze_frame_and_audio_fades_are_rendered(self):
        source = read_worker_source()
        self.assertIn("tpad=stop_mode=clone", source)
        self.assertIn("afade=t=in", source)
        self.assertIn("afade=t=out", source)

    def test_animated_keyframes_are_interpolated_for_picture_and_audio(self):
        source = read_worker_source()
        self.assertIn("keyframe_expr(1, brightness)", source)
        self.assertIn("keyframe_expr(4, volume)", source)
        self.assertIn("eq=eval=frame", source)
        self.assertIn("volume=", source)

    def test_audio_cleanup_filters_are_available(self):
        source = read_worker_source()
        self.assertIn("afftdn=nf=-25", source)
        self.assertIn("acompressor=threshold=0.125", source)
        self.assertIn("loudnorm=I=-16", source)
        self.assertIn("highpass=f=", source)


class OutputDimensionsTests(unittest.TestCase):
    def test_landscape_4k_is_exact_uhd(self):
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "2160p"), (3840, 2160))

    def test_portrait_4k_preserves_portrait_ratio(self):
        self.assertEqual(worker.output_dimensions(1080, 1920, 0, "9:16", "2160p"), (2160, 3840))

    def test_landscape_5k_is_exact_uhd_plus(self):
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "2880p"), (5120, 2880))

    def test_landscape_6k_dimensions(self):
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "3456p"), (6144, 3456))

    def test_original_four_three_ratio_is_preserved(self):
        self.assertEqual(worker.output_dimensions(1440, 1080, 0, "Original", "2160p"), (2880, 2160))

    def test_rotation_changes_original_orientation(self):
        self.assertEqual(worker.output_dimensions(1920, 1080, 90, "Original", "2160p"), (2160, 3840))

    def test_square_ratio(self):
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "1:1", "1080p"), (1080, 1080))

    def test_portrait_three_four_ratio(self):
        self.assertEqual(worker.output_dimensions(1080, 1440, 0, "3:4", "1080p"), (1080, 1440))

    def test_landscape_twenty_one_nine_ratio(self):
        self.assertEqual(worker.output_dimensions(2520, 1080, 0, "21:9", "1080p"), (2520, 1080))

    def test_unknown_resolution_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unsupported_resolution"):
            worker.output_dimensions(1920, 1080, 0, "16:9", "8k")

    def test_invalid_ratio_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "invalid_aspect_ratio"):
            worker.output_dimensions(1920, 1080, 0, "2:1", "1080p")


if __name__ == "__main__":
    unittest.main()
