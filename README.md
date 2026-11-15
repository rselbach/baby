# Baby

Baby is a macOS menu bar app that keeps your Mac awake. It stays awake until
you click again, a timer runs out, or the job that asked finishes. Scripts and
coding agents use its `baby` command line tool. Baby needs Apple silicon and
macOS 14 or later.

Download it from [rselbach.com/baby](https://rselbach.com/baby/) or the
[latest release](https://github.com/rselbach/baby/releases/latest).

## Using Baby

Baby keeps the Mac awake while any *lease* is held and lets it sleep once the
last one ends.

- **Left-click** the icon to hold your own lease, and again to release it. A
  click never ends someone else's lease.
- **Right-click** (or Control- or Option-click) for the menu. **Activate for**
  holds your lease for a while; the leases are listed with a way to release
  each one.
- **Settings** turns on Start at Login and Activate on Launch, edits the
  durations under Activate for, installs the command line tool, and checks for
  updates.

Your own lease keeps both the system and the display awake. A lease from an
agent or script keeps only the system awake, so an overnight job doesn't
light the screen. The icon is faded while only those leases are held.

## The `baby` command

In Settings, **Install** links the tool into `~/.local/bin/baby`. macOS
doesn't put that folder on your `PATH`, so add it if your shell can't find
`baby`:

```sh
export PATH="$HOME/.local/bin:$PATH"   # in ~/.zshrc
```

```text
baby run [--for DURATION] [--id ID] [--label LABEL] [--] COMMAND [ARG...]
baby hold [--for DURATION] [--pid PID] [--id ID] [--label LABEL]
baby release [--] ID
baby status [--json]
```

- `baby run make test` keeps the Mac awake until `make test` exits. The lease
  belongs to the tool's own process, which then becomes the command, so the
  lease ends exactly when the command does.
- `baby hold` prints a lease ID. The lease lasts until `baby release ID`, until
  `--for` passes, or until `--pid` exits, whichever comes first. Holding an
  existing ID replaces that lease.
- `baby release` succeeds even if the lease already ended, so retries are safe.
- `baby status --json` prints `{"awake": …, "leases": […], "running": …}`.

A DURATION combines numbers with `d`, `h`, `m`, or `s`, such as `90s`, `45m`,
or `1h30m`. `run` and `hold` open Baby if it isn't running.

Lease IDs are 1 to 64 letters, digits, dots, dashes, or underscores. `user`
is reserved for the menu's own lease. Labels are trimmed to 64 characters and
256 UTF-8 bytes. Baby holds at most 63 agent leases at a time.

## The control protocol

The tool talks to Baby over a Unix socket at
`~/Library/Application Support/Baby/control.sock`. Only processes running as
the same user can connect. Each connection carries one request and one reply,
each a single line of JSON of at most 64 KiB. Dates are ISO 8601 in UTC.

```json
{"command": "hold", "id": "build", "label": "make", "seconds": 3600, "pid": 48211}
{"lease": {"deadline": "2026-11-15T13:00:00Z", "id": "build", "label": "make", "pid": 48211}}
```

Requests:

| `command` | Fields | Reply |
| --- | --- | --- |
| `hold` | optional `id`, `label`, `seconds`, `pid` | `lease`: the lease held |
| `release` | `id` | `{}` |
| `status` | none | `leases`: every active lease, in the order first held |

A failed request is answered with `{"error": "…"}`. Baby serves up to eight
connections at once. Beyond that it answers that it is busy, and the client
should retry.

## Building

```sh
swift test
./build.sh                 # build/Baby.app, signed ad hoc without a Developer ID
```

`build.sh` signs with the team's Developer ID Application identity when the
keychain has one. `SIGNING_IDENTITY`, `VERSION`, and `BUILD` override the
identity and the bundle's version and build.

The release tooling and website have tests of their own:

```sh
python3 Tests/BuildTests/test_versions.py
python3 Tests/BuildTests/test_rotate_feed_key.py
python3 Tests/DeploymentTests/test_deploy_site.py
python3 Tests/DeploymentTests/test_feed_succession.py
node --test Tests/SiteTests/*.test.mjs
```

## Releasing

Push a `vX.Y.Z` tag. `.github/workflows/release.yml` then does the rest:

1. It builds, signs, and notarizes Baby.
2. It publishes a ZIP for the updater and a DMG for people to install from.
3. It signs `update.json` and deploys it to GitHub Pages, but only after the
   published ZIP downloads and verifies against the signed feed.

The build number comes from the version: `X * 1000000 + Y * 1000 + Z`, from
`scripts/build-number.sh`. Rerunning a release or re-pushing its tag keeps the
same number, and each new version gets a larger one. Y and Z must stay below
1000. A rerun reuses assets that are already published rather than signing
new bytes under the same build.

The workflow needs these repository secrets:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application certificate and key, base64 P12 |
| `MACOS_CERTIFICATE_PASSWORD` | Password of that P12 |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD` | Notarization account |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Seed of the legacy feed key, `UpdateConfig.legacyPublicKey` |
| `BABY_FEED_SIGNING_KEY` | Seed of the dedicated feed key, once rotated (below) |

GitHub Pages must use "GitHub Actions" as its source.

### How updates are trusted

Baby reads `https://rselbach.github.io/baby/update.json`, checking it at
launch and then daily. A feed is accepted only if:

- one of its Ed25519 signatures is by a key the build trusts, signed over a
  `baby-update-feed-v1` context;
- it hasn't expired;
- its build is no lower than any build Baby has already seen.

A downloaded ZIP must match the feed's size and SHA-256. The app inside must
match the feed's version and build, and must be Developer ID signed by the
team and notarized. Baby swaps it in with one atomic rename and keeps the old
copy until the new one has launched.

Each feed expires 90 days after it is signed, so a feed can't be held back or
replayed indefinitely to hide newer releases. `.github/workflows/refresh-feed.yml`
runs weekly and re-signs the live feed once fewer than 60 days remain. GitHub
turns scheduled workflows off after 60 days without repository activity. If
that happens, run **Refresh feed** by hand before the feed expires.

### Rotating to a dedicated feed key

The feed has been signed with a key shared with Sparkle. To give it a key of
its own, run this once on a Mac with `gh` signed in:

```sh
scripts/rotate-feed-key.sh ~/baby-feed-key.txt
```

The script does three things:

- generates a new key and writes its seed to the file you name;
- stores the seed as the `BABY_FEED_SIGNING_KEY` secret;
- updates `UpdateConfig.publicKeys` and `site/site.js` to trust only the new
  key.

Save the seed in a password manager and delete the file: builds that trust the
new key can't update without it. Commit, release, and then deploy the website.

Feeds keep a `signature` by the shared key in the field older builds read, so
those builds still update. The dedicated key's signature goes in
`signatures`, which only newer builds and the website read.

## Website

`site/` is the download page at `https://rselbach.com/baby/`. `./deploy-site.sh`
uploads it and switches the live site over in one step, rolling back if
nginx or the live checks fail.

## License

MIT. See [LICENSE](LICENSE).
