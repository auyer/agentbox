# agentbox

Run LLM coding agents in an isolated container, locked to a dedicated git
worktree. Each session gets its own branch, its own container, and no access
to the rest of your repository's git history.
Install packages with [Devbox](https://www.jetify.com/devbox), for maximum flexibility without custom images.

## Overview

agentbox wraps podman (or docker) to give an LLM agent a clean, reproducible
environment: a fresh git branch checked out as a worktree, a container built
from a local Containerfile, and a controlled set of volume mounts. The agent
can read and write the project files freely, but cannot access `.git`,
cannot push, and cannot affect the rest of the host system.

The container runs as the same UID/GID as the calling user. No files are ever
created as root.

## Requirements

- bash 4.4 or later
- git 2.5 or later (worktree support)
- podman (preferred) or docker
- base64 (coreutils)

## Installation

Run the setup script from the repository:

    ./setup.sh install

This copies all required files to `$HOME/.local/bin/agentbox/`, renames
`agentbox.sh` to `agentbox`, and adds the directory to `PATH` in your shell
rc file (`.zshrc`, `.bashrc`, or `.profile`, detected from `$SHELL`).

Restart your shell or source the rc file to make `agentbox` available.

To remove the installation:

    ./setup.sh uninstall

This deletes `$HOME/.local/bin/agentbox/` and removes the PATH entry from
the rc file.

## Usage

    agentbox <command> [options]

### Commands

    agentbox start [BRANCH] [OPTIONS]
    agentbox stop
    agentbox resume
    agentbox help

---

### agentbox start

Creates a git worktree on a new branch, builds the container image, and
launches the agent inside the container. When `--no-git` is passed, the git
steps are skipped and the current directory is mounted directly.

    agentbox start [BRANCH] [OPTIONS]

**BRANCH**

The name of the git branch and worktree to create, or a session label when
using `--no-git`. Defaults to `agentbox-<ISO date>` (e.g.
`agentbox-2026-03-16`). Slashes are replaced with dashes when deriving the
container name.

In git mode the worktree is created at
`<git-root>/agentbox-worktrees/<branch>`. If the directory already exists it
is reused without error, allowing a session to be restarted on the same
branch. In `--no-git` mode this argument serves only as a label for the
container name.

**Options**

    -a, --agent <type>

The agent to install and launch. Defaults to `claude-code`.

| Value         | Installed package                          | CLI binary  | Config dir        |
|---------------|--------------------------------------------|-------------|-------------------|
| claude-code   | claude.ai/install.sh                       | claude      | ~/.claude         |
| qwen-code     | @qwen-code/qwen-code@latest                | qwen        | ~/.qwen           |
| opencode-ai   | opencode-ai                                | opencode    | ~/.opencode       |
| cursor        | cursor.com/install                         | cursor      | ~/.cursor         |

The agent config directory is mounted read-write into the container so that
credentials and settings persist across sessions.

    -s, --use-stash

Stash any uncommitted changes in the current working tree before creating the
worktree, then pop the stash inside the new worktree. Useful for carrying
work-in-progress into the agent session.

    --no-autostart

Do not launch the agent CLI after the container starts. Drops into a bash
shell instead. Useful for inspecting the environment or running commands
manually.

    --no-devbox

Skip devbox integration even if a `devbox.json` is present in the worktree.
By default, if `devbox.json` is detected, the agent is launched inside
`devbox shell` so that the project's declared toolchain is available.

    --dangerously-skip-permissions

Pass `--dangerously-skip-permissions` to the agent CLI at launch. This
disables the agent's interactive permission prompts. Off by default.

    --no-git

Start a session without a git repository. The current working directory is
mounted as the workspace instead of a dedicated worktree. Branch creation,
stash, and worktree removal steps are skipped entirely. Useful for running an
agent against a plain directory or a project that does not use git.

    --refresh-cache

Delete the on-disk tool cache for the selected agent type (under
`<agentbox-dir>/cache/<agent-type>/`), then start the session so the install
step runs again. Use this to upgrade after a new agent release. Without this
flag, if the agent CLI is already present in the cache from a previous
session, the install command is skipped.

    --privileged

Run the container with the `--privileged` flag. This grants the container full
access to host devices and disables the default seccomp/AppArmor profiles,
which is required for Docker-in-Docker (dind) workflows. Off by default — only
use this when the agent session specifically needs to run a container daemon.

---

### agentbox stop

Stops and removes the running container, then prints the path to the worktree
where the agent made its changes.

    agentbox stop

The worktree and its branch are never deleted automatically. After stopping,
review the changes in the printed directory and merge them manually when
ready. The session can be restarted on the same branch with
`agentbox start <branch>`.

The worktree path is also printed whenever agentbox exits for any reason,
including container exit, script interruption, or failure. This ensures the
location of any uncommitted changes is never silently lost.

---

### agentbox resume

Attaches to a container that is already running.

    agentbox resume

If the container is not running, an error is printed with a hint to use
`agentbox start`.

---

### Global options

    -v, --verbose

Print every podman/docker command to stderr before running it. Can be placed
anywhere in the argument list.

    agentbox --verbose start my-branch --agent qwen-code

---

## Container environment

The container is built from the `Containerfile` in the agentbox directory.
The base image is `docker.io/jetpackio/devbox:latest`.

At build time the `devbox` user inside the container is remapped to match the
calling user's UID and GID via `--build-arg USER_ID` and `--build-arg
GROUP_ID`. This ensures all files written inside the container are owned by
the correct host user without any chowning.

npm is configured during the image build to use `$HOME/.npm-global` as the
global prefix, so `npm install -g` never requires root or sudo.

### Volume mounts

| Host path                        | Container path              | Notes                        |
|----------------------------------|-----------------------------|------------------------------|
| `<worktree>`                     | `/home/devbox/app`          | Project files, read-write    |
| `~/<agent-config-dir>`           | `/home/devbox/<config-dir>` | Agent credentials and config |
| `~/.ssh/` (if present)          | `/home/devbox/.ssh/`        | Read-only                    |
| `~/.ssh/known_hosts` (if present)| `/home/devbox/.ssh/known_hosts` | Read-only               |
| `<git-root>/.devbox/`            | `/home/devbox/app/.devbox/` | If exists and `--no-devbox` not set |
| `<agentbox-dir>/skills/`         | `/home/devbox/app/skills`   | If directory exists          |
| `<agentbox-dir>/workflows/`      | `/home/devbox/app/workflows`| If directory exists          |
| `<agentbox-dir>/cache/<agent>/npm-global` | `/home/devbox/.npm-global` | Agent installs (`npm -g`)   |
| `<agentbox-dir>/cache/<agent>/local`      | `/home/devbox/.local`      | e.g. curl-based CLI binaries |

If a `.devbox` directory exists at the git root, it is automatically mounted
into the container at `/home/devbox/app/.devbox/`. This allows devbox package
configurations and profiles to be shared across sessions. The mount is skipped
if `--no-devbox` is specified.

The cache directories are created automatically. Each `--agent` value has its
own cache so installs do not collide.

On podman, all volumes are relabeled with `:z` for SELinux compatibility and
`--userns=keep-id` is set alongside `--user` to maintain correct namespace
mapping.

The container uses `--network=host` so the agent can reach local services
without port mapping.

### Environment variables

The following variables are always set inside the container:

| Variable                  | Value                        |
|---------------------------|------------------------------|
| `HOME`                    | `/home/devbox`               |
| `CLAUDE_CONFIG_DIR`       | `/home/devbox/.claude`       |

Additional variables are forwarded from the host via `auto_envs.conf` (see
below).

---

## Configuration files

All configuration files live in the agentbox installation directory alongside
the `agentbox` executable.

### auto_envs.conf

Lists host environment variable names to forward into the container. One
name per line. Comments (lines starting with `#` or trailing after `#`) and
blank lines are ignored. The variable value is read from the host at session
start time.

Example:

    # Variables forwarded into every agentbox session
    GITHUB_TOKEN
    NPM_TOKEN

If a listed variable is not set on the host it is silently skipped.

### pre_start.sh

A shell script sourced inside the container before the agent is installed.
Because it is sourced (not executed in a subshell), `export` statements
take effect for the rest of the session, including the agent process.

The script is base64-encoded on the host and decoded inside the container at
runtime, so it may contain any content including multi-line strings and
special characters.

Example:

    export GOPRIVATE=github.com/myorg*
    export NODE_OPTIONS=--max-old-space-size=4096

### defaults.conf

General configuration options for agentbox. One `key=value` pair per line.
Lines starting with `#` are comments.

Example:

    # Default agent type to use when --agent is not specified
    # Options: claude-code, qwen-code, opencode-ai, cursor
    DEFAULT_AGENT=claude-code

### skills/ and workflows/

If a `skills/` or `workflows/` directory exists in the agentbox installation
directory, it is mounted into the container at
`/home/devbox/app/skills` and `/home/devbox/app/workflows` respectively.
These directories are intended for agent-specific skill definitions and
workflow configurations.

---

## Shell Completion

Tab completion is available for bash and zsh after installation. The completion
script is automatically sourced in your shell rc file during installation.

Completion includes:

- Subcommands: `start`, `stop`, `resume`, `help`
- Options: `-v`, `--verbose`, `-s`, `--use-stash`, `--agent`, etc.
- Agent types: `claude-code`, `qwen-code`, `opencode-ai`, `cursor`

### Manual Setup

If completion doesn't work automatically, add this to your shell rc file:

    # bash
    source "${HOME}/.local/bin/agentbox/agentbox.completion"

    # zsh
    autoload -Uz compinit && compinit
    source "${HOME}/.local/bin/agentbox/agentbox.completion"

---

## Session state

agentbox stores the active session in `.agentbox-state` in the installation
directory. The file is a plain `key=value` list written at session start and
deleted at `agentbox stop`.

    CONTAINER_NAME=agentbox-my-branch
    WORKTREE_PATH=/path/to/repo/agentbox-worktrees/my-branch
    BRANCH_NAME=my-branch
    AGENT_TYPE=claude-code
    GIT_ROOT=/path/to/repo

Only one session is active at a time. Starting a second session while a
container is running will either resume the existing container (if the same
container name is detected) or print an error.

---

## Startup sequence

When `agentbox start` is invoked the following steps occur in order:

1. Verify the current directory is inside a git repository (skipped with `--no-git`).
2. Check that no session is already active.
3. Stash changes in the current worktree if `--use-stash` (skipped with `--no-git`).
4. Create the git worktree and branch, or reuse if already present (skipped with `--no-git`).
5. Pop the stash into the new worktree if `--use-stash` (skipped with `--no-git`).
6. Build the container image with the caller's UID/GID as build args.
7. Write the state file.
8. If the container name already exists and is running, attach to it.
9. If the container name exists but is stopped, remove it and start fresh.
10. Inside the new container, in order:
    a. Source `pre_start.sh` (if present).
    b. Install the agent (skipped if the CLI binary already exists in the
       persisted cache, unless `--refresh-cache` cleared it).
    c. Launch the agent CLI (or `devbox shell`, or `bash` depending on flags).
11. On exit — whether the container exits normally, the script is interrupted,
    or a failure occurs — print the worktree path so the user knows where to
    find the agent's changes.
