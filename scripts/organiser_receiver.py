#!/usr/bin/env python3
"""Development-only local spool receiver. No networking, URL fetching or execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time
import uuid
from datetime import datetime, timezone

MAX_MANIFEST = 2 * 1024 * 1024
MAX_ATTACHMENT = 64 * 1024 * 1024

class Rejected(ValueError):
    pass

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")

def digest(data):
    return hashlib.sha256(data).hexdigest()

def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", value):
        raise Rejected("invalid_identity")
    uuid.UUID(value)
    return value

def relative(path):
    if not isinstance(path, str) or len(path.encode()) > 4096 or "\\" in path or "\0" in path or any(p in ("", ".", "..") for p in path.split("/")):
        raise Rejected("unsafe_path")
    return path

def safe_read(root, path, limit):
    parts = relative(path).split("/")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        file = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            before = os.fstat(file)
            if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
                raise Rejected("file_limit_or_type")
            chunks, size = [], 0
            while chunk := os.read(file, 65536):
                size += len(chunk)
                if size > limit:
                    raise Rejected("file_limit")
                chunks.append(chunk)
            after = os.fstat(file)
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise Rejected("file_changed")
            return b"".join(chunks)
        finally:
            os.close(file)
    finally:
        os.close(fd)

def private_directory(path):
    path = Path(path)
    if not path.exists():
        private_directory(path.parent.resolve())
        path.mkdir(mode=0o700)
        sync_directory(path.parent)
    if path.is_symlink() or not path.is_dir():
        raise Rejected("unsafe_directory")

def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def durable_write(path, data):
    path = Path(path)
    private_directory(path.parent)
    temp = path.parent / (".write-" + str(uuid.uuid4()))
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(data)
            output.flush()
        os.fsync(fd)
        if os.uname().sysname == "Darwin":
            import fcntl
            fcntl.fcntl(fd, 51)  # macOS F_FULLFSYNC
    finally:
        os.close(fd)
    os.replace(temp, path)
    sync_directory(path.parent)

def parse_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Rejected("duplicate_key")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(Rejected("invalid_number")))
    except (ValueError, RecursionError, UnicodeError) as error:
        raise Rejected("invalid_json") from error

def validate(request, workspace):
    try:
        p = request["payload"]
        c = p["capture"]
        if type(c["schema_version"]) is not int or c["schema_version"] != 1:
            raise Rejected("unsupported_version")
        def fields(value, required, optional=()):
            if not isinstance(value, dict) or not set(required) <= value.keys() or not value.keys() <= set(required) | set(optional):
                raise Rejected("invalid_fields")
        fields(request, ("payload", "payload_sha256"))
        fields(p, ("workspace_id", "operation_id", "capture"))
        fields(c, ("schema_version", "capture_id", "created_at", "source", "body_markdown", "attachments", "omitted_attachments"), ("title", "source_url", "kind_hint"))
        fields(c["source"], ("app", "version", "installation_id"))
        if identifier(p["workspace_id"]) != workspace:
            raise Rejected("wrong_workspace")
        identifier(p["operation_id"]); identifier(c["capture_id"])
        identifier(c["source"]["installation_id"])
        if c["source"]["app"] != "Quick Capture" or len(c["source"]["version"].encode()) > 128:
            raise Rejected("invalid_source")
        if not c["created_at"].endswith("Z") and not re.search(r"[+-]\d\d:\d\d$", c["created_at"]):
            raise Rejected("invalid_timestamp")
        datetime.fromisoformat(c["created_at"].replace("Z", "+00:00"))
        body = c["body_markdown"]
        if not isinstance(body, str) or len(body.encode()) > 1048576:
            raise Rejected("body_limit")
        if not body and not c.get("source_url") and not c["attachments"]:
            raise Rejected("empty_capture")
        if "kind_hint" in c and c["kind_hint"] not in ("note", "task", "link", "document"):
            raise Rejected("invalid_kind")
        for key, limit in (("title", 4096), ("source_url", 8192)):
            if key in c and (not isinstance(c[key], str) or len(c[key].encode()) > limit):
                raise Rejected("metadata_limit")
        if not isinstance(c["attachments"], list) or not isinstance(c["omitted_attachments"], list):
            raise Rejected("invalid_attachment_collection")
        if len(c["attachments"]) > 16 or len(c["omitted_attachments"]) > 16:
            raise Rejected("attachment_limit")
        seen_paths, seen_ids, seen_sources, total = set(), set(), set(), 0
        for a in c["attachments"]:
            fields(a, ("attachment_id", "relative_path", "source_path", "original_name", "media_type", "byte_count", "sha256"))
            path = relative(a["relative_path"])
            source = relative(a["source_path"])
            aid = identifier(a["attachment_id"])
            if not path.startswith("attachments/") or len(path.split("/")) != 2 or path in seen_paths or aid in seen_ids or source in seen_sources:
                raise Rejected("attachment_identity")
            seen_paths.add(path); seen_ids.add(aid); seen_sources.add(source)
            size = a["byte_count"]
            if type(size) is not int or not 0 <= size <= MAX_ATTACHMENT:
                raise Rejected("attachment_limit")
            if len(a["original_name"].encode()) > 1024 or len(a["media_type"].encode()) > 128 or not re.fullmatch("[0-9a-f]{64}", a["sha256"]):
                raise Rejected("invalid_attachment")
            total += size
        if total > 128 * 1024 * 1024:
            raise Rejected("attachment_limit")
        if len(set(c["omitted_attachments"])) != len(c["omitted_attachments"]):
            raise Rejected("invalid_omission")
        for path in c["omitted_attachments"]:
            if relative(path) in seen_sources:
                raise Rejected("invalid_omission")
        if request["payload_sha256"] != digest(canonical(p)):
            raise Rejected("digest_mismatch")
        return p, c
    except (KeyError, TypeError, AttributeError, ValueError) as error:
        if isinstance(error, Rejected):
            raise
        raise Rejected("invalid_payload") from error

class Receiver:
    def __init__(self, spool, storage, workspace):
        self.spool, self.storage, self.workspace = Path(spool), Path(storage), identifier(workspace)
        for path in (self.spool, self.storage, self.spool / "requests", self.spool / "receipts", self.spool / "errors", self.storage / "items"):
            private_directory(path)
        capabilities = {"schema_version": 1, "workspace_id": workspace, "durable_receipts": True}
        cap_file = self.spool / "capabilities.json"
        if cap_file.exists() and parse_json(safe_read(self.spool, "capabilities.json", 4096)) != capabilities:
            raise Rejected("spool_destination_conflict")
        durable_write(cap_file, canonical(capabilities))
        self.db = sqlite3.connect(self.storage / "receiver.sqlite", timeout=5)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA fullfsync=ON")
        self.db.execute("CREATE TABLE IF NOT EXISTS accepted(workspace TEXT, capture TEXT, operation TEXT, digest TEXT, receipt BLOB, item_path TEXT, deleted INTEGER DEFAULT 0, PRIMARY KEY(workspace,capture), UNIQUE(workspace,operation))")
        os.chmod(self.storage / "receiver.sqlite", 0o600)

    def accept(self, bundle, fault=None):
        request = parse_json(safe_read(bundle, "request.json", MAX_MANIFEST))
        p, c = validate(request, self.workspace)
        if Path(bundle).name != c["capture_id"]:
            raise Rejected("bundle_identity")
        # Deduplication is checked in the same write transaction as acceptance.
        self.db.execute("BEGIN IMMEDIATE")
        try:
            prior = self.db.execute("SELECT digest,receipt FROM accepted WHERE workspace=? AND (capture=? OR operation=?)", (self.workspace, c["capture_id"], p["operation_id"])).fetchone()
            if prior:
                if prior[0] != request["payload_sha256"]:
                    raise Rejected("conflict")
                receipt_bytes = prior[1]
            else:
                content = safe_read(bundle, "content.md", 1048576)
                if content != c["body_markdown"].encode():
                    raise Rejected("content_mismatch")
                item_id = str(uuid.uuid4())
                item_path = self.storage / "items" / item_id
                private_directory(item_path)
                for a in c["attachments"]:
                    data = safe_read(bundle, a["relative_path"], MAX_ATTACHMENT)
                    if len(data) != a["byte_count"] or digest(data) != a["sha256"]:
                        raise Rejected("corrupt_attachment")
                    durable_write(item_path / a["relative_path"], data)
                durable_write(item_path / "content.md", content)
                durable_write(item_path / "request.json", canonical(request))
                sync_directory(item_path); sync_directory(item_path.parent)
                receipt = {"schema_version": 1, "workspace_id": self.workspace, "operation_id": p["operation_id"], "capture_id": c["capture_id"], "organiser_item_id": item_id, "payload_sha256": request["payload_sha256"], "accepted_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")}
                receipt_bytes = canonical(receipt)
                self.db.execute("INSERT INTO accepted(workspace,capture,operation,digest,receipt,item_path) VALUES(?,?,?,?,?,?)", (self.workspace, c["capture_id"], p["operation_id"], request["payload_sha256"], receipt_bytes, str(item_path)))
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        if fault:
            fault("committed")
        durable_write(self.spool / "receipts" / (c["capture_id"] + ".json"), receipt_bytes)
        return parse_json(receipt_bytes)

    def once(self):
        for bundle in sorted((self.spool / "requests").iterdir()):
            if bundle.name.startswith("."):
                continue
            try:
                identifier(bundle.name)
                self.accept(bundle)
            except (Rejected, OSError, ValueError) as error:
                # Never print body text, filenames, paths or the raw exception.
                print("receiver_rejected", flush=True)
                try:
                    identifier(bundle.name)
                    request = parse_json(safe_read(bundle, "request.json", MAX_MANIFEST))
                    code = str(error) if isinstance(error, Rejected) else "io_error"
                    durable_write(self.spool / "errors" / (bundle.name + ".json"), canonical({"code": code, "payload_sha256": request.get("payload_sha256", "")}))
                except (OSError, ValueError, AttributeError):
                    pass

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spool", required=True, type=Path)
    parser.add_argument("--storage", required=True, type=Path)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    receiver = Receiver(args.spool, args.storage, args.workspace)
    while True:
        receiver.once()
        if args.once:
            return
        time.sleep(1)

if __name__ == "__main__":
    main()
