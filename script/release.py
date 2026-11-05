#!/usr/bin/env python3
"""Build, notarize, stage, publish, and install Lean Term releases."""

from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Iterator


ROOT = Path(__file__).resolve().parents[1]
REPO = "mattivilola/lean-term"
APP_NAME = "Lean Term"
APP_ID = "com.mattivilola.leanterm"
PRODUCT = "LeanTerm"
APP_ARCHIVE_NAME = "Lean-Term-macos-arm64.zip"
VERSION_PATTERN = re.compile(r"\d+\.\d+\.\d+\Z")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DEFAULT_IDENTITY = "Developer ID Application: Matti Vilola (MM233FKU38)"
DEFAULT_NOTARY_PROFILE = "lean-vs-code"
DEFAULT_SPARKLE_ACCOUNT = "LeanTerm"
PUBLIC_KEY_FILE = ROOT / "release/sparkle-public-key.txt"
SPARKLE_BIN = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
FEED_URL = f"https://github.com/{REPO}/releases/latest/download/appcast.xml"
ASSET_BASE_URL = f"https://github.com/{REPO}/releases/download"
INSTALL_PATH = Path("/Applications/Lean Term.app")


class ReleaseError(RuntimeError):
    pass


def command(
    args: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            args,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            check=False,
        )
    except FileNotFoundError as error:
        raise ReleaseError(f"Required command was not found: {args[0]}") from error
    if check and result.returncode:
        detail = (result.stderr or result.stdout or "").strip()
        if len(detail) > 1800:
            detail = detail[-1800:]
        message = f"{Path(args[0]).name} exited with status {result.returncode}"
        if detail:
            message += f": {detail}"
        raise ReleaseError(message)
    return result


def current_version() -> str:
    path = ROOT / "VERSION"
    if not path.is_file():
        raise ReleaseError("VERSION is missing")
    value = path.read_text(encoding="utf-8").strip()
    if not VERSION_PATTERN.fullmatch(value):
        raise ReleaseError("VERSION must be a three-part numeric version such as 0.1.1")
    return value


def check_version(value: str) -> str:
    expected = current_version()
    if value != expected:
        raise ReleaseError(f"Requested version {value} does not match VERSION ({expected})")
    return value


def versioned_download_url(version: str) -> str:
    return f"{ASSET_BASE_URL}/v{version}/{APP_ARCHIVE_NAME}"


def appcast_download_url(version: str) -> str:
    return f"{ASSET_BASE_URL}/v{version}/appcast.xml"


def stage_path(version: str) -> Path:
    return ROOT / "dist" / "releases" / f"v{version}"


def app_path(stage: Path) -> Path:
    return stage / f"{APP_NAME}.app"


def validate_source_revision(info: dict[str, Any], source_sha: str) -> None:
    if info.get("LeanTermSourceRevision") != source_sha:
        raise ReleaseError("Release app source revision does not match the clean HEAD commit")


def require_empty_prepared_stage(stage: Path) -> None:
    if stage.exists() and any(stage.iterdir()):
        raise ReleaseError(f"Prepared-app mode refuses existing staging at {stage}; use make release to resume it")


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def public_key() -> str:
    if not PUBLIC_KEY_FILE.is_file():
        raise ReleaseError(f"Missing {PUBLIC_KEY_FILE.relative_to(ROOT)}")
    value = PUBLIC_KEY_FILE.read_text(encoding="utf-8").strip()
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise ReleaseError("Sparkle public key is not valid base64") from error
    if len(decoded) != 32:
        raise ReleaseError("Sparkle EdDSA public key must decode to 32 bytes")
    return value


def check_app_metadata(
    path: Path,
    version: str,
    *,
    release_build: bool,
    source_sha: str | None = None,
) -> dict[str, Any]:
    info_path = path / "Contents/Info.plist"
    if not info_path.is_file():
        raise ReleaseError(f"App bundle is missing {info_path.relative_to(path)}")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    expected = {
        "CFBundleIdentifier": APP_ID,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ReleaseError(f"{path.name} has {key}={info.get(key)!r}; expected {value!r}")
    if release_build:
        release_expected = {
            "LeanTermReleaseBuild": True,
            "SUFeedURL": FEED_URL,
            "SUPublicEDKey": public_key(),
            "SUEnableAutomaticChecks": True,
            "SUAutomaticallyUpdate": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SURequireSignedFeed": True,
        }
        for key, value in release_expected.items():
            if info.get(key) != value:
                raise ReleaseError(f"Release app has unexpected {key} value")
        if source_sha is not None:
            validate_source_revision(info, source_sha)
    executable = path / "Contents/MacOS" / str(info.get("CFBundleExecutable", PRODUCT))
    if not executable.is_file():
        raise ReleaseError(f"App bundle executable is missing: {executable}")
    if release_build:
        architectures = command(["lipo", "-archs", str(executable)], capture=True).stdout or ""
        if architectures.strip() != "arm64":
            raise ReleaseError(f"Release archive is named for Apple silicon; executable architectures are {architectures.strip()!r}")
    return info


@contextlib.contextmanager
def exclusive_bundle_lock(bundle: Path, *, require_lock_file: bool = True) -> Iterator[None]:
    lock_path = bundle / "Contents/Resources/Build.lock"
    if not lock_path.is_file():
        if require_lock_file:
            raise ReleaseError(f"{bundle} has no Build.lock; refusing an unsafe replacement")
        yield
        return
    with lock_path.open("rb") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError(f"{bundle} is running; quit Lean Term before continuing") from error
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def load_state(stage: Path, version: str, source_sha: str) -> dict[str, Any]:
    path = stage / "release-state.json"
    if not path.exists():
        return {
            "version": version,
            "tag": f"v{version}",
            "repo": REPO,
            "source_sha": source_sha,
            "bundle_identifier": APP_ID,
            "artifacts": {},
        }
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Cannot read staged release state {path}") from error
    expected = {
        "version": version,
        "tag": f"v{version}",
        "repo": REPO,
        "source_sha": source_sha,
        "bundle_identifier": APP_ID,
    }
    for key, value in expected.items():
        if state.get(key) != value:
            raise ReleaseError(f"Existing staging state has a different {key}; preserving it at {path}")
    if not isinstance(state.get("artifacts"), dict):
        raise ReleaseError("Staged release state has an invalid artifact map")
    return state


def save_state(stage: Path, state: dict[str, Any]) -> None:
    path = stage / "release-state.json"
    temporary = stage / f".release-state.{os.getpid()}.tmp"
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def repo_status() -> tuple[str, str]:
    status = command(["git", "status", "--porcelain", "--untracked-files=normal"], capture=True).stdout or ""
    if status.strip():
        raise ReleaseError("Release requires a clean working tree. Commit the intended source first.\n" + status.rstrip())
    sha = (command(["git", "rev-parse", "HEAD^{commit}"], capture=True).stdout or "").strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", sha):
        raise ReleaseError("Could not resolve the current source commit")
    return sha, status


def gh_api(path: str) -> dict[str, Any] | list[Any] | None:
    result = command(["gh", "api", f"repos/{REPO}/{path}"], capture=True, check=False)
    if result.returncode:
        error = (result.stderr or "").lower()
        if "http 404" in error or "not found" in error or (
            path.startswith("commits/") and "http 422" in error and "no commit found for sha" in error
        ):
            return None
        detail = (result.stderr or result.stdout or "").strip()
        raise ReleaseError(f"GitHub API request failed for {path}: {detail}")
    try:
        return json.loads(result.stdout or "null")
    except json.JSONDecodeError as error:
        raise ReleaseError(f"GitHub returned invalid JSON for {path}") from error


def remote_release_state(version: str, source_sha: str) -> dict[str, Any] | None:
    tag = f"v{version}"
    release = gh_api(f"releases/tags/{tag}")
    commit = gh_api(f"commits/{tag}")
    tag_sha = commit.get("sha") if isinstance(commit, dict) else None
    if tag_sha and tag_sha != source_sha:
        raise ReleaseError(f"GitHub tag {tag} points at {tag_sha}, not source HEAD {source_sha}")
    if isinstance(release, dict):
        if tag_sha != source_sha and not (
            tag_sha is None and release.get("draft") and release.get("target_commitish") == source_sha
        ):
            raise ReleaseError(f"Could not verify that GitHub release {tag} targets {source_sha}")
        if not release.get("draft", False):
            raise ReleaseError(f"GitHub release {tag} is already published and will not be replaced")
        return release
    if tag_sha and tag_sha != source_sha:
        raise ReleaseError(f"GitHub tag {tag} already exists at a different source commit")
    return None


def check_local_tools() -> list[str]:
    required = ["python3", "swift", "xcrun", "codesign", "security", "spctl", "ditto", "lipo", "gh", "pgrep"]
    missing = [name for name in required if shutil.which(name) is None]
    for name in ("generate_keys", "generate_appcast", "sign_update"):
        if not (SPARKLE_BIN / name).is_file():
            missing.append(str(SPARKLE_BIN.relative_to(ROOT) / name))
    return missing


def verify_sparkle_key(account: str) -> str:
    result = command(
        [str(SPARKLE_BIN / "generate_keys"), "--account", account, "-p"],
        capture=True,
        check=False,
    )
    if result.returncode:
        raise ReleaseError(f"Sparkle signing keychain account {account!r} is unavailable")
    key = (result.stdout or "").strip()
    expected = public_key()
    if key != expected:
        raise ReleaseError("Keychain Sparkle public key does not match release/sparkle-public-key.txt")
    return key


def verify_signing_identity(identity: str) -> None:
    identity_list = command(["security", "find-identity", "-v", "-p", "codesigning"], capture=True).stdout or ""
    if identity not in identity_list or "Developer ID Application" not in identity:
        raise ReleaseError(f"Signing identity is not available as a Developer ID Application: {identity}")


def verify_notary_profile(profile: str) -> None:
    result = command(
        ["xcrun", "notarytool", "history", "--keychain-profile", profile, "--output-format", "json"],
        capture=True,
        check=False,
    )
    if result.returncode:
        raise ReleaseError(f"Notary profile {profile!r} could not be read by notarytool")


def verify_github_auth() -> None:
    result = command(["gh", "auth", "status", "--hostname", "github.com"], capture=True, check=False)
    if result.returncode:
        raise ReleaseError("GitHub CLI is not authenticated for github.com")


def doctor(version: str) -> None:
    check_version(version)
    if platform.system() != "Darwin":
        raise ReleaseError("Release signing and notarization must run on macOS")
    missing = check_local_tools()
    if missing:
        raise ReleaseError("Missing release tools: " + ", ".join(missing))
    key = public_key()
    identity = os.environ.get("CODESIGN_IDENTITY", DEFAULT_IDENTITY)
    verify_signing_identity(identity)
    profile = os.environ.get("NOTARY_KEYCHAIN_PROFILE", DEFAULT_NOTARY_PROFILE)
    verify_notary_profile(profile)
    account = os.environ.get("SPARKLE_KEYCHAIN_ACCOUNT", DEFAULT_SPARKLE_ACCOUNT)
    verify_sparkle_key(account)
    verify_github_auth()
    print(f"Lean Term {version}: local tools, Developer ID identity, notary profile, and {len(base64.b64decode(key))}-byte Sparkle public key are available.")
    print(f"Sparkle signing account for release commands: {os.environ.get('SPARKLE_KEYCHAIN_ACCOUNT', DEFAULT_SPARKLE_ACCOUNT)}")


def check_remote_source(source_sha: str) -> None:
    result = gh_api(f"commits/{source_sha}")
    if not isinstance(result, dict) or result.get("sha") != source_sha:
        raise ReleaseError(f"Source commit {source_sha} is not available in GitHub repository {REPO}; push it before publishing")


def require_forward_release(version: str) -> None:
    latest = gh_api("releases/latest")
    if latest is None:
        return
    tag = latest.get("tag_name", "") if isinstance(latest, dict) else ""
    previous = tag.removeprefix("v")
    if not VERSION_PATTERN.fullmatch(previous):
        raise ReleaseError("Latest GitHub release has an unrecognized version; inspect it before publishing")
    if tuple(map(int, version.split("."))) < tuple(map(int, previous.split("."))):
        raise ReleaseError(f"Refusing to make {version} latest over newer published version {previous}")


def notarization_status(stage: Path, state: dict[str, Any], profile: str) -> None:
    bundle = app_path(stage)
    request_id = state.get("notary_submission_id")
    if not request_id:
        for previous_receipt in sorted(stage.glob("notary-submit-*.json"), reverse=True):
            try:
                previous = json.loads(previous_receipt.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            request_id = previous.get("id") or previous.get("submissionId")
            if request_id:
                state["notary_submission_id"] = request_id
                save_state(stage, state)
                break
    if request_id:
        args = ["xcrun", "notarytool", "wait", str(request_id), "--keychain-profile", profile, "--output-format", "json"]
        label = f"notary-wait-{request_id}-{time.time_ns()}.json"
    else:
        submission_zip = stage / "Lean-Term-macos-arm64.pre-notary.zip"
        if not submission_zip.exists():
            temporary_zip = stage / f".pre-notary-{os.getpid()}.tmp.zip"
            command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(temporary_zip)])
            os.rename(temporary_zip, submission_zip)
        args = [
            "xcrun", "notarytool", "submit", str(submission_zip),
            "--keychain-profile", profile, "--wait", "--no-s3-acceleration", "--output-format", "json",
        ]
        label = f"notary-submit-{time.time_ns()}.json"
    result = command(args, capture=True, check=False)
    receipt_path = stage / label
    receipt_path.write_text(result.stdout or result.stderr or "{}\n", encoding="utf-8")
    try:
        receipt = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as error:
        raise ReleaseError(f"Notary response was not JSON; retained at {receipt_path}") from error
    request_id = receipt.get("id") or receipt.get("submissionId") or request_id
    status = str(receipt.get("status", "")).lower().replace(" ", "")
    if request_id:
        state["notary_submission_id"] = request_id
    state["notary_status"] = receipt.get("status")
    save_state(stage, state)
    if result.returncode and not request_id:
        raise ReleaseError(f"Notarization command failed; response retained at {receipt_path}")
    if status != "accepted":
        if request_id:
            log = command(
                ["xcrun", "notarytool", "log", str(request_id), "--keychain-profile", profile],
                capture=True,
                check=False,
            )
            if log.stdout:
                (stage / f"notary-log-{request_id}-{time.time_ns()}.json").write_text(log.stdout, encoding="utf-8")
        if status == "inprogress":
            raise ReleaseError(f"Notarization is still in progress for {request_id}; rerun make release to resume")
        raise ReleaseError(f"Notarization did not return Accepted (status: {receipt.get('status', 'unknown')}); receipt retained")
    if not request_id:
        raise ReleaseError("Notary accepted the archive but did not return a submission ID")
    state["notary_status"] = "Accepted"
    save_state(stage, state)


def codesign_details(bundle: Path) -> str:
    result = command(["codesign", "-dv", "--verbose=4", str(bundle)], capture=True, check=False)
    return (result.stdout or "") + (result.stderr or "")


def sign_app(bundle: Path, identity: str) -> None:
    """Sign Sparkle inside out, preserving its helper identifiers/entitlements."""
    framework = bundle / "Contents/Frameworks/Sparkle.framework"
    version = framework / "Versions/Current"
    nested = [version / "XPCServices/Downloader.xpc", version / "XPCServices/Installer.xpc",
              version / "Autoupdate", version / "Updater.app", framework]
    for component in nested:
        if not component.exists():
            raise ReleaseError(f"Expected Sparkle signing component is missing: {component}")
        command(["codesign", "--force", "--options", "runtime", "--timestamp",
                 "--preserve-metadata=identifier,entitlements", "--sign", identity, str(component)])
    command(["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(bundle)])


def verify_signed_app(bundle: Path, identity: str, version: str, source_sha: str | None = None) -> None:
    check_app_metadata(bundle, version, release_build=True, source_sha=source_sha)
    command(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(bundle)])
    details = codesign_details(bundle)
    if identity not in details:
        raise ReleaseError(f"App signature does not match the requested Developer ID identity: {identity}")
    if "flags=" not in details or "runtime" not in details:
        raise ReleaseError("App signature does not show hardened runtime")
    if "Timestamp=" not in details:
        raise ReleaseError("App signature is missing a secure timestamp")


def validate_appcast(path: Path, version: str, archive_size: int) -> None:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as error:
        raise ReleaseError(f"Sparkle appcast is not valid XML: {path}") from error
    items = root.findall(".//item")
    if len(items) != 1:
        raise ReleaseError("A version release appcast must contain exactly one update item")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ReleaseError("Sparkle appcast has no enclosure")
    if enclosure.get("url") != versioned_download_url(version):
        raise ReleaseError("Sparkle enclosure URL does not point at this version's GitHub asset")
    if enclosure.get("length") != str(archive_size):
        raise ReleaseError("Sparkle enclosure length does not match the release ZIP")
    signed_version = (
        enclosure.get(f"{{{SPARKLE_NS}}}version")
        or item.get(f"{{{SPARKLE_NS}}}version")
        or item.findtext(f"{{{SPARKLE_NS}}}version")
    )
    if signed_version != version:
        raise ReleaseError(f"Sparkle appcast item version {signed_version!r} does not match {version}")
    if not enclosure.get(f"{{{SPARKLE_NS}}}edSignature"):
        raise ReleaseError("Sparkle appcast enclosure is missing its EdDSA update signature")


def verify_appcast_signature(path: Path) -> None:
    account = os.environ.get("SPARKLE_KEYCHAIN_ACCOUNT", DEFAULT_SPARKLE_ACCOUNT)
    command([str(SPARKLE_BIN / "sign_update"), "--verify", "--account", account, str(path)])


def verify_archive_signature(archive: Path, appcast_path: Path) -> None:
    try:
        root = ET.parse(appcast_path).getroot()
    except (ET.ParseError, OSError) as error:
        raise ReleaseError(f"Sparkle appcast is not valid XML: {appcast_path}") from error
    item = root.find(".//item")
    enclosure = item.find("enclosure") if item is not None else None
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature") if enclosure is not None else None
    if not signature:
        raise ReleaseError("Sparkle appcast enclosure has no EdDSA signature for the ZIP")
    account = os.environ.get("SPARKLE_KEYCHAIN_ACCOUNT", DEFAULT_SPARKLE_ACCOUNT)
    command([str(SPARKLE_BIN / "sign_update"), "--verify", "--account", account, str(archive), signature])


def existing_artifact(stage: Path, name: str, state: dict[str, Any]) -> Path:
    path = stage / name
    if not path.is_file():
        raise ReleaseError(f"Staged release asset is missing: {path}")
    recorded = state["artifacts"].get(name)
    actual_sha = digest(path)
    actual_size = path.stat().st_size
    if recorded and (recorded.get("sha256") != actual_sha or recorded.get("size") != actual_size):
        raise ReleaseError(f"Staged release asset changed after it was recorded: {name}")
    state["artifacts"][name] = {"sha256": actual_sha, "size": actual_size}
    return path


def generate_appcast(stage: Path, version: str, archive: Path) -> Path:
    output = stage / "appcast.xml"
    input_dir = stage / "appcast-input"
    input_dir.mkdir(exist_ok=True)
    input_archive = input_dir / APP_ARCHIVE_NAME
    if not input_archive.exists():
        temporary_input = input_dir / f".{APP_ARCHIVE_NAME}.copy-{os.getpid()}"
        try:
            os.link(archive, temporary_input)
        except OSError:
            shutil.copy2(archive, temporary_input)
        os.rename(temporary_input, input_archive)
    elif digest(input_archive) != digest(archive):
        raise ReleaseError("Existing Sparkle input archive does not match the notarized release ZIP")
    tool = SPARKLE_BIN / "generate_appcast"
    prefix = f"{ASSET_BASE_URL}/v{version}/"
    args = [
        str(tool), "--account", os.environ.get("SPARKLE_KEYCHAIN_ACCOUNT", DEFAULT_SPARKLE_ACCOUNT),
        "--download-url-prefix", prefix,
        "--maximum-versions", "1", "--maximum-deltas", "0", "--versions", version,
        "-o", str(output), str(input_dir),
    ]
    pending_output = stage / f".appcast-{os.getpid()}.pending.xml"
    args[args.index("-o") + 1] = str(pending_output)
    command(args)
    validate_appcast(pending_output, version, archive.stat().st_size)
    verify_appcast_signature(pending_output)
    os.rename(pending_output, output)
    return output


def record_artifact(stage: Path, state: dict[str, Any], path: Path) -> None:
    state["artifacts"][path.name] = {"sha256": digest(path), "size": path.stat().st_size}
    save_state(stage, state)


def release(version: str, *, prepared_app: bool = False) -> None:
    check_version(version)
    if platform.system() != "Darwin":
        raise ReleaseError("Release signing and notarization must run on macOS")
    missing = check_local_tools()
    if missing:
        raise ReleaseError("Missing release tools: " + ", ".join(missing))
    source_sha, _ = repo_status()
    local_app = ROOT / "dist" / f"{APP_NAME}.app"
    stage = stage_path(version)
    staged_app = app_path(stage)
    state_path = stage / "release-state.json"
    if prepared_app:
        require_empty_prepared_stage(stage)
        check_app_metadata(local_app, version, release_build=True, source_sha=source_sha)
        state = None
    elif state_path.is_file():
        state = load_state(stage, version, source_sha)
        if staged_app.exists():
            check_app_metadata(staged_app, version, release_build=True, source_sha=source_sha)
    elif stage.exists() and any(stage.iterdir()):
        raise ReleaseError(f"Existing staging has no matching release state; preserving it at {stage}")
    else:
        state = None

    identity = os.environ.get("CODESIGN_IDENTITY", DEFAULT_IDENTITY)
    profile = os.environ.get("NOTARY_KEYCHAIN_PROFILE", DEFAULT_NOTARY_PROFILE)
    public_key()
    verify_sparkle_key(os.environ.get("SPARKLE_KEYCHAIN_ACCOUNT", DEFAULT_SPARKLE_ACCOUNT))
    verify_signing_identity(identity)
    verify_notary_profile(profile)
    verify_github_auth()
    check_remote_source(source_sha)
    remote_release_state(version, source_sha)
    stage.mkdir(parents=True, exist_ok=True)
    if state is None:
        state = load_state(stage, version, source_sha)
    save_state(stage, state)

    if not staged_app.exists():
        if not prepared_app:
            print(f"Building release-configured Lean Term {version} from {source_sha}…")
            build_env = os.environ.copy()
            build_env["LEANTERM_RELEASE_BUILD"] = "1"
            command(["./script/build_and_run.sh", "--build-only"], env=build_env)
        check_app_metadata(local_app, version, release_build=True, source_sha=source_sha)
        temporary_app = stage / f".{APP_NAME}.app.copy-{os.getpid()}"
        if temporary_app.exists():
            raise ReleaseError(f"Copy staging path already exists and was preserved: {temporary_app}")
        with exclusive_bundle_lock(local_app):
            command(["ditto", str(local_app), str(temporary_app)])
        os.rename(temporary_app, staged_app)
        state["build_completed"] = True
        state["prepared_app"] = prepared_app
        save_state(stage, state)
    check_app_metadata(staged_app, version, release_build=True, source_sha=source_sha)

    with exclusive_bundle_lock(staged_app):
        details = codesign_details(staged_app)
        if identity not in details or "runtime" not in details or "Timestamp=" not in details:
            print(f"Signing {staged_app} with Developer ID and hardened runtime…")
            sign_app(staged_app, identity)
        verify_signed_app(staged_app, identity, version, source_sha)

        state["signature_verified"] = True
        save_state(stage, state)
        stapler = command(["xcrun", "stapler", "validate", str(staged_app)], capture=True, check=False)
        if stapler.returncode:
            notarization_status(stage, state, profile)
            command(["xcrun", "stapler", "staple", str(staged_app)])
            command(["xcrun", "stapler", "validate", str(staged_app)])
        else:
            state["notary_status"] = "Accepted"
            state["app_stapled"] = True
            save_state(stage, state)
        command(["spctl", "--assess", "--type", "execute", "--verbose=4", str(staged_app)])
        state["app_stapled"] = True
        state["gatekeeper_verified"] = True
        save_state(stage, state)

        archive = stage / APP_ARCHIVE_NAME
        if archive.exists():
            existing_artifact(stage, APP_ARCHIVE_NAME, state)
        else:
            temporary_archive = stage / f".{APP_ARCHIVE_NAME}.{os.getpid()}.tmp"
            command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged_app), str(temporary_archive)])
            os.rename(temporary_archive, archive)
            record_artifact(stage, state, archive)
        archive_size = archive.stat().st_size
        if not state["artifacts"].get(APP_ARCHIVE_NAME):
            record_artifact(stage, state, archive)

        appcast = stage / "appcast.xml"
        if appcast.exists():
            validate_appcast(appcast, version, archive_size)
            verify_appcast_signature(appcast)
        else:
            generate_appcast(stage, version, archive)
        verify_archive_signature(archive, appcast)
        record_artifact(stage, state, appcast)

        checksum = stage / f"{APP_ARCHIVE_NAME}.sha256"
        checksum_text = f"{digest(archive)}  {APP_ARCHIVE_NAME}\n"
        if checksum.exists():
            if checksum.read_text(encoding="utf-8") != checksum_text:
                raise ReleaseError(f"Existing checksum file does not match {APP_ARCHIVE_NAME}: {checksum}")
        else:
            temporary_checksum = stage / f".{checksum.name}.{os.getpid()}.tmp"
            temporary_checksum.write_text(checksum_text, encoding="utf-8")
            os.rename(temporary_checksum, checksum)
        record_artifact(stage, state, checksum)
        state["ready"] = True
        save_state(stage, state)

    print(f"Release artifacts are ready in {stage}")
    for name in (APP_ARCHIVE_NAME, "appcast.xml", f"{APP_ARCHIVE_NAME}.sha256"):
        print(f"  {name}: sha256 {state['artifacts'][name]['sha256']}")


def verify_staged_release(version: str) -> tuple[Path, dict[str, Any]]:
    check_version(version)
    stage = stage_path(version)
    state_path = stage / "release-state.json"
    if not state_path.is_file():
        raise ReleaseError(f"No staged release exists for {version}; run make release first")
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Cannot read staged release state {state_path}") from error
    for key, expected in {
        "version": version,
        "tag": f"v{version}",
        "repo": REPO,
        "bundle_identifier": APP_ID,
        "ready": True,
    }.items():
        if state.get(key) != expected:
            raise ReleaseError(f"Staged release state has an invalid {key}")
    source_sha = state.get("source_sha")
    if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40,64}", source_sha):
        raise ReleaseError("Staged release has no valid source commit")
    expected_names = {APP_ARCHIVE_NAME, "appcast.xml", f"{APP_ARCHIVE_NAME}.sha256"}
    if set(state.get("artifacts", {})) != expected_names:
        raise ReleaseError("Staged release does not contain exactly the ZIP, signed appcast, and checksum")
    for name in sorted(expected_names):
        existing_artifact(stage, name, state)
    archive = stage / APP_ARCHIVE_NAME
    checksum = stage / f"{APP_ARCHIVE_NAME}.sha256"
    expected_checksum = f"{digest(archive)}  {APP_ARCHIVE_NAME}\n"
    if checksum.read_text(encoding="utf-8") != expected_checksum:
        raise ReleaseError("Staged SHA-256 file does not match the release ZIP")
    validate_appcast(stage / "appcast.xml", version, archive.stat().st_size)
    verify_appcast_signature(stage / "appcast.xml")
    verify_archive_signature(archive, stage / "appcast.xml")
    verify_signed_app(app_path(stage), os.environ.get("CODESIGN_IDENTITY", DEFAULT_IDENTITY), version, source_sha)
    if not state.get("gatekeeper_verified") or not state.get("app_stapled"):
        raise ReleaseError("Staged app does not record successful notarization and Gatekeeper validation")
    return stage, state


def asset_map(release_data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    assets = release_data.get("assets")
    if not isinstance(assets, list):
        raise ReleaseError("GitHub release response has no asset list")
    return {str(asset.get("name")): asset for asset in assets if isinstance(asset, dict)}


def download_and_verify_asset(tag: str, name: str, destination: Path, expected_sha: str, expected_size: int) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    command(["gh", "release", "download", tag, "--repo", REPO, "--pattern", name, "--dir", str(destination)])
    downloaded = destination / name
    if not downloaded.is_file():
        raise ReleaseError(f"GitHub download did not produce asset {name}")
    if downloaded.stat().st_size != expected_size or digest(downloaded) != expected_sha:
        raise ReleaseError(f"Uploaded GitHub asset failed checksum verification: {name}")


def publish(version: str) -> None:
    stage, state = verify_staged_release(version)
    source_sha = state.get("source_sha")
    if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40,64}", source_sha):
        raise ReleaseError("Staged release has no valid source commit")
    check_remote_source(source_sha)
    require_forward_release(version)
    current_sha, _ = repo_status()
    if current_sha != source_sha:
        raise ReleaseError(f"Current source HEAD {current_sha} differs from staged source {source_sha}")
    tag = f"v{version}"
    release_data = gh_api(f"releases/tags/{tag}")
    existing_commit = gh_api(f"commits/{tag}")
    existing_sha = existing_commit.get("sha") if isinstance(existing_commit, dict) else None
    if existing_sha and existing_sha != source_sha:
        raise ReleaseError(f"GitHub tag {tag} points to {existing_sha}; refusing to attach assets")
    if release_data is None:
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        sections = re.split(r"(?m)^## ", changelog)
        section = next((s for s in sections[1:] if s.startswith(version + " ")), None)
        notes = section.partition("\n")[2].strip() if section else f"Lean Term {version} for macOS (Apple silicon)."
        notes_path = stage / "release-notes.md"
        notes_path.write_text(notes + "\n\nRequires macOS 26 or later and Apple silicon.\n", encoding="utf-8")
        if existing_sha is not None and existing_sha != source_sha:
            raise ReleaseError(f"GitHub tag {tag} points at the wrong source commit")
        command([
            "gh", "release", "create", tag,
            "--repo", REPO,
            "--draft",
            "--target", source_sha,
            "--title", f"Lean Term {version}",
            "--notes-file", str(notes_path),
        ])
        release_data = gh_api(f"releases/tags/{tag}")
    if not isinstance(release_data, dict):
        raise ReleaseError(f"Could not read GitHub draft release {tag}")
    already_published = not release_data.get("draft", False)
    verified_commit = gh_api(f"commits/{tag}")
    verified_sha = verified_commit.get("sha") if isinstance(verified_commit, dict) else None
    if verified_sha != source_sha and not (
        verified_sha is None and not already_published and release_data.get("target_commitish") == source_sha
    ):
        raise ReleaseError(f"GitHub draft {tag} is not attached to exact source SHA {source_sha}")

    files = [APP_ARCHIVE_NAME, "appcast.xml", f"{APP_ARCHIVE_NAME}.sha256"]
    local_assets = {name: stage / name for name in files}
    expected = {name: state["artifacts"][name] for name in files}
    present = asset_map(release_data)
    unexpected = set(present) - set(files)
    if unexpected:
        raise ReleaseError("GitHub draft has unexpected assets; preserving draft: " + ", ".join(sorted(unexpected)))
    for name, asset in present.items():
        if int(asset.get("size", -1)) != int(expected[name]["size"]):
            raise ReleaseError(f"Existing draft asset {name} has a different size; refusing to replace it")
        download_dir = stage / f"verify-upload-{name.replace('/', '_')}-{time.time_ns()}"
        download_and_verify_asset(tag, name, download_dir, expected[name]["sha256"], expected[name]["size"])
    missing = [local_assets[name] for name in files if name not in present]
    if missing:
        if already_published:
            raise ReleaseError(f"Published release {tag} is missing expected assets; refusing to modify it")
        command(["gh", "release", "upload", tag, "--repo", REPO, *[str(path) for path in missing]])

    release_data = gh_api(f"releases/tags/{tag}")
    if not isinstance(release_data, dict):
        raise ReleaseError("GitHub release disappeared before uploaded asset verification")
    if already_published and release_data.get("draft", False):
        raise ReleaseError("GitHub release state changed unexpectedly during verification")
    if not already_published and not release_data.get("draft", False):
        raise ReleaseError("GitHub draft changed unexpectedly before uploaded asset verification")
    present = asset_map(release_data)
    if set(present) != set(files):
        raise ReleaseError("GitHub draft does not contain exactly the three expected assets")
    for name in files:
        asset = present[name]
        if int(asset.get("size", -1)) != int(expected[name]["size"]):
            raise ReleaseError(f"Uploaded GitHub asset size mismatch: {name}")
        download_dir = stage / f"verify-final-{name.replace('/', '_')}-{time.time_ns()}"
        download_and_verify_asset(tag, name, download_dir, expected[name]["sha256"], expected[name]["size"])

    if already_published:
        latest = gh_api("releases/latest")
        if not isinstance(latest, dict) or latest.get("tag_name") != tag:
            raise ReleaseError(f"GitHub release {tag} is published but is not latest")
        print(f"Release {tag} is already published from {source_sha}; all GitHub asset checksums match.")
        return

    command(["gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest"])
    published = gh_api(f"releases/tags/{tag}")
    if not isinstance(published, dict) or published.get("draft", True):
        raise ReleaseError(f"GitHub release {tag} did not become published")
    latest = gh_api("releases/latest")
    if not isinstance(latest, dict) or latest.get("tag_name") != tag:
        raise ReleaseError(f"GitHub release {tag} published, but latest release did not resolve to it")
    print(f"Published {tag} from {source_sha}; GitHub download checksums matched.")


def process_running_without_lock() -> bool:
    result = command(["pgrep", "-x", PRODUCT], capture=True, check=False)
    if result.returncode not in (0, 1):
        raise ReleaseError("Cannot verify whether the legacy app is running; refusing replacement")
    return result.returncode == 0


def verify_install_release(version: str, identity: str) -> tuple[Path, dict[str, Any]]:
    check_version(version)
    stage = stage_path(version)
    state_path = stage / "release-state.json"
    if not state_path.is_file():
        raise ReleaseError(f"No staged release exists for {version}; run make release first")
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Cannot read staged release state {state_path}") from error
    for key, expected in {
        "version": version,
        "tag": f"v{version}",
        "repo": REPO,
        "bundle_identifier": APP_ID,
        "ready": True,
    }.items():
        if state.get(key) != expected:
            raise ReleaseError(f"Staged release state has an invalid {key}")
    source_sha = state.get("source_sha")
    if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40,64}", source_sha):
        raise ReleaseError("Staged release has no valid source commit")
    expected_names = {APP_ARCHIVE_NAME, "appcast.xml", f"{APP_ARCHIVE_NAME}.sha256"}
    if set(state.get("artifacts", {})) != expected_names:
        raise ReleaseError("Staged release does not contain exactly the ZIP, appcast, and checksum")
    for name in sorted(expected_names):
        existing_artifact(stage, name, state)
    archive = stage / APP_ARCHIVE_NAME
    checksum = stage / f"{APP_ARCHIVE_NAME}.sha256"
    if checksum.read_text(encoding="utf-8") != f"{digest(archive)}  {APP_ARCHIVE_NAME}\n":
        raise ReleaseError("Staged SHA-256 file does not match the release ZIP")
    if not state.get("gatekeeper_verified") or not state.get("app_stapled"):
        raise ReleaseError("Staged app does not record successful notarization and Gatekeeper validation")
    verify_signed_app(app_path(stage), identity, version, source_sha)
    return stage, state


def perform_install(stage: Path, version: str, identity: str, source_sha: str) -> None:
    source = app_path(stage)
    command(["xcrun", "stapler", "validate", str(source)])
    command(["spctl", "--assess", "--type", "execute", "--verbose=4", str(source)])
    lock_path = INSTALL_PATH.parent / ".LeanTerm.install.lock"
    if lock_path.is_symlink() or (lock_path.exists() and not lock_path.is_file()):
        raise ReleaseError(f"Refusing to use a non-file install lock at {lock_path}")
    install_lock_mode = "rb" if lock_path.exists() else "a+b"
    with lock_path.open(install_lock_mode) as install_lock:
        try:
            fcntl.flock(install_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError("Another Lean Term install is already in progress") from error
        temporary = INSTALL_PATH.parent / f".Lean Term.install-{os.getpid()}.app"
        if temporary.exists():
            raise ReleaseError(f"Install staging path already exists and was preserved: {temporary}")
        backup: Path | None = None
        if INSTALL_PATH.exists():
            if INSTALL_PATH.is_symlink() or not INSTALL_PATH.is_dir():
                raise ReleaseError(f"Refusing to replace a non-app item at {INSTALL_PATH}")
            try:
                with (INSTALL_PATH / "Contents/Info.plist").open("rb") as info_file:
                    installed_info = plistlib.load(info_file)
            except (OSError, plistlib.InvalidFileException) as error:
                raise ReleaseError(f"Cannot read the existing app at {INSTALL_PATH}") from error
            if installed_info.get("CFBundleIdentifier") != APP_ID:
                raise ReleaseError(f"Refusing to replace a different application at {INSTALL_PATH}")
            if (INSTALL_PATH / "Contents/Resources/Build.lock").exists():
                existing_lock = exclusive_bundle_lock(INSTALL_PATH)
            else:
                if process_running_without_lock():
                    raise ReleaseError("Lean Term is running without a Build.lock; quit it before installing")
                existing_lock = contextlib.nullcontext()
        else:
            existing_lock = contextlib.nullcontext()

        with existing_lock, exclusive_bundle_lock(source):
            command(["ditto", str(source), str(temporary)])
            verify_signed_app(temporary, identity, version, source_sha)
            command(["xcrun", "stapler", "validate", str(temporary)])
            command(["spctl", "--assess", "--type", "execute", "--verbose=4", str(temporary)])
            if INSTALL_PATH.exists():
                backup = INSTALL_PATH.parent / f".LeanTerm-backup-{time.time_ns()}"
                if backup.exists():
                    raise ReleaseError(f"Backup path already exists and was preserved: {backup}")
                os.rename(INSTALL_PATH, backup)
            try:
                os.rename(temporary, INSTALL_PATH)
            except Exception:
                if backup is not None and not INSTALL_PATH.exists():
                    os.rename(backup, INSTALL_PATH)
                raise
        print(f"Installed Lean Term {version} at {INSTALL_PATH}")
        if backup:
            print(f"Previous app preserved at {backup}")


def install(version: str, identity: str) -> None:
    if platform.system() != "Darwin":
        raise ReleaseError("Installation at /Applications requires macOS")
    stage, state = verify_install_release(version, identity)
    if os.geteuid() == 0 or os.access(INSTALL_PATH.parent, os.W_OK):
        perform_install(stage, version, identity, state["source_sha"])
        return
    helper = Path(__file__).resolve()
    command([
        "sudo", sys.executable, str(helper), "install-root",
        "--version", version, "--identity", identity,
    ])


def install_root(version: str, identity: str) -> None:
    if platform.system() != "Darwin" or os.geteuid() != 0:
        raise ReleaseError("Internal privileged install helper must run as root on macOS")
    stage, state = verify_install_release(version, identity)
    perform_install(stage, version, identity, state["source_sha"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("doctor", "release", "publish", "install", "install-root"))
    parser.add_argument("--version", default=os.environ.get("VERSION", ""), help="must match the committed VERSION file")
    parser.add_argument("--identity", default=os.environ.get("CODESIGN_IDENTITY", DEFAULT_IDENTITY))
    parser.add_argument("--prepared-app", action="store_true", help="sign the validated release-configured dist/Lean Term.app without running SwiftPM")
    args = parser.parse_args()
    if args.prepared_app and args.action != "release":
        parser.error("--prepared-app is only valid with the release action")
    if not args.version:
        args.version = current_version()
    try:
        version = check_version(args.version)
        if args.action == "doctor":
            doctor(version)
        elif args.action == "release":
            release(version, prepared_app=args.prepared_app)
        elif args.action == "publish":
            publish(version)
        elif args.action == "install-root":
            install_root(version, args.identity)
        else:
            install(version, args.identity)
    except (ReleaseError, OSError, subprocess.SubprocessError) as error:
        print(f"release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
