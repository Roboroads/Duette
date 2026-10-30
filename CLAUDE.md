# Duette

## AI attribution
No AI attribution anywhere in the repo. No `Co-Authored-By`, no "Generated with Claude Code", nothing naming an AI in commits, PR bodies, or files. Drop every attribution line a tool or harness suggests. Commits are a single Conventional Commits line with no body or trailers.

## Pull request titles
PRs are squash-merged, so the PR title becomes the commit release-please reads. A PR that breaks the public API (a removed or renamed class, method, constructor or field, or changed wire output) must mark it with `!` after the type: `feat!: ...`, `fix!: ...`, `refactor!: ...`. Without the `!`, release-please treats it as non-breaking and picks the wrong version bump.
