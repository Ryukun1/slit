#!/usr/bin/env python3
"""Add one release to Slit's Sparkle feed (appcast.xml), newest first.

Used by .github/workflows/release.yml. Refuses to add a build number that is
already in the feed, and checks the result is well-formed XML before writing.
"""
import argparse
import email.utils
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

MARKER = "<!-- Releases, newest first. Added by the release workflow. -->"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--version", required=True, help="e.g. 1.1")
    parser.add_argument("--build", required=True, help="CFBundleVersion, an integer")
    parser.add_argument("--url", required=True, help="https URL of the DMG")
    parser.add_argument("--notes-url", required=True)
    parser.add_argument("--signature", required=True, help="base64 EdDSA signature")
    parser.add_argument("--length", required=True, help="DMG size in bytes")
    parser.add_argument("--min-system", default="14.0")
    args = parser.parse_args(argv)

    if not re.fullmatch(r"\d+(\.\d+){1,2}", args.version):
        parser.error(f"bad --version {args.version!r}")
    for name in ("build", "length"):
        if not re.fullmatch(r"[1-9]\d*", getattr(args, name)):
            parser.error(f"--{name} must be a positive integer")
    for name in ("url", "notes_url"):
        if not getattr(args, name).startswith("https://"):
            parser.error(f"--{name.replace('_', '-')} must be an https URL")
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", args.signature):
        parser.error("--signature is not a base64 Ed25519 signature")
    return args


def item_xml(args: argparse.Namespace, pub_date: str) -> str:
    return f"""    <item>
      <title>Version {escape(args.version)}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(args.min_system)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(args.notes_url)}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>Slit {escape(args.version)}. <a href="{escape(args.notes_url)}">What's new</a></p>]]></description>
      <enclosure url={quoteattr(args.url)} type="application/octet-stream" sparkle:edSignature={quoteattr(args.signature)} length="{args.length}"/>
    </item>
"""


def existing_builds(text: str) -> set[str | None]:
    root = ET.fromstring(text)
    return {el.text for el in root.iter(f"{{{SPARKLE_NS}}}version")}


def add_item(text: str, args: argparse.Namespace, pub_date: str) -> str:
    if MARKER not in text:
        raise SystemExit(f"appcast has no marker line: {MARKER}")
    if args.build in existing_builds(text):
        raise SystemExit(f"build {args.build} is already in the feed")
    updated = text.replace(MARKER, MARKER + "\n" + item_xml(args, pub_date).rstrip("\n"), 1)
    existing_builds(updated)  # raises if the result is not well-formed
    return updated


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    text = args.appcast.read_text(encoding="utf-8")
    pub_date = email.utils.formatdate(usegmt=True)
    args.appcast.write_text(add_item(text, args, pub_date), encoding="utf-8")
    print(f"Added Slit {args.version} (build {args.build}) to {args.appcast}")


if __name__ == "__main__":
    sys.exit(main())
