# Releasing AmigaCD

A release is a GitHub release that carries the **whole package**: the core,
the userspace binary and the menu core, each at its latest published release.
It is made **by hand, on demand**. `.github/workflows/release.yml` has
`workflow_dispatch` as its only trigger, so no push or pull request publishes
anything.

## The three parts, and where they come from

| File | From | How it gets there |
|---|---|---|
| `_Computer/AmigaCD_<date>.rbf` | this repository | the fit you commit as `releases/AmigaCD_YYYYMMDD.rbf` |
| `MiSTer_AmigaCD` | [FringeCoder/AmigaCD](https://github.com/FringeCoder/AmigaCD/releases) | that repository's latest release (its own release workflow) |
| `menu.rbf` | [FringeCoder/Menu_MiSTer](https://github.com/FringeCoder/Menu_MiSTer/releases) | that repository's latest release (its own release workflow) |

"Latest" means the newest release that is not a draft or a pre-release.
Either can be pinned with the `amigacd_tag` and `menu_tag` inputs.

If either repository has no release yet, nothing is published: the package
has to be complete. Release them first.

The core is not built in CI. Quartus is not installed there, and the fit
needs the seed sweeps in `seed_sweep.sh` to close timing. So the release
takes the bitstream you fitted and checked, committed under `releases/` the
way MiSTer cores ship theirs. Upstream's `Minimig_*.rbf` files in that
directory are never picked up: only `AmigaCD_*.rbf` is.

## Making one

1. Fit the core, then commit it as `releases/AmigaCD_YYYYMMDD.rbf` on
   `cd32-native-mvp`. Date it from the fit, as `stage-output.sh` in
   FringeCoder/AmigaCD names it.
2. Release FringeCoder/AmigaCD and FringeCoder/Menu_MiSTer first if either
   has changes you want in the package.
3. Go to Actions -> **release** -> **Run workflow**.

| Input | Meaning |
|---|---|
| `tag` | Empty means `v<date of the newest releases/AmigaCD_*.rbf>`. Must not exist yet |
| `amigacd_tag`, `menu_tag` | The userspace and menu releases to bundle. Empty means the latest of each |
| `prerelease` | Tick for a build meant for testing |
| `notes` | Optional text shown above the changelog |

The run refuses in any of these cases:
- the branch is not the default branch;
- no `releases/AmigaCD_*.rbf` is committed;
- the file is under 500 KB (a Git LFS pointer or a truncated copy);
- the tag already exists;
- the newest `.rbf` was already in the previous release.

To ship a new userspace or menu with an unchanged core, release those two and
fit or tag the core the next time. A core release always names exactly which
userspace and menu releases it carries.

`rtl-sim.yml` runs as part of the release: if the syntax gate or any bench
fails, nothing is published.

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
