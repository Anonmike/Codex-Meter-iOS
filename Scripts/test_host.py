#!/usr/bin/env python3
"""Run the production core and storage tests on macOS without compiling UIKit.

The main package targets iOS; this temporary host package copies the exact source
files under test. It contains no alternative implementations or real credentials.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="codex-meter-tests-") as directory:
    package = Path(directory)
    shutil.copytree(root / "Sources/CodexMeterCore", package / "Sources/CodexMeterCore")
    storage = package / "Sources/CodexMeterStorage"
    storage.mkdir(parents=True)
    for name in ["KeychainTokenStore.swift", "CodexAPI.swift"]:
        shutil.copy2(root / "Sources/CodexMeter" / name, storage / name)
    for name in ["CodexMeterTests", "CodexMeterStorageTests", "Support"]:
        shutil.copytree(root / "Tests" / name, package / "Tests" / name)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CodexMeterHostTests", platforms: [.macOS(.v14)], targets: [
    .target(name: "CodexMeterCore"),
    .target(name: "CodexMeterStorage", dependencies: ["CodexMeterCore"]),
    .target(name: "TestSupport", dependencies: ["CodexMeterCore"], path: "Tests/Support"),
    .testTarget(name: "CodexMeterTests", dependencies: ["CodexMeterCore", "TestSupport"]),
    .testTarget(name: "CodexMeterStorageTests", dependencies: ["CodexMeterCore", "CodexMeterStorage", "TestSupport"])
])
''', encoding="utf-8")
    subprocess.run(["swift", "test", "--package-path", str(package)], check=True)
