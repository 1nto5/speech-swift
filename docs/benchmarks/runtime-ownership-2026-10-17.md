# Runtime ownership regression and performance verification

The ownership changes were compared with `53510fb99661942b952184c1a744dcedc0a8fdb3`
on an Apple M5 Pro with 48 GiB of memory, macOS 26.6.2 and Swift 6.4.
The candidate contains the runtime ownership changes described below. No weights,
quantization settings or decoding defaults were changed.

## Issues found during verification

- Strict Swift 6 code generation rejected the inference gate's private waiter
  in the cancellation handler. Its mutable fields are protected by the gate's
  lock; an explicit `@unchecked Sendable` declaration documents that invariant.
  The production sources now compile and run under Thread Sanitizer.
- Repeated managed CoreML calls from one background task retained autoreleased
  scratch buffers. A 16-request probe grew from 879 MiB after warm-up to
  2,495 MiB. The adapter now wraps each synchronous inference in an
  `autoreleasepool`, matching the existing native CoreML benchmark's policy.
  A real-weight regression test checks memory growth over 12 repeated requests
  after three warm-up requests, with a 256 MiB allowance for allocator noise.

## Measurement method

Each model run uses its own process, cached weights in offline mode and a
release build with the compiled MLX metallib. Heavy builds, tests and model
measurements run sequentially. Both variants execute on a background task at
`userInitiated` priority. Native CoreML calls use the same per-utterance
autorelease-pool policy as `EngineQwen3CoreML` in `asr-bench`.

The dataset contains the first 20 English and first 20 French clips from the
cached `kyutai-fleurs-float-80` manifests: 40 unique utterances and 427.280
seconds of audio. Audio is decoded to 16 kHz before timing. Both paths use
automatic language detection and their existing default decoding parameters.

After two warm-up transcriptions, each process transcribes the dataset twice.
Timing statistics use the final pass. The order is baseline A, managed A,
managed B, baseline B, then a native control built from the changed sources.
Each baseline/managed group therefore contains 80 warm timing samples and
160 exact transcript comparisons across both passes. WER uses the repository's
`Normalizer` and `WER` implementations. Weighted RTF is total inference wall
time divided by total audio duration; lower is faster.

The first exploratory batch showed substantial timing drift after compilation
and exposed the native caller's autorelease-pool behavior. Those files are
retained under `conditioning/` and excluded from the final comparison.

## Results

No transcript regression or material single-request slowdown was observed in
the measured paths. Both backends produced identical text in all 320 paired
baseline/managed comparisons. The native control built from the changed
sources retained the same WER as the original build.

| Model | Baseline weighted RTF | Managed weighted RTF | Change | Baseline / managed WER |
|---|---:|---:|---:|---:|
| Qwen3-ASR 0.6B MLX INT4 | 0.01378 | 0.01334 | -3.2% | 11.936% / 11.936% |
| Qwen3-ASR full CoreML | 0.13174 | 0.13134 | -0.3% | 7.237% / 7.237% |

The MLX native control's weighted RTF was 0.01380, and the CoreML native
control's was 0.13198. Small differences do not establish an inference
optimization or performance guarantee on other hardware. The two WER values
describe different existing backends on this subset; this is not a quality
ranking of the backends.

Peak physical footprint was 7,834 MiB before and 7,856 MiB after for MLX
(+0.28%). CoreML peaks were 1,354 MiB and 1,257 MiB respectively. Current
footprint at the end of the two 80-request managed runs was 705 MiB and
1,022 MiB. Those readings include allocator and framework-cache variation;
the kernel-recorded peak remained 1,257 MiB across the managed runs.

The same 16-request background probe that exposed the memory issue was
repeated after the fix. Its footprint growth fell from 1,616 MiB to 102 MiB,
with identical transcripts. The fixed probe's footprint rose and fell within
the workload rather than increasing with every request; model/graph caches
still account for part of the process footprint.

| Live API check | Baseline median | Changed median | Samples per version |
|---|---:|---:|---:|
| HTTP MLX transcription | 95.48 ms | 95.36 ms | 12 |
| WebSocket MLX transcription | 97.14 ms | 97.22 ms | 12 |
| HTTP Kokoro synthesis | 86.43 ms | 87.30 ms | 4 |
| WebSocket Kokoro synthesis | 85.09 ms | 85.65 ms | 4 |

Both Kokoro APIs returned byte-identical audio before and after the changes,
with 73,800 samples per response. The TTS timing sample is small; its observed
median increase was below 1 ms. CoreML HTTP and WebSocket requests also
transcribed correctly through the explicit CoreML descriptor. The first
CoreML HTTP request included 13.8 seconds of cached model loading; subsequent
HTTP/WS calls were approximately 0.59–0.60 seconds on the same fixture.

Four simultaneous HTTP requests completed successfully at approximately 97,
191, 284 and 378 ms, with 378 ms total wall time. This is the intended serial
admission behavior. The baseline's concurrent mutable-model execution was
not used as a throughput target. Health requests during inference remained
responsive: 0.53 ms median before and 0.57 ms after.

Uncontended gate admission/release measured 0.21 microseconds median; a warm
generic runtime operation measured 0.33 microseconds. In the concurrent
playback stress, all 28,800,000 samples were consumed and the longest buffer
read was 0.120 ms. A 512-frame callback at 24 kHz has a 21.33 ms period.
The 60-second overflow probe preserved all 1,440,000 samples. Read medians
and p99 values were near the clock's resolution, so they do not support a
precise relative CPU-speed comparison.

The aggregate numbers and input/binary hashes are retained with the local
artifacts as `benchmark-results/runtime-ownership-20261017/published-summary.json`.

## Regression coverage

- CI-style unit selection: 1,427 tests executed, 42 skipped, zero failures.
- Targeted ownership, HTTP/WebSocket, CLI, decoding and playback rerun after
  the Swift 6 fix: 163 tests, zero failures.
- Real MLX inference: native/managed transcript parity, unload/reload,
  cancellation and recovery passed again.
- Real CoreML inference: backend selection and repeated background-request
  memory regression tests passed.
- Live HTTP/WebSocket ASR, CoreML backend discovery/routing, four concurrent
  HTTP requests, and Kokoro HTTP/WebSocket output checks passed. MLX and full
  CoreML CLI smoke tests transcribed the fixture correctly.
- Swift 6 Thread Sanitizer: 16,000 exclusive operations, 64 concurrent cache
  requests, 3,200 cancellation/grant races and 1,966,080 exactly ordered
  playback samples passed without sanitizer reports.
- The model-independent `SpeechRuntime` sources compiled for iOS 18 with
  strict Swift 6 code generation. This is not a full iOS package/app build.

## Reproduction

Create a separate baseline worktree at the revision above. From the changed
worktree, build each harness sequentially:

```bash
python3 scripts/profiling/build_runtime_profile.py ../speech-swift-runtime-baseline-verify
python3 scripts/profiling/build_runtime_profile.py .
BUILD_DIR="$PWD/.build/index-build" ./scripts/build_mlx_metallib.sh release
```

Run the metallib step in the baseline worktree as well. The build helper adds
a temporary profiling target and restores `Package.swift` in a `finally`
block. It does not add production package products.

For the same input selection, construct the manifest from the existing cache:

```python
from pathlib import Path
cache = Path.home() / "Library/Caches/qwen3-speech/benchmarks/kyutai-fleurs-float-80"
rows = []
for language in ("en_us", "fr_fr"):
    for line in (cache / f"fleurs-{language}-80.tsv").read_text().splitlines()[:20]:
        audio, reference = line.split("\t", 1)
        rows.append(f"{cache / audio}\t{reference}")
Path(".build/runtime-profile-40.tsv").write_text("\n".join(rows) + "\n")
```

```bash
python3 scripts/profiling/profile_runtime_models.py \
  --baseline ../speech-swift-runtime-baseline-verify/.build/index-build/release/runtime-ownership-profile \
  --current .build/index-build/release/runtime-ownership-profile \
  --manifest .build/runtime-profile-40.tsv \
  --output-dir benchmark-results/runtime-ownership-20261017
python3 scripts/profiling/summarize_runtime_profiles.py benchmark-results/runtime-ownership-20261017
python3 scripts/profiling/check_runtime_thread_safety.py
```

For live transports, run these sequentially as well (the Python client uses
`numpy`, `soundfile` and `websockets`):

```bash
python3 scripts/profiling/profile_runtime_transports.py \
  --binary ../speech-swift-runtime-baseline-verify/.build/index-build/release/runtime-ownership-profile \
  --audio Tests/Qwen3ASRTests/Resources/test_audio.wav \
  --output benchmark-results/runtime-ownership-20261017/transports-baseline.json --tts
python3 scripts/profiling/profile_runtime_transports.py \
  --binary .build/index-build/release/runtime-ownership-profile \
  --audio Tests/Qwen3ASRTests/Resources/test_audio.wav \
  --output benchmark-results/runtime-ownership-20261017/transports-current.json \
  --tts --coreml --concurrent 4
```

The manifest is a TSV containing absolute audio paths and reference text.
It is constructed from the two cached language manifests described above.
Raw per-utterance results, binary/manifest hashes, memory snapshots and logs
are local artifacts under `benchmark-results/runtime-ownership-20261017/`.

## Limits

This is a regression comparison of Qwen3-ASR 0.6B MLX INT4 and full CoreML on
one machine and a small fixed bilingual subset. It is not the full model
quality or E2E matrix. Download times, uncached installation, the 1.7B variant
and full iOS builds were not measured.

The shared server lane intentionally serializes mutable model access across
protocols and engines. Concurrent request latency includes queueing; concurrent
throughput is not claimed to match the previous unsafe shared-model behavior.
Cached variants and queued playback audio still consume memory without a
global residency/queue-byte budget. Buffer timing measurements exercise the
storage and synchronization code, not physical audio-device deadlines.
