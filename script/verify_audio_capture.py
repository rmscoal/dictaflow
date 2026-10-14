"""Opt-in microphone benchmarks using the signed Dev test host.

Records short samples into private temporary files, verifies capture and output
state, and removes those samples. Never requests microphone permission.
"""

from pathlib import Path
import plistlib
import subprocess


root = Path(__file__).resolve().parents[1]
derived_data = root / ".build/DerivedData"
subprocess.run([
    "xcodebuild", "-project", "DictaFlow.xcodeproj", "-scheme", "DictaFlow Dev",
    "-configuration", "Debug", "-derivedDataPath", str(derived_data),
    "build-for-testing",
], check=True, cwd=root)

products = derived_data / "Build/Products"
runs = list(products.glob("DictaFlow Dev_*.xctestrun"))
if not runs:
    raise SystemExit("Xcode did not create a Dev test-run configuration.")
configuration = plistlib.loads(max(runs, key=lambda path: path.stat().st_mtime).read_bytes())
for test_configuration in configuration["TestConfigurations"]:
    for target in test_configuration["TestTargets"]:
        target.setdefault("EnvironmentVariables", {})["DICTAFLOW_RUN_AUDIO_CHECKS"] = "1"
run_path = products / "AudioCaptureChecks.xctestrun"
run_path.write_bytes(plistlib.dumps(configuration))
subprocess.run([
    "xcodebuild", "-xctestrun", str(run_path), "-destination", "platform=macOS",
    "-only-testing:DictaFlowTests/RecordingAudioIntegrationTests",
    "test-without-building",
], check=True, cwd=root)
