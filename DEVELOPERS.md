# Developers

Notes for people working on this repo's CI and component pins, not just
consuming the image. See [README.md](README.md) for build and usage
instructions.

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
   [Build it](README.md#build-it) in the README).

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

7. **Merge to `main`, then release.** Merging to `main` builds the SDK
   image but does not publish it. A release tag publishes it; see
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

### SDK image

The `sdk` job assembles the SDK image from the component images, pinned
by digest, in a few minutes. The image carries the labels
`eu.openchip.ime.toolchain` and `eu.openchip.ime.qemu`, which hold the
component image digests, and a label with the digest of
`sdk.lock.yaml`.

| Trigger | SDK image |
| --- | --- |
| pull request | built, never pushed |
| push to `main` | built, never pushed |
| push of tag `openchip-vYYYY.MM.DD` | pushed as `:openchip-vYYYY.MM.DD`, then `:latest` |
| `workflow_dispatch` with **publish** | pushed as `:openchip-v<short-sha>` |

`<short-sha>` is the first 7 characters of the commit SHA.

The summary of each run lists the component images by digest, whether
each was reused or built in that run, and whether the SDK image was
pushed.

`:latest` is the newest release. Only a release tag moves it. The last
step of the `sdk` job moves it after pushing the release image.
It skips the move if a release tag with a later date exists, so a re-run
of an older release never moves `:latest` back.

Every image carries `sdk_version` from `sdk.lock.yaml` in its
`org.opencontainers.image.version` label, whatever its tag.

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
replaced. They never publish an SDK image.
A failure means the pinned inputs no longer reproduce a build, for
example because a package mirror or a component commit has gone away.

The Apptainer publish job is disabled for now.

## Publishing from a feature branch

1. Open the repo on GitHub and go to the **Actions** tab.
2. In the left sidebar, click the **sdk** workflow.
3. Click the **Run workflow** button (top right of the run list).
4. In the dropdown, set **Use workflow from** to your feature branch.
   `main` works too.
5. Check the **publish** box ("Push the image to GHCR"). Leave the
   **from-scratch** box unchecked. It runs the no-cache verification
   described in [From-scratch verification](#from-scratch-verification),
   which takes hours and does not publish the SDK image.
6. Click the green **Run workflow** button to start it.

This triggers a new, separate run of `sdk` on that branch (distinct from
whatever run a plain `git push` already started) and pushes the image as
`ghcr.io/openchip-software/riscv-ime-sdk:openchip-v<short-sha>`, where
`<short-sha>` is the first 7 characters of the branch's current head
commit. It does **not** update the `:latest` tag, which only a release
tag moves. The run reuses the component images when their tags already
exist. Requires write access to the repo.
