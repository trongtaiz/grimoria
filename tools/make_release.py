#!/usr/bin/env python3
"""Generate the two files lib/updater.lua reads, and bump the version.

The updater installs whatever `update/manifest.json` lists, verified against
the sizes and checksums in the same file. Writing that by hand is exactly the
kind of thing that goes wrong quietly -- one stale checksum and every device
that tries to update rolls back -- so it is generated from the tree that is
about to be tagged, and nothing else.

    python3 tools/make_release.py 3.1.0 --notes "Fixes the occupation leak."

What it writes:

    update/manifest.json   the file list, with size + sha256 for each entry.
                           Read BY TAG, so it must be committed and tagged
                           together with the files it describes.
    update/latest.json     the pointer read from the default branch. This is
                           the file that makes a release visible to installs
                           in the wild; publishing it is the last step.
    grimoria.koplugin/_meta.lua   version bumped to match.

The contract number and the field names are frozen -- lib/updater.lua explains
why at length. Adding a field is fine; changing what one means is not.

--updater-version is the escape hatch. Raise it only when a release cannot be
installed by the updater already on people's devices; those installs will then
replace their own lib/updater.lua first and update on a second pass.

RUN `git add -A` FIRST. The manifest is checked against the git index before it
is written -- a file the repository does not have, or one whose bytes differ
from what git stored, is refused rather than shipped. See check_against_git.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

CONTRACT = 1
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN_DIR = os.path.join(REPO_ROOT, "grimoria.koplugin")
UPDATE_DIR = os.path.join(REPO_ROOT, "update")

# Never shipped to a device, so never in the manifest. test/ is the developer
# harness; the dot-directories are the updater's own workspace. This list is
# the same exclusion lib/updater.lua applies when it decides what to move
# aside -- if the two ever disagree, files start disappearing across updates.
SKIP_TOP = {"test", ".update-staging", ".update-backup"}


def iter_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
            dirnames[:] = [d for d in dirnames if d not in SKIP_TOP and not d.startswith(".")]
        else:
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            rel = os.path.join(rel_dir, name).replace("\\", "/")
            yield rel, os.path.join(dirpath, name)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args):
    """Run a git command in the repo, or return None if git is unavailable."""
    try:
        out = subprocess.run(("git",) + args, cwd=REPO_ROOT,
                             capture_output=True, check=True)
        return out.stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def check_against_git(files):
    """The manifest must describe exactly what the tag will actually serve.

    The updater downloads from raw.githubusercontent.com, which serves the
    COMMITTED blob -- so a manifest generated from the working tree is a
    statement about a different set of bytes, and two ways of being wrong have
    already been found the hard way:

      * A FILE GIT DOES NOT HAVE. `bash.exe.stackdump`, a Cygwin crash artifact,
        appeared inside the plugin folder during a release. It is gitignored, so
        raw.githubusercontent answers 404 -- and the updater cannot tell a 404
        from a private repository, so every install would fail verification on a
        file that was never meant to exist.

      * DIFFERENT BYTES. Git normalises CRLF to LF on commit (.gitattributes
        pins this), so a file that has never been through a checkout can hash
        differently in the working tree than in the repository. That was caught
        by hand before v3.1.0 and produces "expected 12071 bytes, got 11983" on
        every device, which says nothing about its cause.

    Both are checked here rather than remembered, because the failure lands on
    other people's devices and there is no console on a Kindle.
    """
    listing = git("ls-files", "-z", "--", os.path.relpath(PLUGIN_DIR, REPO_ROOT))
    if listing is None:
        print("make_release: WARNING -- git is not available, so the manifest "
              "could not be checked against what the repository will serve.")
        return

    prefix = os.path.relpath(PLUGIN_DIR, REPO_ROOT).replace("\\", "/") + "/"
    tracked = set()
    for name in listing.decode("utf-8").split("\0"):
        if name.startswith(prefix):
            tracked.add(name[len(prefix):])

    untracked = [f["path"] for f in files if f["path"] not in tracked]
    if untracked:
        sys.exit("make_release: these files are in the plugin folder but not in "
                 "git, so the release would list files nobody can download:\n  "
                 + "\n  ".join(untracked)
                 + "\n\nEither `git add` them, or remove them from the plugin "
                   "folder if they are junk. Then run this again.")

    differing = []
    for f in files:
        blob = git("show", ":" + prefix + f["path"])
        if blob is None:
            continue                      # staged-only oddity; the check above
                                          # already proved git knows the path
        if len(blob) != f["size"] or hashlib.sha256(blob).hexdigest() != f["sha256"]:
            differing.append("%s (working tree %d bytes, repository %d)"
                             % (f["path"], f["size"], len(blob)))
    if differing:
        sys.exit("make_release: these files differ between the working tree and "
                 "what git has staged, so the manifest describes bytes the "
                 "release will not serve (line endings are the usual cause):\n  "
                 + "\n  ".join(differing)
                 + "\n\n`git add` the plugin folder, then run this again.")

    print("checked %d file(s) against the git index -- all match" % len(files))


def bump_meta(version):
    """Rewrite _meta.lua's version in place.

    A targeted regex rather than a rewrite of the file: _meta.lua also carries
    the gettext-wrapped name and description KOReader shows in its plugin list,
    and regenerating those from here would silently drop any edit made to them.
    """
    path = os.path.join(PLUGIN_DIR, "_meta.lua")
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    new, n = re.subn(r'(version\s*=\s*")[^"]*(")', r"\g<1>%s\g<2>" % version, text, count=1)
    if n != 1:
        sys.exit("make_release: could not find a version field in %s" % path)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(new)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version", help='the new version, e.g. "3.1.0"')
    ap.add_argument("--tag", help='git tag holding it (default: "v" + version)')
    ap.add_argument("--notes", default="", help="one or two lines shown to the user")
    ap.add_argument("--updater-version", type=int, default=1,
                    help="minimum updater this release needs (raise only when "
                         "older updaters genuinely cannot install it)")
    ap.add_argument("--no-bump", action="store_true",
                    help="leave _meta.lua alone (it already carries this version)")
    args = ap.parse_args()

    if not re.match(r"^\d+(\.\d+)*$", args.version):
        sys.exit("make_release: version must be numeric and dotted, e.g. 3.1.0")
    tag = args.tag or ("v" + args.version)

    if not os.path.isdir(PLUGIN_DIR):
        sys.exit("make_release: no grimoria.koplugin/ next to tools/")

    if not args.no_bump:
        print("bumped %s -> %s" % (bump_meta(args.version), args.version))

    files = []
    total = 0
    for rel, path in iter_files(PLUGIN_DIR):
        size = os.path.getsize(path)
        total += size
        files.append({"path": rel, "size": size, "sha256": sha256(path)})

    if not files:
        sys.exit("make_release: the plugin folder is empty?")

    # main.lua must be in there, or an install would end up with no plugin.
    if not any(f["path"] == "main.lua" for f in files):
        sys.exit("make_release: main.lua is missing from the manifest")
    if not any(f["path"] == "lib/updater.lua" for f in files):
        sys.exit("make_release: lib/updater.lua is missing -- an install that "
                 "took this release could never update again")

    check_against_git(files)

    os.makedirs(UPDATE_DIR, exist_ok=True)

    manifest = {"contract": CONTRACT, "version": args.version, "tag": tag, "files": files}
    # The explicit LF newline is not cosmetic. On Windows, Python's text mode
    # writes CRLF; git normalises it back to LF on commit; and anything that
    # hashed the local copy then disagrees with what the repository serves.
    # That is exactly the class of failure .gitattributes exists to prevent,
    # and it would make every update fail verification with a byte-count error
    # that says nothing about its cause.
    manifest_path = os.path.join(UPDATE_DIR, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write("\n")

    latest = {
        "contract": CONTRACT,
        "version": args.version,
        "tag": tag,
        "updater_version": args.updater_version,
        "notes": args.notes,
    }
    latest_path = os.path.join(UPDATE_DIR, "latest.json")
    with open(latest_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(latest, f, indent=1, sort_keys=True)
        f.write("\n")

    print("wrote %s  (%d files, %.0f KB)" % (manifest_path, len(files), total / 1024.0))
    print("wrote %s" % latest_path)
    print()
    print("Next, in this order -- latest.json is what makes the release visible,")
    print("so it must not point at a tag that does not exist yet:")
    print("  git add -A && git commit -m 'Release %s'" % args.version)
    print("  git tag %s && git push && git push --tags" % tag)
    print()
    print("Then verify from a device one version behind: Menu -> Grimoria ->")
    print("Check for updates. A release nobody has installed once is untested.")


if __name__ == "__main__":
    main()
