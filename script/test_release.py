"""Offline checks for release metadata and staging guards."""

import json
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from script import release


class ReleaseHelpersTests(unittest.TestCase):
    def test_missing_tag_endpoint_finds_existing_authenticated_draft(self) -> None:
        from subprocess import CompletedProcess
        draft = {"tag_name": "v0.1.1", "draft": True, "id": 123}
        responses = [CompletedProcess([], 1, "", "HTTP 404"),
                     CompletedProcess([], 0, json.dumps([draft]), "")]
        with patch.object(release, "command", side_effect=responses):
            self.assertEqual(release.gh_api("releases/tags/v0.1.1"), draft)


    def test_github_missing_tag_commit_422_is_distinct_from_other_failures(self) -> None:
        with patch.object(release, "command") as run:
            run.return_value.returncode = 1
            run.return_value.stdout = ""
            run.return_value.stderr = "gh: No commit found for SHA: v0.1.1 (HTTP 422)"
            self.assertIsNone(release.gh_api("commits/v0.1.1"))
            run.return_value.stderr = "gh: Validation failed (HTTP 422)"
            with self.assertRaises(release.ReleaseError):
                release.gh_api("commits/v0.1.1")

    def test_publishing_cannot_move_latest_backwards(self) -> None:
        with patch.object(release, "gh_api", return_value={"tag_name": "v0.1.2"}):
            with self.assertRaises(release.ReleaseError):
                release.require_forward_release("0.1.1")
            release.require_forward_release("0.1.2")
            release.require_forward_release("0.1.3")

    def test_draft_can_target_an_exact_commit_before_its_tag_exists(self) -> None:
        sha = "a" * 40
        draft = {"draft": True, "target_commitish": sha}
        with patch.object(release, "gh_api", side_effect=[draft, None]):
            self.assertEqual(release.remote_release_state("0.1.1", sha), draft)
        with patch.object(release, "gh_api", side_effect=[{"draft": True, "target_commitish": "main"}, None]):
            with self.assertRaises(release.ReleaseError):
                release.remote_release_state("0.1.1", sha)

    def test_signs_nested_sparkle_components_before_the_host_app(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Lean Term.app"
            version = bundle / "Contents/Frameworks/Sparkle.framework/Versions/Current"
            for name in ("XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Autoupdate", "Updater.app"):
                (version / name).mkdir(parents=True)
            with patch.object(release, "command") as command:
                release.sign_app(bundle, "identity")
            calls = [call.args[0] for call in command.call_args_list]
            self.assertEqual(len(calls), 6)
            self.assertEqual(calls[-1][-1], str(bundle))
            self.assertTrue(all("--deep" not in args for args in calls))
            self.assertTrue(all("--preserve-metadata=identifier,entitlements" in args for args in calls[:-1]))

    def test_legacy_process_query_failure_refuses_replacement(self) -> None:
        with patch.object(release, "command") as command:
            command.return_value.returncode = 3
            with self.assertRaises(release.ReleaseError):
                release.process_running_without_lock()

    def test_versioned_asset_urls_use_the_renamed_repository(self) -> None:
        self.assertEqual(
            release.versioned_download_url("0.1.1"),
            "https://github.com/mattivilola/lean-term/releases/download/v0.1.1/Lean-Term-macos-arm64.zip",
        )
        self.assertEqual(
            release.appcast_download_url("0.1.1"),
            "https://github.com/mattivilola/lean-term/releases/download/v0.1.1/appcast.xml",
        )

    def test_appcast_requires_versioned_url_signature_and_exact_archive_size(self) -> None:
        xml = f'''<?xml version="1.0"?>
        <rss xmlns:sparkle="{release.SPARKLE_NS}"><channel><item>
          <enclosure url="{release.versioned_download_url('0.1.1')}"
            length="1234" type="application/octet-stream"
            sparkle:version="0.1.1" sparkle:edSignature="signature" />
        </item></channel></rss>'''
        with tempfile.TemporaryDirectory() as directory:
            appcast = Path(directory) / "appcast.xml"
            appcast.write_text(xml, encoding="utf-8")
            release.validate_appcast(appcast, "0.1.1", 1234)
            with self.assertRaises(release.ReleaseError):
                release.validate_appcast(appcast, "0.1.1", 1235)

    def test_appcast_rejects_stable_or_wrong_version_asset_urls(self) -> None:
        xml = f'''<rss xmlns:sparkle="{release.SPARKLE_NS}"><channel><item>
          <enclosure url="{release.FEED_URL}" length="1234" sparkle:version="0.1.1"
            sparkle:edSignature="signature" />
        </item></channel></rss>'''
        with tempfile.TemporaryDirectory() as directory:
            appcast = Path(directory) / "appcast.xml"
            appcast.write_text(xml, encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.validate_appcast(appcast, "0.1.1", 1234)

    def test_app_metadata_checks_identifier_and_both_version_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Lean Term.app"
            executable = app / "Contents/MacOS/LeanTerm"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"test executable")
            info = {
                "CFBundleIdentifier": release.APP_ID,
                "CFBundleExecutable": "LeanTerm",
                "CFBundleShortVersionString": "0.1.1",
                "CFBundleVersion": "0.1.1",
            }
            with (app / "Contents/Info.plist").open("wb") as target:
                plistlib.dump(info, target)
            release.check_app_metadata(app, "0.1.1", release_build=False)
            info["CFBundleVersion"] = "0.1.0"
            with (app / "Contents/Info.plist").open("wb") as target:
                plistlib.dump(info, target)
            with self.assertRaises(release.ReleaseError):
                release.check_app_metadata(app, "0.1.1", release_build=False)

    def test_staging_state_is_bound_to_repository_version_and_source_sha(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            state = release.load_state(stage, "0.1.1", "a" * 40)
            release.save_state(stage, state)
            self.assertEqual(json.loads((stage / "release-state.json").read_text())["source_sha"], "a" * 40)
            with self.assertRaises(release.ReleaseError):
                release.load_state(stage, "0.1.1", "b" * 40)

    def test_prepared_app_source_revision_must_match_head(self) -> None:
        source_sha = "a" * 40
        release.validate_source_revision({"LeanTermSourceRevision": source_sha}, source_sha)
        with self.assertRaises(release.ReleaseError):
            release.validate_source_revision({"LeanTermSourceRevision": "b" * 40}, source_sha)

    def test_prepared_mode_rejects_existing_staging_without_deleting_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory) / "v0.1.1"
            stage.mkdir()
            receipt = stage / "notary-submit.json"
            receipt.write_text("preserve", encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.require_empty_prepared_stage(stage)
            self.assertEqual(receipt.read_text(encoding="utf-8"), "preserve")

    def test_sha256_is_streamed_and_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact"
            path.write_bytes(b"lean term release")
            self.assertEqual(
                release.digest(path),
                "68b6eeb9bc95bbb537d59adba24713a34b3306c1d0132377d4847baa075ea719",
            )


if __name__ == "__main__":
    unittest.main()
