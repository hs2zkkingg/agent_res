#!/usr/bin/env python3
"""Archive and replay ComfyUI PNG generations using only Python stdlib."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import sqlite3
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid
import zlib
from pathlib import Path


SCHEMA_VERSION = 1
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MODEL_INPUTS = {
    "CheckpointLoaderSimple": {"ckpt_name": ("checkpoints",)},
    "UNETLoader": {"unet_name": ("diffusion_models", "unet")},
    "CLIPLoader": {"clip_name": ("text_encoders", "clip")},
    "DualCLIPLoader": {
        "clip_name1": ("text_encoders", "clip"),
        "clip_name2": ("text_encoders", "clip"),
    },
    "VAELoader": {"vae_name": ("vae",)},
    "UpscaleModelLoader": {"model_name": ("upscale_models",)},
    "LoraLoader": {"lora_name": ("loras",)},
    "LoraLoaderModelOnly": {"lora_name": ("loras",)},
}
INPUT_ASSET_INPUTS = {
    "LoadImage": ("image",),
    "LoadImageMask": ("image",),
}


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, path)


def parse_png(path: Path) -> tuple[dict[str, str], int, int]:
    texts: dict[str, str] = {}
    width = height = 0
    with path.open("rb") as handle:
        if handle.read(8) != PNG_SIGNATURE:
            raise ValueError("not a PNG file")
        while True:
            raw_length = handle.read(4)
            if not raw_length:
                break
            if len(raw_length) != 4:
                raise ValueError("truncated PNG chunk length")
            length = struct.unpack(">I", raw_length)[0]
            kind = handle.read(4)
            data = handle.read(length)
            crc = handle.read(4)
            if len(kind) != 4 or len(data) != length or len(crc) != 4:
                raise ValueError("truncated PNG chunk")
            if kind == b"IHDR" and len(data) >= 8:
                width, height = struct.unpack(">II", data[:8])
            elif kind == b"tEXt":
                key, sep, value = data.partition(b"\0")
                if sep:
                    texts[key.decode("latin-1")] = value.decode("latin-1")
            elif kind == b"zTXt":
                key, sep, rest = data.partition(b"\0")
                if sep and len(rest) > 1 and rest[0] == 0:
                    texts[key.decode("latin-1")] = zlib.decompress(rest[1:]).decode("utf-8")
            elif kind == b"iTXt":
                key, separator, rest = data.partition(b"\0")
                if separator and len(rest) >= 2:
                    compression_flag, compression_method = rest[0], rest[1]
                    _language, language_separator, rest = rest[2:].partition(b"\0")
                    _translated, translated_separator, value = rest.partition(b"\0")
                    if language_separator and translated_separator:
                        if compression_flag == 1:
                            if compression_method != 0:
                                raise ValueError("unsupported iTXt compression method")
                            value = zlib.decompress(value)
                        elif compression_flag != 0:
                            raise ValueError("invalid iTXt compression flag")
                        texts[key.decode("latin-1")] = value.decode("utf-8")
            if kind == b"IEND":
                break
    return texts, width, height


def default_config_path() -> Path:
    env_path = os.environ.get("COMFYUI_ARCHIVE_CONFIG")
    candidates = []
    if env_path:
        candidates.append(Path(env_path))
    candidates.append(Path.cwd() / "archive_config.json")
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        candidates.append(Path(local_app_data) / "Codex" / "comfyui-archive-replay" / "archive_config.json")
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    return candidates[0].resolve()


def resolve_config_paths(config: dict, base: Path, key: str) -> None:
    config[key] = [str((base / value).resolve()) for value in config.get(key, [])]


def load_config(config_path: Path) -> dict:
    if not config_path.is_file():
        raise FileNotFoundError(
            f"config not found: {config_path}. Run init-config or pass --config <path>."
        )
    config = json.loads(config_path.read_text(encoding="utf-8"))
    base = config_path.parent
    config["archive_dir"] = str((base / config.get("archive_dir", "archive")).resolve())
    resolve_config_paths(config, base, "source_dirs")
    resolve_config_paths(config, base, "model_roots")
    resolve_config_paths(config, base, "input_roots")
    config.setdefault("comfy_url", "http://127.0.0.1:8188")
    return config


def connect_db(archive_root: Path) -> sqlite3.Connection:
    archive_root.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(archive_root / "archive.db")
    db.row_factory = sqlite3.Row
    db.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS entries (
            archive_id TEXT PRIMARY KEY,
            image_sha256 TEXT NOT NULL UNIQUE,
            archived_at TEXT NOT NULL,
            generated_at TEXT NOT NULL,
            source_path TEXT NOT NULL,
            item_dir TEXT NOT NULL,
            replayable INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            prompt_sha256 TEXT,
            workflow_sha256 TEXT,
            summary_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS model_cache (
            path TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            sha256 TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS source_cache (
            path TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            image_sha256 TEXT NOT NULL,
            archive_id TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS replay_log (
            replay_id TEXT PRIMARY KEY,
            archive_id TEXT NOT NULL,
            prompt_id TEXT NOT NULL,
            submitted_at TEXT NOT NULL,
            FOREIGN KEY (archive_id) REFERENCES entries(archive_id)
        );
        """
    )
    return db


def summarize_prompt(prompt: dict) -> dict:
    summary: dict[str, object] = {
        "models": [],
        "input_assets": [],
        "texts": [],
        "samplers": [],
        "latents": [],
    }
    for node_id, node in prompt.items():
        if not isinstance(node, dict):
            continue
        class_type = node.get("class_type")
        inputs = node.get("inputs", {})
        for input_name in MODEL_INPUTS.get(class_type, {}):
            value = inputs.get(input_name)
            if isinstance(value, str):
                summary["models"].append(
                    {"node_id": str(node_id), "class_type": class_type, "input": input_name, "name": value}
                )
        for input_name in INPUT_ASSET_INPUTS.get(class_type, ()):
            value = inputs.get(input_name)
            if isinstance(value, str):
                summary["input_assets"].append(
                    {"node_id": str(node_id), "class_type": class_type, "input": input_name, "name": value}
                )
        if class_type == "CLIPTextEncode" and isinstance(inputs.get("text"), str):
            summary["texts"].append({"node_id": str(node_id), "text": inputs["text"]})
        if class_type in {"KSampler", "KSamplerAdvanced"}:
            summary["samplers"].append(
                {
                    "node_id": str(node_id),
                    "seed": inputs.get("seed"),
                    "steps": inputs.get("steps"),
                    "cfg": inputs.get("cfg"),
                    "sampler_name": inputs.get("sampler_name"),
                    "scheduler": inputs.get("scheduler"),
                    "denoise": inputs.get("denoise"),
                }
            )
        if class_type in {"EmptyLatentImage", "EmptySD3LatentImage"}:
            summary["latents"].append(
                {
                    "node_id": str(node_id),
                    "width": inputs.get("width"),
                    "height": inputs.get("height"),
                    "batch_size": inputs.get("batch_size"),
                }
            )
    return summary


def get_system_snapshot(comfy_url: str) -> dict | None:
    try:
        with urllib.request.urlopen(comfy_url.rstrip("/") + "/system_stats", timeout=5) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def get_object_info(comfy_url: str) -> dict:
    url = comfy_url.rstrip("/") + "/object_info"
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            value = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cannot inspect ComfyUI nodes at {comfy_url}: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError(f"unexpected ComfyUI object_info response from {url}")
    return value


def find_model(model: dict, model_roots: list[Path]) -> Path | None:
    folders = MODEL_INPUTS.get(model["class_type"], {}).get(model["input"], ())
    relative_name = Path(model["name"])
    for root in model_roots:
        for folder in folders:
            candidate = root / folder / relative_name
            if candidate.is_file():
                return candidate.resolve()
    return None


def cached_model_hash(db: sqlite3.Connection, path: Path) -> str:
    stat = path.stat()
    row = db.execute("SELECT size, mtime_ns, sha256 FROM model_cache WHERE path = ?", (str(path),)).fetchone()
    if row and row["size"] == stat.st_size and row["mtime_ns"] == stat.st_mtime_ns:
        return row["sha256"]
    digest = sha256_file(path)
    db.execute(
        "INSERT OR REPLACE INTO model_cache(path, size, mtime_ns, sha256) VALUES (?, ?, ?, ?)",
        (str(path), stat.st_size, stat.st_mtime_ns, digest),
    )
    db.commit()
    return digest


def fingerprint_models(db: sqlite3.Connection, summary: dict, roots: list[Path], do_hash: bool) -> list[dict]:
    result = []
    for model in summary["models"]:
        path = find_model(model, roots)
        item = dict(model)
        if path:
            stat = path.stat()
            item.update({"resolved_path": str(path), "size": stat.st_size, "mtime_ns": stat.st_mtime_ns})
            item["sha256"] = cached_model_hash(db, path) if do_hash else None
        else:
            item.update({"resolved_path": None, "size": None, "mtime_ns": None, "sha256": None})
        result.append(item)
    return result


def safe_relative_asset(name: str) -> Path | None:
    relative = Path(name.replace("\\", "/"))
    if relative.is_absolute() or ".." in relative.parts:
        return None
    return relative


def fingerprint_input_assets(summary: dict, roots: list[Path], item_dir: Path) -> list[dict]:
    result = []
    for asset in summary.get("input_assets", []):
        item = dict(asset)
        relative = safe_relative_asset(asset["name"])
        source = None
        if relative is not None:
            for root in roots:
                candidate = root / relative
                if candidate.is_file():
                    source = candidate.resolve()
                    break
        if source is None:
            item.update({"resolved_path": None, "archived_file": None, "size": None, "sha256": None})
        else:
            digest = sha256_file(source)
            suffix = source.suffix.lower() or ".bin"
            archived_relative = Path("inputs") / f"{digest[:16]}{suffix}"
            archived_path = item_dir / archived_relative
            archived_path.parent.mkdir(parents=True, exist_ok=True)
            if not archived_path.exists():
                shutil.copy2(source, archived_path)
            item.update(
                {
                    "resolved_path": str(source),
                    "archived_file": archived_relative.as_posix(),
                    "size": source.stat().st_size,
                    "sha256": digest,
                }
            )
        result.append(item)
    return result


def backfill_system_snapshot(
    db: sqlite3.Connection, archive_id: str, system_snapshot: dict | None
) -> None:
    if system_snapshot is None:
        return
    row = db.execute("SELECT item_dir FROM entries WHERE archive_id = ?", (archive_id,)).fetchone()
    if row is None:
        return
    manifest_path = Path(row["item_dir"]) / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("comfyui_system_snapshot") is None:
        manifest["comfyui_system_snapshot"] = system_snapshot
        atomic_json(manifest_path, manifest)


def archive_one(
    db: sqlite3.Connection,
    archive_root: Path,
    image_path: Path,
    model_roots: list[Path],
    input_roots: list[Path],
    hash_models: bool,
    system_snapshot: dict | None,
) -> tuple[str, bool]:
    image_path = image_path.resolve()
    stat = image_path.stat()
    cached = db.execute(
        "SELECT archive_id FROM source_cache WHERE path = ? AND size = ? AND mtime_ns = ?",
        (str(image_path), stat.st_size, stat.st_mtime_ns),
    ).fetchone()
    if cached:
        backfill_system_snapshot(db, cached["archive_id"], system_snapshot)
        return cached["archive_id"], False
    image_sha = sha256_file(image_path)
    existing = db.execute("SELECT archive_id FROM entries WHERE image_sha256 = ?", (image_sha,)).fetchone()
    if existing:
        db.execute(
            "INSERT OR REPLACE INTO source_cache(path, size, mtime_ns, image_sha256, archive_id) VALUES (?, ?, ?, ?, ?)",
            (str(image_path), stat.st_size, stat.st_mtime_ns, image_sha, existing["archive_id"]),
        )
        db.commit()
        backfill_system_snapshot(db, existing["archive_id"], system_snapshot)
        return existing["archive_id"], False

    texts, width, height = parse_png(image_path)
    prompt = json.loads(texts["prompt"]) if texts.get("prompt") else None
    workflow = json.loads(texts["workflow"]) if texts.get("workflow") else None
    summary = summarize_prompt(prompt) if isinstance(prompt, dict) else {
        "models": [], "input_assets": [], "texts": [], "samplers": [], "latents": []
    }
    models = fingerprint_models(db, summary, model_roots, hash_models)
    generated = dt.datetime.fromtimestamp(image_path.stat().st_mtime, dt.timezone.utc)
    archive_id = generated.strftime("%Y%m%dT%H%M%SZ") + "-" + image_sha[:10]
    item_dir = archive_root / "items" / archive_id
    item_dir.mkdir(parents=True, exist_ok=False)
    shutil.copy2(image_path, item_dir / "image.png")
    input_assets = fingerprint_input_assets(summary, input_roots, item_dir)

    prompt_sha = workflow_sha = None
    if prompt is not None:
        atomic_json(item_dir / "prompt.json", prompt)
        prompt_sha = sha256_bytes(json_bytes(prompt))
    if workflow is not None:
        atomic_json(item_dir / "workflow.json", workflow)
        workflow_sha = sha256_bytes(json_bytes(workflow))

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "archive_id": archive_id,
        "archived_at": now_utc(),
        "generated_at": generated.isoformat(timespec="seconds"),
        "source_path": str(image_path),
        "image": {
            "file": "image.png",
            "original_name": image_path.name,
            "sha256": image_sha,
            "size": image_path.stat().st_size,
            "width": width,
            "height": height,
        },
        "replayable": prompt is not None,
        "prompt": {"file": "prompt.json", "sha256": prompt_sha} if prompt is not None else None,
        "workflow": {"file": "workflow.json", "sha256": workflow_sha} if workflow is not None else None,
        "summary": summary,
        "models": models,
        "input_assets": input_assets,
        "comfyui_system_snapshot": system_snapshot,
    }
    atomic_json(item_dir / "manifest.json", manifest)
    db.execute(
        """INSERT INTO entries(
            archive_id, image_sha256, archived_at, generated_at, source_path, item_dir,
            replayable, width, height, prompt_sha256, workflow_sha256, summary_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            archive_id,
            image_sha,
            manifest["archived_at"],
            manifest["generated_at"],
            str(image_path),
            str(item_dir),
            int(prompt is not None),
            width,
            height,
            prompt_sha,
            workflow_sha,
            json.dumps(summary, ensure_ascii=False),
        ),
    )
    db.execute(
        "INSERT OR REPLACE INTO source_cache(path, size, mtime_ns, image_sha256, archive_id) VALUES (?, ?, ?, ?, ?)",
        (str(image_path), stat.st_size, stat.st_mtime_ns, image_sha, archive_id),
    )
    db.commit()
    return archive_id, True


def discover_images(config: dict, explicit: list[str]) -> list[Path]:
    if explicit:
        paths = [Path(value) for value in explicit]
    else:
        paths = [Path(value) for value in config.get("source_dirs", [])]
    images: list[Path] = []
    for path in paths:
        if path.is_file() and path.suffix.lower() == ".png":
            images.append(path)
        elif path.is_dir():
            images.extend(path.rglob("*.png"))
    return sorted({path.resolve() for path in images}, key=lambda p: (p.stat().st_mtime_ns, str(p)))


def export_catalog(db: sqlite3.Connection, archive_root: Path) -> None:
    rows = db.execute(
        "SELECT archive_id, generated_at, width, height, replayable, image_sha256, summary_json "
        "FROM entries ORDER BY generated_at DESC"
    ).fetchall()
    catalog = {
        "schema_version": SCHEMA_VERSION,
        "exported_at": now_utc(),
        "count": len(rows),
        "entries": [
            {
                "archive_id": row["archive_id"],
                "generated_at": row["generated_at"],
                "width": row["width"],
                "height": row["height"],
                "replayable": bool(row["replayable"]),
                "image_sha256": row["image_sha256"],
                "summary": json.loads(row["summary_json"]),
            }
            for row in rows
        ],
    }
    atomic_json(archive_root / "catalog.json", catalog)


def cmd_archive(args: argparse.Namespace, config: dict) -> int:
    root = Path(config["archive_dir"])
    db = connect_db(root)
    model_roots = [Path(value) for value in config.get("model_roots", [])]
    input_roots = [Path(value) for value in config.get("input_roots", [])]
    system_snapshot = get_system_snapshot(config["comfy_url"])
    created = duplicates = failed = 0
    for image in discover_images(config, args.paths):
        try:
            archive_id, is_new = archive_one(
                db, root, image, model_roots, input_roots, not args.no_model_hash, system_snapshot
            )
            print(f"{'ARCHIVED' if is_new else 'EXISTS'} {archive_id} {image}")
            created += int(is_new)
            duplicates += int(not is_new)
        except Exception as exc:
            failed += 1
            print(f"FAILED {image}: {exc}", file=sys.stderr)
    export_catalog(db, root)
    print(f"SUMMARY new={created} existing={duplicates} failed={failed}")
    return 1 if failed else 0


def cmd_list(args: argparse.Namespace, config: dict) -> int:
    db = connect_db(Path(config["archive_dir"]))
    rows = db.execute(
        "SELECT archive_id, generated_at, width, height, replayable, summary_json FROM entries ORDER BY generated_at DESC"
    ).fetchall()
    for row in rows:
        summary = json.loads(row["summary_json"])
        text = summary.get("texts", [{}])[0].get("text", "") if summary.get("texts") else ""
        seed = summary.get("samplers", [{}])[0].get("seed", "") if summary.get("samplers") else ""
        print(f"{row['archive_id']}  {row['width']}x{row['height']}  seed={seed}  replay={bool(row['replayable'])}  {text[:80]}")
    return 0


def get_entry(db: sqlite3.Connection, archive_id: str) -> sqlite3.Row:
    row = db.execute("SELECT * FROM entries WHERE archive_id = ?", (archive_id,)).fetchone()
    if row is None:
        matches = db.execute("SELECT * FROM entries WHERE archive_id LIKE ?", (archive_id + "%",)).fetchall()
        if len(matches) == 1:
            return matches[0]
        raise KeyError(f"archive ID not found or ambiguous: {archive_id}")
    return row


def verify_entry(row: sqlite3.Row, verify_models: bool) -> list[str]:
    item_dir = Path(row["item_dir"])
    manifest = json.loads((item_dir / "manifest.json").read_text(encoding="utf-8"))
    issues: list[str] = []
    if sha256_file(item_dir / "image.png") != manifest["image"]["sha256"]:
        issues.append("image SHA-256 mismatch")
    for key in ("prompt", "workflow"):
        record = manifest.get(key)
        if record:
            value = json.loads((item_dir / record["file"]).read_text(encoding="utf-8"))
            if sha256_bytes(json_bytes(value)) != record["sha256"]:
                issues.append(f"{key} SHA-256 mismatch")
    if verify_models:
        for model in manifest.get("models", []):
            path = Path(model["resolved_path"]) if model.get("resolved_path") else None
            if not path or not path.is_file():
                issues.append(f"model missing: {model['name']}")
            elif model.get("sha256") and sha256_file(path) != model["sha256"]:
                issues.append(f"model SHA-256 mismatch: {model['name']}")
    return issues


def cmd_verify(args: argparse.Namespace, config: dict) -> int:
    db = connect_db(Path(config["archive_dir"]))
    rows = [get_entry(db, args.archive_id)] if args.archive_id else db.execute("SELECT * FROM entries").fetchall()
    failed = 0
    for row in rows:
        issues = verify_entry(row, args.models)
        if issues:
            failed += 1
            print(f"FAILED {row['archive_id']}: {'; '.join(issues)}")
        else:
            print(f"OK {row['archive_id']}")
    return 1 if failed else 0


def replay_preflight(row: sqlite3.Row, config: dict, verify_model_hashes: bool) -> list[str]:
    item_dir = Path(row["item_dir"])
    manifest = json.loads((item_dir / "manifest.json").read_text(encoding="utf-8"))
    issues = verify_entry(row, False)

    model_roots = [Path(value) for value in config.get("model_roots", [])]
    for model in manifest.get("models", []):
        path = find_model(model, model_roots)
        if path is None:
            resolved = Path(model["resolved_path"]) if model.get("resolved_path") else None
            path = resolved if resolved and resolved.is_file() else None
        if path is None:
            issues.append(f"model missing: {model['name']}")
        elif verify_model_hashes and model.get("sha256") and sha256_file(path) != model["sha256"]:
            issues.append(f"model SHA-256 mismatch: {model['name']}")

    input_roots = [Path(value) for value in config.get("input_roots", [])]
    for asset in manifest.get("input_assets", []):
        relative = safe_relative_asset(asset["name"])
        available = False
        if relative is not None:
            available = any((root / relative).is_file() for root in input_roots)
        if not available and asset.get("resolved_path"):
            available = Path(asset["resolved_path"]).is_file()
        if not available:
            archived = item_dir / asset["archived_file"] if asset.get("archived_file") else None
            suffix = f"; archived copy: {archived}" if archived and archived.is_file() else ""
            issues.append(f"input asset missing from ComfyUI input roots: {asset['name']}{suffix}")

    prompt_path = item_dir / "prompt.json"
    if not prompt_path.is_file():
        issues.append("this archive has no executable prompt metadata")
        return issues
    prompt = json.loads(prompt_path.read_text(encoding="utf-8"))
    object_info = get_object_info(config["comfy_url"])
    missing_nodes = sorted(
        {
            node.get("class_type")
            for node in prompt.values()
            if isinstance(node, dict)
            and isinstance(node.get("class_type"), str)
            and node["class_type"] not in object_info
        }
    )
    if missing_nodes:
        issues.append("ComfyUI node types missing: " + ", ".join(missing_nodes))
    return issues


def cmd_preflight(args: argparse.Namespace, config: dict) -> int:
    db = connect_db(Path(config["archive_dir"]))
    row = get_entry(db, args.archive_id)
    issues = replay_preflight(row, config, args.verify_models)
    if issues:
        print(f"NOT READY {row['archive_id']}: {'; '.join(issues)}")
        return 1
    print(f"READY {row['archive_id']}")
    return 0


def submit_prompt(comfy_url: str, prompt: dict, archive_id: str) -> dict:
    body = json.dumps(
        {"prompt": prompt, "client_id": f"comfy-archive-{uuid.uuid4()}", "extra_data": {"archive_id": archive_id}},
        ensure_ascii=False,
    ).encode("utf-8")
    request = urllib.request.Request(
        comfy_url.rstrip("/") + "/prompt",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.URLError as exc:
        raise RuntimeError(f"cannot reach ComfyUI at {comfy_url}: {exc}") from exc


def cmd_replay(args: argparse.Namespace, config: dict) -> int:
    root = Path(config["archive_dir"])
    db = connect_db(root)
    row = get_entry(db, args.archive_id)
    issues = replay_preflight(row, config, args.verify_models)
    if issues and not args.force:
        raise RuntimeError("archive verification failed: " + "; ".join(issues))
    prompt_path = Path(row["item_dir"]) / "prompt.json"
    if not prompt_path.is_file():
        raise RuntimeError("this archive has no executable prompt metadata")
    prompt = json.loads(prompt_path.read_text(encoding="utf-8"))
    response = submit_prompt(config["comfy_url"], prompt, row["archive_id"])
    prompt_id = response.get("prompt_id")
    db.execute(
        "INSERT INTO replay_log(replay_id, archive_id, prompt_id, submitted_at) VALUES (?, ?, ?, ?)",
        (str(uuid.uuid4()), row["archive_id"], prompt_id, now_utc()),
    )
    db.commit()
    print(json.dumps(response, ensure_ascii=False))
    return 0 if not response.get("node_errors") else 1


def cmd_init_config(args: argparse.Namespace, _config: dict | None = None) -> int:
    output = Path(args.output).resolve()
    if output.exists() and not args.force:
        raise FileExistsError(f"refusing to overwrite existing config: {output}; pass --force to replace it")
    config = {
        "schema_version": SCHEMA_VERSION,
        "comfy_url": args.comfy_url,
        "archive_dir": args.archive_dir,
        "source_dirs": args.source_dir,
        "model_roots": args.model_root,
        "input_roots": args.input_root,
    }
    atomic_json(output, config)
    print(f"CREATED {output}")
    return 0


def cmd_watch(args: argparse.Namespace, config: dict) -> int:
    print(f"Watching every {args.interval:g}s. Press Ctrl+C to stop.")
    archive_args = argparse.Namespace(paths=[], no_model_hash=args.no_model_hash)
    try:
        while True:
            cmd_archive(archive_args, config)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("Stopped.")
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Archive and replay ComfyUI PNG generations")
    parser.add_argument("--config", default=str(default_config_path()))
    sub = parser.add_subparsers(dest="command", required=True)
    init_config = sub.add_parser("init-config", help="create a portable configuration file")
    init_config.add_argument("--output", required=True)
    init_config.add_argument("--comfy-url", default="http://127.0.0.1:8188")
    init_config.add_argument("--archive-dir", default="archive")
    init_config.add_argument("--source-dir", action="append", default=[])
    init_config.add_argument("--model-root", action="append", default=[])
    init_config.add_argument("--input-root", action="append", default=[])
    init_config.add_argument("--force", action="store_true")
    init_config.set_defaults(func=cmd_init_config)
    archive = sub.add_parser("archive", help="archive PNG files or configured output folders")
    archive.add_argument("paths", nargs="*")
    archive.add_argument("--no-model-hash", action="store_true", help="skip slow model SHA-256 fingerprints")
    archive.set_defaults(func=cmd_archive)
    listing = sub.add_parser("list", help="list archived generations")
    listing.set_defaults(func=cmd_list)
    verify = sub.add_parser("verify", help="verify archived files")
    verify.add_argument("archive_id", nargs="?")
    verify.add_argument("--models", action="store_true", help="also re-hash model files")
    verify.set_defaults(func=cmd_verify)
    preflight = sub.add_parser("preflight", help="check whether an archive is ready to replay")
    preflight.add_argument("archive_id")
    preflight.add_argument("--verify-models", action="store_true")
    preflight.set_defaults(func=cmd_preflight)
    replay = sub.add_parser("replay", help="submit an archived prompt to ComfyUI")
    replay.add_argument("archive_id")
    replay.add_argument("--verify-models", action="store_true")
    replay.add_argument("--force", action="store_true")
    replay.set_defaults(func=cmd_replay)
    watch = sub.add_parser("watch", help="continuously archive new PNG outputs")
    watch.add_argument("--interval", type=float, default=10.0)
    watch.add_argument("--no-model-hash", action="store_true")
    watch.set_defaults(func=cmd_watch)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "init-config":
            return args.func(args, None)
        config = load_config(Path(args.config).resolve())
        return args.func(args, config)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
