# Releasing AmigaCD

A release is a GitHub release that carries the **whole package**: the core,
the userspace binary and the menu core, each at its latest published release.
It is made **by hand, on demand**. `.github/workflows/release.yml` has
`workflow_dispatch` as its only trigger, so no push or pull request publishes
anything.

## The three parts, and where they come from

| File | From | How it gets there |
|---|---|---|
| `_Computer/AmigaCD_<date>.rbf` | this repository | fitted in CI by `fit.yml`, from the commit being released |
| `MiSTer_AmigaCD` | [FringeCoder/AmigaCD](https://github.com/FringeCoder/AmigaCD/releases) | that repository's latest release (its own release workflow) |
| `menu.rbf` | [FringeCoder/Menu_MiSTer](https://github.com/FringeCoder/Menu_MiSTer/releases) | that repository's latest release (its own release workflow) |

"Latest" means the newest release that is not a draft or a pre-release.
Either can be pinned with the `amigacd_tag` and `menu_tag` inputs.

If either repository has no release yet, nothing is published: the package
has to be complete. Release them first.

## How the core is fitted

`.github/workflows/fit.yml` runs Quartus 17.0.2 Lite for Cyclone V, from the
`theypsilon/quartus-lite-c5:17.0.2.docker1` image that the MiSTer nightly
builds use. That is the version `AmigaCD.qsf` was last saved with, and the
tag is pinned. Each placement seed is fitted in a job of its own, all in
parallel. `scripts/ci-fit.sh` runs one seed and reads both worst-case slacks
from the timing report.

- **On every push to `cd32-native-mvp`:** it fits the `.qsf`'s own seed. The
  run summary shows the slacks, and the bitstream is kept as the `core`
  artifact for 14 days. Missing timing is a warning there, not a failure.
- **In a release:** it fits every seed in the `seeds` input. Only a seed with
  setup **and** hold slack both positive can be released. `seed_sweep_both.sh`
  explains why setup alone is not enough. The best such seed is published. If
  no seed qualifies, nothing is published: try other seeds, or the change
  does not fit.
- **By hand:** Actions -> **fit** -> Run workflow, with any seeds.

The release notes record the seed and both slacks.

## Making one

1. Release FringeCoder/AmigaCD and FringeCoder/Menu_MiSTer first if either
   has changes you want in the package.
2. Go to Actions -> **release** -> **Run workflow**, on `cd32-native-mvp`.

| Input | Meaning |
|---|---|
| `tag` | Empty means `v<today, UTC>`. Must not exist yet |
| `seeds` | Placement seeds to fit in parallel. The default is the order the local sweeps ranked best |
| `allow_unchanged` | Release with no new commit since the last release, to re-package a newer userspace or menu release |
| `amigacd_tag`, `menu_tag` | The userspace and menu releases to bundle. Empty means the latest of each |
| `prerelease` | Tick for a build meant for testing |
| `notes` | Optional text shown above the changelog |

The run refuses in any of these cases:
- the branch is not the default branch;
- the tag already exists;
- nothing was committed since the previous release (unless `allow_unchanged`);
- no seed closes timing.

`rtl-sim.yml` runs as part of the release, beside the fit. If the syntax gate
or any bench fails, nothing is published.

## What is published

- `AmigaCD_<tag>.zip`, laid out like the SD card: `MiSTer_AmigaCD`,
  `menu.rbf`, `_Computer/AmigaCD_<date>.rbf` and `INSTALL.txt`.
- The three files on their own as well, for updating one piece, and
  `SHA256SUMS`.

The release notes have a table of the bundled releases, each with a link, and
this repository's changelog. Each of the other two releases carries its own
changelog.

Kickstart ROMs are never included.

## Access

FringeCoder/AmigaCD and FringeCoder/Menu_MiSTer are public, so the run's own
token can read their releases. If either becomes private, add a fine-grained
token with read-only Contents access to it as the repository secret
`AMIGACD_RELEASE_TOKEN`; the workflow uses that secret when it is set.

The changelog script `scripts/release-notes.py` is a copy of the one in
FringeCoder/AmigaCD, which owns it and its test.
