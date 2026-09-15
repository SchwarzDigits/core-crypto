# SchwarzDigits fork of CoreCrypto

This repository is a fork of [wireapp/core-crypto](https://github.com/wireapp/core-crypto). `digits/main` holds a release of Wire's CoreCrypto plus our changes, and we build and publish `schwarz.opensource.natrium:core-crypto-kmp` from it. Every change that is useful for Wire goes to Wire as a pull request.

## Branches

| Branch | What it is |
|---|---|
| `main` | Mirror of Wire's `main`. Fast-forward only; never commit to it. |
| `digits/main` | Our consolidated state and the default branch: the Wire release we build on (currently `v10.5.2`) plus all our changes. Releases are tagged here (see [Releases](#releases)). |
| `fix/<topic>` | One change per branch for Wire, based on Wire's `main` or on the change it builds on. |
| `digits/<topic>` | A change that stays in this fork, or the port of a `fix/` change to `digits/main`. |

Change branches for Wire are always named `fix/<topic>`, also for new functionality.

## Why `digits/main` follows Wire's releases

Kalium and our releases need a released CoreCrypto version, not Wire's `main`. `digits/main` therefore moves from one Wire release to the next: a new release is merged into it as its tag (see [Keeping up with Wire](#keeping-up-with-wire)).

`fix/` branches start from Wire's `main`, `digits/main` from a Wire release. Merging a `fix/` branch into `digits/main` would bring along Wire's unreleased `main`, so a change reaches `digits/main` as a port instead.

## Lifecycle of a change

1. Create `fix/<topic>` from Wire's `main` and make the change, with tests.
2. Go through [Before opening a pull request](#before-opening-a-pull-request).
3. Open a pull request against `main` of `wireapp/core-crypto`.
4. Port the change: create `digits/<topic>` from `digits/main`, cherry-pick the commits of `fix/<topic>`, and adapt them to the release where needed.
5. Open a pull request from `digits/<topic>` into `digits/main`. The digits release workflow builds and checks the artifact there without publishing. Merge it with a merge commit, then delete `digits/<topic>`.
6. Once Wire has released a version with the change, it comes back into `digits/main` when that release is merged. Delete `fix/<topic>` only then.

A change that is never meant for Wire starts directly as `digits/<topic>` from `digits/main` and continues at step 5.

If things go differently:

- **Wire changes the change before merging it:** When the Wire release with it is merged into `digits/main`, Wire's version wins, wording included.
- **Wire declines it:** The port stays in `digits/main`. Keep `fix/<topic>` while a later attempt at Wire is likely.
- **Wire's `main` moves past an open pull request and conflicts:** Rebase the branch. This rewrites a branch with an open pull request, so agree on it first.

## Rules

- One change per branch and per pull request. A change that needs another one is based on that branch, and its pull request says so.
- Start `fix/` branches from Wire's `main`, and `digits/` branches from `digits/main`.
- Never commit to `main`, and don't force-push a branch with an open pull request without agreeing on it first.
- The pull request into `digits/main` and the one at Wire don't reference each other.
- Text in code, documentation and commit messages must be true for Wire's code as well, and names no product or customer.
- Commit and pull request titles follow [Conventional Commits](https://www.conventionalcommits.org/) as `fix(<scope>): …`.

## Before opening a pull request

- Run the tests of the crates you changed, for example `cargo test -p core-crypto-keystore`, and the checks from `.pre-commit-config.yaml`.
- If the change touches the JVM or Kotlin Multiplatform build, push the `digits/` branch: the dry run of the digits release workflow builds every native library and checks the artifact.
- For the pull request at Wire:
  - run the check from [Fork-only files](#fork-only-files),
  - make sure Wire's CLA check passes.

## Keeping up with Wire

- Fast-forward `main` about once a week.
- Merge a new Wire release into `digits/main` when Kalium moves to it, and before a release of ours that should carry Wire's fixes.

```sh
git remote add wire https://github.com/wireapp/core-crypto.git    # once
git fetch wire main --tags
git push origin wire/main:main          # fast-forward our main
git switch digits/main && git pull
git merge v<version>                    # the tag of Wire's release
git push origin digits/main             # dry run: builds and checks the artifact
```

Conflicts:

- **In a change that Wire released:** take Wire's version, wording included.
- **In one of our changes that Wire hasn't released:** keep our change and adapt it to Wire's new code.

Wire's tags are fetched locally but never pushed to this fork: push only our own tags, and never use `git push --tags`.

## Releases

A release is an annotated tag on `digits/main` named `v<Wire's version>-digits.<n>`, for example `v10.5.2-digits.1`. `<n>` counts our releases on the same Wire version. The version is part of the Maven coordinates, so it names the Wire release it's built on.

```sh
git switch digits/main && git pull
git tag -a v10.5.2-digits.2
git push origin v10.5.2-digits.2
```

The tag runs `.github/workflows/digits-release.yml`. It builds the native libraries for all targets, packages `schwarz.opensource.natrium:core-crypto-kmp` with notices and SBOMs, signs it and publishes it on Maven Central. A push to a `digits/` branch or a pull request into `digits/main` runs the same build as a dry run with the version `<Wire's version>-digits.0`, without publishing. Changes to Markdown files alone don't build. The details are in `release/README.md`.

Tags without `-digits.` are Wire's; never create them here.

## Fork-only files

These files exist only in `digits/main`, so pull requests to Wire must not carry them:

- `FORK.md`,
- `release/`,
- `.github/workflows/digits-release.yml`.

Before opening a pull request at Wire, check that the branch doesn't contain any of them:

```sh
git diff --name-only wire/main...HEAD | grep -E '^(FORK\.md|release/|\.github/workflows/digits-)' && echo "fork-only files in this branch"
```

## CI

Wire's workflows are disabled in this fork (`release/disable-upstream-workflows.sh`); only `digits release` runs.

## AI coding agents

Keep agent instructions out of the repository, for example a local `CLAUDE.md` listed in `.git/info/exclude`. For Claude Code, the line `@FORK.md` in it imports this file; point other agents to `FORK.md`.
