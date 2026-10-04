"""Render DictaFlow's original sound cues and previews without dependencies."""

import math
from pathlib import Path
import random
import wave


SAMPLE_RATE = 48_000
PEAK_CEILING = 10 ** (-17 / 20)
TARGET_WINDOW_RMS = 10 ** (-25.5 / 20)
OUTPUT_DIRECTORY = Path(__file__).resolve().parent
RESOURCE_DIRECTORY = OUTPUT_DIRECTORY.parents[1] / "Resources" / "SoundCues"

# Each partial is (frequency multiplier, amplitude, decay multiplier).
# The alternatives change pitch, harmonic balance, attack, and pacing while
# keeping the same event motifs as soft digital.
STYLES = {
    "01-soft-digital": {
        "base_frequency": 620,
        "partials": [(1, 1, 1), (2, 0.12, 1.8)],
        "decay": 4,
        "length": 1,
    },
    "02-mellow-pulse": {
        "base_frequency": 415,
        "partials": [(1, 1, 1), (2, 0.06, 1.8), (3, 0.025, 2.5)],
        "decay": 2.5,
        "length": 1.1,
        "attack": 0.012,
    },
}

# Notes are (start seconds, duration seconds, pitch semitones, amplitude).
# Start rises; stop falls.
# Error repeats a low note with a quiet minor-second layer on the final pulse.
CUES = {
    "start-recording": [(0, 0.10, 0, 0.85), (0.065, 0.13, 5, 1)],
    "stop-recording": [(0, 0.09, 5, 0.8), (0.065, 0.12, 0, 1)],
    "error": [(0, 0.12, -12, 0.8), (0.17, 0.16, -12, 1), (0.17, 0.16, -11, 0.14)],
}


def render_cue(style, notes):
    length = style["length"]
    duration = max((start + duration) * length for start, duration, _, _ in notes)
    samples = [0.0] * (math.ceil(duration * SAMPLE_RATE) + 1)

    for start, note_duration, semitones, gain in notes:
        start *= length
        note_duration *= length
        frequency = style["base_frequency"] * 2 ** (semitones / 12)
        offset = round(start * SAMPLE_RATE)
        attack = style.get("attack", 0.008)
        release = 0.035 * length
        for index in range(math.ceil(note_duration * SAMPLE_RATE)):
            time = index / SAMPLE_RATE
            attack_envelope = math.sin(min(time / attack, 1) * math.pi / 2) ** 2
            release_envelope = math.sin(
                min(max((note_duration - time) / release, 0), 1) * math.pi / 2
            ) ** 2
            value = sum(
                amplitude
                * math.exp(-style["decay"] * decay * time / note_duration)
                * math.sin(2 * math.pi * frequency * multiplier * time)
                for multiplier, amplitude, decay in style["partials"]
            )
            samples[offset + index] += gain * attack_envelope * release_envelope * value

    # Match the strongest 50 ms of each cue rather than its whole-file RMS.
    # Whole-file RMS would make the error cue louder because of its silent gap.
    # Short cues are too brief for meaningful integrated loudness measurements.
    gain = min(
        TARGET_WINDOW_RMS / strongest_window_rms(samples),
        PEAK_CEILING / max(abs(sample) for sample in samples),
    )
    return [sample * gain for sample in samples]


def strongest_window_rms(samples):
    width = round(0.05 * SAMPLE_RATE)
    energy = [sample * sample for sample in samples]
    rolling = sum(energy[:width])
    strongest = rolling
    for index in range(width, len(energy)):
        rolling += energy[index] - energy[index - width]
        strongest = max(strongest, rolling)
    return math.sqrt(strongest / width)


def write_wav(path, samples):
    # Deterministic triangular dither avoids correlated quantization at quiet
    # fades. At 24 bits it sits far below normal playback noise.
    rng = random.Random(0)
    pcm = bytearray()
    for index, sample in enumerate(samples):
        quantized = round(sample * 8_388_607 + rng.random() - rng.random())
        if index == 0 or index == len(samples) - 1:
            quantized = 0
        pcm.extend(quantized.to_bytes(3, "little", signed=True))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(3)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def main():
    RESOURCE_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for name, style in STYLES.items():
        directory = OUTPUT_DIRECTORY / name
        directory.mkdir(parents=True, exist_ok=True)
        preview = [0.0] * round(0.25 * SAMPLE_RATE)
        for cue_name, notes in CUES.items():
            samples = render_cue(style, notes)
            write_wav(directory / f"{cue_name}.wav", samples)
            write_wav(RESOURCE_DIRECTORY / f"{name[3:]}-{cue_name}.wav", samples)
            preview.extend(samples)
            preview.extend([0.0] * round(0.85 * SAMPLE_RATE))
        write_wav(directory / "preview.wav", preview)
        print(f"Rendered {name}: {len(CUES)} bundled cues and one preview.")


if __name__ == "__main__":
    main()
