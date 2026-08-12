#!/usr/bin/env python3
"""Build a small, reproducible, local-only trilingual STT benchmark.

The script deliberately downloads individual Common Voice clips and small
per-speaker AISHELL archives instead of multi-gigabyte dataset bundles. Audio
is normalized to signed 16-bit, 16 kHz, mono WAV and never uploaded.
"""

from __future__ import annotations

import argparse
import array
import contextlib
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import wave


DATASET_ID = "knock-knock-public-stt-benchmark-v1"
COUNT_PER_LOCALE = 40
MIN_SPEAKERS_PER_LOCALE = 8
MAX_CLIPS_PER_SPEAKER = 5
MIN_DURATION_SECONDS = 2.0
MAX_DURATION_SECONDS = 12.0
MIN_RMS_DBFS = -38.0
MAX_CLIPPING_RATIO = 0.01

EN_REPO = "fixie-ai/common_voice_17_0"
EN_REVISION = "34f78a43893414e7b6e271ba94c1d5e05f18b239"
YUE_REPO = "JackyHoCL/common_voice_22_yue"
YUE_REVISION = "2b89538754195fa30065b5f45cfe3ade529be942"
AISHELL_REPO = "AISHELL/AISHELL-1"
AISHELL_REVISION = "bbe295d530192a4cd41644b711c9aecd087df653"

DATASETS_SERVER = "https://datasets-server.huggingface.co"
HF_BASE = "https://huggingface.co"
USER_AGENT = "knock-knock-public-stt-benchmark/1.0"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="New or empty output directory. Audio is not suitable for git.",
    )
    parser.add_argument(
        "--count-per-locale",
        type=int,
        default=COUNT_PER_LOCALE,
        help="Defaults to 40. Lower values are only for tooling smoke tests.",
    )
    parser.add_argument(
        "--plan-only",
        action="store_true",
        help="Validate remote metadata and print the pinned source plan.",
    )
    return parser.parse_args()


def request_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()


def request_json(url: str, parameters: dict[str, str] | None = None) -> object:
    if parameters:
        url = f"{url}?{urllib.parse.urlencode(parameters)}"
    return json.loads(request_bytes(url))


def request_dataset_rows(parameters: dict[str, str]) -> dict[str, object]:
    delays = [0, 3, 8, 15]
    payload: object = {}
    for delay in delays:
        if delay:
            time.sleep(delay)
        command = [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--get",
            "--retry",
            "3",
            "--retry-all-errors",
            "--max-time",
            "120",
            f"{DATASETS_SERVER}/filter",
        ]
        for key, value in parameters.items():
            command.extend(["--data-urlencode", f"{key}={value}"])
        try:
            response = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(response.stdout)
        except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
            payload = {"error": f"temporary dataset service failure: {error}"}
            continue
        if not isinstance(payload, dict):
            break
        error = str(payload.get("error", ""))
        if "index is loading" not in error.lower():
            return payload
    if not isinstance(payload, dict):
        raise RuntimeError("dataset viewer returned an invalid response")
    return payload


def download(url: str, destination: Path) -> str:
    digest = hashlib.sha256()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=300) as response:
        with destination.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def hashed_identifier(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def run_ffmpeg(source: Path, destination: Path) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(destination),
        ],
        check=True,
    )


def inspect_wav(path: Path) -> dict[str, float | int]:
    with contextlib.closing(wave.open(str(path), "rb")) as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2:
            raise ValueError("normalized audio must be mono signed 16-bit PCM")
        if audio.getframerate() != 16_000:
            raise ValueError("normalized audio must be 16 kHz")
        frames = audio.readframes(audio.getnframes())
        frame_count = audio.getnframes()
        duration = frame_count / audio.getframerate()
    samples = array.array("h")
    samples.frombytes(frames)
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        raise ValueError("audio contains no samples")
    square_mean = sum(sample * sample for sample in samples) / len(samples)
    rms = math.sqrt(square_mean) / 32768.0
    rms_dbfs = 20 * math.log10(max(rms, 1e-12))
    clipping = sum(abs(sample) >= 32760 for sample in samples) / len(samples)
    peak = max(abs(sample) for sample in samples) / 32768.0
    return {
        "duration_seconds": round(duration, 3),
        "sample_rate": 16_000,
        "channels": 1,
        "rms_dbfs": round(rms_dbfs, 3),
        "peak": round(peak, 6),
        "clipping_ratio": round(clipping, 8),
    }


def quality_reason(metrics: dict[str, float | int]) -> str | None:
    duration = float(metrics["duration_seconds"])
    if duration < MIN_DURATION_SECONDS or duration > MAX_DURATION_SECONDS:
        return "duration"
    if float(metrics["rms_dbfs"]) < MIN_RMS_DBFS:
        return "too_quiet"
    if float(metrics["peak"]) < 0.02:
        return "near_silence"
    if float(metrics["clipping_ratio"]) > MAX_CLIPPING_RATIO:
        return "clipping"
    return None


def audio_url(row: dict[str, object]) -> str:
    audio = row.get("audio")
    if isinstance(audio, list) and audio and isinstance(audio[0], dict):
        source = audio[0].get("src")
    elif isinstance(audio, dict):
        source = audio.get("src")
    else:
        source = None
    if not isinstance(source, str) or not source.startswith("https://"):
        raise ValueError("dataset row has no HTTPS audio asset")
    return source


def fetch_common_voice_rows(
    *, repository: str, config: str, splits: list[str], where: str, needed: int
) -> list[dict[str, object]]:
    accepted: list[dict[str, object]] = []
    seen_speakers: set[str] = set()
    for split in splits:
        offset = 0
        while offset < 5_000 and (len(accepted) < needed or len(seen_speakers) < 12):
            payload = request_dataset_rows(
                {
                    "dataset": repository,
                    "config": config,
                    "split": split,
                    "where": where,
                    "offset": str(offset),
                    "length": "100",
                }
            )
            if not isinstance(payload, dict) or payload.get("error"):
                raise RuntimeError(
                    f"dataset viewer failed for {repository}/{split}: {payload}"
                )
            rows = payload.get("rows")
            if not isinstance(rows, list) or not rows:
                break
            for item in rows:
                if not isinstance(item, dict) or not isinstance(item.get("row"), dict):
                    continue
                row = dict(item["row"])
                row["_row_idx"] = item.get("row_idx")
                row["_split"] = split
                speaker = row.get("client_id")
                sentence = row.get("sentence")
                if (
                    isinstance(speaker, str)
                    and speaker
                    and isinstance(sentence, str)
                    and sentence.strip()
                ):
                    seen_speakers.add(speaker)
                    accepted.append(row)
            offset += len(rows)
    if len(accepted) < needed:
        raise RuntimeError(f"only {len(accepted)} candidate rows found for {repository}")
    return accepted


def add_common_voice_samples(
    *,
    candidates: list[dict[str, object]],
    locale: str,
    locale_slug: str,
    repository: str,
    revision: str,
    output_root: Path,
    temporary_root: Path,
    needed: int,
    examples: list[dict[str, object]],
    manifest: list[dict[str, object]],
) -> None:
    max_per_speaker = max(1, math.ceil(needed / MIN_SPEAKERS_PER_LOCALE))
    speaker_counts: dict[str, int] = {}
    seen_text: set[str] = set()
    rejected: dict[str, int] = {}
    for row in candidates:
        if sum(speaker_counts.values()) >= needed:
            break
        speaker = str(row["client_id"])
        if speaker_counts.get(speaker, 0) >= max_per_speaker:
            continue
        text = str(row["sentence"]).strip()
        normalized_text = "".join(text.lower().split())
        if normalized_text in seen_text:
            continue
        row_index = int(row["_row_idx"])
        sample_id = f"public-{locale_slug}-{sum(speaker_counts.values()) + 1:03d}"
        original = temporary_root / f"{sample_id}.source"
        normalized = output_root / "audio" / locale / f"{sample_id}__public.wav"
        normalized.parent.mkdir(parents=True, exist_ok=True)
        try:
            source_hash = download(audio_url(row), original)
            run_ffmpeg(original, normalized)
            metrics = inspect_wav(normalized)
            reason = quality_reason(metrics)
            if reason:
                rejected[reason] = rejected.get(reason, 0) + 1
                normalized.unlink(missing_ok=True)
                continue
        except (OSError, subprocess.CalledProcessError, ValueError) as error:
            rejected[type(error).__name__] = rejected.get(type(error).__name__, 0) + 1
            normalized.unlink(missing_ok=True)
            continue
        finally:
            original.unlink(missing_ok=True)

        speaker_counts[speaker] = speaker_counts.get(speaker, 0) + 1
        seen_text.add(normalized_text)
        examples.append({"id": sample_id, "locale": locale, "text": text})
        manifest.append(
            {
                "id": sample_id,
                "locale": locale,
                "relative_path": str(normalized.relative_to(output_root)),
                "sha256": sha256_file(normalized),
                "source": {
                    "repository": repository,
                    "revision": revision,
                    "config": "en" if locale == "en-HK" else "default",
                    "split": str(row["_split"]),
                    "row_index": row_index,
                    "speaker_sha256": hashed_identifier(speaker),
                    "license": "CC0-1.0",
                    "original_sha256": source_hash,
                },
                "quality": metrics,
            }
        )
    selected_speakers = len(speaker_counts)
    if sum(speaker_counts.values()) != needed or selected_speakers < MIN_SPEAKERS_PER_LOCALE:
        raise RuntimeError(
            f"{locale}: selected {sum(speaker_counts.values())}/{needed} clips from "
            f"{selected_speakers} speakers; rejected={rejected}"
        )


def aishell_archives() -> list[dict[str, object]]:
    payload = request_json(
        f"{HF_BASE}/api/datasets/{AISHELL_REPO}/tree/{AISHELL_REVISION}/data_aishell/wav",
        {"recursive": "false", "expand": "false"},
    )
    if not isinstance(payload, list):
        raise RuntimeError("AISHELL archive listing is unavailable")
    archives = [
        item
        for item in payload
        if isinstance(item, dict)
        and str(item.get("path", "")).endswith(".tar.gz")
        and isinstance(item.get("size"), int)
    ]
    return sorted(archives, key=lambda item: (int(item["size"]), str(item["path"])))


def aishell_transcripts(temporary_root: Path) -> dict[str, str]:
    relative_path = "data_aishell/transcript/aishell_transcript_v0.8.txt"
    url = f"{HF_BASE}/datasets/{AISHELL_REPO}/resolve/{AISHELL_REVISION}/{relative_path}?download=true"
    path = temporary_root / "aishell_transcript_v0.8.txt"
    download(url, path)
    transcripts: dict[str, str] = {}
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            fields = line.strip().split()
            if len(fields) >= 2:
                transcripts[fields[0]] = "".join(fields[1:])
    if len(transcripts) < 100_000:
        raise RuntimeError("AISHELL transcript map is unexpectedly small")
    return transcripts


def add_aishell_samples(
    *,
    output_root: Path,
    temporary_root: Path,
    needed: int,
    examples: list[dict[str, object]],
    manifest: list[dict[str, object]],
) -> None:
    transcripts = aishell_transcripts(temporary_root)
    max_per_speaker = max(1, math.ceil(needed / MIN_SPEAKERS_PER_LOCALE))
    target_speakers = max(MIN_SPEAKERS_PER_LOCALE, math.ceil(needed / max_per_speaker))
    selected = 0
    speaker_count = 0
    rejected: dict[str, int] = {}
    for archive_info in aishell_archives():
        if selected >= needed:
            break
        if speaker_count >= target_speakers and selected < needed:
            target_speakers += 1
        relative_path = str(archive_info["path"])
        speaker = Path(relative_path).name.removesuffix(".tar.gz")
        archive_path = temporary_root / Path(relative_path).name
        archive_url = (
            f"{HF_BASE}/datasets/{AISHELL_REPO}/resolve/{AISHELL_REVISION}/"
            f"{urllib.parse.quote(relative_path)}?download=true"
        )
        archive_hash = download(archive_url, archive_path)
        accepted_for_speaker = 0
        with tarfile.open(archive_path, "r:gz") as archive:
            wav_members = sorted(
                (
                    member
                    for member in archive.getmembers()
                    if member.isfile() and member.name.endswith(".wav")
                ),
                key=lambda member: member.name,
            )
            for member in wav_members:
                if selected >= needed or accepted_for_speaker >= max_per_speaker:
                    break
                utterance_id = Path(member.name).stem
                text = transcripts.get(utterance_id)
                if not text:
                    continue
                extracted = temporary_root / f"{utterance_id}.wav"
                source_stream = archive.extractfile(member)
                if source_stream is None:
                    continue
                source_digest = hashlib.sha256()
                with extracted.open("wb") as output:
                    while chunk := source_stream.read(1024 * 1024):
                        output.write(chunk)
                        source_digest.update(chunk)
                sample_id = f"public-zh-{selected + 1:03d}"
                normalized = output_root / "audio" / "zh-Hans-CN" / f"{sample_id}__public.wav"
                normalized.parent.mkdir(parents=True, exist_ok=True)
                try:
                    run_ffmpeg(extracted, normalized)
                    metrics = inspect_wav(normalized)
                    reason = quality_reason(metrics)
                    if reason:
                        rejected[reason] = rejected.get(reason, 0) + 1
                        normalized.unlink(missing_ok=True)
                        continue
                finally:
                    extracted.unlink(missing_ok=True)
                selected += 1
                accepted_for_speaker += 1
                examples.append({"id": sample_id, "locale": "zh-Hans-CN", "text": text})
                manifest.append(
                    {
                        "id": sample_id,
                        "locale": "zh-Hans-CN",
                        "relative_path": str(normalized.relative_to(output_root)),
                        "sha256": sha256_file(normalized),
                        "source": {
                            "repository": AISHELL_REPO,
                            "revision": AISHELL_REVISION,
                            "archive": relative_path,
                            "archive_sha256": archive_hash,
                            "utterance_id": utterance_id,
                            "speaker_id": speaker,
                            "license": "Apache-2.0",
                            "original_sha256": source_digest.hexdigest(),
                        },
                        "quality": metrics,
                    }
                )
        archive_path.unlink(missing_ok=True)
        if accepted_for_speaker:
            speaker_count += 1
    if selected != needed or speaker_count < MIN_SPEAKERS_PER_LOCALE:
        raise RuntimeError(
            f"zh-Hans-CN: selected {selected}/{needed} clips from {speaker_count} speakers; "
            f"rejected={rejected}"
        )


def validate_manifest(
    output_root: Path,
    examples: list[dict[str, object]],
    manifest: list[dict[str, object]],
    expected_per_locale: int,
) -> None:
    expected_total = expected_per_locale * 3
    if len(examples) != expected_total or len(manifest) != expected_total:
        raise RuntimeError("benchmark row count is incomplete")
    example_ids = {str(item["id"]) for item in examples}
    manifest_ids = {str(item["id"]) for item in manifest}
    if len(example_ids) != expected_total or example_ids != manifest_ids:
        raise RuntimeError("benchmark IDs are missing or duplicated")
    for locale in ["en-HK", "zh-Hans-CN", "yue-Hant-HK"]:
        if sum(item["locale"] == locale for item in examples) != expected_per_locale:
            raise RuntimeError(f"{locale} count is incorrect")
    for row in manifest:
        relative_path = Path(str(row["relative_path"]))
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise RuntimeError("unsafe relative audio path")
        audio_path = output_root / relative_path
        if sha256_file(audio_path) != row["sha256"]:
            raise RuntimeError(f"hash verification failed for {relative_path}")


def source_plan(count: int) -> dict[str, object]:
    return {
        "dataset_id": DATASET_ID,
        "count_per_locale": count,
        "audio_policy": "local-only; never committed or uploaded",
        "sources": [
            {
                "locale": "en-HK",
                "repository": EN_REPO,
                "revision": EN_REVISION,
                "selection": "train; Hong Kong English; up_votes>=2; down_votes=0",
                "license": "CC0-1.0",
            },
            {
                "locale": "zh-Hans-CN",
                "repository": AISHELL_REPO,
                "revision": AISHELL_REVISION,
                "selection": "smallest per-speaker archives; max five clips per speaker",
                "license": "Apache-2.0",
            },
            {
                "locale": "yue-Hant-HK",
                "repository": YUE_REPO,
                "revision": YUE_REVISION,
                "selection": "test; up_votes>=2; down_votes=0",
                "license": "CC0-1.0",
            },
        ],
    }


def main() -> int:
    args = parse_args()
    for required_command in ["curl", "ffmpeg"]:
        if shutil.which(required_command) is None:
            raise SystemExit(f"{required_command} is required")
    if args.count_per_locale < MIN_SPEAKERS_PER_LOCALE:
        raise SystemExit(f"--count-per-locale must be at least {MIN_SPEAKERS_PER_LOCALE}")
    output = args.output.expanduser().resolve()
    if not output.is_absolute() or output == Path("/") or output == Path.home():
        raise SystemExit("--output must resolve to a safe absolute directory")
    if output.is_symlink() or (output.exists() and any(output.iterdir())):
        raise SystemExit("--output must be a new or empty non-symlink directory")

    plan = source_plan(args.count_per_locale)
    # Fail early if pinned repositories were removed or replaced.
    for source in plan["sources"]:
        metadata = request_json(
            f"{HF_BASE}/api/datasets/{source['repository']}/revision/{source['revision']}"
        )
        if not isinstance(metadata, dict) or metadata.get("sha") != source["revision"]:
            raise RuntimeError(f"pinned source revision changed: {source['repository']}")
    if args.plan_only:
        print(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True))
        return 0

    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="knock-knock-public-stt.") as temporary:
        temporary_root = Path(temporary)
        examples: list[dict[str, object]] = []
        manifest: list[dict[str, object]] = []
        en_candidates = fetch_common_voice_rows(
            repository=EN_REPO,
            config="en",
            splits=["train"],
            where='"accent" LIKE \'%Hong%\' AND "up_votes" >= 2 AND "down_votes" = 0',
            needed=args.count_per_locale,
        )
        add_common_voice_samples(
            candidates=en_candidates,
            locale="en-HK",
            locale_slug="en",
            repository=EN_REPO,
            revision=EN_REVISION,
            output_root=output,
            temporary_root=temporary_root,
            needed=args.count_per_locale,
            examples=examples,
            manifest=manifest,
        )
        add_aishell_samples(
            output_root=output,
            temporary_root=temporary_root,
            needed=args.count_per_locale,
            examples=examples,
            manifest=manifest,
        )
        yue_candidates = fetch_common_voice_rows(
            repository=YUE_REPO,
            config="default",
            splits=["test"],
            where='"up_votes" >= 2 AND "down_votes" = 0',
            needed=args.count_per_locale,
        )
        add_common_voice_samples(
            candidates=yue_candidates,
            locale="yue-Hant-HK",
            locale_slug="yue",
            repository=YUE_REPO,
            revision=YUE_REVISION,
            output_root=output,
            temporary_root=temporary_root,
            needed=args.count_per_locale,
            examples=examples,
            manifest=manifest,
        )
        validate_manifest(output, examples, manifest, args.count_per_locale)

    generated_at = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()
    dataset = {
        "schema_version": 1,
        "dataset_id": DATASET_ID,
        "purpose": "stt_only",
        "generated_at": generated_at,
        "examples": examples,
    }
    (output / "KNOCK_KNOCK_VOICE_GOLDEN_V2.json").write_text(
        json.dumps(dataset, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output / "audio-manifest.jsonl").open("w", encoding="utf-8") as stream:
        for row in manifest:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    licenses = {
        **plan,
        "generated_at": generated_at,
        "license_notes": [
            "Common Voice audio is CC0-1.0; local benchmark access uses pinned mirrors.",
            "Mozilla requests that public redistribution use Mozilla Data Collective.",
            "AISHELL-1 is Apache-2.0 on OpenSLR SLR33.",
            "Generated audio must remain outside git and must not be shipped in the app.",
        ],
    }
    (output / "SOURCES_AND_LICENSES.json").write_text(
        json.dumps(licenses, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Prepared {len(examples)} local-only clips at {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
