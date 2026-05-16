---
title: Completions
description: "Shell completions for bash, zsh, and fish — plus an LLM-oriented Markdown reference."
---

`imsg completions` generates completion scripts for interactive shells and a Markdown CLI reference for in-context LLM use.

## Shell completions

### Bash

```bash
imsg completions bash > ~/.bash_completion.d/imsg
# or, system-wide:
sudo imsg completions bash > /usr/local/etc/bash_completion.d/imsg
```

Reload your shell, then tab-completion for `imsg` is live.

### Zsh

```bash
mkdir -p ~/.zsh/completions
imsg completions zsh > ~/.zsh/completions/_imsg
```

Make sure `~/.zsh/completions` is on `fpath` and `compinit` is called. A standard `~/.zshrc` snippet:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit
```

### Fish

```bash
imsg completions fish > ~/.config/fish/completions/imsg.fish
```

Fish picks up new completions on next launch; no extra setup required.

## LLM reference

```bash
imsg completions llm
```

Emits a Markdown CLI reference that documents every command, flag, argument, and example. It's designed to be embedded in an agent's system prompt or a tool's documentation index so the model always has accurate, current help for the locally installed version of `imsg`.

Because it's generated from the same `CommandSpec` the parser uses, the output is always in sync with the binary. There's no separate doc-comment drift.

A common pattern:

```bash
imsg completions llm > /tmp/imsg-help.md
# Embed /tmp/imsg-help.md in your agent's tool description, prompt, or memory.
```

## What's covered

The same source-of-truth (`CommandSpec`) feeds all four generators:

- Command names and abstracts.
- Flag names (long and short), argument labels, optional/required status, help text.
- Constrained value lists (e.g. `--service imessage|sms|auto`, `--reaction love|like|dislike|laugh|emphasis|question`).
- Per-command examples.

Completions and the LLM reference are emitted to stdout. There's no install step beyond redirecting to a file in the right location for your shell.
