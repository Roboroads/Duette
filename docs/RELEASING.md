# Releasing and test builds

Two ways to get a Duette installer onto a Mac: a real release, and a test build of any branch. Both run the same scripts (`scripts/sign.sh`, `scripts/build-pkg.sh`, `scripts/notarize.sh`) on a GitHub macOS runner.

Signing and notarization need the secrets from [SIGNING.md](SIGNING.md). Without them the build still runs and makes an ad-hoc signed pkg that a Mac warns about.

## One-time repo setup

- Add the seven signing secrets (SIGNING.md).
- In the repo's **Settings**, **Actions**, **General**, **Workflow permissions**, turn on **Allow GitHub Actions to create and approve pull requests**. release-please cannot open its release PR without it.
- Optional: add a personal access token as the secret `RELEASE_PLEASE_TOKEN`. Pull requests opened with the built-in token do not start other workflows, so `ci.yml` does not run on the release PR. With a token of your own it does. Without one, start CI by hand on the release PR's branch: `gh workflow run ci.yml --ref release-please--branches--main`.

## A real release

1. Merge PRs to `main`. The PR title must be a Conventional Commit (`feat:`, `fix:`, `feat!:` for a breaking change), because the squashed title is what release-please reads.
2. release-please keeps one release PR open. It edits `version.txt` and `CHANGELOG.md`. Never edit those by hand.
3. Merge the release PR when you want to release. release-please tags `vX.Y.Z` and creates the GitHub release. While the version starts with `0.` it is marked as a prerelease.
4. In the same workflow run, `release.yml` builds at that tag, signs, notarizes, staples, and attaches `Duette-X.Y.Z.pkg`, `uninstall.sh`, `SHA256SUMS` and (when `docs/TESTING.md` exists) `TESTING.md` to the release.

If the secrets are missing, step 4 builds an ad-hoc pkg, keeps it as a workflow artifact and uploads nothing to the release. Add the secrets and re-run: **Actions**, **Release**, **Run workflow**, with the tag name (for example `v0.1.0`).

The first release is `0.1.0`, because `release-please-config.json` sets `"initial-version": "0.1.0"`. Without that setting release-please ignores the `0.0.0` in the manifest and makes the first release `1.0.0`, a full release instead of a prerelease.

## A test build from any branch

Use this to try a fix on a real Mac without cutting a release. It builds the branch, signs and notarizes it when the secrets exist, and publishes a prerelease named `test-<shortsha>`.

```sh
gh workflow run prerelease.yml --repo Roboroads/Duette --ref my-branch
```

That builds the tip of `my-branch`. You can also build another ref from the workflow of the branch you start it on: `-f ref=some-other-branch`. A pushed tag works too, and the tag name becomes the release name:

```sh
git tag test-hiss-fix && git push origin test-hiss-fix
```

Then watch it and get the download link:

```sh
gh run watch --repo Roboroads/Duette
gh release list --repo Roboroads/Duette --limit 5
gh release view test-abc1234 --repo Roboroads/Duette --json url --jq .url
```

The pkg is at `https://github.com/Roboroads/Duette/releases/download/test-abc1234/Duette-<version>-test-abc1234.pkg`. The release notes say whether the build was signed and notarized.

Things to know:

- Only build trusted refs. The build runs the scripts of the commit it builds, with the signing secrets in reach. `prerelease.yml` and `release.yml` therefore refuse any commit that is not on a branch or tag of this repository (for example a commit from a fork's pull request). Anything pushed to a branch here is built, so treat write access like access to the secrets.
- The branch has to contain `prerelease.yml`, `release.yml` and the scripts, because the workflow runs the files of the commit it builds. Merge `main` into your branch first.
- A run takes roughly 10 minutes plus notarization, which is usually a few minutes.
- Running it again on the same commit replaces the files of the same `test-<shortsha>` release.
- Test builds publish even if signing failed to set up (no secrets). A real release never does.
- The version in the file name is whatever `version.txt` says, `0.0.0` until the first release. The installer does not compare build numbers, so installing an older test build over a newer one works. Installing a test build over a real release works too.

Delete old test builds when you no longer need them:

```sh
gh release delete test-abc1234 --repo Roboroads/Duette --cleanup-tag --yes
```

## On the Mac that tests

1. Download the pkg from the release page and double-click it. A notarized pkg opens without a warning. An unsigned one is refused the first time: double-click it once, then open **System Settings**, **Privacy & Security**, scroll down to the message about the pkg and click **Open Anyway**.
2. Follow the installer. Audio pauses for a second while the audio system restarts, and the Duette icon appears in the menu bar.
3. If the app does not open, run `sudo "/Library/Application Support/Duette/duette-diagnose.sh"` in Terminal. It puts a zip on the Desktop to send back.
4. Remove it with `sudo "/Library/Application Support/Duette/uninstall.sh"`. Installing the next test build over the old one does not need an uninstall first.

## If a build fails

- `Duette.driver not found` or `Duette.app not found` at the signing step: the branch does not have `scripts/ci/build-driver.sh` or `build-app.sh` yet, so there is nothing to package.
- `CFBundleShortVersionString is ... but version.txt says ...`: the build script did not stamp the version from `version.txt`.
- Anything about certificates or notarization: the table at the end of [SIGNING.md](SIGNING.md).
- `Tag v... does not match version.txt`: `release.yml` was started for a tag but checked out another commit. Leave the `ref` input empty so it builds the tag itself.

## Pipeline test

`packaging.yml` runs on every change to the packaging files. It lints the scripts and workflows, builds a pkg from stand-in bundles, checks what is inside, installs it on the runner, runs the diagnose script and uninstalls it. Started by hand (`gh workflow run packaging.yml`), it also signs and notarizes the stand-ins when the secrets exist. That is the quickest way to check the secrets before the real app is ready.
