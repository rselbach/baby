#!/usr/bin/env python3
"""Refuse to deploy a feed that doesn't supersede the live one.

Mirrors Release.verifySupersedes in Sources/BabyUpdate/Feed.swift: a new
feed must be identical to the live one, re-sign the same release with a
later expiry, or carry a higher build without a lower version. Signatures are
checked earlier by baby-update-tool; this guards the deploy step itself, for
example when an older run is redeployed.

Usage: check-feed-succession.py LIVE_FEED NEW_FEED
"""

import base64
from datetime import datetime
import json
import sys


def load(path):
    with open(path, "rb") as file:
        raw = file.read()
    envelope = json.loads(raw)
    return raw, json.loads(base64.b64decode(envelope["payload"], validate=True))


def version(text):
    parts = [int(part) for part in text.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def expiry(release):
    value = release.get("expires_at")
    if value is None:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def problem(live_path, new_path):
    """Returns why the new feed can't replace the live one, or None."""
    live_raw, live = load(live_path)
    new_raw, new = load(new_path)
    if new_raw == live_raw or new == live:
        return None
    if new["build"] == live["build"]:
        def rest(release):
            return {key: value for key, value in release.items() if key != "expires_at"}
        new_expiry, live_expiry = expiry(new), expiry(live)
        if (rest(new) != rest(live) or new_expiry is None
                or live_expiry is not None and new_expiry < live_expiry):
            return (f"refusing build {new['build']}: a live build may change only"
                    " by a later expiry")
        return None
    if new["build"] < live["build"]:
        return f"refusing build {new['build']} < live build {live['build']}"
    if version(new["version"]) < version(live["version"]):
        return f"refusing version {new['version']} < live version {live['version']}"
    return None


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    reason = problem(sys.argv[1], sys.argv[2])
    if reason:
        sys.exit(reason)


if __name__ == "__main__":
    main()
