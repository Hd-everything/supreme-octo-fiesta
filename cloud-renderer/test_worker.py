import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-only-not-a-secret")

import worker


def read_worker_source():
    return Path(worker.__file__).read_text(encoding="utf-8")


class ESPCNGuardTests(unittest.TestCase):
    def test_espcn_accepts_short_480p_video(self):
        from espcn import validate_espcn_source
        validate_espcn_source(854, 480, 24, 8.0)
        validate_espcn_source(480, 854, 24, 8.0)

    def test_espcn_rejects_hd_sources_and_clips_over_three_minutes(self):
        from espcn import validate_espcn_source
        with self.assertRaisesRegex(ValueError, "espcn_source_must_be_480p_or_lower"):
            validate_espcn_source(1280, 720, 24, 5.0)
        validate_espcn_source(640, 360, 24, 180.0)
        with self.assertRaisesRegex(ValueError, "espcn_clip_limit_180_seconds"):
            validate_espcn_source(640, 360, 24, 180.1)

    def test_espcn_rejects_high_frame_rate(self):
        from espcn import validate_espcn_source
        with self.assertRaisesRegex(ValueError, "espcn_frame_rate_limit_24fps"):
            validate_espcn_source(640, 360, 30, 5.0)


class AiEnhancementRoutingTests(unittest.TestCase):
    def test_every_advertised_model_has_a_worker_route(self):
        self.assertEqual(
            set(worker.SUPPORTED_AI_MODELS),
            {"espcn", "edsr", "swinir", "realesrgan", "basicvsr", "vrt"},
        )
        for model in worker.SUPPORTED_AI_MODELS:
            with self.subTest(model=model):
                mode, selected = worker.resolve_ai_selection(
                    {"enhancementMode": "ai", "aiModel": model},
                    [{"mediaType": "video"}], "1440p",
                )
                self.assertEqual((mode, selected), ("ai", model))
                if model != "espcn":
                    requirements = Path(worker.__file__).with_name(worker.AI_REQUIREMENTS_BY_MODEL[model])
                    self.assertTrue(requirements.is_file())

    def test_legacy_espcn_flag_remains_compatible(self):
        self.assertEqual(
            worker.resolve_ai_selection(
                {"aiEnhancement": True}, [{"mediaType": "video"}], "1440p"
            ),
            ("ai", "espcn"),
        )

    def test_ai_processed_clip_is_appended_as_an_input_without_corrupting_loglevel(self):
        args = ["ffmpeg", "-loglevel", "error"]
        worker.append_clip_input(args, Path("enhanced.mp4"), 0.0, 2.0, False)
        self.assertEqual(args[args.index("-loglevel") + 1], "error")
        self.assertEqual(args[-1], "enhanced.mp4")
        self.assertEqual(args.count("-i"), 1)

    def test_ai_resolution_and_clip_limits_are_enforced(self):
        with self.assertRaisesRegex(ValueError, "ai_only_supports_1440p"):
            worker.resolve_ai_selection(
                {"enhancementMode": "ai", "aiModel": "swinir"},
                [{"mediaType": "video"}], "1080p",
            )
        with self.assertRaisesRegex(ValueError, "ai_requires_single_video_clip"):
            worker.resolve_ai_selection(
                {"enhancementMode": "both", "aiModel": "vrt"},
                [{"mediaType": "video"}, {"mediaType": "video"}], "2160p",
            )


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


class CompletedSourceCleanupTests(unittest.TestCase):
    def test_sources_are_removed_from_primary_bucket_and_cleared_after_success(self):
        job = {"id": "job-123", "source_object_paths": ["owner/source-a", "owner/source-b", "owner/source-a"]}
        with patch.object(worker.urllib.request, "urlopen") as urlopen, \
             patch.object(worker, "update_job") as update:
            self.assertTrue(worker.cleanup_source_objects(job))

        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, worker.SUPABASE_URL + "/storage/v1/object/" + worker.BUCKET)
        self.assertEqual(request.get_method(), "DELETE")
        self.assertEqual(json.loads(request.data), {"prefixes": ["owner/source-a", "owner/source-b"]})
        update.assert_called_once_with("job-123", source_object_paths=[])

    def test_cleanup_failure_does_not_clear_source_paths_or_raise(self):
        job = {"id": "job-123", "source_object_paths": ["owner/source-a"]}
        with patch.object(worker.urllib.request, "urlopen", side_effect=OSError("storage unavailable")), \
             patch.object(worker, "update_job") as update:
            self.assertFalse(worker.cleanup_source_objects(job))
        update.assert_not_called()


class CloudEditingFeatureTests(unittest.TestCase):
    def test_speed_curve_maps_segments_and_duration(self):
        segments = worker.clip_speed_segments({
            "speed": 1,
            "speedCurve": [{"timeMs": 2000, "speed": 2}],
        }, 5000)
        self.assertEqual(segments, [(0, 2, 1.0), (2, 5, 2.0)])
        self.assertEqual(worker.speed_curve_duration(segments), 3.5)
        self.assertIn("setpts=", worker.speed_curve_setpts(segments))
        with self.assertRaisesRegex(ValueError, "invalid_speed_curve_order"):
            worker.clip_speed_segments({"speedCurve": [{"timeMs": 1000, "speed": 1}, {"timeMs": 1000, "speed": 2}]}, 5000)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is installed in the worker workflow")
    def test_speed_curve_filter_executes_on_real_ffmpeg(self):
        expression = worker.speed_curve_setpts([(0, .2, 1.0), (.2, .4, 2.0)])
        result = subprocess.run([
            "ffmpeg", "-hide_banner", "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=size=320x180:rate=30:duration=0.4", "-vf", expression,
            "-f", "null", "-",
        ], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is installed in the worker workflow")
    def test_chroma_mask_and_transform_filter_chain_executes(self):
        graph = (
            "scale=320:180,format=rgba,colorkey=0x00FF00:0.25:0.08,"
            "rotate=a='(t*30)*PI/180':ow=iw:oh=ih:c=black@0,"
            "pad=iw*4:ih*4:iw*3/2:ih*3/2:color=black@0,"
            "zoompan=z='4.8':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=320x180:fps=30,"
            "format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*0.8',"
            "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
            "a='alpha(X,Y)*if(lte(pow((X-W/2)/(min(W,H)/2),2)+pow((Y-H/2)/(min(W,H)/2),2),1),255,0)/255'"
        )
        result = subprocess.run([
            "ffmpeg", "-hide_banner", "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=size=320x180:rate=30:duration=0.2", "-vf", graph,
            "-f", "null", "-",
        ], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)

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


class OutputChunkTests(unittest.TestCase):
    def test_small_output_stays_a_single_compatible_mp4_object(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "render.mp4"
            source.write_bytes(b"mp4-data")
            uploads = []
            with patch.object(worker, "OUTPUT_PART_BYTES", 16), \
                 patch.object(worker, "storage_upload", side_effect=lambda path, object_path, job: uploads.append((path.read_bytes(), object_path))), \
                 patch.object(worker, "api", return_value=[{"status": "finalizing"}]), \
                 patch.object(worker, "update_job"):
                output_path, metadata = worker.upload_output_parts(
                    source,
                    {"id": "job-123", "owner_id": "owner-123"},
                    {"width": 720},
                    Path(directory),
                )

        self.assertEqual(uploads, [(b"mp4-data", "owner-123/exports/job-123.mp4")])
        self.assertEqual(output_path, uploads[0][1])
        self.assertNotIn("chunks", metadata)
        self.assertEqual(metadata["bytes"], len(b"mp4-data"))

    def test_output_is_uploaded_as_ordered_parts_that_reassemble_byte_for_byte(self):
        original = bytes(range(19))
        job = {"id": "job-123", "owner_id": "owner-123"}
        uploaded = []
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "render.mp4"
            source.write_bytes(original)

            def capture_part(path, object_path, job):
                uploaded.append((object_path, path.read_bytes()))

            with patch.object(worker, "OUTPUT_PART_BYTES", 7), \
                 patch.object(worker, "MAX_OUTPUT_BYTES", 100), \
                 patch.object(worker, "storage_upload", side_effect=capture_part), \
                 patch.object(worker, "api", return_value=[{"status": "finalizing"}]), \
                 patch.object(worker, "update_job"):
                first_path, metadata = worker.upload_output_parts(source, job, {"width": 1280}, Path(directory))

        self.assertEqual([chunk for _, chunk in uploaded], [original[:7], original[7:14], original[14:]])
        self.assertEqual(b"".join(chunk for _, chunk in uploaded), original)
        self.assertEqual(first_path, uploaded[0][0])
        self.assertEqual([item["path"] for item in metadata["chunks"]], [path for path, _ in uploaded])
        self.assertEqual(metadata["bytes"], len(original))
        self.assertTrue(metadata["chunked"])

    def test_output_larger_than_free_storage_guard_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "render.mp4"
            source.write_bytes(b"12345")
            with patch.object(worker, "MAX_OUTPUT_BYTES", 4):
                with self.assertRaisesRegex(ValueError, "output_exceeds_free_storage_limit"):
                    worker.upload_output_parts(source, {"id": "id", "owner_id": "owner"}, {}, Path(directory))

    def test_failed_part_upload_removes_already_uploaded_parts(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "render.mp4"
            source.write_bytes(bytes(range(12)))
            uploaded = []

            def fail_on_second_part(path, object_path, job):
                if len(uploaded) == 1:
                    raise RuntimeError("simulated_upload_failure")
                uploaded.append(object_path)

            with patch.object(worker, "OUTPUT_PART_BYTES", 4), \
                 patch.object(worker, "MAX_OUTPUT_BYTES", 100), \
                 patch.object(worker, "storage_upload", side_effect=fail_on_second_part), \
                 patch.object(worker, "api", return_value=[{"status": "finalizing"}]), \
                 patch.object(worker, "storage_remove") as remove, \
                 patch.object(worker, "update_job") as update:
                with self.assertRaisesRegex(RuntimeError, "simulated_upload_failure"):
                    worker.upload_output_parts(
                        source,
                        {"id": "job-123", "owner_id": "owner-123"},
                        {},
                        Path(directory),
                    )

        remove.assert_called_once_with(
            [uploaded[0], "owner-123/exports/job-123.part001"],
            {"id": "job-123", "owner_id": "owner-123"},
        )
        self.assertEqual(update.call_args.args[0], "job-123")
        self.assertEqual(update.call_args.kwargs["output_path"], None)

    def test_cancellation_during_part_upload_cleans_uploaded_parts(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "render.mp4"
            source.write_bytes(bytes(range(12)))
            uploaded = []
            with patch.object(worker, "OUTPUT_PART_BYTES", 4), \
                 patch.object(worker, "MAX_OUTPUT_BYTES", 100), \
                 patch.object(worker, "storage_upload", side_effect=lambda path, object_path, job: uploaded.append(object_path)), \
                 patch.object(worker, "api", side_effect=[
                     [{"status": "finalizing"}],
                     [{"status": "cancel_requested"}],
                 ]), \
                 patch.object(worker, "storage_remove") as remove, \
                 patch.object(worker, "update_job"):
                with self.assertRaisesRegex(InterruptedError, "cancelled"):
                    worker.upload_output_parts(
                        source,
                        {"id": "job-123", "owner_id": "owner-123"},
                        {},
                        Path(directory),
                    )

        remove.assert_called_once_with([uploaded[0]], {"id": "job-123", "owner_id": "owner-123"})


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
