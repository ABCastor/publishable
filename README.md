# publishable

`publishable` checks whether a git repository can be made public, and splits what it finds into what you can still edit and what is already past editing.

[![checks](https://github.com/ABCastor/publishable/actions/workflows/checks.yml/badge.svg?branch=main)](https://github.com/ABCastor/publishable/actions/workflows/checks.yml)

![publishable finding a home path in a repository's history](docs/demo.gif)

## Why

I have projects that would be useful to other people and are still private, and not one of them is private for a good reason. They are private because I could not answer one question fast enough to act on it: is there still something of mine in here, anywhere in the history? By hand that question is unbounded, so the answer stayed no.

![What each layer can catch. Four layers compared across four kinds of leak: a provider key, a home path, an agent's working note, and that same path once it sits in an older commit. GitHub push protection knows key formats only. The two git hooks have no check for a working note and cannot reach an old commit. publishable check is the only column that stops all four, and the only one that does not run on its own.](docs/coverage.svg)

## Install

```sh
git clone https://github.com/ABCastor/publishable.git
cd publishable && ./install.sh
```

Needs `git`, `perl`, [`jq`](https://jqlang.github.io/jq/) and [gitleaks](https://github.com/gitleaks/gitleaks), which does the secret scanning underneath. [`gh`](https://cli.github.com) is optional: it adds the repository-description check and the live lookups that fork and upstream handling rely on.

`install.sh` copies the engine into its own read-only folder, `~/.local/share/publishable/engines/<version>`, and links `publishable` onto your path. It adds a pre-commit hook to `~/.git-template` and points [`init.templateDir`](https://git-scm.com/docs/git-init#Documentation/git-init.txt---templatelttemplate-directorygt) at it, so everything you clone or create from then on inherits it. **An existing hook is never replaced**: the installer leaves it alone and tells you how to call the Publishable scan from it.

Already-existing repositories need `git init` re-run inside them to pick the hook up. That is safe and leaves history alone.

## Use

```sh
publishable check ~/code/my-app
```

Findings split into two kinds, and the split decides what you do.

**Working tree.** In the files as they are now. Edit, commit, done.

**History.** In commits. Deleting the file does nothing, and rewriting history is unreliable: a fork keeps the old objects, [GitHub will not remove data from someone else's fork](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository), and rewritten commits stay reachable by SHA. For a repository already public, rotate and disclose. For one that is not, export the clean tree into a fresh repository with one initial commit.

By default the check judges what `git push <remote> HEAD` would expose: the files, plus every commit reachable from HEAD. Before a first publication, or a push of every branch, add `--all-refs` to cover every branch and tag.

Exit codes: `0` clean, `1` findings, `2` usage error. Output is readable in a terminal and machine-parseable when piped, so `publishable check . | grep BLOCKING` works with no flag.

A repository with no commits reports `history UNSCANNED`. There is nothing to scan yet, and calling that clean would be the most dangerous kind of wrong answer.

![Where the checks fire. Four checks sit between an edit and a public repository, drawn against a history where a home path went into a commit made before any hook existed. The pre-commit hook is handed only what is not committed, and the pre-push hook and GitHub push protection are handed the same thing as each other, the commits you are pushing, so the old commit is out of range for all three. publishable check is handed all of it and catches the leak. Flipping a repository to public fires none of the three automatic checks.](docs/pipeline.svg)

## What it blocks

- Secrets, from the full gitleaks ruleset, in every commit in scope.
- Your own identifiers (the `personal-*` rules below), including inside `tests/`, `fixtures/` and `*.example.*`, where rules files usually allowlist everything.
- Agent and process files: hand-off logs, plans, `.claude/`, `.codex/`, `.cursor/`.
- Internal records: agent instructions such as `CLAUDE.md`, decision records under `adr/` or `decisions/`, lessons, build ledgers and drafts, in the tree and in commits not yet published.
- Currency figures and long opaque IDs inside a hand-off log, tracked or not.
- Terms from a denylist, in tracked files and in history (see below).
- Commits whose author or committer differs from your configured public identity, and any AI vendor named as author or committer.
- AI co-authorship lines in commit messages or files.
- A tracked `.env` or key file, or no ignore rule for `.env`.
- A shallow clone, replacement refs or grafts, because a rewritten graph cannot prove anything about history.

## Your rules

`publishable` ships no personal patterns, because yours are not mine. `install.sh` leaves a starter file at `~/.config/publishable/personal.toml` with the placeholders still in it, and marks it not ready.

It [extends](https://github.com/gitleaks/gitleaks#configuration) the default gitleaks ruleset, so you keep every credential pattern and add your own:

```toml
[[rules]]
id = "personal-absolute-home-path"
description = "Replace this absolute home path with $HOME or a runtime-configured path."
regex = '''/Users/YOURNAME(?:/|["'`[:space:]]|$)'''
keywords = ["/Users/YOURNAME"]
```

Write `description` as the fix. You read it at the moment you are blocked, and "replace this with `$HOME`" gets acted on where "personal path detected" gets overridden.

Replace every placeholder, then set `rules_ready=true` in `~/.config/publishable/config`. Until you do, `publishable` refuses to scan and so does the hook, because a security tool that returns clean while it is still holding the example rules is worse than none.

Keep the rules file out of your repositories. It lists the strings you most want to keep private.

### Denylists

Rules catch your own identifiers. They cannot know a repository's third parties: the client, the colleague, the real record a fixture was copied from. List those terms one per line in a gitignored `.publish-denylist`, or keep the list elsewhere and name it with `git config publishable.denylist <path>`. A single word matches as a whole word, with underscore counting as a boundary so `test_alice_share` matches `alice`; a phrase matches as written; `date && route` matches only when both sit on one line. Only locations are reported, never the term.

A repository with a sibling named `<name>-data`, `<name>-private` or `<name>-private-data` was probably built from private records, so for it a missing denylist blocks instead of warning.

### Config

`~/.config/publishable/config` holds one `key=value` per line. A leading `~` means your home folder.

| Key | Effect |
|---|---|
| `rules_path`, `rules_ready` | The rules file, and whether you have replaced its placeholders. |
| `author_name`, `author_email` | Your public commit identity. When set, the repository's local config and every unpublished commit must match it. |
| `github_handle`, `own_github_owners` | Owners treated as yours. Default: `github_handle`. |
| `code_roots` | Folders searched for `-data` siblings, separated by `:`. Default: the repository's parent folder. |
| `test_path_rules` | Rule ids re-checked inside test and example paths. Default: `^personal-`. |
| `exempt_owner`, `exempt_rules` | Rules allowed when every GitHub remote belongs to that owner, for example your own name on your own organisation's repositories. One remote elsewhere and they block again. |
| `own_identity_pattern` | A regular expression for your identities, used by `publicUpstream` below. |
| `checks_dir` | Your own checks. Default: `checks.d` next to the config. |

### Your own checks

Every `*.sh` in `checks_dir` runs after the built-in checks with `PUBLISHABLE_REPO`, `PUBLISHABLE_TRACKED_PATHS` (a file listing tracked paths) and `PUBLISHABLE_HISTORY_SCOPE` set. It prints finding lines in the same format, `BLOCKING|section=PUBLISH_BASICS|scope=tree|file=README.md|line=n/a|commit=HEAD|rule=my-rule|description=...`. A check that exits non-zero or prints anything else blocks, so a broken check never passes silently.

### Forks

A fork that keeps its upstream's history would be judged on commits it never wrote. Declare the upstream with `git config publishable.publicUpstream <owner>/<repo>` and its commits leave the scan, once GitHub confirms the upstream is public, is not one of your owners, and its current head exists locally. Any commit under that head that one of your identities wrote stays in scope, with everything built on it.

## Behind a hook

Each run writes a stamp to `~/.local/state/publishable/<sha256 of the repository path>`: the verdict, the scope, a hash of the refs, a hash of the engine, and an `input=<sha256> <path>` line for every file the verdict read, among them the rules, the config, your checks, each denylist and the repository's `.git/config`. A hook that allows a push on a clean stamp should recompute all of them and refuse when any differs.

To pin one engine version for such a hook, run `./install.sh --engine-only` from a clean checkout. It installs nothing else and prints the engine folder and its hash. The folder is never edited in place, so pinning both values means an edited engine cannot ride an older clean stamp.

## Publishable by default

The usual order is build first, clean up before publishing. That order is why most side projects stay private. The cleanup is unbounded, nobody can verify it, and it falls due exactly when you have stopped caring.

Invert it. Decide at the start that your personal layer lives outside the repository, and the repository carries only questions, examples, and references. Publishing then costs nothing, because there is nothing to take out. `check` exists to catch the places you got that wrong, and the separation itself does the work.

The dividing line: **anything that changes when the person changes is policy.** Your name, your paths, your keys, your taste, your examples. All of it belongs in a config file, a first-run prompt, or a secret manager. Anything that survives the person is mechanism, and it ships.

The whole test fits in one sentence, borrowed from [Twelve-Factor](https://12factor.net/config): could this repository be made public right now, with nothing removed?

```sh
publishable init my-app --lang python
```

Scaffolds a repository built that way: a `.gitignore` covering the files that leak most often, a config example plus a loader reading from `~/.config/<name>/`, a README skeleton, and CI that fails when the README stops being true. It asks once for the values that are yours and stores them outside the repository. It will not invent a default author.

This repository is built the same way, which is the only reason to trust it. Its own rules are configuration; only their shape ships.

There is a second reason to care, beyond your own repositories. **Most small useful things never get published**, not because anyone decided against it but because the cleanup was unbounded and the moment passed. So they get rebuilt, from scratch, a thousand times over, and every rebuild costs somebody hours they will not get back. Making publishing cost nothing is the part of that problem an individual can actually fix.

## Why shouldn't I use this?

- **It is not a credential scanner.** It extends gitleaks rather than replacing it. For verified secret detection add [TruffleHog](https://github.com/trufflesecurity/trufflehog).
- **It cannot help after the fact.** Once history is public, forks make it permanent. This is for the moment before the first push.
- **Rules need tuning.** Too broad and you override it constantly, which is how guards get uninstalled. Start narrow.
- **Bash, Perl and git only.** No Windows without WSL.
- **Decision records stay private.** `check` treats `adr/` and `decisions/` as internal records. If you publish your ADRs on purpose, this tool will argue with you.

For a hosted scanner with a dashboard and verified secrets, use [GitGuardian](https://www.gitguardian.com) or TruffleHog. This is local, offline, and single-purpose.

## License

MIT, see [LICENSE](LICENSE).

<p><a href="https://abcastor.com"><img src="docs/link-castor.svg" height="18" align="absmiddle" alt="abcastor.com"></a>&nbsp; <a href="https://abcastor.com">abcastor.com</a> &nbsp;·&nbsp; <a href="https://abcastor.com/writing/">Writing</a> &nbsp;·&nbsp; <a href="https://abcastor.com/who/">Who&nbsp;we&nbsp;are</a></p>

<p><a href="https://www.linkedin.com/company/abcastor"><img src="docs/link-linkedin.svg" height="18" align="absmiddle" alt="LinkedIn"></a>&nbsp; <a href="https://www.linkedin.com/company/abcastor">Castor</a> &nbsp;·&nbsp; <a href="https://www.linkedin.com/in/emanuele-russo-656a10199/">Emanuele&nbsp;Russo</a> &nbsp;·&nbsp; <a href="https://www.linkedin.com/in/edoardoavenia/">Edoardo&nbsp;Avenia</a></p>

<p><a href="https://abcastor.com"><img src="docs/castor-footer.svg" width="350" alt="Chip, the Castor beaver, Castor, we give a dam"></a></p>
