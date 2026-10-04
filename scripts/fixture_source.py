"""Record fixture decoder inputs from the monorepo or a historical checkout."""
import hashlib
from pathlib import Path
import subprocess


def git(directory, *arguments):
    return subprocess.check_output(["git", "-C", str(directory), *arguments])


def source_files(directory):
    # Git's ignore rules exclude generated binaries, fixtures and build caches.
    # Include untracked sources so an in-progress monorepo import is identified
    # by its actual contents rather than only the previous repository commit.
    names = git(directory, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", ".")
    for name in sorted(set(names.split(b"\0")) - {b""}):
        source = directory / name.decode()
        if source.is_dir():
            # A gitlink is a source input too. Hash its files using that
            # submodule's ignore rules; an uninitialized gitlink must fail.
            root = Path(git(source, "rev-parse", "--show-toplevel").decode().strip())
            if root.resolve() != source.resolve():
                raise ValueError(f"Initialize decoder source submodule: {source}")
            yield from source_files(source)
        else:
            yield source


def decoder_provenance(decoder, monorepo_decoder, standalone_revision):
    decoder = decoder.resolve()
    revision = git(decoder, "rev-parse", "HEAD").decode().strip()
    if decoder != monorepo_decoder.resolve() and revision != standalone_revision:
        raise ValueError(f"Standalone decoder fixture source must be pinned to {standalone_revision}, found {revision}")
    repository = Path(git(decoder, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    digest = hashlib.sha256()
    files = sorted(source_files(decoder), key=lambda path: path.relative_to(decoder).as_posix())
    if not files:
        raise ValueError(f"No decoder sources found at {decoder}")
    for source in files:
        digest.update(source.relative_to(decoder).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(source.read_bytes()).digest())
    return {"decoder_revision": revision,
            "decoder_source_path": decoder.relative_to(repository).as_posix(),
            "decoder_source_sha256": digest.hexdigest()}
