# Grove

A native Git client for macOS — SwiftUI shell, AppKit where it matters (commit graph, diffs), and the real `git` CLI underneath so hooks, credential helpers, signing and your `.gitconfig` just work.

## Layout

- `Sources/GroveCore` — UI-independent engine
  - `Git` — process runner (`run` / streaming `records` for `-z` output)
  - `GitParse` — parsers for `log -z`, `status --porcelain=v2 -z`, `--name-status -z`, `for-each-ref`
  - `Repository` — actor per working tree; reads are `nonisolated` (parallel), writes are serialized
  - `GraphLayout` — incremental lane assignment for the commit graph (works while `git log` streams)
  - `RepositoryWatcher` — FSEvents on the working tree and git dirs, classified into working-tree / index / refs changes
  - `AskpassServer` — answers credential prompts from `grove-askpass`
- `Sources/GroveAskpass` — `grove-askpass`, the `GIT_ASKPASS` / `SSH_ASKPASS` helper: forwards git/ssh prompts (password, token, key passphrase, host key) over a Unix socket to the app, which asks in a sheet
- `Sources/Grove` — the app: NSTableView commit list with custom-drawn graph, TextKit diff view, working copy with stage/unstage/commit

## Develop

```sh
swift test                               # unit + end-to-end tests against temp repos
swift run Grove ~/path/to/repo           # or GROVE_REPO=~/path/to/repo swift run Grove
scripts/bundle.sh                        # build/Grove.app (ad-hoc signed)
```

`GROVE_GIT=/path/to/git` overrides the git binary (default: Homebrew git, then `/usr/bin/git`).

Requires macOS 15+.
