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

Needs `git` and [gitleaks](https://github.com/gitleaks/gitleaks), which does the scanning underneath. [`gh`](https://cli.github.com) and `jq` are optional and only add repository-description checks.

`install.sh` puts the hooks in `~/.git-template` and points [`init.templateDir`](https://git-scm.com/docs/git-init#Documentation/git-init.txt---templatelttemplate-directorygt) at it, so everything you clone or create from then on inherits them. It prints what it changed and will not overwrite an existing template silently.

Already-existing repositories need `git init` re-run inside them to pick the hooks up. That is safe and leaves history alone.

## Use

```sh
publishable check ~/code/my-app
```

Findings split into two kinds, and the split decides what you do.

**Working tree.** In the files as they are now. Edit, commit, done.

**History.** In commits. Deleting the file does nothing, and rewriting history is unreliable: a fork keeps the old objects, [GitHub will not remove data from someone else's fork](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository), and rewritten commits stay reachable by SHA. For a repository already public, rotate and disclose. For one that is not, export the clean tree into a fresh repository with one initial commit.

Exit codes: `0` clean, `1` findings, `2` usage error. Output is readable in a terminal and machine-parseable when piped, so `publishable check . | grep BLOCKING` works with no flag.

A repository with no commits reports `history UNSCANNED`. There is nothing to scan yet, and calling that clean would be the most dangerous kind of wrong answer.

![Where the checks fire. Four checks sit between an edit and a public repository, drawn against a history where a home path went into a commit made before any hook existed. The pre-commit hook is handed only what is not committed, and the pre-push hook and GitHub push protection are handed the same thing as each other, the commits you are pushing, so the old commit is out of range for all three. publishable check is handed all of it and catches the leak. Flipping a repository to public fires none of the three automatic checks.](docs/pipeline.svg)

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

Replace every placeholder, then set `rules_ready=true` in `~/.config/publishable/config`. Until you do, `publishable` refuses to scan and so do the hooks, because a security tool that returns clean while it is still holding the example rules is worse than none.

Keep the rules file out of your repositories. It lists the strings you most want to keep private.

## Publishable by default

The usual order is build first, clean up before publishing. That order is why most side projects stay private. The cleanup is unbounded, nobody can verify it, and it falls due exactly when you have stopped caring.

Invert it. Decide at the start that your personal layer lives outside the repository, and the repository carries only questions, examples, and references. Publishing then costs nothing, because there is nothing to take out. `check` exists to catch the places you got that wrong, and the separation itself does the work.

The dividing line: **anything that changes when the person changes is policy.** Your name, your paths, your keys, your taste, your examples. All of it belongs in a config file, a first-run prompt, or a secret manager. Anything that survives the person is mechanism, and it ships.

The whole test fits in one sentence, borrowed from [Twelve-Factor](https://12factor.net/config): could this repository be made public right now, with nothing removed?

```sh
publishable init my-app --lang python
```

Scaffolds a repository built that way: a `.gitignore` covering the files that leak most often, a config example plus a loader reading from `~/.config/<name>/`, [`docs/adr/`](https://adr.github.io) for decisions, a README skeleton, and CI that fails when the README stops being true. It asks once for the values that are yours and stores them outside the repository. It will not invent a default author.

This repository is built the same way, which is the only reason to trust it. Its own rules are configuration; only their shape ships.

There is a second reason to care, beyond your own repositories. **Most small useful things never get published**, not because anyone decided against it but because the cleanup was unbounded and the moment passed. So they get rebuilt, from scratch, a thousand times over, and every rebuild costs somebody hours they will not get back. Making publishing cost nothing is the part of that problem an individual can actually fix.

## Why shouldn't I use this?

- **It is not a credential scanner.** It extends gitleaks rather than replacing it. For verified secret detection add [TruffleHog](https://github.com/trufflesecurity/trufflehog).
- **It cannot help after the fact.** Once history is public, forks make it permanent. This is for the moment before the first push.
- **Rules need tuning.** Too broad and you override it constantly, which is how guards get uninstalled. Start narrow.
- **Bash and git only.** No Windows without WSL.

For a hosted scanner with a dashboard and verified secrets, use [GitGuardian](https://www.gitguardian.com) or TruffleHog. This is local, offline, and single-purpose.

## License

MIT, see [LICENSE](LICENSE).

<p><a href="https://abcastor.com"><img src="docs/link-castor.svg" height="18" align="absmiddle" alt="abcastor.com"></a>&nbsp; <a href="https://abcastor.com">abcastor.com</a> &nbsp;·&nbsp; <a href="https://abcastor.com/writing/">Writing</a> &nbsp;·&nbsp; <a href="https://abcastor.com/who/">Who&nbsp;we&nbsp;are</a></p>

<p><a href="https://www.linkedin.com/company/abcastor"><img src="docs/link-linkedin.svg" height="18" align="absmiddle" alt="LinkedIn"></a>&nbsp; <a href="https://www.linkedin.com/company/abcastor">Castor</a> &nbsp;·&nbsp; <a href="https://www.linkedin.com/in/emanuele-russo-656a10199/">Emanuele&nbsp;Russo</a> &nbsp;·&nbsp; <a href="https://www.linkedin.com/in/edoardoavenia/">Edoardo&nbsp;Avenia</a></p>

<p><a href="https://abcastor.com"><img src="docs/castor-footer.svg" width="350" alt="Chip, the Castor beaver, Castor, we give a dam"></a></p>
