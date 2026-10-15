#!/usr/bin/env python3
"""Validate iOS project policy, and optionally an actual physical-device .app bundle."""

from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile


def require(condition, message):
    if not condition:
        raise SystemExit(message)


project = Path(__file__).resolve().parents[1]
with (project / "ios/Runner/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
require(info["CFBundleDisplayName"] == "AniView", "Incorrect app name")
schemes = [s for entry in info["CFBundleURLTypes"] for s in entry["CFBundleURLSchemes"]]
require("aniview" in schemes, "OAuth URL scheme missing")
require(info.get("FlutterDeepLinkingEnabled") is False, "app_links must own OAuth links")
ats = info.get("NSAppTransportSecurity", {})
require(not ats.get("NSAllowsArbitraryLoads"), "Global ATS bypass must not be enabled")
require(not ats.get("NSAllowsArbitraryLoadsInWebContent"), "WebView ATS bypass must not be enabled")
pbx = (project / "ios/Runner.xcodeproj/project.pbxproj").read_text()
require("DEVELOPMENT_TEAM =" not in pbx, "Personal signing team must stay in Signing.xcconfig")
require(set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);", pbx)) == {"15.0"},
        "Expected iOS 15.0 deployment target")
print("iOS project: name, callback scheme, ATS and signing configuration OK")

if len(sys.argv) == 1:
    sys.exit(0)

app = Path(sys.argv[1]).resolve()
if app.suffix == ".ipa":
    with zipfile.ZipFile(app) as archive:
        names = archive.namelist()
        require("Payload/Runner.app/Info.plist" in names, "Missing iPhone app payload")
        metadata = [name for name in names if any(
            part.startswith("._") or part == "__MACOSX" for part in Path(name).parts
        )]
        require(not metadata, "IPA contains macOS metadata inside its payload")
        require(not any(name.endswith("/embedded.mobileprovision") for name in names),
                "Unsigned IPA must not carry a provisioning profile")
        require(archive.testzip() is None, "Corrupt IPA ZIP entry")
    print("Unsigned IPA: payload present, ZIP integrity valid, no macOS metadata or provisioning profile")
    sys.exit(0)

with (app / "Info.plist").open("rb") as stream:
    built = plistlib.load(stream)
require(built.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Expected a device app, not a simulator")
require(built["MinimumOSVersion"] == "15.0", "Unexpected minimum iOS version")
require(built["CFBundleIdentifier"] == "com.kidfury.aniview", "Unexpected bundle identifier")
frameworks = app / "Frameworks"
for name in ("App", "Flutter", "Mpv", "Avcodec", "Avformat", "media_kit_video"):
    require((frameworks / f"{name}.framework" / name).is_file(), f"Missing native library: {name}")

binaries = [app / built["CFBundleExecutable"]]
binaries += [p / p.stem for p in frameworks.glob("*.framework") if (p / p.stem).is_file()]
binaries += list(frameworks.glob("*.dylib"))
for binary in binaries:
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    require("arm64" in arch.split() and set(arch.split()) <= {"arm64", "arm64e"},
            f"Non-device architecture in {binary.name}: {arch}")
    platform = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
    require("IOSSIMULATOR" not in platform and (
        re.search(r"platform\s+IOS\b", platform) or "LC_VERSION_MIN_IPHONEOS" in platform),
            f"Not an iOS device binary: {binary.name}")
    dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    for dependency in dependencies:
        name = dependency.strip().split(" (")[0]
        if name.startswith("@rpath/"):
            require((frameworks / name.removeprefix("@rpath/")).exists(),
                    f"Missing embedded dependency for {binary.name}: {name}")

require(not (app / "embedded.mobileprovision").exists(), "Unsigned package must not carry a provisioning profile")
print(f"Device bundle: {built['CFBundleIdentifier']}, iOS {built['MinimumOSVersion']}+, {len(binaries)} arm64 binaries")
print("Native framework dependencies present. Signing and physical-device behavior still require validation.")
