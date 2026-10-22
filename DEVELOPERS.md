<!--
SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
SPDX-License-Identifier: Apache-2.0
-->

# Developers

Notes for people working on this repo's CI and component pins, not just
consuming the image. See [README.md](README.md) for build and usage
instructions.

## Building from a clone

Build from a clone to change the components or the build files.

```sh
make sdk
```

This builds the SDK image `riscv-ime-sdk:openchip-v<sdk_version>`, where
`<sdk_version>` comes from `sdk.lock.yaml`. It runs `docker buildx bake` on
[`docker-bake.hcl`](docker-bake.hcl), as CI does. Before the build,
[`scripts/resolve-components.sh`](scripts/resolve-components.sh) prints one
line per component:

- `✓ prebuilt image found, reusing <image>`: the published component image
  is reused.
- `⚠ no prebuilt image (<image> not found or not readable) — building from
  source (this can take hours)`: the component is built from source.
- `⚠ uncommitted changes in build/<component> are ignored (hash is taken
  from HEAD)`: see the next paragraph.

At the end, `make sdk` prints `==> Built riscv-ime-sdk:openchip-v<sdk_version>`.
If a component is built from source when you expected reuse, press Ctrl-C.

Commit your changes under `build/toolchain` or `build/qemu` before you run
`make sdk`. The reuse check uses the git tree hash of each
`build/<component>` directory at `HEAD` (see `make hashes`). Uncommitted
edits do not change the hash, so `make sdk` reuses the published component
image and ignores them.

After you edit `components.yaml`, run `make lock && make check && make sdk`.
See [Updating components.yaml](#updating-componentsyaml).

`build/sdk/Dockerfile` starts from `ubuntu:26.04`. The components are built
on it and need its libraries, so keep that base image or pass
`--build-arg BASE_IMAGE=<ubuntu_26.04_digest>`.

Requirements: `docker buildx` (BuildKit),
[mikefarah/yq](https://github.com/mikefarah/yq) v4 and `curl`. Ubuntu's
apt `yq` package is a different tool and does not work here; install yq
from its [releases](https://github.com/mikefarah/yq/releases). The
component repositories are public, so no credentials are needed.

| Target | Does |
| --- | --- |
| `make sdk` | build the SDK image (recommended) |
| `make` | `make sdk`, then export `riscv-ime-sdk-openchip-v<sdk_version>.sif` and `.tar.xz`; needs `apptainer >= 1.3` |
| `make toolchain`, `make qemu` | build one component from source, without the GHCR reuse check |
| `make lock`, `pins`, `check`, `hashes`, `print` | maintainer tools; see [Updating components.yaml](#updating-componentsyaml) |

`make` builds the `.sif` from [`build/sdk/sdk.def`](build/sdk/sdk.def),
which adds labels and help text.

## Updating components.yaml

`components.yaml` is intent, `sdk.lock.yaml` is the integration gate.
The four component repos (crosstool-NG, gcc, binutils, qemu)
can be pushed to at any time — contributors are free to land changes
there whenever — but none of that reaches the SDK until a PR here
updates the component's resolved commit in `sdk.lock.yaml`. The build
reads only `build/*/pins.hcl`, which `make lock` renders from the lock;
`components.yaml` never touches the build directly.

To pull a change from a component repo into the SDK:

1. **Land the change in the component repo first.** It needs to exist
   there as a commit, tag, or branch head before this repo can point at
   it.
2. **Point `components.yaml` at it.** Edit the component's `ref:` to
   the branch name, tag name, or commit SHA you want:

   ```yaml
   # components.yaml
     gcc:
       repo: https://github.com/<org>/<component-repo>.git
       ref:  ime-cleanup   # was: some-other-branch-or-tag-or-sha
   ```

   A moving branch name is fine here during development — that's what
   `components.yaml` is for. Pin to a tag or exact SHA once the change
   is settled, so the manifest documents what you actually meant to
   build, not just what happened to be at the tip of a branch that day.

3. **Resolve it: `make lock`.** This runs
   [`scripts/make-lock.sh`](scripts/make-lock.sh). The component repos
   are public, so it needs no credentials. For each component it tries,
   in order: a branch named `ref`, then a tag named `ref` (peeled to its
   commit), then falls back to treating `ref` as a literal 40-character
   commit SHA.
   Whatever resolves is written to `sdk.lock.yaml` as `commit:`,
   alongside `resolved_from: <ref>` and a `generated_at` timestamp.
   The `base_image` tag is resolved to a digest through the Docker Hub
   registry API, so `curl` needs access to Docker Hub. The script then
   renders `build/<stage>/pins.hcl` for each stage listed under
   `stages:` in `components.yaml`. Each `pins.hcl` holds the pinned base
   image and the repo URL and commit of every component of that stage.
   `components.yaml` itself is never modified by this step.
   `make pins` re-renders the `pins.hcl` files from the existing lock
   without resolving anything.

4. **Guard it: `make check`.** Runs
   [`scripts/check-pins.sh`](scripts/check-pins.sh) — confirms no
   credentials or internal hostnames crept in, and that component repo
   URLs still appear only in `components.yaml`, `sdk.lock.yaml`,
   `build/*/pins.hcl`, `README.md`, the guard script itself, and
   `.github/` — never hardcoded into a Dockerfile or `docker-bake.hcl`.
   It then runs [`scripts/check-lock.sh`](scripts/check-lock.sh), which
   confirms that `components.yaml`, `sdk.lock.yaml` and
   `build/*/pins.hcl` agree. The `guard` workflow runs both scripts.

5. **Build and sanity-check it locally:** `make sdk` (see
   [Building from a clone](#building-from-a-clone)).

6. **Commit `components.yaml`, `sdk.lock.yaml` and `build/*/pins.hcl`
   together and open a PR.** The diff is small and mechanical — one
   `ref:` line, the matching `commit:`/`resolved_from:` lines in the
   lock, and the matching `*_COMMIT` line in one `pins.hcl` — which
   makes it easy to review and, if the new commit turns out to be bad,
   easy to `git bisect` back to. The `guard` workflow fails if the
   `pins.hcl` files differ from what the lock renders. All three are
   listed in [`CODEOWNERS`](.github/CODEOWNERS), so that PR specifically
   needs sign-off from a named reviewer, independent of whoever else
   reviews the rest.

7. **Merge to `main`, then release.** Merging to `main` builds the
   component images and checks that the SDK image assembles from them. A
   release tag gives the component images a release name; see
   [Releasing](#releasing) below. Until a release is tagged, the new
   component commit is only in `main` and in local builds.

A corollary: pushing to a component repo's default branch does
**nothing** to the SDK by itself, even if `components.yaml` names that
same branch. The lock pins an exact commit at the moment `make lock`
last ran; nobody downstream re-resolves it for you.

## CI

The `sdk` workflow runs three jobs: `resolve`, `component` and `sdk`.

### Component images

The toolchain and QEMU are published as separate component images:

```text
ghcr.io/openchip-software/riscv-ime-sdk-toolchain:<hash>
ghcr.io/openchip-software/riscv-ime-sdk-qemu:<hash>
```

`<hash>` is the git tree hash of `build/<component>`. `make hashes`
prints both tags for the current `HEAD`. The `resolve` job computes the
tags and checks which images already exist in GHCR. The `component` job
is a matrix that builds only the missing images.

Every input of a component lives in its directory: the Dockerfile,
`defconfig.in` for the toolchain, and `pins.hcl`. Any change inside
`build/<component>` gives a new tag and a rebuild. No other change does.
A change to `build/sdk`, the workflows or the README reuses both
component images. A `sdk_version` bump does not rebuild the toolchain,
because the toolchain package version names the gcc commit, not the SDK
version.

Component images are a build cache keyed by their inputs, so every run
from this repo pushes the ones it builds, pull requests included. A
toolchain built on a pull request is reused by `main` after the merge,
and by every other branch with the same inputs. Pull requests from forks
cannot push to GHCR, and component builds for them are not supported.

To force a rebuild with unchanged inputs, bump the number in the
`To force a rebuild` line at the top of `build/<component>/Dockerfile`.
This changes the tree hash.

The component repos are public, so component builds fetch them with no
credentials. The workflows must be able to read
and write the `riscv-ime-sdk-toolchain` and `riscv-ime-sdk-qemu`
packages. If a package is new, link it to this repo and give the repo
write access in the package settings.

### SDK image and release names

The SDK image is not published. Users assemble it from the component
images with `build/sdk/Dockerfile`; see [Quick start](README.md#quick-start).

The `sdk` job assembles the SDK image from the component images, pinned
by digest, in a few minutes, and keeps only the build cache. The
assembly checks that the components fit together. When it succeeds, the
job may add a release name to both component images:

| Trigger | Component images get |
| --- | --- |
| pull request | no release name |
| push to `main` | no release name |
| push of tag `openchip-vYYYY.MM.DD` | `:openchip-vYYYY.MM.DD`, then `:latest` |
| `workflow_dispatch` with **publish** | `:openchip-v<short-sha>` |

`<short-sha>` is the first 7 characters of the commit SHA. A release name
is an extra tag on the digest that assembled, added in the registry, so
nothing is rebuilt or uploaded again.

The summary of each run lists the component images by digest, whether
each was reused or built in that run, and which release name each got.

`:latest` is the newest release. Only a release tag moves it. The last
step of the `sdk` job moves it on both component images. It skips the
move if a release tag with a later date exists, so a re-run of an older
release never moves `:latest` back.

### Releasing

`sdk_version` in `components.yaml` is the only hand-edited copy of the
SDK version. `make lock` copies it into `sdk.lock.yaml` and
`build/sdk/pins.hcl`, and the `guard` workflow fails if either differs.
`make` passes it to `apptainer build` for the `.sif`.

1. Set `sdk_version` in `components.yaml` to the release date,
   `YYYY.MM.DD`.
2. Run `make lock`, and commit `components.yaml`, `sdk.lock.yaml` and
   `build/*/pins.hcl`.
3. Open a PR and merge it.
4. Tag the merge commit and push the tag:

   ```sh
   git tag openchip-v<version> <merge commit>
   git push github openchip-v<version>
   ```

   Creating a GitHub Release with the tag name `openchip-v<version>` on
   the merge commit does the same.

The `resolve` job fails before anything is pushed if the tag is not
`openchip-vYYYY.MM.DD`, or if it is not `openchip-v` followed by
`sdk_version` from `sdk.lock.yaml` at the tagged commit. To fix it,
delete the tag, bump `sdk_version` in `components.yaml`, run
`make lock`, merge, and tag the new merge commit.

### From-scratch verification

`workflow_dispatch` with **from-scratch** checked rebuilds both
components with no cache. These runs push the component images under
`<hash>-verify-<run id>` tags, so the reused `<hash>` images are not
replaced. They never add a release name.
A failure means the pinned inputs no longer reproduce a build, for
example because a package mirror or a component commit has gone away.

## Publishing test components from a feature branch

1. Open the repo on GitHub and go to the **Actions** tab.
2. In the left sidebar, click the **sdk** workflow.
3. Click the **Run workflow** button (top right of the run list).
4. In the dropdown, set **Use workflow from** to your feature branch.
   `main` works too.
5. Check the **publish** box ("Tag the component images as
   openchip-v<short-sha>"). Leave the **from-scratch** box unchecked. It
   runs the no-cache verification described in
   [From-scratch verification](#from-scratch-verification), which takes
   hours and adds no release name.
6. Click the green **Run workflow** button to start it.

This triggers a new, separate run of `sdk` on that branch (distinct from
whatever run a plain `git push` already started). It tags both component
images as `openchip-v<short-sha>`, where `<short-sha>` is the first 7
characters of the branch's current head commit. Testers then assemble the
SDK image as in [Quick start](README.md#quick-start), with `V=openchip-v<short-sha>`
and the branch name instead of `$V` in the build context URL. It does
**not** update the `:latest` tag, which only a release tag moves. The run
reuses the component images when their tags already exist. Requires write
access to the repo.

## Building the SDK tarball

The tarball comes with a source tarball and two container recipes that
users build themselves. No container image is published for it.

```sh
make release             # builder image, then dist/ (hours)
make verify              # scripts/verify-sdk.sh on dist/
```

On a host with Apptainer and no Docker:

```sh
make release-apptainer   # builder.sif, then dist/
make verify
```

`make release` builds the internal builder image from
[`build/builder/`](build/builder/), AlmaLinux 8 with the pinned
crosstool-NG, then runs [`scripts/build-sdk.sh`](scripts/build-sdk.sh)
inside it. That script builds into `work/` and writes to `dist/`:

| File | Contents |
| --- | --- |
| `riscv-ime-sdk-<version>-x86_64-linux.tar.xz` | the SDK, top directory `sdk/` |
| `riscv-ime-sdk-<version>-source.tar.xz` | the source of everything in the SDK, and this recipe |
| `SHA256SUMS` | checksums of both |

The builder image and `builder.sif` are internal and not published.
[`release/Dockerfile`](release/Dockerfile) and
[`release/sdk.def`](release/sdk.def) are the consumer recipes, also
shipped inside the tarball. The `release` workflow builds and verifies
`dist/` and keeps it as a workflow artifact.

`build-sdk.sh` runs in steps and skips a step that finished earlier, so an
interrupted build resumes. The header of `build-sdk.sh` lists the steps
and the environment variables.

## Repository layout

```text
components.yaml          intent — hand-edited
sdk.lock.yaml            pins — generated, CODEOWNERS-gated
Makefile                 build entry point
docker-bake.hcl          build graph: toolchain, qemu, sdk targets
build/toolchain/         Dockerfile, crosstool-NG defconfig template, pins.hcl
build/qemu/              Dockerfile, pins.hcl
build/sdk/               Dockerfile that assembles the image, apptainer def, pins.hcl
build/builder/           internal builder of the SDK tarball: Dockerfile, apptainer def, pins.hcl
build/release/           SDK tarball inputs: crosstool-NG defconfig template, sources.list,
                         env.sh, CMake toolchain file, user README, pins.hcl
release/                 consumer recipes: Dockerfile, sdk.def
scripts/                 make-lock.sh, check-pins.sh, check-lock.sh,
                         build-sdk.sh, package-sdk.sh, verify-sdk.sh, audit-linkage.sh
tests/sdk/               tests of an extracted SDK, run by verify-sdk.sh
.github/workflows/       guard (pins and lock checks), sdk (component images; SDK image assembled, not pushed),
                         release (SDK tarball)
.github/actions/         free-disk, setup-yq
```
