#!/usr/bin/env python3
"""Write only reviewed public values to the fork's ignored release overrides."""
import argparse
import os
from pathlib import Path

from fork_release import NAMESPACE, FORK, STABLE, PREVIEW, validate_info, release_build_number
from sparkle_setup import DEFAULT_CONFIG, read_public_key


def configuration(commit, tag, environment, public_config=DEFAULT_CONFIG):
    public_key = read_public_key(public_config)
    override = environment.get("FORK_SPARKLE_PUBLIC_KEY", "")
    if override and override != public_key:
        raise ValueError("Repository Sparkle variable must match the checked-in fork public key")
    info = {"CFBundleIdentifier": NAMESPACE, "NativForkRepository": FORK, "NativForkRevision": commit,
            "CFBundleShortVersionString": tag.removeprefix("v").split("rc")[0], "CFBundleVersion": "1",
            "SUFeedURL": STABLE, "NativPreviewFeedURL": PREVIEW,
            "SUPublicEDKey": public_key,
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            "NativGitHubAppClientID": environment.get("FORK_GITHUB_APP_CLIENT_ID", ""),
            "NativGitHubAppSlug": environment.get("FORK_GITHUB_APP_SLUG", "")}
    validate_info(info, commit)
    values = {"NATIV_SPARKLE_PUBLIC_KEY": info["SUPublicEDKey"],
              "NATIV_GITHUB_APP_CLIENT_ID": info["NativGitHubAppClientID"],
              "NATIV_GITHUB_APP_SLUG": info["NativGitHubAppSlug"],
              "NATIV_FORK_REVISION": commit,
              "NATIV_STABLE_FEED_URL": STABLE.replace("://", ":/$()/"),
              "NATIV_PREVIEW_FEED_URL": PREVIEW.replace("://", ":/$()/")}
    for key, value in values.items():
        if "\n" in value or "\r" in value or "#" in value:
            raise ValueError("Invalid public release value: " + key)
    return "".join(key + " = " + value + "\n" for key, value in values.items())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    Path("Configuration/Signing.local.xcconfig").write_text(configuration(args.commit, args.tag, os.environ))
    build = release_build_number(args.tag)
    with open(os.environ["GITHUB_ENV"], "a") as handle:
        handle.write(f"FORK_BUILD_NUMBER={build}\n")
