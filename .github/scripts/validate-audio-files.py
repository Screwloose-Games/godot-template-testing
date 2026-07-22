# Run this with: python .github/scripts/validate-audio-files.py --file-list audio_files.txt
# (positional args also work for one-off manual checks: ... validate-audio-files.py foo.wav bar.ogg)
#
# NOTE: don't invoke this via `$(cat audio_files.txt)` -- unquoted shell command
# substitution word-splits on spaces, which silently corrupts any filename that
# contains a space (exactly the kind of filename this script needs to flag).
# --file-list reads the file directly, one path per line, with no shell involved.

import argparse
import json
import os
import re
import sys
import wave

MAX_FILE_SIZE = 49 * 1024 * 1024  # 49 MB

AUDIO_EXTENSIONS = (".wav", ".ogg", ".mp3")

# Applies to all audio files (.wav, .ogg, .mp3, ...) regardless of container format:
# lowercase letters/numbers only, underscores as the sole word separator, lowercase extension.
FILENAME_PATTERN = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*\.[a-z0-9]+$")

WAV_FILE_SPECIFICATIONS = {
    "sample_rate": 44100,  # Hz
    "bit_depth": 16,       # bits per sample
    "channels": 1,         # 1 for mono, 2 for stereo
    "target_lufs": -16,    # LUFS loudness normalization
    "peak_volume": -1.0,   # dBFS, avoid clipping
    "looping": False,      # true only for seamless loops
    "filename_convention": {
        "casing": "lowercase",
        "separator": "underscore",
        "extension": ".wav"
    },
    "max_length": 10,      # seconds
    "max_file_size": MAX_FILE_SIZE,  # 49 MB
}

class AudioFileReport:
    """Class to generate a report for audio file data. Includes detailed information about the audio file.
        Attributes:
            file_path (str): Path to the audio file.
            file_size (int): Size of the audio file in Megabytes.
            sample_rate (int): Sample rate of the audio file.
            bit_depth (int): Bit depth of the audio file.
            channels (int): Number of channels in the audio file.
            duration (float): Duration of the audio file in seconds.
            errors (list): List of validation errors encountered during processing."""

    report_template = """Audio File Report:
    File Path: `{file_path}`
    File Size: {file_size:.2f} Megabytes
    Sample Rate: {sample_rate} Hz
    Bit Depth: {bit_depth} bits
    Channels: {channels}
    Duration: {duration} seconds
    Errors: {errors}
    """

    def __init__(self, file_path):
        self.file_path = file_path
        self.file_size = os.path.getsize(file_path) / (1024 * 1024) # in Megabytes

        is_wav = file_path.lower().endswith(".wav")
        if is_wav:
            try:
                with wave.open(file_path, 'rb') as wav_file:
                    self.sample_rate = wav_file.getframerate()
                    self.bit_depth = wav_file.getsampwidth() * 8
                    self.channels = wav_file.getnchannels()
                    self.duration = round(wav_file.getnframes() / float(self.sample_rate), 2)
            except (wave.Error, EOFError):
                self.sample_rate = self.bit_depth = self.channels = self.duration = "N/A"
        else:
            # WAV-container stats don't apply to compressed formats (.ogg, .mp3, ...)
            self.sample_rate = self.bit_depth = self.channels = self.duration = "N/A"

        validator = AudioFileValidator(self.file_path)
        validator.validate()
        self.errors = list(validator.errors)

    def __str__(self):
        return self.report_template.format(
            file_path=self.file_path,
            file_size=self.file_size,
            sample_rate=self.sample_rate,
            bit_depth=self.bit_depth,
            channels=self.channels,
            duration=self.duration,
            errors=self.errors
        )

class AudioFileValidator:
    def __init__(self, file_path):
        self.file_path = file_path
        self.errors = []

    def validation_results(self):
        return "\n".join(self.errors) if self.errors else "No errors found."

    def validate(self):
        if not os.path.isfile(self.file_path):
            self.errors.append(f"File does not exist: {self.file_path}")
            return False

        file_size = os.path.getsize(self.file_path)
        if file_size > WAV_FILE_SPECIFICATIONS["max_file_size"]:
            self.errors.append(f"File size exceeds limit: {file_size} bytes > {WAV_FILE_SPECIFICATIONS['max_file_size']} bytes")

        basename = os.path.basename(self.file_path)
        if not FILENAME_PATTERN.match(basename):
            self.errors.append(
                f"Filename '{basename}' does not follow the naming convention: use only lowercase "
                "letters, numbers, and underscores (underscores separate words); no spaces, apostrophes, "
                "parentheses, exclamation marks, hyphens, or other special characters; the extension must "
                "also be lowercase (e.g. 'ive_got_your_back_intro.ogg')"
            )

        # WAV-container-specific technical checks (sample rate, bit depth, channels, duration)
        # don't apply to compressed formats like .ogg/.mp3.
        if not self.file_path.lower().endswith('.wav'):
            return not self.errors

        try:
            with wave.open(self.file_path, 'rb') as wav_file:
                sample_rate = wav_file.getframerate()
                channels = wav_file.getnchannels()
                sampwidth = wav_file.getsampwidth()  # in bytes

            # Check sample rate
            if sample_rate != WAV_FILE_SPECIFICATIONS["sample_rate"]:
                self.errors.append(
                f"Sample rate mismatch: {sample_rate} Hz (expected {WAV_FILE_SPECIFICATIONS['sample_rate']} Hz) in {self.file_path}"
                )

            # Check channels
            if channels != WAV_FILE_SPECIFICATIONS["channels"]:
                self.errors.append(
                f"Channel count mismatch: {channels} (expected {WAV_FILE_SPECIFICATIONS['channels']}) in {self.file_path}"
                )

            # Check bit depth
            bit_depth = sampwidth * 8
            if bit_depth != WAV_FILE_SPECIFICATIONS["bit_depth"]:
                self.errors.append(
                f"Bit depth mismatch: {bit_depth} (expected {WAV_FILE_SPECIFICATIONS['bit_depth']}) in {self.file_path}"
                )

            # Check duration
            n_frames = wav_file.getnframes()
            duration = n_frames / float(sample_rate)
            if duration > WAV_FILE_SPECIFICATIONS["max_length"]:
                self.errors.append(
                f"Audio duration exceeds limit: {duration:.2f} seconds (max {WAV_FILE_SPECIFICATIONS['max_length']} seconds) in {self.file_path}"
                )

        except wave.Error as e:
            self.errors.append(f"Error reading WAV file: {self.file_path} ({e})")
        except Exception as e:
            self.errors.append(f"Unexpected error reading WAV file: {self.file_path} ({e})")

        return not self.errors


def load_changed_files_json(path):
    """Parse a tj-actions/changed-files `all_changed_files` JSON array (json: true)
    and return the audio-file paths within it.

    The action MUST be configured with `safe_output: false`; otherwise it
    backslash-escapes special characters (spaces, (), !, ', ...) even in JSON
    mode, producing invalid JSON like [\\"a\\",\\"b\\"]. We detect that case and
    raise an actionable error instead of a raw JSONDecodeError.
    """
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    try:
        files = json.loads(raw)
    except json.JSONDecodeError as e:
        hint = ""
        if '\\"' in raw or raw.lstrip().startswith("[\\"):
            hint = (
                "\nThe input looks backslash-escaped. The tj-actions/changed-files "
                "step must set `safe_output: false` so it emits valid JSON."
            )
        raise SystemExit(f"Could not parse changed-files JSON from {path}: {e}{hint}")
    if not isinstance(files, list):
        raise SystemExit(f"Expected a JSON array in {path}, got {type(files).__name__}")
    return [f for f in files if isinstance(f, str) and f.lower().endswith(AUDIO_EXTENSIONS)]


def main(audio_files):
    """Validate the given audio files. Returns True if any file had errors."""
    validators = [AudioFileValidator(file_path) for file_path in audio_files]
    reports = [AudioFileReport(file_path) for file_path in audio_files]
    has_errors = False
    for validator in validators:
        if not validator.validate():
            has_errors = True
            print(f"Validation failed for {validator.file_path}:")
            for error in validator.errors:
                print(f" - {error}")
            print()
        else:
            print(f"Validation succeeded for {validator.file_path}")
    for report in reports:
        print(report)

    # GITHUB_OUTPUT is only set inside GitHub Actions; skip it for local runs/tests.
    out_path = os.environ.get("GITHUB_OUTPUT")
    if out_path and os.path.exists(out_path):
        with open(out_path, "a") as fh:
            reports_str = "\n\n".join([str(report) for report in reports])
            metadata = {
                "audio_reports": reports_str,
            }
            print("metadata<<EOF", file=fh)
            print(json.dumps(metadata, indent=2), file=fh)
            print("EOF", file=fh)
            print(f"has_errors={'true' if has_errors else 'false'}", file=fh)

    return has_errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("audio_files", nargs="*", help="Audio file paths to validate")
    parser.add_argument("--file-list", metavar="FILE",
                         help="Read newline-separated audio file paths from FILE (safe for filenames containing spaces)")
    parser.add_argument("--changed-files-json", metavar="FILE",
                         help="Read a tj-actions/changed-files JSON array from FILE, filter to audio files, and validate them. "
                              "This is the exact code path CI uses -- point it at a saved payload to reproduce CI locally.")
    args = parser.parse_args()

    audio_files = list(args.audio_files)
    if args.file_list:
        with open(args.file_list, "r", encoding="utf-8") as f:
            audio_files.extend(line for line in f.read().splitlines() if line.strip())
    if args.changed_files_json:
        audio_files.extend(load_changed_files_json(args.changed_files_json))

    if not audio_files:
        # No audio files to check (e.g. the changed-files list had none) -- not an error.
        print("No audio files to validate.")
        sys.exit(0)

    sys.exit(1 if main(audio_files) else 0)