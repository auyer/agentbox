# agentbox

Run LLM coding agents in an isolated container, locked to a dedicated git
worktree. Each session gets its own branch, its own container, and no access
to the rest of your repository's git history.
It can use your Containerfile/Dockerfile for dependencies, and automatically loads a .devcontainer config if available.


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

    agentbox [BRANCH] [OPTIONS]
    agentbox start [BRANCH] [OPTIONS]   # backwards-compatible alias

### Commands

    agentbox [BRANCH] [OPTIONS]
    agentbox help

---

### agentbox start

Creates a git worktree on a new branch, builds the container image, and
launches the agent inside the container. When `--no-git-worktree` is passed,
no branch or worktree is created — the current directory is mounted into the
container as-is.

    agentbox start [BRANCH] [OPTIONS]

**BRANCH**

The name of the git branch and worktree to create. Defaults to
`agentbox-<ISO date>` (e.g. `agentbox-2026-03-16`). Slashes are replaced with
dashes when deriving the container name.

The worktree is created at `<git-root>/agentbox-worktrees/<branch>`. If the
directory already exists it is reused without error, allowing a session to be
restarted on the same branch.

Ignored when `--no-git-worktree` is passed — the argument is not accepted in
that mode.

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

    --dangerously-skip-permissions

Pass `--dangerously-skip-permissions` to the agent CLI at launch. This
disables the agent's interactive permission prompts. Off by default.

    --no-git-worktree

Mount the current directory into the container as-is, without creating a
branch or worktree. The agent works directly inside your existing directory —
no separate folder is created, no branch is checked out, and `--use-stash` has
no effect. Useful when you want the agent to operate on the current state of
the project without isolation, or when the project does not use git.

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

    --keep-container

Do not pass `--rm` to the container runtime. By default the container is
automatically removed when the session ends. With this flag the container
persists after exit; on exit agentbox prints the exact command to reconnect:

    podman exec -it agentbox-myproject-my-branch bash

Use the printed `podman rm -f <name>` (or `docker rm -f <name>`) command to
clean up the container when you no longer need it.

    --no-devcontainer

Disable automatic devcontainer.json detection. By default, when `--image` is
not specified and a `.devcontainer/devcontainer.json` (or `.devcontainer.json`)
is found in the project root, its image or Dockerfile is used automatically.
See [**Devcontainer auto-detection**](#devcontainer-auto-detection) below.

    --image <image-ref|path>

Use a user-provided container image as the base runtime environment instead of
the agentbox built-in image. See [**Custom images**](#custom-images) below.

    --mount <host:container[:options]>

Mount an additional host path into the container. The container path may start
with `./` to be interpreted as relative to the project workdir. Can be
specified multiple times.

Variables `${CONTAINER_HOME}`, `${CONTAINER_WORKDIR}`, `${HOME}`, and
`${AGENT_DIR}` are expanded in both paths.

    --docker

Force the use of `docker` even when `podman` is available.

---

### Global options

    -v, --verbose

Print every podman/docker command to stderr before running it. Can be placed
anywhere in the argument list.

    agentbox --verbose start my-branch --agent qwen-code

---

## Container environment

The container is built from the `Containerfile` in the agentbox directory.
The base image is `docker.io/node:trixie-slim`.

At build time the host user's UID and GID are passed as `USER_ID` and
`GROUP_ID` build args. The home directory `/home/agentbox` and all its
subdirectories are created and chowned to these IDs at build time, so all
files written inside the container are owned by the correct host user without
any runtime chowning.

npm is configured during the image build to use `$HOME/.npm-global` as the
global prefix, so `npm install -g` never requires root.

The project worktree is always mounted at `/home/agentbox/app`, which is also
set as the container's working directory.

### Volume mounts

| Host path                                 | Container path                  | Notes                     |
|-------------------------------------------|---------------------------------|---------------------------|
| `<worktree>`                              | `/home/agentbox/app`            | Project files, read-write |
| `~/<agent-config-dir>`                    | `/home/agentbox/<config-dir>`   | Agent credentials/config  |
| `~/.ssh/` (if present)                    | `/home/agentbox/.ssh/`          | Read-only                 |
| `~/.ssh/known_hosts` (if present)         | `/home/agentbox/.ssh/known_hosts` | Read-only               |
| `<agentbox-dir>/skills/`                  | `/home/agentbox/app/skills`     | If directory exists       |
| `<agentbox-dir>/workflows/`               | `/home/agentbox/app/workflows`  | If directory exists       |
| `<agentbox-dir>/cache/<agent>/npm-global` | `/home/agentbox/.npm-global`    | Agent installs (`npm -g`) |
| `<agentbox-dir>/cache/<agent>/local`      | `/home/agentbox/.local`         | e.g. curl-based CLIs      |

The cache directories are created automatically. Each `--agent` value has its
own cache so installs do not collide.

On podman, all volumes are relabeled with `:z` for SELinux compatibility and
`--userns=keep-id` is set alongside `--user` to maintain correct namespace
mapping.

The container uses `--network=host` so the agent can reach local services
without port mapping.

### Environment variables

The following variables are set inside the container:

| Variable            | Value                          |
|---------------------|--------------------------------|
| `HOME`              | `/home/agentbox`               |
| `CLAUDE_CONFIG_DIR` | `/home/agentbox/.claude`       |
| `NPM_CONFIG_PREFIX` | `/home/agentbox/.npm-global`   |

Additional variables are forwarded from the host via `auto_envs.conf` (see
below).

---

## Devcontainer auto-detection

When `--image` is not provided, agentbox checks for a devcontainer.json in
the project root and uses its image configuration automatically.

### Search paths (in priority order)

1. `.devcontainer/devcontainer.json`
2. `.devcontainer.json`
3. `.devcontainer/<subdir>/devcontainer.json` (one level deep)

### Supported configuration

| devcontainer.json field | Behaviour |
|-------------------------|-----------|
| `"image": "<ref>"` | Image reference used directly (equivalent to `--image <ref>`) |
| `"build.dockerfile"` + `"build.context"` | Dockerfile built with the given context; result used as base image |
| `"dockerComposeFile"` | Not supported — auto-detection skipped |

`build.context` defaults to the directory containing `devcontainer.json` if
not specified. `build.args` entries are ignored; agentbox always passes
`USER_ID` and `GROUP_ID` from the host.

JSON parsing is done by running `jq` inside the agentbox base image, so no
`jq` installation is required on the host.

### Disabling

Pass `--no-devcontainer` to skip detection entirely and use the agentbox
built-in image, or pass `--image` to supply an explicit image instead.

---

## Custom images

The `--image` flag lets you bring your own container image as the runtime
environment. agentbox layers the agentbox environment on top of it so the
agent CLI works regardless of what the base image contains.

    agentbox start --image rust:bookworm --agent claude-code
    agentbox start --image ./MyDockerfile --agent qwen-code

### How it works

When `--image` is used agentbox performs the following build steps before
starting the container:

1. **Build `agentbox-image`** from the local `Containerfile` as usual. This
   image is used as the source for node/npm if they are missing from your
   image.

2. **Build the user image.** If the value is a path to a local
   `Containerfile`/`Dockerfile`, it is built first and tagged
   `agentbox-user-image`. If it is an image reference (e.g. `rust:bookworm`),
   it is pulled/used directly.

3. **Build the runtime image.** A thin wrapper `Containerfile` is generated
   and built on top of the user image. This wrapper:
   - Copies the node runtime (`node`, `npm`, `npx` and `node_modules`) from
     `agentbox-image` if the user image does not already have node.
   - Creates `/home/agentbox` with the correct directory structure and
     ownership (`chown -R <host-uid>:<host-gid>`).
   - Sets `HOME`, `NPM_CONFIG_PREFIX`, `PATH`, and `WORKDIR` to the agentbox
     conventions.

   The result is tagged `agentbox-user-image`. Because Docker/Podman layer
   caching applies, subsequent runs with an unchanged user image are instant.

4. **Pre-populate the tool cache.** A one-shot installer container runs from
   `agentbox-image` to install the agent CLI into the on-disk cache
   (`<agentbox-dir>/cache/<agent-type>/`). Subsequent runs skip this if the
   CLI is already cached.

5. **Start the runtime container** (`agentbox-user-image`) with the tool cache
   mounted at `/home/agentbox/.npm-global` and `/home/agentbox/.local`.

### What you get in the container

- Your image's toolchain is fully preserved and available in `PATH` (e.g.
  `cargo`, `go`, system packages).
- The agent CLI (`claude`, `qwen`, etc.) is installed and on `PATH`.
- The project is mounted at `/home/agentbox/app` (the working directory).
- Agent config and credentials are mounted from the host as usual.

### Requirements

The user image must have `bash` available. glibc-based images (Debian, Ubuntu,
Fedora, RHEL) work out of the box. Alpine/musl images are not supported.

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

### default_mounts.conf

Extra volume mounts added to every container. Format: `host:container[:options]`,
one per line.

The container path may start with `./` to be resolved relative to the project
workdir. The following variables are expanded in both paths:

| Variable              | Expands to                              |
|-----------------------|-----------------------------------------|
| `${CONTAINER_HOME}`   | Container home directory (`/home/agentbox`) |
| `${CONTAINER_WORKDIR}`| Container working directory             |
| `${HOME}`             | Host user home directory                |
| `${AGENT_DIR}`        | agentbox installation directory         |

### default-flags

Default command-line flags prepended to every agentbox invocation. One flag
(and its value, if any) per line. Lines starting with `#` and blank lines are
ignored. CLI flags always override these — specifying a flag twice is fine.

All supported flags are listed in the file as commented-out examples. To set
a default, uncomment the relevant line. Example:

    # Always use qwen-code and skip the agent permission prompts
    --agent qwen-code
    --dangerously-skip-permissions

### skills/ and workflows/

If a `skills/` or `workflows/` directory exists in the agentbox installation
directory, it is mounted into the container at
`/home/agentbox/app/skills` and `/home/agentbox/app/workflows` respectively.

---

## Shell Completion

Tab completion is available for bash and zsh after installation. The completion
script is automatically sourced in your shell rc file during installation.

Completion includes:

- Subcommands: `start`, `help`
- Options: `-v`, `--verbose`, `-s`, `--use-stash`, `--agent`, etc.
- Agent types: `claude-code`, `qwen-code`, `opencode-ai`, `cursor`
- File path suggestions for `--image`

### Manual Setup

If completion doesn't work automatically, add this to your shell rc file:

    # bash
    source "${HOME}/.local/bin/agentbox/agentbox.completion"

    # zsh
    autoload -Uz compinit && compinit
    source "${HOME}/.local/bin/agentbox/agentbox.completion"

---

## Session state

agentbox does not maintain a session state file. Container lifecycle is
managed directly by podman/docker.

By default containers are run with `--rm` and are automatically removed when
the session ends. The worktree path is always printed on exit so uncommitted
changes are never silently lost.

With `--keep-container` the container persists after the session ends.
agentbox prints the exact command to reconnect on exit:

    Container was kept. To reconnect:
      podman exec -it agentbox-myproject-my-branch bash
    To stop and remove it:
      podman rm -f agentbox-myproject-my-branch

If you start a new session using the same branch name while a container with
that name is already running, agentbox attaches to it instead of starting a
new one. If the container exists but is stopped, it is removed and a fresh
container is started.

---

## Startup sequence

When `agentbox start` is invoked the following steps occur in order:

1. Verify the current directory is inside a git repository (skipped with `--no-git-worktree`).
2. If a container with the computed name already exists and is running, attach to it and exit.
   If it exists but is stopped, remove it.
3. Stash changes in the current worktree if `--use-stash` (skipped with `--no-git-worktree`).
4. Create the git worktree and branch, or reuse if already present. With `--no-git-worktree`
   this step is skipped entirely — the current directory is used directly.
5. Pop the stash into the new worktree if `--use-stash` (skipped with `--no-git-worktree`).
6. Build `agentbox-image` from the local `Containerfile`.
7. If `--image` is set:
   a. Build the user image (if a local file path was given).
   b. Build the combined runtime image, layering node (if needed) and the
      agentbox environment on top of the user image.
   c. Run a one-shot installer container to pre-populate the agent CLI cache.
8. Start the container (with `--rm` unless `--keep-container` was passed). Inside:
   a. Source `pre_start.sh` (if present).
   b. Install the agent CLI (skipped if already in the persisted cache, unless
      `--refresh-cache` cleared it). Skipped entirely when `--image` is used,
      since the cache was pre-populated in step 7c.
   c. Launch the agent CLI (or `bash` if `--no-autostart`).
9. On exit — whether the container exits normally, the script is interrupted,
   or a failure occurs — print the worktree path. If `--keep-container` was
   used, also print the reconnect and remove commands.
