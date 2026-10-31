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
| 1.6 | ⬜ Discard & stash | Discard file changes (confirm); stash save / apply / pop / drop, stashes in sidebar with their diff | 0.4h |
| 1.7 | ⬜ Commit polish | Amend (loads last message), subject-length guide, sign-off | 0.2h |
| 1.8 | ⬜ Commit context menu | Copy SHA / subject, checkout detached, branch / tag here, cherry-pick, revert, reset soft / mixed / hard (confirm) | 0.4h |

## Phase 2 — Navigation & power

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ⬜ History search | Filter by message / author / SHA as you type; path filter (`-- path`) | 0.4h |
| 2.2 | ⬜ Quick switcher | ⌘K fuzzy branch / tag / commit jump; ⇧⌘P command palette | 0.4h |
| 2.3 | ⬜ Merge & rebase | Merge / rebase onto a branch; in-progress banner (continue / abort / skip), conflicted files with take ours / theirs / mark resolved | 0.8h |
| 2.4 | ⬜ Undo | ⌘Z for Grove's own commit / amend / reset / checkout / merge, via reflog + recorded pre-op state | 0.6h |
| 2.5 | ⬜ File history & blame | History of one path (follows renames); blame gutter with commit jump | 0.6h |
| 2.6 | ⬜ Better diffs | Side-by-side mode, word-level highlights, syntax highlighting, image diff via QuickLook | 1h |
| 2.7 | ⬜ Interactive rebase | Reorder / squash / fixup / reword / drop by drag, runs with a scripted `GIT_SEQUENCE_EDITOR` | 1h |

## Phase 3 — Polish & distribution

| # | Item | Notes | Est. |
|---|---|---|---|
| 3.1 | ⬜ Settings & icon | Settings window (git binary, pull mode, diff font size); app icon | 0.3h |
| 3.2 | ⬜ Submodules & worktrees | Listed in the sidebar, open in a new window | 0.5h |
| 3.3 | ⬜ Large-repo performance | Offer `git commit-graph write`, fsmonitor; lazy ref badges; measure on linux.git-sized history | 0.5h |
| 3.4 | ⬜ GitHub / GitLab | Open commit / branch / PR in browser; create PR for current branch | 0.5h |
| 3.5 | ⬜ Release pipeline | Developer ID signing, notarization, Sparkle updates, CI | 0.5h + **user must do this manually**: Apple Developer account, certificates — duration outside Claude's control |
