# PyroWave Metal source and GPU analysis, September 30, 2026

This follow-up investigates GPU execution separately from the CPU preparation,
network assembly and confirmed presentation intervals in the
[native decoder report](pyrowave-decoder-latency-2026-09-30.md). The measured live
GPU interval was approximately 1.87 ms on an Apple M3 at 3440 × 1440, HDR10,
4:4:4. CPU parsing and network latency cannot explain that GPU interval.

## Upstream benchmark context

The [upstream README](https://github.com/Themaister/pyrowave) gives approximate
sub-0.1 ms 1080p and sub-0.2 ms 4K encode/decode figures for its Vulkan
implementation. It does not identify a GPU, bit depth, chroma format, precision
or measurement procedure. The claim predates the Metal port.

The author's [June 2025 article](https://themaister.net/blog/2025/06/16/i-designed-my-own-ridiculously-fast-game-streaming-video-codec-pyrowave/)
identifies RX 9070 XT/RADV, 1080p 4:2:0 and under 100 microseconds for decoding.
It discusses packed FP16 arithmetic. A [September 2026 author comment](https://github.com/Themaister/pyrowave/issues/2#issuecomment-5877681909)
reports about 6,000 GPU decode FPS for 4K 4:4:4 on RX 9070 XT, equivalent to
about 0.167 ms. Depth, precision and measurement procedure are unspecified in
that comment. Chroma alone therefore cannot dismiss our GPU performance gap.

Current [bench.cpp](https://github.com/Themaister/pyrowave/blob/89f7e47d4abbf650c91fae766728af866c5e32a0/bench.cpp)
repeats decoding of one encoded Y4M frame 10,000 times. GPU timestamps surround
the Vulkan decode commands; CPU parsing, queue waiting and display are outside
that interval. This documents the current benchmark, not the original 2025
measurement method: decode timing was added in July 2026.

The [Metal port notes](https://github.com/Themaister/pyrowave/blob/89f7e47d4abbf650c91fae766728af866c5e32a0/metal/README.md)
describe a basic port and recommend FP32 arithmetic with FP16 storage. They
provide no absolute Apple GPU timing. Current upstream `89f7e47d` and our pinned
`186f0393` have identical relevant decoder and shader files. Download hashes and
exact source references are preserved under the ignored
`artifacts/pyrowave-stage-2026-09-30/upstream-reference/` directory.

## Source findings

The production decoder has two compute encoders: dequantization, then five
dependent inverse-wavelet levels. At 4:4:4 it dispatches dequantization 48 times
and synthesis 15 times. Components are independent within a level and already
use concurrent dispatch; four texture barriers preserve dependencies between
synthesis levels. Vulkan's compute path has the same dispatch counts.

The default synthesis kernel uses 64 threads for a 32 × 32 output tile. Each
thread carries up to sixteen `float2` intermediate values. A 20 × 41 `half2`
threadgroup array supports the apron and transpose operations. Texture gathers,
FP32 lifting operations, intermediate half conversion and threadgroup barriers
remain in the generated MSL. This is a candidate for Apple-specific scheduling,
not proof of register spills or low occupancy.

Proven implementation differences and testable candidates:

| Candidate | Concrete source change | Expected benefit and constraint |
| --- | --- | --- |
| Pipeline compiler limits | Set the actual 64/128-thread maximum and SIMD-multiple guarantee in `create_pipeline` | Apple documents additional compiler optimizations. Dispatch and arithmetic remain identical; benefit must be measured. |
| Dequant batching | Dispatch component/band records through a metadata table and grid Z, grouping each level | Could reduce 48 dispatches to five. Concurrent encoding already overlaps independent work, so dispatch count alone does not predict savings. |
| Typed payload loads | Compare Metal texture-buffer loads with the existing byte-buffer path | Vulkan selects typed texel-buffer/linear-image alternatives on some devices; Metal currently transpiles only the plain buffer variant. Prioritize if dequantization dominates. |
| Native synthesis scheduling | Reduce live temporaries, shared-memory transposes and apron overhead while retaining precision and edge rules | Targets the large inverse-wavelet work. Requires pixel comparisons on partial tiles, 4:2:0/4:4:4, R8/R16 and partial-loss inputs. |
| Final synthesis/render fusion | Avoid writing three full-resolution planes that the renderer immediately reads | At 3440 × 1440 R16/4:4:4, those writes plus reads account for about 59.4 MB of logical traffic per frame. Requires deliberate ownership, color and scaling integration; measure total latency because work moves across stage boundaries. |

Relevant Apple documentation:
[maximum threadgroup size](https://developer.apple.com/documentation/metal/mtlcomputepipelinedescriptor/maxtotalthreadsperthreadgroup),
[SIMD-multiple guarantee](https://developer.apple.com/documentation/metal/mtlcomputepipelinedescriptor/threadgroupsizeismultipleofthreadexecutionwidth).
Neither proves that the current decoder is bandwidth- or occupancy-bound.

Packing four bands into RGBA16Float could improve addressing locality, but
does not reduce coefficient bytes or automatically reduce texture instructions.
It also complicates producers: independent dequant dispatches cannot safely
write separate channels of the same texel. Intermediate synthesis currently
updates only a two-byte LL slice. Preserving the other packed channels through
read/modify/write would add about 69.4 MB of nominal traffic across the four
intermediate levels at the aligned current geometry. A separate LL resource
avoids that cost but requires additional source reads. This is not an obvious
replacement for the existing layout without a measured producer/consumer design.

The retained production decoder uses FP32 arithmetic with FP16 storage. An
earlier apron barrier removal preserved pixels but gave no repeatable GPU gain
and was restored. No alternate precision, shader rewrite or renderer fusion has
been promoted on the basis of source inspection alone.

## Measurement boundaries

The stage profiler is an ignored native benchmark that includes the production
vendor decoder. Public Metal timestamp counters require an encoder boundary on
this Apple M3, so profiling each synthesis level adds four encoder boundaries.
Its stage timings diagnose the work distribution; they do not replace timings
from the unmodified two-encoder decoder. Original and experimental pipelines run
alternately in one process on the same legal input, followed by exact plane
readback comparisons. GPU completion and readback are synchronous only in this
benchmark, never in production presentation.

System-wide AGX device utilization does not measure shader occupancy or assign
work to this decoder. The earlier 71.9% live sample cannot establish how much
parallelism or memory bandwidth a particular synthesis kernel leaves unused.
Offscreen measurements do not establish live presentation, physical scanout,
HDR appearance or physical-device mobile acceptance.

## Initial GPU measurements

The quiet offscreen benchmark alternated the unmodified two-encoder decoder
with the six-encoder stage profiler. After ten warmup pairs, each variant ran
120 times for the 3440 × 1440 profile; other geometry runs used 240 or 480
samples per variant. All three output planes matched exactly. Input was a legal
synthetic coefficient stream capped at 1 MB, not the author's source video.

| GPU interval, 3440 × 1440 4:4:4/R16 | Median |
| --- | ---: |
| Unmodified decoder | 1.292 ms |
| Profiled decoder with four additional encoder boundaries | 1.301 ms |
| Dequantization | 0.350 ms |
| Inverse-wavelet level 4, coarsest | 0.009 ms |
| Inverse-wavelet level 3 | 0.018 ms |
| Inverse-wavelet level 2 | 0.059 ms |
| Inverse-wavelet level 1 | 0.186 ms |
| Inverse-wavelet level 0, full resolution | 0.667 ms |

Medians of separate intervals need not add to the total median. Here they locate
the dominant work: full-resolution synthesis is roughly half the GPU interval,
and dequantization roughly a quarter. Small coarse-level dispatch overhead alone
cannot explain or remove the gap. The profile overhead was small in this run;
unmodified command-buffer duration remains the comparison metric.

The descriptor-hint candidate compiled with actual maximum threadgroup sizes
128/64 rather than the reference pipelines' reported 1,024. All pipelines had
32-wide execution. Alternating original and hinted pipelines on the same
3440 × 1440 input produced 1.279/1.284 ms median, p95 1.795/1.829 ms, with exact
output planes. It was not promoted because it did not improve GPU execution.

Additional original-pipeline runs measured 0.308 ms at 1920 × 1080 4:2:0/R8 and
1.912 ms at 3840 × 2160 4:4:4/R8. These measurements establish scaling on this
M3 with the same synthetic input generator and 1 MB cap; they are not a matched
reproduction of upstream's Radeon benchmark.

A 500 KB cap, matching current upstream's encoded-byte target, measured
0.274 ms at 1080p 4:2:0/R8. Its dequantization median was 0.085 ms and the
full-resolution synthesis pass 0.087 ms. At 4K 4:4:4/R8 the 500 KB run measured
1.999 ms total, 0.604 ms dequantization and 0.955 ms final synthesis. The fixture
content and GPU remain different from the author’s benchmark. Reducing the byte
target does not remove the full image-sized synthesis work.

Full FP16 arithmetic was also compared with default FP32 arithmetic/FP16
storage using 480 alternating pairs at 3440 × 1440 4:4:4/R16. Original/full-FP16
medians were 1.2785/1.2740 ms, a difference of about 0.35%, without a material
GPU improvement. Roughly 2.67–2.99 million pixels differed in each output plane
on the legal stress input; maximum R16Unorm code differences were 3,618–4,128.
This stress fixture is not a picture-quality assessment of host content, but it
demonstrates that the precision change is not bit-equivalent. It was not
promoted.

An interior-tile loader reused one coordinate calculation for all four band
gathers. A group-uniform condition required the complete 20 × 20 input tile to
lie inside the image; edge and small-level tiles retained the original
parity-dependent mirror calculation. The four gathers, their swizzle, shared
storage, lifting operations and barriers were unchanged. About 94% of final
tiles at 3440 × 1440 satisfy the interior condition. Nevertheless, 480 paired
samples measured 1.27900/1.28087 ms median for original/candidate, with exact
planes. It was not promoted because it gave no GPU improvement.

Exact equality also passed fourteen small/edge cases: 2 × 2, 128 × 98 and
130 × 34 at 4:2:0; 1 × 1, 127 × 97, 130 × 65 and 128 × 128 at 4:4:4; each in
R8 and R16. Odd-sized 4:2:0 inputs were rejected by the unchanged production
geometry validator before GPU work. Raw logs and source fingerprints are listed
in `.build-pyrowave/metal-stage-profile/README.md` and `SHA256SUMS` in the decoder
checkout. Production shader, pipeline creation and scheduling sources still
match the preserved stage-only baseline exactly.

## Next implementation priorities

The tested small changes did not improve execution. Further work should address
the measured large stages rather than accumulating unmeasured shader changes:

1. Prototype an Apple-specific final synthesis kernel with fewer live
   intermediates and less shared-memory transpose traffic. SIMD shuffles are
   not a direct replacement: the present 64-thread tile spans two SIMD groups,
   and the second transform requires values from both. Any redesign must retain
   cross-group synchronization, mirror parity and the present arithmetic/storage
   precision. Measure the unchanged total decoder and compare planes before
   promoting it.
2. Batch dequantization bands/components and test typed payload loads. This
   targets the measured approximately 0.35 ms dequant stage. Vulkan has the same
   dispatch counts, so batching is an Apple experiment rather than an explanation
   of the entire Vulkan/Metal difference.
3. Evaluate final synthesis/render fusion as a larger pipeline change. Its
   potential is reducing intermediate plane traffic and scheduling handoff, but
   it requires integration with drawable acquisition, decoded-frame selection,
   texture leases, scaling and HDR color conversion. Assess confirmed
   first-packet-to-presentation and cadence together; a shorter reported decode
   interval caused by moving work into rendering is not a latency improvement.

No sub-0.2 ms M3 result or speedup from these larger candidates has been
demonstrated. The current 1.29 ms quiet offscreen result is an observed baseline,
not a hardware lower bound. The live approximately 1.87 ms interval remains the
relevant application measurement until a candidate passes a matched live run.

Profiler source, build output and raw measurement logs are preserved in the
decoder checkout's ignored `.build-pyrowave/metal-stage-profile/` directory. No
production shader or pipeline change resulted from these measurements.
