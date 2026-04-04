# GHelper
![CI](https://github.com/kyanjeuring/ghelper/actions/workflows/ci.yml/badge.svg)

**Opinionated Git workflow helpers for the terminal**

`GHelper` is a Bash-based toolkit that wraps common Git workflows into safer, faster, and more ergonomic commands.

It reduces repetitive Git friction, protects against common mistakes, and makes everyday version-control tasks easier through a small set of task-oriented commands.

Think of it as a workflow layer on top of Git: same power, better defaults.

---

## Who is this for?

GHelper is for developers who:

- Use Git daily
- Want faster branch, commit, and recovery workflows
- Occasionally mess up history (reset, amend, force-push)
- Prefer terminal tools over GUIs
- Want safer defaults without losing Git flexibility

---

## Features

- Safer wrappers around common Git operations
- Fast branch switching and syncing
- Clean commit and amend flows (with co-author support)
- Built-in recovery tools (reflog, undo, restore)
- Strong guard rails around history rewrites
- Repo templating support
- SSH-aware cloning

---

## Platform availability

> [!IMPORTANT]
> Requires **Bash 4+** and a working `git` installation.

- Linux: fully supported  
- macOS: supported  
- Windows: via **WSL** or **Git Bash**

> [!WARNING]
> PowerShell and CMD are not supported.

---

## Installation

### One-line install

```bash
curl -fsSL https://kyanjeuring.com/scripts/install-ghelper | bash
````

### Specific version

```bash
curl -fsSL https://kyanjeuring.com/scripts/install-ghelper | GHELPER_VERSION=vx.y.z bash
```

### Manual install

```bash
git clone https://github.com/kyanjeuring/ghelper.git ~/.local/share/ghelper
chmod +x ~/.local/share/ghelper/ghelper.sh
```

Then add to your shell:

```bash
echo 'source ~/.local/share/ghelper/ghelper.sh' >> ~/.bashrc
# or ~/.zshrc
```

---

## 15-second demo

```bash
gs
gsw main
gc 'Add auth validation'
gus
```

---

## Core commands (highlights)

| Command                    | Description                   |
| -------------------------- | ----------------------------- |
| `gs`                       | Rich repository status        |
| `gsw <branch>`             | Switch + sync branch          |
| `gc`                       | Stage + commit                |
| `gca`                      | Amend last commit             |
| `gus`                      | Undo last commit (safe)       |
| `gmove <branch>`           | Move commit to another branch |
| `gcp <commit>`             | Cherry-pick commits           |
| `gmerge <source> [target]` | Merge branches safely         |
| `gpromote`                 | Promote branch (dev -> main)   |
| `ghead`                    | Inspect reflog / recovery     |

These represent the main workflows: inspect, commit, recover, move, merge, and promote.

---

## Quick start

### Inspect repo

```bash
gs
```

### Switch branches

```bash
gsw dev
gsw feature/auth
```

### Commit

```bash
gc 'Add login'
gc 'Fix bug' 'Add validation'
```

### Undo mistakes

```bash
gus
ghead
grestorehead HEAD@{1}
```

---

## Workflows

### Commit flow

```bash
gc 'message'
gca 'updated message'
```

- Auto-stages changes
- Supports multi-line commits
- Supports co-authors

---

### Recovery flow

```bash
gus
gusn 3
guh
ghead
grestorehead HEAD@{2}
```

Recover from almost any mistake using soft/hard resets + reflog.

---

### Branch workflow

```bash
gsw feature/auth
gmerge dev main
gpromote
```

- Safe switching
- Guarded merges
- Structured promotion flow

---

### Move & copy commits

```bash
gmove dev
gcp abc123 --to main
```

Fix wrong-branch commits without messy rebases.

---

## Repo templating

```bash
create-gitignore
create-gitattributes
gtemplate
```

Templates come from:

```bash
~/.local/share/ghelper/templates
```

---

## Configuration

GHelper supports lightweight configuration via environment variables (similar to DStack).

Add these to your shell config (`.bashrc`, `.zshrc`) and reload your shell.

---

### Git host (for cloning)

```bash
export GHELPER_SSH_HOST=github.com
```

Used by `gclone` when constructing SSH/HTTPS URLs.

---

### Protected branches

```bash
export GHELPER_PROTECTED_BRANCHES="main master"
```

Branches listed here receive extra safety checks for:

- history rewrites
- force pushes
- destructive operations

---

### Example configuration

```bash
# ~/.bashrc or ~/.zshrc

export GHELPER_SSH_HOST=github.com
export GHELPER_PROTECTED_BRANCHES="main master release"
```

---

### Notes

- No config file required — environment variables keep it simple
- Defaults are safe out of the box
- Configuration is optional

---

## Safety model

GHelper adds guard rails around risky Git operations:

- Blocks switching with dirty working tree
- Warns on rewriting pushed commits
- Protects main/master branches
- Uses `--force-with-lease` instead of `--force`
- Requires confirmations for destructive actions

---

## Updating

Same method as install:

- Installer -> re-run script
- Git clone -> `git pull`
- Manual -> repeat install

Reload your shell after updating.

---

## Uninstall

```bash
rm -rf ~/.local/share/ghelper
```

Remove the source line from your shell config.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)

---

## Support

[https://buymeacoffee.com/kyanjeuring](https://buymeacoffee.com/kyanjeuring)

---

## License

MIT License
