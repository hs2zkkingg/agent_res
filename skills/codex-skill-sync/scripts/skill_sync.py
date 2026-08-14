#!/usr/bin/env python3
"""Audit, refresh, and safely deploy Skills from authoritative manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
from datetime import datetime


IGNORED_NAMES = {"__pycache__", ".DS_Store"}
IGNORED_SUFFIXES = {".pyc", ".pyo", ".tmp"}
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
FRONTMATTER_NAME_RE = re.compile(r"(?m)^name:\s*([^\r\n]+)")
SECRET_PATTERNS = (
    re.compile(b"s" + rb"k-[A-Za-z0-9_-]{16,}"),
    re.compile(rb"Bearer\s+[A-Za-z0-9._-]{16,}", re.IGNORECASE),
    re.compile(b"PRIVATE" + b" KEY-----"),
)


class SyncError(RuntimeError):
    pass


def included_files(folder: Path):
    for path in sorted(folder.rglob("*"), key=lambda item: item.as_posix().lower()):
        if not path.is_file():
            continue
        relative = path.relative_to(folder)
        if any(part in IGNORED_NAMES for part in relative.parts):
            continue
        if path.suffix.lower() in IGNORED_SUFFIXES:
            continue
        yield path, relative


def folder_hash(folder: Path) -> str:
    digest = hashlib.sha256()
    for path, relative in included_files(folder):
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest().upper()


def frontmatter_name(skill_file: Path) -> str:
    text = skill_file.read_text(encoding="utf-8")
    match = FRONTMATTER_NAME_RE.search(text)
    if not match:
        raise SyncError(f"Missing frontmatter name: {skill_file}")
    return match.group(1).strip().strip('"\'')


def resolve_inside(root: Path, relative: str) -> Path:
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as exc:
        raise SyncError(f"Manifest path escapes repository: {relative}") from exc
    return candidate


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def load_manifests(paths: list[Path]):
    ownership = {}
    repositories = []
    for manifest_path in paths:
        manifest_path = manifest_path.resolve()
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        if data.get("schema_version") != 1:
            raise SyncError(f"Unsupported schema_version: {manifest_path}")
        repo_root = manifest_path.parent.parent.resolve()
        declared = set()
        for entry in data.get("skills", []):
            name = entry.get("name", "")
            if not NAME_RE.fullmatch(name):
                raise SyncError(f"Invalid Skill name {name!r} in {manifest_path}")
            if name in ownership:
                raise SyncError(f"Duplicate authority for {name}: {manifest_path}")
            source = resolve_inside(repo_root, entry["path"])
            skill_file = source / "SKILL.md"
            if not skill_file.is_file():
                raise SyncError(f"Missing SKILL.md for {name}: {source}")
            if source.name != name:
                raise SyncError(f"Folder name does not match {name}: {source.name}")
            if frontmatter_name(skill_file) != name:
                raise SyncError(f"Frontmatter name does not match {name}: {skill_file}")
            item = dict(entry)
            item.update(source=source, manifest=manifest_path, repository=data.get("repository"))
            ownership[name] = item
            declared.add(source.resolve())
        repositories.append((repo_root, manifest_path.parent.resolve(), declared))
    return ownership, repositories


def scan_secrets(folder: Path):
    hits = []
    for path, _ in included_files(folder):
        data = path.read_bytes()
        if any(pattern.search(data) for pattern in SECRET_PATTERNS):
            hits.append(path)
    return hits


def audit(paths: list[Path], install_root: Path):
    ownership, repositories = load_manifests(paths)
    rows = []
    for name, entry in sorted(ownership.items()):
        source_hash = folder_hash(entry["source"])
        target = install_root / name
        target_hash = folder_hash(target) if target.is_dir() else None
        expected = entry.get("source_sha256")
        if expected and expected.upper() != source_hash:
            state = "SOURCE_HASH_MISMATCH"
        elif not target.is_dir():
            state = "MISSING"
        elif source_hash == target_hash:
            state = "MATCH"
        else:
            state = "DRIFT"
        rows.append({
            "name": name,
            "repository": entry.get("repository"),
            "state": state,
            "source_sha256": source_hash,
            "installed_sha256": target_hash,
            "source": str(entry["source"]),
            "installed": str(target),
        })

    for repo_root, skills_root, declared in repositories:
        for skill_file in skills_root.glob("*/SKILL.md"):
            folder = skill_file.parent.resolve()
            if folder not in declared:
                rows.append({
                    "name": folder.name,
                    "repository": repo_root.name,
                    "state": "UNMANAGED_SOURCE",
                    "source": str(folder),
                    "installed": None,
                    "source_sha256": folder_hash(folder),
                    "installed_sha256": None,
                })

    if install_root.is_dir():
        for skill_file in install_root.glob("*/SKILL.md"):
            if skill_file.parent.name not in ownership:
                rows.append({
                    "name": skill_file.parent.name,
                    "repository": None,
                    "state": "UNMANAGED_INSTALLED",
                    "source": None,
                    "installed": str(skill_file.parent),
                    "source_sha256": None,
                    "installed_sha256": folder_hash(skill_file.parent),
                })
    return rows, ownership


def print_rows(rows, output_format: str):
    if output_format == "json":
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    print("STATE\tSKILL\tREPOSITORY\tSOURCE_SHA256\tINSTALLED_SHA256")
    for row in rows:
        print("\t".join([
            row["state"],
            row["name"],
            row.get("repository") or "-",
            (row.get("source_sha256") or "-")[:12],
            (row.get("installed_sha256") or "-")[:12],
        ]))


def write_json_atomic(path: Path, data: dict):
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
        delete=False,
    )
    temporary = Path(handle.name)
    try:
        with handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def refresh_manifests(paths: list[Path], apply: bool) -> int:
    ownership, _ = load_manifests(paths)
    updates_by_manifest: dict[Path, dict[str, str]] = {}
    for name, entry in sorted(ownership.items()):
        source_hash = folder_hash(entry["source"])
        expected = entry.get("source_sha256", "").upper()
        if expected == source_hash:
            continue
        secret_hits = scan_secrets(entry["source"])
        if secret_hits:
            raise SyncError(f"Secret-like content in {name}: {secret_hits}")
        updates_by_manifest.setdefault(entry["manifest"], {})[name] = source_hash
        action = "REFRESH" if apply else "REFRESH_DRY_RUN"
        print(f"{action}\t{name}\t{expected or '-'}\t{source_hash}")

    if apply:
        for manifest_path, updates in updates_by_manifest.items():
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            for entry in data.get("skills", []):
                if entry.get("name") in updates:
                    entry["source_sha256"] = updates[entry["name"]]
            write_json_atomic(manifest_path, data)

    if not updates_by_manifest:
        print("REFRESH\tNO_CHANGES")
    return sum(len(updates) for updates in updates_by_manifest.values())


def deploy(rows, ownership, install_root: Path, apply: bool, replace: bool, backup_root: Path | None):
    protected = {"DRIFT", "SOURCE_HASH_MISMATCH"}
    if replace and not backup_root:
        raise SyncError("--replace requires --backup-root")
    for row in rows:
        if row["name"] not in ownership:
            continue
        entry = ownership[row["name"]]
        if not entry.get("deploy", True):
            continue
        state = row["state"]
        if state == "MATCH":
            continue
        if state in protected and not replace:
            print(f"PROTECTED\t{row['name']}\t{state}")
            continue
        if state not in {"MISSING", "DRIFT"}:
            print(f"SKIP\t{row['name']}\t{state}")
            continue
        secret_hits = scan_secrets(entry["source"])
        if secret_hits:
            raise SyncError(f"Secret-like content in {row['name']}: {secret_hits}")
        target = install_root / row["name"]
        action = "REPLACE" if target.exists() else "INSTALL"
        print(f"{action}{'' if apply else '_DRY_RUN'}\t{row['name']}\t{target}")
        if not apply:
            continue
        install_root.mkdir(parents=True, exist_ok=True)
        if target.exists():
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            backup_root.mkdir(parents=True, exist_ok=True)
            backup = backup_root / f"{row['name']}-{stamp}"
            if backup.exists():
                raise SyncError(f"Backup destination exists: {backup}")
            shutil.move(str(target), str(backup))
        shutil.copytree(entry["source"], target)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("audit", "refresh", "deploy"))
    parser.add_argument("--manifest", action="append", type=Path)
    parser.add_argument("--install-root", type=Path)
    parser.add_argument("--format", choices=("table", "json"), default="table")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--backup-root", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest_args = args.manifest
    if not manifest_args:
        raw = os.environ.get("CODEX_SKILL_MANIFESTS", "")
        manifest_args = [Path(item) for item in raw.split(os.pathsep) if item]
    if not manifest_args:
        raise SyncError("Provide --manifest or CODEX_SKILL_MANIFESTS")

    if args.command == "refresh":
        changed = refresh_manifests(manifest_args, args.apply)
        if args.strict and changed:
            return 2
        return 0

    install_root = (args.install_root or Path(os.environ.get("CODEX_SKILLS_ROOT", Path.home() / ".codex" / "skills"))).resolve()
    if install_root in {Path.home().resolve(), Path(install_root.anchor).resolve()}:
        raise SyncError(f"Unsafe install root: {install_root}")
    rows, ownership = audit(manifest_args, install_root)
    repository_roots = {entry["manifest"].parent.parent.resolve() for entry in ownership.values()}
    if any(is_within(install_root, root) or is_within(root, install_root) for root in repository_roots):
        raise SyncError(f"Install root overlaps an authoritative repository: {install_root}")
    print_rows(rows, args.format)
    if args.command == "deploy":
        deploy(rows, ownership, install_root, args.apply, args.replace, args.backup_root)
    if args.strict and any(row["state"] != "MATCH" for row in rows):
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, SyncError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
