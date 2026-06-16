#!/usr/bin/env python3
"""Lightweight repository checks for workflow and build metadata maintenance."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
WORKFLOWS = sorted(WORKFLOW_DIR.glob("*.yml"))
BUILD_CONFIG = ROOT / ".github" / "build-config.env"
BOARD_LIST = ROOT / "config" / "openwrt_boards.txt"
DEFAULT_BOARD = "s905d_s905x3_s912_s922x-ct2000"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_key_value_file(path: Path) -> dict[str, str]:
    config: dict[str, str] = {}
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        config[key.strip()] = value.strip()
    return config


def collect_list_entries(path: Path) -> list[str]:
    entries: list[str] = []
    for line in read_text(path).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.append(line)
    return entries


def duplicates(entries: list[str]) -> list[str]:
    seen: set[str] = set()
    dupes: set[str] = set()
    for entry in entries:
        if entry in seen:
            dupes.add(entry)
        seen.add(entry)
    return sorted(dupes)


def workflow_has_inline_board_options(text: str) -> bool:
    lines = text.splitlines()
    in_board = False
    for index, line in enumerate(lines):
        if re.match(r"^\s{6}openwrt_board:\s*$", line):
            in_board = True
            continue
        if in_board:
            if re.match(r"^\s{6}[A-Za-z0-9_]+:\s*$", line):
                return False
            if re.match(r"^\s{8}options:\s*$", line):
                return True
            if index > 0 and not line.startswith(" "):
                return False
    return False


def main() -> int:
    errors: list[str] = []

    if not BUILD_CONFIG.exists():
        errors.append(".github/build-config.env is missing")
        config: dict[str, str] = {}
    else:
        config = read_key_value_file(BUILD_CONFIG)

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

    for name in ["St2_Build-iStoreOS-ib.yml", "StX_Build-iStoreOS-src.yml"]:
        path = WORKFLOW_DIR / name
        text = read_text(path)
        if "./.github/workflows/_Pack-iStoreOS.yml" not in text:
            errors.append(f"{name}: should call the shared _Pack-iStoreOS workflow")
        if workflow_has_inline_board_options(text):
            errors.append(f"{name}: openwrt_board choices must live in config/openwrt_boards.txt")

    if not BOARD_LIST.exists():
        errors.append("config/openwrt_boards.txt is missing")
    else:
        boards = collect_list_entries(BOARD_LIST)
        if not boards:
            errors.append("config/openwrt_boards.txt is empty")
        if DEFAULT_BOARD not in boards:
            errors.append(f"config/openwrt_boards.txt does not include default board {DEFAULT_BOARD}")
        board_dupes = duplicates(boards)
        if board_dupes:
            errors.append(f"config/openwrt_boards.txt duplicate boards: {', '.join(board_dupes[:5])}")

    if version:
        repositories_conf = read_text(ROOT / "arm64" / "repositories.conf")
        if f"/releases/{version}/" not in repositories_conf:
            errors.append("arm64/repositories.conf does not reference the configured VERSION")

    package_dir = ROOT / "arm64" / "package-lists"
    for path in sorted(package_dir.glob("*.txt")):
        entries = collect_list_entries(path)
        package_dupes = duplicates(entries)
        if package_dupes:
            display = path.relative_to(ROOT).as_posix()
            errors.append(f"{display}: duplicate package entries: {', '.join(package_dupes[:5])}")

    if errors:
        print("Repository checks failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print("Repository checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
