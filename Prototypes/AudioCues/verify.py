"""Check bundled cue audio without playing it or accessing a microphone."""

import hashlib
import math
from pathlib import Path
import wave

from generate import CUES, OUTPUT_DIRECTORY, RESOURCE_DIRECTORY, STYLES, strongest_window_rms


def verify_directory(directory):
    expected = {f"{style[3:]}-{cue}.wav" for style in STYLES for cue in CUES}
    actual = {path.name for path in directory.glob("*.wav")}
    assert actual == expected, f"Unexpected cue assets: {actual ^ expected}"
    levels = []
    for name in sorted(expected):
        path = directory / name
        with wave.open(str(path)) as audio:
            assert audio.getnchannels() == 1, name
            assert audio.getsampwidth() == 3, name
            assert audio.getframerate() == 48_000, name
            duration = audio.getnframes() / audio.getframerate()
            assert 0.15 <= duration <= 0.4, name
            pcm = audio.readframes(audio.getnframes())
        samples = [
            int.from_bytes(pcm[index:index + 3], "little", signed=True) / 8_388_607
            for index in range(0, len(pcm), 3)
        ]
        assert samples[0] == samples[-1] == 0, f"Nonzero endpoint: {name}"
        peak_db = 20 * math.log10(max(map(abs, samples)))
        assert peak_db <= -16.99, f"Peak ceiling exceeded: {name}"
        dc = abs(sum(samples) / len(samples))
        assert dc < 10 ** (-80 / 20), f"DC offset: {name}"
        largest_step = max(abs(left - right) for left, right in zip(samples, samples[1:]))
        assert largest_step < 0.03, f"Abrupt sample transition: {name}"
        level = 20 * math.log10(strongest_window_rms(samples))
        levels.append(level)
        assert abs(level + 25.5) < 0.01, f"Unexpected level: {name}"
        style, cue = next(
            (style, cue) for style in STYLES for cue in CUES
            if name == f"{style[3:]}-{cue}.wav"
        )
        prototype = OUTPUT_DIRECTORY / style / f"{cue}.wav"
        assert hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(prototype.read_bytes()).digest(), name
        print(f"{name}: {duration:.3f}s, peak {peak_db:.2f} dBFS, 50ms RMS {level:.2f} dBFS")
    assert max(levels) - min(levels) < 0.01
    print(f"Passed: {len(expected)} cues, zero endpoints, clean levels. Total: {sum((directory / name).stat().st_size for name in expected):,} bytes.")


if __name__ == "__main__":
    import sys
    verify_directory(Path(sys.argv[1]) if len(sys.argv) > 1 else RESOURCE_DIRECTORY)
