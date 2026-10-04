"""Compile and run the mock-only recording coordinator checks."""
from pathlib import Path
import subprocess


root = Path(__file__).resolve().parents[2]
build = root / ".build"
build.mkdir(exist_ok=True)
framework = root / "Vendor/whisper.cpp/build-apple/whisper.xcframework/macos-arm64_x86_64"
sources = sorted(
    str(path)
    for folder in ("App", "Core", "Features", "Models", "Services")
    for path in (root / folder).rglob("*.swift")
    if path.name != "DictaFlowApp.swift"
)
executable = build / "verify-recording-flow"
subprocess.run([
    "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
    "-F", str(framework), "-framework", "whisper",
    "-Xlinker", "-rpath", "-Xlinker", str(framework),
    *sources, str(Path(__file__).with_suffix(".swift")), "-o", str(executable),
], check=True, cwd=root)
subprocess.run([str(executable)], check=True, cwd=root)
