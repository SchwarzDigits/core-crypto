#!/usr/bin/env python3
"""Checks the Maven publication of core-crypto-jvm in target/digits/maven/ before it's uploaded.

  release/check.py [--signed] <version>

It compares the jars with Wire's release in target/digits/wire/ (the same Kotlin classes, sources
and documentation; the natives the manifest names; the licence files), checks the fields Maven Central
requires in the POM and its dependencies against Wire's POM, and checks the SBOM against the jar.
With --signed, it also verifies the signatures and checksums that release/bundle.sh adds.
UNRELEASED=1 accepts a jar built from a working tree with changes, for tests.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

GROUP = "schwarz.opensource.natrium"
ARTIFACT = "core-crypto-jvm"
NATIVES = ["darwin-aarch64/libcore_crypto_ffi.dylib", "linux-x86-64/libcore_crypto_ffi.so",
           "linux-aarch64/libcore_crypto_ffi.so", "win32-x86-64/core_crypto_ffi.dll"]
LICENCE_FILES = ["META-INF/LICENSE", "META-INF/NOTICE"]
POM_FIELDS = ["name", "description", "url", "licenses/license/name", "licenses/license/url",
              "developers/developer/name", "scm/url", "scm/connection", "scm/developerConnection"]
NS = {"m": "http://maven.apache.org/POM/4.0.0"}
ROOT = Path(__file__).resolve().parent.parent

problems = []


def check(ok, message):
    if not ok:
        problems.append(message)


def digest(data, alg="sha512"):
    return hashlib.new(alg, data).hexdigest()


def entries(path):
    with zipfile.ZipFile(path) as z:
        return {i.filename: (i.CRC, i.file_size) for i in z.infolist() if not i.is_dir()}


def compare_with_wire(ours, wire, name, own):
    """Every entry of Wire's jar is in ours, unchanged; ours adds or replaces only `own`."""
    ours, wire = entries(ours), entries(wire)
    for entry in ["META-INF/MANIFEST.MF", *own]:
        wire.pop(entry, None)
    for entry, info in wire.items():
        check(ours.get(entry) == info, f"{name}: {entry} differs from Wire's")
    extra = set(ours) - set(wire) - {"META-INF/MANIFEST.MF"} - set(own)
    check(not extra, f"{name}: unexpected entries {sorted(extra)}")
    check(set(own) <= set(ours), f"{name}: missing {sorted(set(own) - set(ours))}")


def pom_text(root, path):
    return (root.findtext("/".join(f"m:{p}" for p in path.split("/")), "", NS) or "").strip()


def section(root, name):
    element = root.find(f"m:{name}", NS)
    return "" if element is None else re.sub(r">\s+<", "><", ET.tostring(element, encoding="unicode").strip())


def main():
    args = sys.argv[1:]
    signed = "--signed" in args
    args = [a for a in args if a != "--signed"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    version = args[0]
    wire_version = re.fullmatch(r"(\d+\.\d+\.\d+)-digits\.\d+", version).group(1)
    out = ROOT / "target/digits/maven" / GROUP.replace(".", "/") / ARTIFACT / version
    wire = ROOT / "target/digits/wire" / wire_version
    base = out / f"{ARTIFACT}-{version}"
    files = {suffix: Path(f"{base}{suffix}")
             for suffix in (".jar", "-sources.jar", "-javadoc.jar", ".pom", "-cyclonedx.json")}
    missing = [str(f) for f in files.values() if not f.is_file()]
    if missing:
        raise SystemExit("missing: " + ", ".join(missing))

    # The jar
    jar = files[".jar"]
    compare_with_wire(jar, wire / f"{ARTIFACT}-{wire_version}.jar", jar.name,
                      NATIVES + LICENCE_FILES + ["META-INF/THIRD_PARTY_NOTICES.txt"])
    with zipfile.ZipFile(jar) as z:
        # Manifest lines wrap at 72 bytes; a continuation starts with a space.
        lines = z.read("META-INF/MANIFEST.MF").decode().replace("\r\n", "\n").replace("\n ", "").splitlines()
        manifest = dict(line.split(": ", 1) for line in lines if ": " in line)
        natives = {n: z.read(n) for n in NATIVES if n in z.namelist()}
        check(z.read("META-INF/LICENSE") == (ROOT / "LICENSE").read_bytes(), f"{jar.name}: LICENSE isn't the repository's")
        notices = z.read("META-INF/THIRD_PARTY_NOTICES.txt").decode()
        check(f"{ARTIFACT}:{version}" in notices, f"{jar.name}: THIRD_PARTY_NOTICES.txt is for another version")
    check(manifest.get("Implementation-Version") == version, f"{jar.name}: Implementation-Version isn't {version}")
    built = manifest.get("Built-From", "")
    check(re.fullmatch(r"\S+ [0-9a-f]{40}", built) or os.environ.get("UNRELEASED") == "1",
          f"{jar.name}: built from a working tree with changes ({built})")
    for name, data in natives.items():
        key = "Native-SHA256-" + name.split("/")[0]
        check(manifest.get(key) == digest(data, "sha256"), f"{jar.name}: {name} doesn't match {key}")

    compare_with_wire(files["-sources.jar"], wire / f"{ARTIFACT}-{wire_version}-sources.jar",
                      files["-sources.jar"].name, LICENCE_FILES + ["NATIVE-SOURCES.md"])
    compare_with_wire(files["-javadoc.jar"], wire / f"{ARTIFACT}-{wire_version}-javadoc.jar",
                      files["-javadoc.jar"].name, LICENCE_FILES)

    # The POM
    pom = ET.parse(files[".pom"]).getroot()
    wire_pom = ET.parse(wire / f"{ARTIFACT}-{wire_version}.pom").getroot()
    for field, expected in (("groupId", GROUP), ("artifactId", ARTIFACT), ("version", version)):
        check(pom_text(pom, field) == expected, f"POM: {field} isn't {expected}")
    for field in POM_FIELDS:
        check(pom_text(pom, field), f"POM: no {field}")
    for name in ("dependencyManagement", "dependencies"):
        check(section(pom, name) == section(wire_pom, name), f"POM: {name} differ from Wire's")
    check("published-with-gradle-metadata" not in files[".pom"].read_text(), "POM: refers to Gradle metadata")

    # The SBOM
    bom = json.loads(files["-cyclonedx.json"].read_text())
    component = bom["metadata"]["component"]
    check(bom["specVersion"] == "1.5", "SBOM: not CycloneDX 1.5")
    check(component["purl"] == f"pkg:maven/{GROUP}/{ARTIFACT}@{version}", "SBOM: wrong component")
    check(component.get("hashes") == [{"alg": "SHA-512", "content": digest(jar.read_bytes())}], "SBOM: jar hash")
    hashes = {c["name"]: c["hashes"][0]["content"] for c in bom["components"] if c["type"] == "file"}
    for name, data in natives.items():
        check(hashes.get(name) == digest(data), f"SBOM: no hash of {name}")
    check(all(c.get("licenses") for c in bom["components"] if c["type"] == "library"), "SBOM: component without licence")

    # Signatures and checksums
    if signed:
        for f in files.values():
            status = subprocess.run(["gpg", "--status-fd", "1", "--verify", f"{f}.asc", str(f)],
                                    capture_output=True, text=True).stdout
            match = re.search(r"^\[GNUPG:\] VALIDSIG (\w+)", status, re.M)
            check(match, f"{f.name}.asc: no valid signature")
            if match:
                print(f"{f.name}: signed by {match.group(1)}")
            for alg in ("md5", "sha1", "sha256", "sha512"):
                sum_file = Path(f"{f}.{alg}")
                check(sum_file.is_file() and sum_file.read_text().strip() == digest(f.read_bytes(), alg),
                      f"{sum_file.name}: missing or wrong")
        unexpected = {p.name for p in out.iterdir()} - {
            f"{f.name}{ext}" for f in files.values() for ext in ("", ".asc", ".md5", ".sha1", ".sha256", ".sha512")}
        check(not unexpected, f"unexpected files: {sorted(unexpected)}")

    if problems:
        print("\n".join(problems), file=sys.stderr)
        raise SystemExit(f"{len(problems)} problem(s) in {out}")
    print(f"{out}: ok ({len(natives)} natives, built from {built}{', signed' if signed else ''})")


if __name__ == "__main__":
    main()
