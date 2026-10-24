import os
import shutil
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

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


class DispatchedJobClaimTests(unittest.TestCase):
    def test_worker_claims_the_dispatched_job_instead_of_an_older_queued_job(self):
        job_id = "12345678-1234-5678-1234-567812345678"
        with patch.object(worker, "api") as api:
            api.side_effect = [
                [{"id": job_id, "status": "queued", "attempts": 0, "started_at": None}],
                [{"id": job_id, "status": "processing", "attempts": 1}],
            ]
            claimed = worker.claim_render_job(job_id)

        self.assertEqual(claimed["id"], job_id)
        self.assertIn(f"id=eq.{job_id}", api.call_args_list[1].args[0])
        self.assertIn("status=eq.queued", api.call_args_list[1].args[0])
        self.assertEqual(api.call_args_list[1].args[1], "PATCH")
        self.assertEqual(api.call_count, 2)

    def test_worker_does_not_claim_an_unrelated_job_when_dispatched_job_is_missing(self):
        with patch.object(worker, "api", return_value=[]) as api:
            self.assertIsNone(worker.claim_render_job("12345678-1234-5678-1234-567812345678"))
        self.assertEqual(api.call_count, 1)


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

    def test_each_editor_effect_has_a_worker_filter_mapping(self):
        effects = (
            "none", "flash", "shake", "blur", "glitch", "phonk", "grayscale",
            "negative", "cinematic", "moody", "vivid", "dramatic", "vintage",
            "fade", "night", "sunset", "noir", "soft", "dreamy",
        )
        for effect in effects:
            with self.subTest(effect=effect):
                worker.visual_effect_filters(effect, 320, 180)
        with self.assertRaisesRegex(ValueError, "unsupported_effect"):
            worker.visual_effect_filters("not-an-editor-effect", 320, 180)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is installed in the worker workflow")
    def test_each_editor_effect_executes_on_a_real_ffmpeg_filter_graph(self):
        effects = (
            "none", "flash", "shake", "blur", "glitch", "phonk", "grayscale",
            "negative", "cinematic", "moody", "vivid", "dramatic", "vintage",
            "fade", "night", "sunset", "noir", "soft", "dreamy",
        )
        for effect in effects:
            with self.subTest(effect=effect):
                filters = worker.visual_effect_filters(effect, 320, 180)
                command = [
                    "ffmpeg", "-hide_banner", "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=320x180:rate=30:duration=0.2",
                ]
                if filters:
                    command += ["-vf", ",".join(filters)]
                command += ["-frames:v", "4", "-f", "null", "-"]
                result = subprocess.run(command, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)


class FFmpegDiagnosticTests(unittest.TestCase):
    def test_diagnostic_redacts_credentials_urls_and_work_directory(self):
        work = Path("/tmp/vyntra-render-test")
        diagnostic = worker.safe_ffmpeg_diagnostic(
            "[Parsed_scale_0] Failed at /tmp/vyntra-render-test/clip_0.media "
            "Authorization: Bearer abc123 https://example.test/signed?token=secret\n"
            "Conversion failed!",
            work,
        )
        self.assertIn("Failed", diagnostic)
        self.assertIn("[render-workdir]", diagnostic)
        self.assertIn("[redacted]", diagnostic)
        self.assertIn("[url-redacted]", diagnostic)
        self.assertNotIn("abc123", diagnostic)
        self.assertNotIn("token=secret", diagnostic)
        self.assertNotIn("Conversion failed!", diagnostic)

    def test_database_error_summary_respects_existing_column_limit(self):
        code = worker.ffmpeg_error_code("filter error: " + "x" * 400)
        self.assertTrue(code.startswith("ffmpeg_failed:"))
        self.assertLessEqual(len(code), 100)


class OutputDimensionsTests(unittest.TestCase):
    def test_free_sd_and_hd_resolutions(self):
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "480p"), (854, 480))
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "540p"), (960, 540))
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "720p"), (1280, 720))

    def test_ad_supported_2k_and_3k_output_resolutions(self):
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "1440p"), (2560, 1440))
        self.assertEqual(worker.output_dimensions(1920, 1080, 0, "16:9", "1620p"), (2880, 1620))

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
