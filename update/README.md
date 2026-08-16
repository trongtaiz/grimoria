# The update contract

`lib/updater.lua` inside the plugin reads exactly two files from this
directory. Their field meanings are **frozen**: a copy of the updater
installed today has to be able to read a release published years from now, and
it has no way to learn a new interpretation of an old field.

Adding a field is always safe — older updaters ignore what they do not know.
Changing what an existing field means is not, and there is a mechanism for
that case instead (see *Breaking the format*, below).

## `latest.json` — read from the default branch

The mutable pointer. Publishing this is what makes a release visible to every
install in the wild.

```json
{
  "contract": 1,
  "version": "3.1.0",
  "tag": "v3.1.0",
  "updater_version": 1,
  "notes": "Fixes an occupation field that could reveal a later chapter."
}
```

| field | meaning |
|---|---|
| `contract` | Format generation. An updater that speaks a lower number refuses the release and says so, rather than guessing at fields it has never seen. |
| `version` | Compared numerically against the installed `_meta.lua` version. Missing components count as zero, so `3.1` equals `3.1.0`. |
| `tag` | The git tag the files are fetched from. **Never a branch** — the manifest and the files it describes must come from one immutable commit. |
| `updater_version` | The minimum updater a release needs. See below. |
| `notes` | One or two lines shown in the confirmation dialog. |

## `manifest.json` — read at the tag

The immutable file list. Every path is relative to `grimoria.koplugin/`.

```json
{
  "contract": 1,
  "version": "3.1.0",
  "tag": "v3.1.0",
  "files": [ { "path": "main.lua", "size": 11761, "sha256": "…" } ]
}
```

Paths containing `..`, absolute paths and drive letters are rejected by the
updater. `size` is always checked; `sha256` is checked whenever the KOReader
build can compute one, and its absence is not a reason to refuse an update.

**A file that exists in an install and is absent from the manifest is not
restored after the swap** — that is how a release deletes or renames a file.

## Breaking the format

When a release genuinely cannot be installed by the updaters already on
people's devices, raise `updater_version` above what they carry. Those installs
then replace *only* `lib/updater.lua`, ask for a restart, and the successor —
which by definition understands the new scheme — performs the real update on a
second pass.

This is why one rule matters more than any other here: **`lib/updater.lua`
must appear in every manifest, forever.** `make_release.py` refuses to write a
manifest without it, because an install that took such a release could never
update again.

## Producing a release

```sh
python3 tools/make_release.py 3.1.0 --notes "What changed, in one line."
git add -A && git commit -m "Release 3.1.0"
git tag v3.1.0 && git push && git push --tags
```

Order matters: `latest.json` advertises a tag, so the tag has to exist by the
time anyone reads it.

The release is not finished until an install one version behind has actually
run **Menu → Grimoria → Check for updates** against it. A release nobody has
installed once is untested, and the failure mode is a device that cannot load
its plugin.

## Configuring where updates come from

`config.lua` carries it:

```lua
update_repo = "trongtaiz/grimoria",
```

The updater accepts only a bare `owner/name`. A full URL, an empty value, or
anything still reading as a placeholder means "not configured", and the menu
says so rather than fetching from a repository somebody else controls — an
updater that silently points somewhere unexpected is a way to install arbitrary
code on a reader's device.

A fork updates from itself by editing that line. A reader can override it
without touching the plugin, by writing `owner/name` into
`<koreader>/settings/grimoria/update_repo.txt`.

### The repository has to stay public

`raw.githubusercontent.com` serves a private repository as **404**, with no
distinction from a file that does not exist. The updater has no token and
deliberately never asks for one — a plugin that stores a GitHub credential on a
Kindle is a worse problem than a manual update.

`trongtaiz/grimoria` is public and serving (`HEAD/grimoria.koplugin/main.lua`
returns 200), so the mechanism is live. Making the repository private again
would turn it off for every install in the world, silently: they would simply
report that the release information could not be read.
