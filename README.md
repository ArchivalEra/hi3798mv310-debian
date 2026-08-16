# hi3798mv310-debian

Debian bring-up work for the Hisilicon Hi3798MV310 SoC (STB platform).
Repository freshly initialized -- content TBD.

## File policy (whitelist mode)

`.gitignore` is in **whitelist mode**: everything is ignored by default, and
only files explicitly re-included with a `!` rule can be committed.

- To allow a new file: add `!path/to/file` to `.gitignore`.
- To allow a whole directory: un-ignore the directory first, then its
  contents, e.g. `!patches/` followed by `!patches/**`.

Currently allowed: baseline files (`.gitignore`, `README.md`), the `hooks/`
directory, `*.sh` / `*.mk` / `Makefile`, `*defconfig*` / `*.config` /
`*.dts` / `*.dtsi`, `*.patch` / `*.diff`, and `docs/`.

## No Chinese characters, ever

This repository must **never contain any Chinese (CJK) characters** -- not in
file names, file content, commit messages, or author/committer names.

Enforcement: `hooks/pre-push` scans every commit in the pushed range and the
final tree of the pushed ref, and refuses the push (`exit 1`) if any CJK
character is found. If the hook cannot detect CJK on a machine it fails
closed (push refused). Merge conflict resolutions are covered via the
final-tree scan.

### Install the hook on a clone

Hooks live in the repo (`hooks/`) so they are versioned and shared. Enable
them once per clone:

```sh
git config core.hooksPath hooks
```

(Already configured on the original development machine.)

## Pushing

The repository is configured to authenticate to GitHub with the dedicated
SSH key via `core.sshCommand` (see `git config --get core.sshCommand`).
Plain `git push` is all that is needed on that machine.
