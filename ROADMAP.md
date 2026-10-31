# Grove Roadmap

Status: ✅ done · 🚧 in progress · ⬜ planned

Estimates are Claude Code session time.

## Done

- ✅ Package scaffold (`GroveCore` library + `Grove` app), public repo, `scripts/bundle.sh`
- ✅ Git engine: `git` CLI runner with streaming `-z` records, porcelain v2 / `log -z` / `--name-status` / `for-each-ref` parsers, `Repository` actor (parallel reads, serialized writes)
- ✅ History: NSTableView with custom-drawn commit graph and ref badges, streamed `git log` (30k commits instant), commit detail + file list + colored diff
- ✅ Working copy: staged / unstaged lists, stage / unstage file / all, commit (real `git commit`, hooks + signing apply)
- ✅ Sidebar: branches (current, ↑↓ tracking), remotes, tags → jump to commit

## Phase 1 — Everyday client

| # | Item | Notes | Est. |
|---|---|---|---|
| 1.1 | ✅ Straighter graph | First-parent chain keeps its lane (main stays on the left); merged side lanes free up immediately | 0.3h |
| 1.2 | ✅ Auto refresh | FSEvents on the working tree + `.git` (HEAD, refs, index), debounced; ignores lock-file churn | 0.3h |
| 1.3 | ✅ Branch operations | Checkout (double-click; remote → tracking branch), new branch from any commit, rename, delete (confirm, force if unmerged); sidebar filter, remotes grouped by remote | 0.5h |
| 1.4 | ✅ Fetch / pull / push | Toolbar buttons, progress + cancel, push sets upstream, pull ff / rebase; activity log of every git command run | 0.5h |
| 1.4b | ✅ Credential prompts | `GIT_ASKPASS` / `SSH_ASKPASS` helper that asks in a sheet (HTTPS password / token, SSH key passphrase, host-key confirmation); today only credentials already in a helper or ssh-agent work | 0.4h |
| 1.5 | ✅ Hunk & line staging | Diff parser in Core; stage / unstage / discard a hunk or selected lines via `git apply` | 0.6h |
| 1.6 | ✅ Discard & stash | Discard file changes (confirm); stash save / apply / pop / drop, stashes in sidebar with their diff | 0.4h |
| 1.7 | ✅ Commit polish | Amend (loads last message), subject-length guide, sign-off | 0.2h |
| 1.8 | ✅ Commit context menu | Copy SHA / subject, checkout detached, branch / tag here, cherry-pick, revert, reset soft / mixed / hard (confirm) | 0.4h |

## Phase 2 — Navigation & power

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ✅ History search | Filter by message / author / SHA as you type; path filter (`-- path`) | 0.4h |
| 2.2 | ✅ Quick switcher | ⌘K: fuzzy branch / tag jump (⌘↩ checks out), commit search by subject / SHA, `>` for commands (one palette: ⇧⌘P is Push) | 0.4h |
| 2.3 | ✅ Merge & rebase | Merge / rebase onto a branch; in-progress banner (continue / abort / skip), conflicted files with take ours / theirs / mark resolved | 0.8h |
| 2.4 | ✅ Undo | ⌘Z (Edit ▸ Undo <action>) for commit, amend, reset (hard too: uncommitted changes are snapshotted), merge / rebase / cherry-pick / revert / pull, checkout, create / delete branch, discard (incl. untracked files), drop stash. Redo not yet | 0.6h |
| 2.5 | ✅ File history & blame | History of a file follows renames (`--follow` + parents rewritten against the full graph so lanes stay connected); directories use a path-limited log. Blame sheet (working tree or any commit, `-M -C`), age-shaded gutter, click to jump to the commit | 0.6h |
| 2.6 | ✅ Better diffs | Side-by-side mode, word-level highlights, syntax highlighting, image diff via QuickLook | 1h |
| 2.7 | ✅ Interactive rebase | Reorder / squash / fixup / reword / drop by drag, runs with a scripted `GIT_SEQUENCE_EDITOR` | 1h |

## Phase 3 — Polish & distribution

| # | Item | Notes | Est. |
|---|---|---|---|
| 3.1 | ✅ Settings & icon | Settings window (git binary, pull mode, diff font size); app icon | 0.3h |
| 3.2 | ✅ Submodules & worktrees | Listed in the sidebar, open in a new window | 0.5h |
| 3.3 | ✅ Large-repo performance | `git log` runs undecorated (ref badges come from `for-each-ref`; `--decorate` made the first byte ~3× slower). "Optimize Repository" (suggested for 20k+ commits without one): commit-graph with changed-path filters, fsmonitor, untracked cache. Benchmark harness (`GROVE_BENCH_REPO=… swift test -c release --filter Benchmarks`): 300k commits stream + lay out in ~5.6 s, first rows ~1.3 s, status 0.1 s | 0.5h |
| 3.4 | ✅ GitHub / GitLab | Open commit / branch / PR in browser; create PR for current branch | 0.5h |
| 3.5 | 🚧 Release pipeline | ✅ CI build on every push and tag-triggered GitHub Release of an ad-hoc signed `Grove-vX.Y.Z.zip` (#1–#3). ⬜ Developer ID signing + notarization + Sparkle updates | 0.5h + **user must do this manually**: Apple Developer account, Developer ID certificate, notarization credentials as repo secrets — duration outside Claude's control |

## Phase 4 — Depth

| # | Item | Notes | Est. |
|---|---|---|---|
| 4.1 | ✅ Redo | ⇧⌘Z re-applies an undone git action (each undo registers its inverse) | 0.3h |
| 4.2 | ✅ Reflog | Sidebar "Reflog": HEAD's recent positions with the action that moved it; select to inspect, check out or reset to it — the safety net for anything Undo doesn't cover | 0.4h |
| 4.3 | ⬜ Content search | Find commits that added / removed text (`git log -S`) or whose diff matches a regex (`-G`), from the history filter (`s:` / `g:` prefixes) | 0.4h |
| 4.4 | ⬜ Signatures | Commit detail shows GPG / SSH signature status and signer (verified lazily per selected commit) | 0.3h |
| 4.5 | ⬜ Git LFS | Detect LFS; mark LFS-tracked files; show pointer diffs as "LFS object a → b (size)"; LFS fetch / pull go through git's hooks | 0.4h |
| 4.6 | ⬜ Window tabs | Repositories open as native window tabs (⌘T to open another), tab title = repo name | 0.3h |
| 4.7 | ⬜ Smarter highlighting | Highlighter keeps multi-line comment / string state across lines in a hunk | 0.3h |
| 4.8 | ⬜ Split-view staging | Stage / unstage / discard hunks and lines from the side-by-side working-copy diff too | 0.5h |
| 4.9 | ⬜ Merge editor | Conflicted text files: per-conflict "ours / theirs / both" choices with live preview, then mark resolved | 1h |

