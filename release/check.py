#!/usr/bin/env python3
"""Checks the publication of core-crypto-kmp in target/digits/maven/ before it's uploaded.

  release/check.py [--signed] <version>

For each module it checks:
- the POM: the fields Maven Central requires, this project's coordinates, no dependency on Wire's;
- the native libraries in the jvm jar, the android aar and the cinterop klibs: the ones in
  target/<target>/release, where release/build.sh put them;
- the licence files: LICENSE, NOTICE and THIRD_PARTY_NOTICES.txt in META-INF/core-crypto-kmp/ of the
  jvm jar and the aar, the notices next to the klib modules;
- the SBOM: the module, and the checksums of its artifact and libraries.
The common module has to name the five platform modules. With --signed, it also verifies the
signatures and checksums that release/bundle.sh adds.
"""
import hashlib
import io
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

GROUP = "schwarz.opensource.natrium"
ROOT = Path(__file__).resolve().parent.parent
MAVEN = ROOT / "target/digits/maven" / GROUP.replace(".", "/")
NOTICES = "META-INF/core-crypto-kmp"
POM_FIELDS = ["name", "description", "url", "licenses/license/name", "licenses/license/url",
              "developers/developer/name", "scm/url", "scm/connection", "scm/developerConnection"]
NS = {"m": "http://maven.apache.org/POM/4.0.0"}
CHECKSUMS = ("md5", "sha1", "sha256", "sha512")


def lib(triple, name="libcore_crypto_ffi.so"):
    return ROOT / "target" / triple / "release" / name


# Per module: the artifact's extension, and the native libraries in it by their name in the SBOM,
# with the entry that holds them and the library in target/.
MODULES = {
    "core-crypto-kmp": (".jar", {}),
    "core-crypto-kmp-jvm": (".jar", {
        name: (name, built) for name, built in [
            ("linux-x86-64/libcore_crypto_ffi.so", lib("x86_64-unknown-linux-gnu")),
            ("linux-aarch64/libcore_crypto_ffi.so", lib("aarch64-unknown-linux-gnu")),
            ("darwin-aarch64/libcore_crypto_ffi.dylib", lib("aarch64-apple-darwin", "libcore_crypto_ffi.dylib")),
            ("win32-x86-64/core_crypto_ffi.dll", lib("x86_64-pc-windows-gnu", "core_crypto_ffi.dll"))]}),
    "core-crypto-kmp-android": (".aar", {
        name: (name, built) for name, built in [
            ("jni/arm64-v8a/libcore_crypto_ffi.so", lib("aarch64-linux-android")),
            ("jni/armeabi-v7a/libcore_crypto_ffi.so", lib("armv7-linux-androideabi")),
            ("jni/x86_64/libcore_crypto_ffi.so", lib("x86_64-linux-android"))]}),
    "core-crypto-kmp-iosarm64": (".klib", {"libcore_crypto_ffi.a": (
        "default/targets/ios_arm64/included/libcore_crypto_ffi.a", lib("aarch64-apple-ios", "libcore_crypto_ffi.a"))}),
    "core-crypto-kmp-iossimulatorarm64": (".klib", {"libcore_crypto_ffi.a": (
        "default/targets/ios_simulator_arm64/included/libcore_crypto_ffi.a",
        lib("aarch64-apple-ios-sim", "libcore_crypto_ffi.a"))}),
    "core-crypto-kmp-macosarm64": (".klib", {"libcore_crypto_ffi.a": (
        "default/targets/macos_arm64/included/libcore_crypto_ffi.a", lib("aarch64-apple-darwin", "libcore_crypto_ffi.a"))}),
}

problems = []


def check(ok, message):
    if not ok:
        problems.append(message)


def digest(data, alg="sha512"):
    return hashlib.new(alg, data).hexdigest()


def pom_text(root, path):
    return (root.findtext("/".join(f"m:{p}" for p in path.split("/")), "", NS) or "").strip()


def check_notices(read, where, module, version):
    """LICENSE, NOTICE and THIRD_PARTY_NOTICES.txt in META-INF/core-crypto-kmp/, through read(entry)."""
    try:
        check(read(f"{NOTICES}/LICENSE") == (ROOT / "LICENSE").read_bytes(), f"{where}: LICENSE isn't the repository's")
        check(version.encode() in read(f"{NOTICES}/NOTICE"), f"{where}: NOTICE is for another version")
        check(f"{GROUP}:{module}:{version}".encode() in read(f"{NOTICES}/THIRD_PARTY_NOTICES.txt"),
              f"{where}: THIRD_PARTY_NOTICES.txt is for another module or version")
    except KeyError as missing:
        problems.append(f"{where}: no {missing}")


def check_module(module, version, signed):
    extension, natives = MODULES[module]
    directory = MAVEN / module / version
    stem = directory / f"{module}-{version}"
    artifact = Path(f"{stem}{extension}")
    required = [artifact, *(Path(f"{stem}{s}") for s in (".pom", ".module", "-sources.jar", "-javadoc.jar",
                                                          "-cyclonedx.json"))]
    if extension == ".klib":
        required += [Path(f"{stem}-cinterop-rust.klib"), Path(f"{stem}-third-party-notices.txt")]
    missing = [f.name for f in required if not f.is_file()]
    if missing:
        problems.append(f"{module}: missing {missing}")
        return

    # The native libraries, and the licence files
    holder = Path(f"{stem}-cinterop-rust.klib") if extension == ".klib" else artifact
    with zipfile.ZipFile(holder) as z:
        found = {name: z.read(entry) for name, (entry, _) in natives.items() if entry in z.namelist()}
        if extension == ".jar" and natives:
            check_notices(z.read, artifact.name, module, version)
        if extension == ".aar":
            with zipfile.ZipFile(io.BytesIO(z.read("classes.jar"))) as classes:
                check_notices(classes.read, f"{artifact.name}!classes.jar", module, version)
    for name, (entry, built) in natives.items():
        check(name in found, f"{holder.name}: no {entry}")
        if name in found:
            check(found[name] == built.read_bytes(), f"{holder.name}: {entry} differs from {built.relative_to(ROOT)}")
    if extension == ".klib":
        text = Path(f"{stem}-third-party-notices.txt").read_text()
        check(f"{GROUP}:{module}:{version}" in text, f"{module}: third-party notices are for another module or version")

    # The POM
    pom = ET.parse(f"{stem}.pom").getroot()
    for field, expected in (("groupId", GROUP), ("artifactId", module), ("version", version)):
        check(pom_text(pom, field) == expected, f"{module}.pom: {field} isn't {expected}")
    for field in POM_FIELDS:
        check(pom_text(pom, field), f"{module}.pom: no {field}")
    check("wireapp" not in pom_text(pom, "url") + pom_text(pom, "scm/url"), f"{module}.pom: names Wire's repository")
    groups = {d.findtext("m:groupId", "", NS) for d in pom.findall("m:dependencies/m:dependency", NS)}
    check("com.wire" not in groups, f"{module}.pom: depends on Wire's artifacts")

    # The SBOM
    bom = json.loads(Path(f"{stem}-cyclonedx.json").read_text())
    component = bom["metadata"]["component"]
    check(bom["specVersion"] == "1.5", f"{module} SBOM: not CycloneDX 1.5")
    check(component["purl"] == f"pkg:maven/{GROUP}/{module}@{version}", f"{module} SBOM: wrong component")
    check(component.get("hashes") == [{"alg": "SHA-512", "content": digest(artifact.read_bytes())}],
          f"{module} SBOM: wrong checksum of {artifact.name}")
    hashes = {c["name"]: c["hashes"][0]["content"] for c in bom["components"] if c["type"] == "file"}
    for name, data in found.items():
        check(hashes.get(name) == digest(data), f"{module} SBOM: no checksum of {name}")
    check(all(c.get("licenses") for c in bom["components"] if c["type"] == "library"),
          f"{module} SBOM: component without licence")

    # Signatures and checksums
    if signed:
        files = [f for f in directory.iterdir() if f.suffix[1:] not in ("asc", *CHECKSUMS)]
        for f in files:
            status = subprocess.run(["gpg", "--status-fd", "1", "--verify", f"{f}.asc", str(f)],
                                    capture_output=True, text=True).stdout
            check(re.search(r"^\[GNUPG:\] VALIDSIG ", status, re.M), f"{f.name}.asc: no valid signature")
            for alg in CHECKSUMS:
                sum_file = Path(f"{f}.{alg}")
                check(sum_file.is_file() and sum_file.read_text().strip() == digest(f.read_bytes(), alg),
                      f"{sum_file.name}: missing or wrong")
        known = {f"{f.name}{ext}" for f in files for ext in ("", ".asc", *(f".{a}" for a in CHECKSUMS))}
        check({f.name for f in directory.iterdir()} <= known, f"{module}: files without the artifact they sign")
    return found


def main():
    args = sys.argv[1:]
    signed = "--signed" in args
    args = [a for a in args if a != "--signed"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    version = args[0]

    root = MAVEN / "core-crypto-kmp" / version / f"core-crypto-kmp-{version}.module"
    if root.is_file():
        metadata = json.loads(root.read_text())
        named = {v["available-at"]["module"] for v in metadata["variants"] if v.get("available-at")}
        check(named == set(MODULES) - {"core-crypto-kmp"}, f"core-crypto-kmp.module names {sorted(named)}")
        for variant in metadata["variants"]:
            at = variant.get("available-at")
            check(not at or (at["group"], at["version"]) == (GROUP, version),
                  f"core-crypto-kmp.module: {variant['name']} points to {at}")
    libraries = sum(len(check_module(module, version, signed) or {}) for module in MODULES)

    if problems:
        print("\n".join(problems), file=sys.stderr)
        raise SystemExit(f"{len(problems)} problem(s) in {MAVEN}")
    print(f"core-crypto-kmp {version}: ok, {len(MODULES)} modules, {libraries} native libraries"
          f"{', signed' if signed else ''}")


if __name__ == "__main__":
    main()
