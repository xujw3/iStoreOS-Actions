#!/usr/bin/env python3
"""Lightweight repository checks for GitHub workflow maintenance."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
WORKFLOWS = sorted(WORKFLOW_DIR.glob("*.yml"))
BUILD_CONFIG = ROOT / ".github" / "build-config.env"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_build_config() -> dict[str, str]:
    config: dict[str, str] = {}
    for line in read_text(BUILD_CONFIG).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        config[key.strip()] = value.strip()
    return config


def collect_board_options(path: Path) -> list[str]:
    lines = read_text(path).splitlines()
    in_board = False
    in_options = False
    options: list[str] = []

    for line in lines:
        if re.match(r"^\s{6}openwrt_board:\s*$", line):
            in_board = True
            continue

        if in_board and re.match(r"^\s{8}options:\s*$", line):
            in_options = True
            continue

        if in_options:
            if re.match(r"^\s{6}[A-Za-z0-9_]+:\s*$", line):
                break
            match = re.match(r"^\s+-\s+(.+?)\s*$", line)
            if match:
                options.append(match.group(1))

    return options


def collect_package_entries(path: Path) -> list[str]:
    entries: list[str] = []
    for line in read_text(path).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.append(line)
    return entries


def main() -> int:
    errors: list[str] = []

    if not BUILD_CONFIG.exists():
        errors.append(".github/build-config.env is missing")
        config: dict[str, str] = {}
    else:
        config = read_build_config()

    version = config.get("VERSION")
    if not version:
        errors.append(".github/build-config.env must define VERSION")
    elif not re.fullmatch(r"\d+\.\d+\.\d+", version):
        errors.append(f".github/build-config.env VERSION looks invalid: {version}")

    for path in WORKFLOWS:
        text = read_text(path)
        display = path.relative_to(ROOT).as_posix()

        if "actions/checkout@v3" in text:
            errors.append(f"{display}: use actions/checkout@v4 or newer")
        if re.search(r"uses:\s+[^\n]+@main\b", text):
            errors.append(f"{display}: pin external actions instead of @main")
        if "secrets.GH_TOKEN" in text:
            errors.append(f"{display}: use the built-in github.token with explicit permissions")
        if "env.VERSION" in text or re.search(r"^\s+VERSION:\s+\d", text, re.MULTILINE):
            errors.append(f"{display}: read VERSION from .github/build-config.env instead of redefining it")
        if re.search(r"sed\s+-i\s+['\"][0-9]+,[0-9]+d", text):
            errors.append(f"{display}: avoid line-number based sed deletion")

    st1 = ROOT / ".github" / "workflows" / "St1_Build-Rootfs-release.yml"
    if "steps.build_config.outputs.version" not in read_text(st1):
        errors.append("St1_Build-Rootfs-release.yml: build config version output is not used")

    st2 = ROOT / ".github" / "workflows" / "St2_Build-iStoreOS-ib.yml"
    stx = ROOT / ".github" / "workflows" / "StX_Build-iStoreOS-src.yml"
    st2_boards = collect_board_options(st2)
    stx_boards = collect_board_options(stx)

    if not st2_boards:
        errors.append("St2_Build-iStoreOS-ib.yml: openwrt_board options not found")
    if not stx_boards:
        errors.append("StX_Build-iStoreOS-src.yml: openwrt_board options not found")
    if st2_boards and stx_boards and st2_boards != stx_boards:
        errors.append("St2/StX openwrt_board option lists differ")

    if version:
        repositories_conf = read_text(ROOT / "arm64" / "repositories.conf")
        if f"/releases/{version}/" not in repositories_conf:
            errors.append("arm64/repositories.conf does not reference the configured VERSION")

    package_dir = ROOT / "arm64" / "package-lists"
    for path in sorted(package_dir.glob("*.txt")):
        entries = collect_package_entries(path)
        seen: set[str] = set()
        duplicates = sorted({entry for entry in entries if entry in seen or seen.add(entry)})
        if duplicates:
            display = path.relative_to(ROOT).as_posix()
            errors.append(f"{display}: duplicate package entries: {', '.join(duplicates[:5])}")

    if errors:
        print("Repository checks failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print("Repository checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
