# Decoder source import

This directory contains the first-party decoder formerly maintained in
[`NickMagic25/moonlight-apple-decoder`](https://github.com/NickMagic25/moonlight-apple-decoder),
imported on October 4, 2026 from commit
`dd295065417344a0a5d3d240bce9060d2646851c` (`codex/pyrowave`).

The import includes all tracked source, headers, tests, tools, scripts, example
code, benchmark configurations, documentation, historical evidence and license
notices. The two GitHub workflows now live in Swiftlight's root
`.github/workflows`. Repository metadata and ignored build outputs were excluded.
The original repository retains the pre-import Git history.

Swiftlight uses this directory as a local Swift package. CMake consumers can
continue to build it independently. New decoder changes belong in this monorepo
and use Swiftlight's commit history; there is no separate decoder revision to
publish or resolve.

The decoder's PyroWave submodule retains revision
`488564aa2b5ffca0377938c27a1b67fce817c5b9`. Swiftlight's direct PyroWave bridge
has its own submodule and revision. Both are registered in the monorepo's root
`.gitmodules` and verified by dependency bootstrap.
