#!/usr/bin/env python3
"""Third-party notices and a CycloneDX SBOM for one module of core-crypto-kmp.

The components of a module are the Rust crates linked into core-crypto-ffi for its targets (normal
dependencies, without proc-macros, which only run at build time), the C libraries those crates
compile in, and the Maven dependencies of its POM. Licence texts come from each crate's own licence
files; crates without any get the standard text from release/licenses/.

  release/third-party.py notices <module> <version> <output file>
  release/third-party.py sbom <module> <version> <output file> <pom> <artifact> [<name>=<file> ...]

<module> is a Maven module of core-crypto-kmp, e.g. core-crypto-kmp-jvm, and <version> Wire's version
with the patch set, e.g. 10.5.2-digits.1. The SBOM lists the module's artifact (its jar, aar or klib)
and the named files, such as the native libraries in it, with their SHA-512. Run it from the
repository root.
"""
import hashlib
import json
import re
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

GROUP = "schwarz.opensource.natrium"
REPO_URL = "https://github.com/SchwarzDigits/core-crypto"
SUPPLIER = {"name": "Schwarz Digits KG", "url": ["https://schwarz-it.com"]}
WIRE = {"name": "Wire Swiss GmbH", "url": ["https://wire.com"]}

# The modules of core-crypto-kmp: the Rust targets whose libraries they carry, and the C libraries
# in those. The common module carries none.
MODULES = {
    "core-crypto-kmp": {"targets": [], "c_libraries": []},
    "core-crypto-kmp-jvm": {
        "targets": ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "aarch64-apple-darwin",
                    "x86_64-pc-windows-gnu"],
        "c_libraries": ["sqlite3mc"],
    },
    "core-crypto-kmp-android": {
        "targets": ["aarch64-linux-android", "armv7-linux-androideabi", "x86_64-linux-android"],
        "c_libraries": ["sqlcipher", "openssl"],
    },
    "core-crypto-kmp-iosarm64": {"targets": ["aarch64-apple-ios"], "c_libraries": ["sqlcipher", "openssl"]},
    "core-crypto-kmp-iossimulatorarm64": {"targets": ["aarch64-apple-ios-sim"],
                                          "c_libraries": ["sqlcipher", "openssl"]},
    "core-crypto-kmp-macosarm64": {"targets": ["aarch64-apple-darwin"], "c_libraries": ["sqlite3mc"]},
}

# The licence of CoreCrypto, in the repository's LICENSE. Crates of this repository under it are
# CoreCrypto itself; the others are listed with the third-party components.
ARTIFACT_LICENSE = "GPL-3.0-only"
# Crates whose manifest has no licence field, with the licence their repository states.
CLARIFIED_LICENSES = {"pkiprocmacros": "Apache-2.0 OR MIT"}
# Maven dependencies by group, as their POMs state.
MAVEN_LICENSES = {
    "org.jetbrains.kotlin": "Apache-2.0",
    "org.jetbrains.kotlinx": "Apache-2.0",
    "net.java.dev.jna": "LGPL-2.1-or-later OR Apache-2.0",
    "androidx.annotation": "Apache-2.0",
}
LICENSE_FILE_PREFIXES = ("LICENSE", "LICENCE", "COPYING", "UNLICENSE", "NOTICE")
STANDARD_TEXTS = [("MIT", "MIT.txt"), ("Apache-2.0", "Apache-2.0.txt"), ("MPL-2.0", "MPL-2.0.txt")]
SQLITE_NOTICE = "The SQLite source code is in the public domain, see https://sqlite.org/copyright.html."

ROOT = Path.cwd()
HERE = Path(__file__).resolve().parent


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"{' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def check_version(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+-digits\.\d+", version):
        raise SystemExit(f"version {version!r} is not <Wire's version>-digits.<n>")


def linked_crates(spec):
    """(name, version) of every crate linked into core-crypto-ffi for any of the module's targets."""
    crates = set()
    for target in spec["targets"]:
        tree = run("cargo", "tree", "--locked", "--quiet", "-p", "core-crypto-ffi", "--target", target,
                   "--edges", "normal,no-proc-macro", "--prefix", "none", "--format", "{p}")
        for line in tree.splitlines():
            name, version = line.split()[:2]
            crates.add((name, version.lstrip("v")))
    return crates


def licence_files(directory):
    return sorted(p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(LICENSE_FILE_PREFIXES))


def standard_text(expression):
    if "GPL-3.0" in expression:
        return "GPL-3.0", (ROOT / "LICENSE").read_text()
    for spdx, file in STANDARD_TEXTS:
        if spdx in expression:
            return spdx, (HERE / "licenses" / file).read_text()
    raise SystemExit(f"no standard text for licence expression {expression!r}")


def c_version(path, pattern):
    match = re.search(pattern, Path(path).read_text(errors="replace"))
    if not match:
        raise SystemExit(f"no version in {path}")
    return match.group(1)


def c_library(name, version, licence, author, purl, url, files, via, text=None):
    return {"name": name, "version": version, "license": licence, "author": author,
            "purl": purl.format(version=version), "url": url, "files": files, "via": via, "text": text}


def c_libraries(spec, packages):
    """The C libraries the module's crates compile in, with their licence files."""
    libraries = []
    vendor = ROOT / "vendor/libsqlite3-sys"
    if "sqlite3mc" in spec["c_libraries"]:
        source = vendor / "sqlite3mc/sqlite3mc_amalgamation.c"
        libraries += [
            c_library("SQLite3 Multiple Ciphers",
                      c_version(source, r'SQLITE3MC_VERSION_STRING\s+"SQLite3 Multiple Ciphers ([0-9.]+)"'), "MIT",
                      "Ulrich Telle", "pkg:github/utelle/SQLite3MultipleCiphers@v{version}",
                      "https://github.com/utelle/SQLite3MultipleCiphers", [vendor / "sqlite3mc/LICENSE"],
                      "libsqlite3-sys (vendored, feature bundled-sqlite3mc)"),
            c_library("SQLite", c_version(source, r'#define SQLITE_VERSION\s+"([0-9.]+)"'), None,
                      "D. Richard Hipp and contributors", "pkg:generic/sqlite@{version}",
                      "https://sqlite.org/copyright.html", [], "SQLite3 Multiple Ciphers", SQLITE_NOTICE),
        ]
    if "sqlcipher" in spec["c_libraries"]:
        source = vendor / "sqlcipher/sqlite3.c"
        libraries += [
            c_library("SQLCipher", c_version(source, r"#define CIPHER_VERSION_NUMBER ([0-9.]+)"), "BSD-3-Clause",
                      "Zetetic LLC", "pkg:github/sqlcipher/sqlcipher@v{version}",
                      "https://github.com/sqlcipher/sqlcipher", [vendor / "sqlcipher/LICENSE"],
                      "libsqlite3-sys (vendored, feature bundled-sqlcipher)"),
            c_library("SQLite", c_version(source, r'#define SQLITE_VERSION\s+"([0-9.]+)"'), None,
                      "D. Richard Hipp and contributors", "pkg:generic/sqlite@{version}",
                      "https://sqlite.org/copyright.html", [], "SQLCipher", SQLITE_NOTICE),
        ]
    if "openssl" in spec["c_libraries"]:
        source = next(Path(p["manifest_path"]).parent for p in packages if p["name"] == "openssl-src")
        numbers = dict(re.findall(r"^(MAJOR|MINOR|PATCH)=(\d+)", (source / "openssl/VERSION.dat").read_text(), re.M))
        libraries.append(
            c_library("OpenSSL", f"{numbers['MAJOR']}.{numbers['MINOR']}.{numbers['PATCH']}", "Apache-2.0",
                      "The OpenSSL Project Authors", "pkg:generic/openssl@{version}", "https://www.openssl.org",
                      [source / "openssl/LICENSE.txt"], "openssl-src (feature vendored of openssl-sys)"))
    return libraries


def components(spec):
    if not spec["targets"]:
        return [], []
    meta = json.loads(run("cargo", "metadata", "--format-version", "1", "--locked"))
    workspace = set(meta["workspace_members"])
    by_key = {}
    for package in meta["packages"]:
        by_key.setdefault((package["name"], package["version"]), []).append(package)
    crates = []
    for key in sorted(linked_crates(spec)):
        for package in by_key[key]:
            licence = package.get("license") or CLARIFIED_LICENSES.get(package["name"])
            if not licence:
                raise SystemExit(f"{package['name']} {package['version']} has no licence")
            own = package["id"] in workspace
            crates.append({"name": package["name"], "version": package["version"], "license": licence,
                           "authors": package.get("authors") or [], "repository": package.get("repository"),
                           "own": own, "core": own and licence == ARTIFACT_LICENSE,
                           "source": package.get("source") or "", "dir": Path(package["manifest_path"]).parent})
    return crates, c_libraries(spec, meta["packages"])


def notices(module, version, output):
    crates, libraries = components(MODULES[module])
    listed = [c for c in crates if not c["core"]]
    texts = {}  # licence text without whitespace -> (text, components that use it)

    def add(text, who):
        texts.setdefault(" ".join(text.split()), (text.strip(), []))[1].append(who)

    for crate in listed:
        who = f"{crate['name']} {crate['version']}"
        files = licence_files(crate["dir"])
        if files:
            for f in files:
                add(f.read_text(errors="replace"), f"{who} ({f.name})")
        else:
            name, text = standard_text(crate["license"])
            add(text, f"{who} (standard {name} text)")
    for library in libraries:
        who = f"{library['name']} {library['version']}"
        for f in library["files"]:
            add(f.read_text(errors="replace"), f"{who} ({f.name})")
        if library["text"]:
            add(library["text"], who)

    lines = [f"THIRD-PARTY NOTICES for {GROUP}:{module}:{version}", "",
             "This artifact is CoreCrypto by Wire Swiss GmbH, with changes by Schwarz Digits KG, licensed",
             "under the GNU General Public License v3.0 (see LICENSE). Its source code is at",
             f"{REPO_URL}, tag v{version}.", "",
             "It contains the components below, which are licensed under their own terms.", ""]
    lines += [f"C libraries ({len(libraries)})", "-" * 40]
    for library in libraries:
        lines.append(f"{library['name']} {library['version']}  [{library['license'] or 'Public Domain'}]  "
                     f"{library['author']}; in {library['via']}")
    lines += ["", f"Rust crates ({len(listed)})", "-" * 40]
    for crate in listed:
        authors = ", ".join(crate["authors"]) or "see licence text"
        lines.append(f"{crate['name']} {crate['version']}  [{crate['license']}]  {authors}")
    lines += ["", "Licence texts", "-" * 40]
    for text, users in texts.values():
        lines += ["", "=" * 78, "Used by: " + ", ".join(users), "=" * 78, "", text]
    Path(output).write_text("\n".join(lines) + "\n")
    print(f"{output}: {len(listed)} crates, {len(libraries)} C libraries, {len(texts)} distinct licence texts")


def sha512(path):
    return hashlib.sha512(Path(path).read_bytes()).hexdigest()


def vcs_purl(url, rev):
    return "?vcs_url=" + quote(f"{url}@{rev}", safe=":/")


def maven_dependencies(pom):
    ns = {"m": "http://maven.apache.org/POM/4.0.0"}
    dependencies = []
    for dependency in ET.parse(pom).getroot().findall("m:dependencies/m:dependency", ns):
        group, name, version, scope = (dependency.findtext(f"m:{field}", "", ns)
                                       for field in ("groupId", "artifactId", "version", "scope"))
        if group not in MAVEN_LICENSES:
            raise SystemExit(f"no licence known for Maven group {group}")
        dependencies.append((group, name, version, scope))
    return dependencies


def sbom(module, version, output, pom, artifact, files):
    crates, libraries = components(MODULES[module])
    commit = run("git", "rev-parse", "HEAD").strip()
    top_purl = f"pkg:maven/{GROUP}/{module}@{version}"
    top = {"type": "library", "bom-ref": top_purl, "group": GROUP, "name": module, "version": version,
           "purl": top_purl, "supplier": SUPPLIER, "licenses": [{"license": {"id": ARTIFACT_LICENSE}}],
           "hashes": [{"alg": "SHA-512", "content": sha512(artifact)}],
           "externalReferences": [{"type": "vcs", "url": f"{REPO_URL}/tree/v{version}"}]}
    entries = []
    for crate in crates:
        purl = f"pkg:cargo/{crate['name']}@{crate['version']}"
        if crate["own"]:
            purl += vcs_purl(f"git+{REPO_URL}", commit)
        elif crate["source"].startswith("git+"):
            url, rev = crate["source"].split("#")
            purl += vcs_purl(url.split("?")[0], rev)
        entry = {"type": "library", "bom-ref": purl, "name": crate["name"], "version": crate["version"], "purl": purl,
                 "licenses": [{"expression": crate["license"]}]}
        if crate["own"]:
            entry["supplier"] = WIRE
        if crate["authors"]:
            entry["author"] = ", ".join(crate["authors"])
        if crate["repository"]:
            entry["externalReferences"] = [{"type": "vcs", "url": crate["repository"]}]
        entries.append(entry)
    for library in libraries:
        licence = ([{"license": {"id": library["license"]}}] if library["license"]
                   else [{"license": {"name": "Public Domain"}}])
        entries.append({"type": "library", "bom-ref": library["purl"], "name": library["name"],
                        "version": library["version"], "purl": library["purl"], "author": library["author"],
                        "licenses": licence, "externalReferences": [{"type": "website", "url": library["url"]}]})
    dependencies = maven_dependencies(pom)
    for group, name, dep_version, scope in dependencies:
        purl = f"pkg:maven/{group}/{name}@{dep_version}"
        entries.append({"type": "library", "bom-ref": purl, "group": group, "name": name, "version": dep_version,
                        "purl": purl, "licenses": [{"expression": MAVEN_LICENSES[group]}],
                        "properties": [{"name": "maven:scope", "value": scope}]})
    for f in files:
        name, separator, path = f.partition("=")
        if not separator:
            raise SystemExit(f"{f}: files are given as <name>=<file>")
        entries.append({"type": "file", "bom-ref": f"file:{name}", "name": name,
                        "hashes": [{"alg": "SHA-512", "content": sha512(path)}]})
    document = {
        "bomFormat": "CycloneDX", "specVersion": "1.5",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, f"{top_purl}#{commit}")),
        "version": 1,
        "metadata": {"timestamp": run("git", "log", "-1", "--format=%cI").strip(), "supplier": SUPPLIER,
                     "component": top,
                     "tools": {"components": [{"type": "application", "name": "release/third-party.py",
                                               "version": commit}]}},
        "components": entries,
        "dependencies": [{"ref": top_purl, "dependsOn": [e["bom-ref"] for e in entries if e["type"] == "library"]}],
    }
    Path(output).write_text(json.dumps(document, indent=2) + "\n")
    print(f"{output}: {len(crates)} crates, {len(libraries)} C libraries, {len(dependencies)} Maven dependencies")


def main():
    args = sys.argv[1:]
    if len(args) < 4 or args[0] not in ("notices", "sbom") or args[1] not in MODULES:
        raise SystemExit(__doc__)
    check_version(args[2])
    if args[0] == "notices" and len(args) == 4:
        notices(*args[1:4])
    elif args[0] == "sbom" and len(args) >= 6:
        sbom(*args[1:6], args[6:])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
