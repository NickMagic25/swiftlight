#!/usr/bin/env python3
"""Build a reproducible patched source tree from pinned public Git sources."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Dependencies/versions.json"
PATCHES = ROOT / "patches/moonlight-common-c"
OUTPUT = ROOT / "Sources/CStreamBridge/vendor/common-c"
CACHE = ROOT / ".build/dependency-sources/moonlight-common-c"
STAMP = ".swiftlight-source.json"


def git(directory, *arguments):
    return subprocess.check_output(["git", "-C", str(directory), *arguments], stderr=subprocess.PIPE)


def initialized(directory):
    try:
        return Path(git(directory, "rev-parse", "--show-toplevel").decode().strip()).resolve() == directory.resolve()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def verify_checkout(directory, revision):
    actual = git(directory, "rev-parse", "HEAD").decode().strip()
    if actual != revision:
        raise RuntimeError(f"{directory}: expected {revision}, found {actual}")
    if git(directory, "status", "--porcelain", "--untracked-files=no").strip():
        raise RuntimeError(f"{directory} has modified tracked content; keep upstream pristine and put changes in {PATCHES}")


def clone_checkout(directory, url, revision):
    directory.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "git", "clone", "--no-checkout", "--filter=blob:none", "--no-tags", url, str(directory)
    ], check=True)
    subprocess.run(["git", "-C", str(directory), "checkout", "--detach", "--quiet", revision], check=True)
    verify_checkout(directory, revision)


def ensure_checkout(directory, url, revision):
    if initialized(directory):
        verify_checkout(directory, revision)
        return
    if directory.exists():
        raise RuntimeError(f"{directory} exists but is not a Git checkout; remove it before preparing common-c")
    clone_checkout(directory, url, revision)


def nested_checkout(root, relative_path, source):
    directory = (root / relative_path).resolve()
    if not directory.is_relative_to(root.resolve()):
        raise RuntimeError(f"Nested source path escapes common-c checkout: {relative_path}")
    ensure_checkout(directory, source["url"], source["revision"])
    return directory


def archive(directory, destination):
    # Only committed files enter the generated tree. Never copy .git pointers or local files.
    with tarfile.open(fileobj=io.BytesIO(git(directory, "archive", "--format=tar", "HEAD"))) as bundle:
        for entry in bundle:
            path = destination / entry.name
            if not path.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError(f"Unsafe upstream archive path: {entry.name}")
            if entry.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(entry) as source, path.open("wb") as target:
                    shutil.copyfileobj(source, target)
                path.chmod(entry.mode & 0o777)
            else:
                raise RuntimeError(f"Unexpected upstream archive entry: {entry.name}")


def tree_digest(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise RuntimeError(f"Unexpected generated source symlink: {path}")
        if path.is_file() and path.name != STAMP:
            digest.update(path.relative_to(directory).as_posix().encode() + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def main():
    lock = json.loads(LOCK.read_text())["moonlight-common-c"]
    upstream = CACHE
    ensure_checkout(upstream, lock["url"], lock["revision"])
    checkouts = [(upstream, lock["revision"])]
    for path, source in lock["submodules"].items():
        checkouts.append((nested_checkout(upstream, path, source), source["revision"]))
    for path, revision in reversed(checkouts):
        verify_checkout(path, revision)

    series = [line.strip() for line in (PATCHES / "series").read_text().splitlines()
              if line.strip() and not line.lstrip().startswith("#")]
    if not series or len(series) != len(set(series)):
        raise RuntimeError("The common-c patch series must be nonempty and contain no duplicates")
    if set(series) != {path.name for path in PATCHES.glob("*.patch")}:
        raise RuntimeError("Every common-c .patch file must appear exactly once in series")
    patch_paths = []
    digest = hashlib.sha256(LOCK.read_bytes() + Path(__file__).read_bytes())
    for name in series:
        if Path(name).name != name:
            raise RuntimeError(f"Patch must be a filename: {name}")
        patch = PATCHES / name
        digest.update(name.encode() + b"\0" + patch.read_bytes())
        patch_paths.append(patch)
    preparation = digest.hexdigest()
    stamp = OUTPUT / STAMP
    if stamp.exists():
        recorded = json.loads(stamp.read_text())
        if recorded.get("preparation_sha256") == preparation and recorded.get("source_sha256") == tree_digest(OUTPUT):
            print(f"common-c {lock['revision'][:12]}: pinned sources and {len(series)} patches verified")
            return

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".common-c-", dir=OUTPUT.parent) as temporary:
        prepared = Path(temporary) / "common-c"
        prepared.mkdir()
        archive(upstream, prepared)
        for path in lock["submodules"]:
            archive(upstream / path, prepared / path)
        # Stop repository discovery above the generated tree so git apply uses these paths.
        # --unsafe-paths is deliberately absent: patch paths must remain inside it.
        patch_environment = dict(os.environ, GIT_CEILING_DIRECTORIES=str(OUTPUT.parent))
        for patch in patch_paths:
            subprocess.run(["git", "apply", "--check", str(patch)], cwd=prepared, env=patch_environment, check=True)
            subprocess.run(["git", "apply", str(patch)], cwd=prepared, env=patch_environment, check=True)
        (prepared / STAMP).write_text(json.dumps({
            "revision": lock["revision"], "submodules": lock["submodules"], "patches": series,
            "preparation_sha256": preparation, "source_sha256": tree_digest(prepared)
        }, indent=2) + "\n")
        # Replace only generated output after all checks succeeded. Failed patches preserve it.
        if OUTPUT.exists():
            OUTPUT.rename(Path(temporary) / "previous")
        prepared.rename(OUTPUT)
    print(f"common-c {lock['revision'][:12]}: prepared pinned sources with {len(series)} targeted patches")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"common-c preparation failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)
