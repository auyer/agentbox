#!/usr/bin/env bash
set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
FORCE_DOCKER=0
declare -a EXTRA_MOUNTS=()
declare -a BLOCK_FOLDERS=()

# Globals set by cmd_start; read by _on_exit trap
WORKTREE_PATH_HINT=''
CONTAINER_NAME_HINT=''
KEEP_CONTAINER_HINT=0
CMD_HINT=''

# Agent type → host:container config dir pairs
# Host folder stays the same for all tools; container folder differs for opencode-ai
declare -A AGENT_CONFIG_DIRS=(
	['claude-code']="${HOME}/.claude:/home/agentbox/.claude"
	['qwen-code']="${HOME}/.qwen:/home/agentbox/.qwen"
	['opencode-ai']="${HOME}/.opencode:/home/agentbox/.local/share/opencode"
	['cursor']="${HOME}/.cursor:/home/agentbox/.cursor"
)

# Agent type → container-side skills directory
# Skills from <agentbox-dir>/skills are mounted here for each agent
declare -A AGENT_SKILL_DIRS=(
	['claude-code']='/home/agentbox/.claude/skills'
	['qwen-code']='/home/agentbox/.qwen/skills'
	['opencode-ai']='/home/agentbox/.agents/skills'
	['cursor']='/home/agentbox/.cursor/skills'
)

# Agent type → npm install command
declare -A AGENT_INSTALL_CMDS=(
	['claude-code']='curl -fsSL https://claude.ai/install.sh | bash'
	['qwen-code']='npm install -g @qwen-code/qwen-code@latest'
	['opencode-ai']='npm i -g opencode-ai'
	['cursor']='curl https://cursor.com/install -fsS | bash'
)

# Agent type → env var name that tells the agent where its config dir is.
# The value is the container-side path from AGENT_CONFIG_DIRS at runtime,
# so the path is never duplicated.  Empty means no config-dir env var.
declare -A AGENT_CONFIG_ENV_VAR=(
	['claude-code']='CLAUDE_CONFIG_DIR'
	['qwen-code']=''
	['opencode-ai']=''
	['cursor']=''
)

# Agent type → CLI binary to launch after install
declare -A AGENT_CLI_CMDS=(
	['claude-code']='claude'
	['qwen-code']='qwen'
	['opencode-ai']='opencode'
	['cursor']='cursor-agent'
)

# Compatibility helper: realpath works on Linux but not macOS
# Try realpath, then readlink -f, then perl fallback
function _realpath_compat() {
	if command -v realpath &>/dev/null; then
		realpath "$@"
	elif [[ "$(uname)" == "Darwin" ]]; then
		perl -e "use Cwd; print Cwd::realpath(shift)" "$1"
	else
		readlink -f "$@"
	fi
}

# Compatibility helper: base64 encoding with proper options for macOS and Linux
function _base64_encode() {
	local file="$1"
	# Try Linux syntax first (-w 0), fallback to macOS syntax (-b 0)
	base64 -w 0 < "${file}" 2>/dev/null || base64 -b 0 -i "${file}"
}


function usage() {
	printf 'Usage: agentbox [BRANCH] [OPTIONS]\n'
	printf '\n'
	printf 'Commands:\n'
	printf '  [BRANCH] [OPTIONS]  Start a new agent session\n'
	printf '  help                Show this help message\n'
	printf '\n'
	printf 'Options:\n'
	printf '  BRANCH                    Branch name'
	printf ' (default: agentbox-<date>)\n'
	printf '  -a, --agent <type>        Agent type (default: claude-code)\n'
	printf '                            Options: claude-code, qwen-code,\n'
	printf '                            opencode-ai, cursor\n'
	printf '  -s, --use-stash           Stash current changes and apply\n'
	printf '                            to the new worktree\n'
	printf '  --no-autostart            Do not launch the agent CLI\n'
	printf '                            automatically (drops into bash)\n'
	printf '  --dangerously-skip-permissions\n'
	printf '                            Run agent in yolo mode\n'
	printf '                            (off by default)\n'
	printf '  --no-git-worktree                  Run without a git repository.\n'
	printf '                            Mounts the current directory;\n'
	printf '                            skips worktree and branch creation\n'
	printf '  --mount <host:container>  Mount a host path into the container.\n'
	printf '                            Container path starting with ./ is\n'
	printf '                            relative to the container workdir.\n'
	printf '                            Can be specified multiple times.\n'
	printf '  --block-folder <path>      Hide a directory from the agent by\n'
	printf '                            mounting an empty volume over it.\n'
	printf '                            Paths starting with ./ are relative\n'
	printf '                            to the workdir. Can be specified\n'
	printf '                            multiple times.\n'
	printf '  --refresh-cache           Remove cached agent install for this\n'
	printf '                            agent type, then reinstall on start\n'
	printf '  --privileged              Run the container in privileged mode\n'
	printf '                            (enables Docker-in-Docker and full\n'
	printf '                            device access; off by default)\n'
	printf '  --mount-docker-socket     Mount the host docker/podman socket\n'
	printf '                            into the container at\n'
	printf '                            /var/run/docker.sock. Socket path\n'
	printf '                            is resolved from DOCKER_HOST or\n'
	printf '                            via context inspect. On podman,\n'
	printf '                            --security-opt label=disable is\n'
	printf '                            added automatically.\n'
	printf '  --keep-container          Do not remove the container on exit.\n'
	printf '                            The reconnect command is printed on\n'
	printf '                            exit. By default containers are\n'
	printf '                            removed automatically (--rm).\n'
	printf '  --no-devcontainer         Skip automatic devcontainer.json\n'
	printf '                            detection. By default, if no --image\n'
	printf '                            is given and a devcontainer.json is\n'
	printf '                            found, its image or Dockerfile is\n'
	printf '                            used automatically.\n'
	printf '  --image <image-ref>       Use a custom container image instead\n'
	printf '                            of building from Containerfile.\n'
	printf '                            Requires a glibc-based image with\n'
	printf '\nGlobal options:\n'
	printf '  -v, --verbose             Print container commands before\n'
	printf '                            running them\n'
	printf '  --docker                  Use docker even if podman is available\n'
}

function print_worktree_hint() {
	local path="${1}"
	printf '\n'
	printf 'The agent session ended. Code changes are in:\n'
	printf '  %s\n' "${path}"
	printf 'Review the changes there before merging into your main branch.\n'
}

# Print worktree hint (and reconnect hint when --keep-container was used)
# on any exit so changes and container names are never silently lost.
function _on_exit() {
	if [[ -n "${WORKTREE_PATH_HINT}" ]]; then
		print_worktree_hint "${WORKTREE_PATH_HINT}"
	fi
	if [[ "${KEEP_CONTAINER_HINT}" -eq 1 ]] && [[ -n "${CONTAINER_NAME_HINT}" ]]; then
		printf '\nContainer was kept. To reconnect:\n'
		printf '  %s exec -it %s bash\n' "${CMD_HINT}" "${CONTAINER_NAME_HINT}"
		printf 'To stop and remove it:\n'
		printf '  %s rm -f %s\n' "${CMD_HINT}" "${CONTAINER_NAME_HINT}"
	fi
}
trap '_on_exit' EXIT

# Run a command, printing it first when verbose mode is on.
function run_cmd() {
	if [[ "${VERBOSE}" -eq 1 ]]; then
		printf '+' >&2
		printf ' %q' "$@" >&2
		printf '\n' >&2
	fi
	"$@"
}

function detect_container_cmd() {
	if [[ "${FORCE_DOCKER}" -eq 0 ]] && command -v podman >/dev/null 2>&1; then
		printf 'podman'
		return 0
	fi
	if command -v docker >/dev/null 2>&1; then
		printf 'docker'
		return 0
	fi
	printf 'ERROR: neither podman nor docker found in PATH\n' >&2
	exit 1 # EPERM
}

# Resolve the host docker/podman socket path for --mount-docker-socket.
# Priority: DOCKER_HOST env var → <cmd> context inspect → error.
# Prints the resolved absolute socket path on stdout (no unix:// prefix).
# Usage: resolve_docker_socket <cmd>
function resolve_docker_socket() {
	local cmd="${1}"
	local socket_path=''

	# Priority 1: DOCKER_HOST env var (set by Docker, Podman, and compatible tools)
	if [[ -n "${DOCKER_HOST:-}" ]]; then
		if [[ "${DOCKER_HOST}" == unix://* ]]; then
			socket_path="${DOCKER_HOST#unix://}"
		elif [[ "${DOCKER_HOST}" != *://* ]]; then
			# Bare path with no URI scheme — use as-is
			socket_path="${DOCKER_HOST}"
		fi
		# tcp:// and other non-socket schemes are silently skipped
	fi

	# Priority 2: probe via context inspect (works for both docker and podman)
	if [[ -z "${socket_path}" ]]; then
		socket_path="$(
			"${cmd}" context inspect \
				--format '{{(index .Endpoints "docker").Host}}' 2>/dev/null \
				| sed 's|^unix://||'
		)" || socket_path=''
	fi

	if [[ -z "${socket_path}" ]]; then
		printf 'ERROR: --mount-docker-socket: cannot determine socket path.\n' >&2
		printf '  Set DOCKER_HOST (e.g. DOCKER_HOST=unix:///run/user/%s/podman/podman.sock)\n' \
			"$(id -u)" >&2
		printf '  or ensure "%s context inspect" returns a valid endpoint.\n' "${cmd}" >&2
		exit 1
	fi

	printf '%s' "${socket_path}"
}

function get_git_root() {
	local git_root
	git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
		printf 'ERROR: not inside a git repository\n' >&2
		exit 2 # ENOENT
	}
	printf '%s' "${git_root}"
}

# Expand ~ and ${HOME} / ${AGENT_DIR} / ${CONTAINER_HOME} /
# ${CONTAINER_WORKDIR} in a path string.
# Usage: normalize_mount_path <path> [container_home] [container_workdir]
function normalize_mount_path() {
	local path="${1}"
	local c_home="${2:-/home/agentbox}"
	local c_workdir="${3:-/home/agentbox/app}"
	if [[ "${path}" == '~'* ]]; then
		path="${HOME}${path:1}"
	fi
	path="${path//\$\{HOME\}/${HOME}}"
	path="${path//\$\{AGENT_DIR\}/${AGENT_DIR}}"
	path="${path//\$\{CONTAINER_HOME\}/${c_home}}"
	path="${path//\$\{CONTAINER_WORKDIR\}/${c_workdir}}"
	printf '%s' "${path}"
}

# Parse a mount spec of the form host:container[:options] and print a
# --volume= argument. Silently skips the entry if the host path does not exist.
# Usage: parse_mount_spec <spec> <selinux_suffix> [container_home] [container_workdir]
function parse_mount_spec() {
	local raw_spec="${1}"
	local selinux="${2}"
	local c_home="${3:-/home/agentbox}"
	local c_workdir="${4:-/home/agentbox/app}"

	# Must contain at least one colon
	if [[ "${raw_spec}" != *:* ]]; then
		printf 'WARNING: ignoring malformed mount spec (no colon): %s\n' \
			"${raw_spec}" >&2
		return 0
	fi

	local host remainder container user_opts=''
	host="${raw_spec%%:*}"
	remainder="${raw_spec#*:}"
	# remainder may be "container" or "container:opts"
	container="${remainder%%:*}"
	if [[ "${remainder}" == *:* ]]; then
		user_opts="${remainder#*:}"
	fi

	if [[ -z "${container}" ]]; then
		printf 'WARNING: ignoring mount spec with empty container path: %s\n' \
			"${raw_spec}" >&2
		return 0
	fi

	host="$(normalize_mount_path "${host}" "${c_home}" "${c_workdir}")"

	# Rewrite relative container path to workdir-relative absolute path
	if [[ "${container}" == './'* ]]; then
		container="${c_workdir}/${container:2}"
	fi
	# Expand variables in the container-side path (e.g. ${CONTAINER_HOME})
	container="$(normalize_mount_path "${container}" "${c_home}" "${c_workdir}")"

	# Skip if the host path does not exist
	if [[ ! -e "${host}" ]]; then
		printf 'WARNING: mount host path does not exist, skipping: %s\n' \
			"${host}" >&2
		return 0
	fi

	# Combine selinux (:z) and user options (e.g. ro) with a comma so that
	# podman receives a valid option string like :z,ro
	local option_str=''
	if [[ -n "${selinux}" ]] && [[ -n "${user_opts}" ]]; then
		option_str="${selinux},${user_opts}"
	elif [[ -n "${selinux}" ]]; then
		option_str="${selinux}"
	elif [[ -n "${user_opts}" ]]; then
		option_str=":${user_opts}"
	fi

	printf '%s\n' "--volume=${host}:${container}${option_str}"
}

# Read default_mounts.conf and emit --volume= args for each valid entry.
# Usage: read_mounts_file <selinux_suffix> [container_home] [container_workdir]
function read_mounts_file() {
	local selinux="${1}"
	local c_home="${2:-/home/agentbox}"
	local c_workdir="${3:-/home/agentbox/app}"
	local mounts_file="${AGENT_DIR}/default_mounts.conf"
	[[ -f "${mounts_file}" ]] || return 0
	local line
	while IFS= read -r line; do
		line="${line%%#*}"
		# Strip leading and trailing whitespace
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -z "${line}" ]] && continue
		parse_mount_spec "${line}" "${selinux}" "${c_home}" "${c_workdir}"
	done <"${mounts_file}"
}

function build_run_args() {
	local cmd="${1}"
	local worktree_path="${2}"
	local container_name="${3}"
	local agent_type="${4}"
	local git_root="${5:-}"
	local privileged="${6:-0}"
	local custom_image="${7:-}"
	local container_home="${8:-/home/agentbox}"
	local container_workdir="${9:-/home/agentbox/app}"
	local keep_container="${10:-0}"
	local docker_socket_path="${11:-}"
	local config_pair container_config_dir config_dir
	local -a args

	config_pair="${AGENT_CONFIG_DIRS[${agent_type}]}"
	config_dir="${config_pair%%:*}"
	container_config_dir="${config_pair#*:}"

	args=(
		'--interactive'
		'--tty'
		'--network=host'
		"--workdir=${container_workdir}"
		"--name=${container_name}"
		"--env=HOME=${container_home}"
	)

	# Auto-remove the container on exit unless --keep-container was requested.
	if [[ "${keep_container}" -eq 0 ]]; then
		args+=('--rm')
	fi

	# If this agent type uses an env var to locate its config dir, set it
	# to the container-side path extracted from AGENT_CONFIG_DIRS above.
	local config_env_var="${AGENT_CONFIG_ENV_VAR[${agent_type}]:-}"
	if [[ -n "${config_env_var}" ]]; then
		args+=("--env=${config_env_var}=${container_config_dir}")
	fi

	# Always run as the host user so the process is never root.
	# --userns=keep-id (podman) maps host UID into the container
	# namespace and is required alongside --user for correct
	# volume ownership. :z relabels volumes for SELinux (podman only).
	local selinux=''
	args+=("--user=$(id -u):$(id -g)")
	if [[ "${cmd}" == 'podman' ]]; then
		args+=('--userns=keep-id')
		selinux=':z'
	fi
	if [[ "${privileged}" -eq 1 ]]; then
		args+=('--privileged')
	fi

	# Mount docker/podman socket when --mount-docker-socket is requested.
	if [[ -n "${docker_socket_path}" ]]; then
		if [[ "${cmd}" == 'podman' ]]; then
			# :Z does per-container relabeling; label=disable allows cross-context
			# socket access under SELinux (required for podman + SELinux setups).
			args+=("--volume=${docker_socket_path}:/var/run/docker.sock:Z")
			args+=('--security-opt' 'label=disable')
		else
			args+=("--volume=${docker_socket_path}:/var/run/docker.sock")
		fi
		# Add the socket file's GID as a supplementary group so the container
		# user can access the socket without being root.  This works regardless
		# of what the group is named on the host (docker, podman, root, etc.).
		local socket_gid
		socket_gid="$(stat -f '%Xg' "${docker_socket_path}" 2>/dev/null || stat -c '%g' "${docker_socket_path}" 2>/dev/null || true)"
		if [[ -n "${socket_gid}" ]] && [[ "${socket_gid}" != '0' ]]; then
			args+=("--group-add=${socket_gid}")
		fi
		# Forward DOCKER_HOST into the container when it was set on the host,
		# so tooling inside the container uses the same socket path.
		if [[ -n "${DOCKER_HOST:-}" ]]; then
			args+=("--env=DOCKER_HOST=${DOCKER_HOST}")
		fi
	fi

	args+=("--volume=${worktree_path}:${container_workdir}${selinux}")


	# Persist npm global + ~/.local installs across sessions (per agent type).
	local cache_base="${AGENT_DIR}/cache/${agent_type}"
	args+=("--volume=${cache_base}/npm-global:/home/agentbox/.npm-global${selinux}")
	args+=("--volume=${cache_base}/local:/home/agentbox/.local${selinux}")

	args+=("--volume=${config_dir}:${container_config_dir}${selinux}")

	# Mount shared skills directory to agent's skill directory
	local skills_host="${AGENT_DIR}/skills"
	local skills_container="${AGENT_SKILL_DIRS[${agent_type}]}"
	if [[ -d "${skills_host}" ]] && [[ -n "${skills_container}" ]]; then
		args+=("--volume=${skills_host}:${skills_container}${selinux}")
	fi

	# Mounts from default_mounts.conf
	local mount_spec
	while IFS= read -r mount_spec; do
		[[ -n "${mount_spec}" ]] && args+=("${mount_spec}")
	done < <(read_mounts_file "${selinux}" "${container_home}" "${container_workdir}")

	# Mounts from --mount CLI flags
	local extra_spec
	for extra_spec in "${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"}"; do
		mount_spec="$(parse_mount_spec "${extra_spec}" "${selinux}" \
			"${container_home}" "${container_workdir}")"
		[[ -n "${mount_spec}" ]] && args+=("${mount_spec}")
	done

	# Blocked folders — mount empty tmpfs volumes to hide directories
	# from the agent. Paths starting with ./ are resolved relative to
	# the container workdir; absolute paths are used as-is.
	local blocked_path
	for blocked_path in "${BLOCK_FOLDERS[@]+"${BLOCK_FOLDERS[@]}"}"; do
		if [[ "${blocked_path}" == './'* ]]; then
			blocked_path="${container_workdir}/${blocked_path:2}"
		fi
		args+=("--volume=:${blocked_path}")
	done

	# Forward TERMINFO from host if set, mounting the path for terminal support.
	if [[ -n "${TERMINFO:-}" ]]; then
		args+=("--env=TERMINFO=${TERMINFO}")
		args+=("--volume=${TERMINFO}:${TERMINFO}${selinux}")
	fi

	# Forward host env vars listed in auto_envs.conf into the container.
	# Lines starting with # and blank lines are ignored.
	if [[ -f "${AGENT_DIR}/auto_envs.conf" ]]; then
		local var_name
		while IFS= read -r var_name; do
			# Strip inline comments and surrounding whitespace
			var_name="${var_name%%#*}"
			var_name="${var_name//[[:space:]]/}"
			[[ -z "${var_name}" ]] && continue
			if [[ -v "${var_name}" ]]; then
				args+=("--env=${var_name}=${!var_name}")
			fi
		done <"${AGENT_DIR}/auto_envs.conf"
	fi

	printf '%s\n' "${args[@]}"
}

# Return 0 if the given image has the command in PATH, non-zero otherwise.
# Usage: image_has_command <cmd> <image_ref> <command>
function image_has_command() {
	local cmd="${1}"
	local image_ref="${2}"
	local command="${3}"
	run_cmd "${cmd}" run --rm "${image_ref}" \
		sh -c "command -v ${command} >/dev/null 2>&1"
}

# Return 0 if the given image has node in PATH, non-zero otherwise.
# Usage: image_has_node <cmd> <image_ref>
function image_has_node() {
	image_has_command "${1}" "${2}" node
}

# Detect the package manager in the image. Prints the binary name or empty.
# Usage: detect_package_manager <cmd> <image_ref>
function detect_package_manager() {
	local cmd="${1}" image_ref="${2}"
	if image_has_command "${cmd}" "${image_ref}" apt-get; then
		printf 'apt-get'
	elif image_has_command "${cmd}" "${image_ref}" dnf; then
		printf 'dnf'
	elif image_has_command "${cmd}" "${image_ref}" yum; then
		printf 'yum'
	elif image_has_command "${cmd}" "${image_ref}" apk; then
		printf 'apk'
	else
		printf ''
	fi
}

# Detect the home directory and working directory configured in a container
# image. Prints two lines: first container_home, then container_workdir.
# Falls back to /root and <home>/app respectively if detection fails.
# Usage: detect_image_paths <cmd> <image_ref>
function detect_image_paths() {
	local cmd="${1}"
	local image_ref="${2}"
	local home_dir workdir

	# Primary: run the image so its own environment expands $HOME.
	home_dir="$(
		run_cmd "${cmd}" run --rm "${image_ref}" \
			sh -c 'printf "%s" "${HOME}"' 2>/dev/null || printf ''
	)"

	# Fallback 1: parse ENV entries from image metadata.
	if [[ -z "${home_dir}" ]]; then
		home_dir="$(
			run_cmd "${cmd}" inspect "${image_ref}" \
				--format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
				| grep '^HOME=' | head -1 | cut -d= -f2-
		)"
	fi

	# Fallback 2: /root is correct for images running as root.
	home_dir="${home_dir:-/root}"

	# Working directory: metadata-only, no container startup needed.
	workdir="$(
		run_cmd "${cmd}" inspect "${image_ref}" \
			--format '{{.Config.WorkingDir}}' 2>/dev/null || printf ''
	)"

	# Treat empty or bare-root WORKDIR as "not configured".
	if [[ -z "${workdir}" ]] || [[ "${workdir}" == '/' ]]; then
		workdir="${home_dir}/app"
	fi

	printf '%s\n%s\n' "${home_dir}" "${workdir}"
}

# Search for a devcontainer.json under root and extract the image config.
# Prints one of:
#   image:<ref>                              — direct image field
#   dockerfile:<abs_path> context:<abs_path> — build.dockerfile + build.context
# Prints nothing when no spec is found or the config type is unsupported
# (e.g. dockerComposeFile).  jq runs inside agentbox-image — no host dep.
# Usage: find_devcontainer_image <search_root> <cmd>
function find_devcontainer_image() {
	local root="${1}"
	local cmd="${2}"
	local spec_file=''

	# Search paths per devcontainer spec (in priority order)
	local -a candidates=(
		"${root}/.devcontainer/devcontainer.json"
		"${root}/.devcontainer.json"
	)
	# One level deep subdirectories inside .devcontainer/
	local subdir
	for subdir in "${root}/.devcontainer"/*/; do
		[[ -f "${subdir}devcontainer.json" ]] && \
			candidates+=("${subdir}devcontainer.json")
	done

	local candidate
	for candidate in "${candidates[@]}"; do
		if [[ -f "${candidate}" ]]; then
			spec_file="${candidate}"
			break
		fi
	done
	[[ -z "${spec_file}" ]] && return 0

	local spec_dir
	spec_dir="$(dirname "${spec_file}")"

	# --- direct image field ---
	local image_ref
	image_ref="$(
		run_cmd "${cmd}" run --rm -i agentbox-image \
			jq -r '.image // empty' < "${spec_file}"
	)"
	if [[ -n "${image_ref}" ]]; then
		printf 'image:%s' "${image_ref}"
		return 0
	fi

	# --- build.dockerfile field ---
	local dockerfile_rel
	dockerfile_rel="$(
		run_cmd "${cmd}" run --rm -i agentbox-image \
			jq -r '.build.dockerfile // empty' < "${spec_file}"
	)"
	if [[ -n "${dockerfile_rel}" ]]; then
		local ctx_rel abs_dockerfile abs_context
		ctx_rel="$(
			run_cmd "${cmd}" run --rm -i agentbox-image \
				jq -r '.build.context // "."' < "${spec_file}"
		)"
		abs_dockerfile="$(_realpath_compat "${spec_dir}/${dockerfile_rel}")"
		abs_context="$(_realpath_compat "${spec_dir}/${ctx_rel}")"
		printf 'dockerfile:%s context:%s' "${abs_dockerfile}" "${abs_context}"
		return 0
	fi

	# dockerComposeFile and other unsupported types: return nothing
}

# Run a one-shot installer container (agentbox-image) to populate the tool
# cache.  Skipped when the expected CLI binary is already present on disk.
# Usage: ensure_tool_cache <cmd> <agent_type> <cache_base>
function ensure_tool_cache() {
	local cmd="${1}"
	local agent_type="${2}"
	local cache_base="${3}"

	local cli_base="${AGENT_CLI_CMDS[${agent_type}]}"
	local install_cmd="${AGENT_INSTALL_CMDS[${agent_type}]}"

	# npm-installed agents land in npm-global/bin; others in local/bin
	local cli_path
	if [[ "${install_cmd}" == npm* ]]; then
		cli_path="${cache_base}/npm-global/bin/${cli_base}"
	else
		cli_path="${cache_base}/local/bin/${cli_base}"
	fi

	if [[ -f "${cli_path}" ]]; then
		printf 'Tool cache is warm for %s, skipping installer\n' "${agent_type}"
		return 0
	fi

	printf 'Cache is cold — running installer container for %s\n' "${agent_type}"

	local selinux=''
	[[ "${cmd}" == 'podman' ]] && selinux=':z'

	local -a installer_args=(
		'--rm'
		'--network=host'
		'--env=HOME=/home/agentbox'
		'--env=NPM_CONFIG_PREFIX=/home/agentbox/.npm-global'
		'--env=PATH=/home/agentbox/.local/bin:/home/agentbox/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
		"--volume=${cache_base}/npm-global:/home/agentbox/.npm-global${selinux}"
		"--volume=${cache_base}/local:/home/agentbox/.local${selinux}"
		"--user=$(id --user):$(id --group)"
	)
	if [[ "${cmd}" == 'podman' ]]; then
		installer_args+=('--userns=keep-id')
	fi

	local install_if_missing="command -v ${cli_base} >/dev/null 2>&1 || { ${install_cmd}; }"

	run_cmd "${cmd}" run "${installer_args[@]}" agentbox-image \
		/bin/bash -c "${install_if_missing}"
}

function cmd_start() {
	local branch_name=''
	local use_stash=0
	local agent_type
	local autostart=1
	local yolo=0
	local no_git=0
	local refresh_cache=0
	local privileged=0
	local mount_docker_socket=0
	local docker_socket_path=''
	local keep_container=0
	local no_devcontainer=0
	local dry_run=0
	local custom_image=''
	local git_root worktree_path container_name cmd
	local install_cmd cli_base cli_cmd
	local -a run_args

	local agent_type='claude-code'

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		-s | --use-stash)
			use_stash=1
			shift
			;;
		-a | --agent)
			agent_type="${2}"
			shift 2
			;;
		--agent=*)
			agent_type="${1#--agent=}"
			shift
			;;
		--no-autostart)
			autostart=0
			shift
			;;
		--dangerously-skip-permissions)
			yolo=1
			shift
			;;
		--no-git-worktree)
			no_git=1
			shift
			;;
		--refresh-cache)
			refresh_cache=1
			shift
			;;
		--privileged)
			privileged=1
			shift
			;;
		--mount-docker-socket)
			mount_docker_socket=1
			shift
			;;
		--keep-container)
			keep_container=1
			shift
			;;
		--no-devcontainer)
			no_devcontainer=1
			shift
			;;
		--image)
			custom_image="${2}"
			shift 2
			;;
		--image=*)
			custom_image="${1#--image=}"
			shift
			;;
		--mount)
			EXTRA_MOUNTS+=("${2}")
			shift 2
			;;
		--mount=*)
			EXTRA_MOUNTS+=("${1#--mount=}")
			shift
			;;
		--block-folder)
			BLOCK_FOLDERS+=("${2}")
			shift 2
			;;
		--block-folder=*)
			BLOCK_FOLDERS+=("${1#--block-folder=}")
			shift
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		-*)
			printf 'ERROR: unknown option: %s\n' "${1}" >&2
			usage
			exit 22 # EINVAL
			;;
		*)
			if [[ -z "${branch_name}" ]]; then
				branch_name="${1}"
			else
				printf 'ERROR: unexpected argument: %s\n' "${1}" >&2
				usage
				exit 22 # EINVAL
			fi
			shift
			;;
		esac
	done

	if [[ -z "${AGENT_INSTALL_CMDS[${agent_type}]+set}" ]]; then
		printf 'ERROR: unknown agent type: %s\n' "${agent_type}" >&2
		printf 'Valid types: claude-code, qwen-code, opencode-ai, cursor\n' >&2
		exit 22 # EINVAL
	fi

	# Create agent config directory if it doesn't exist
	local config_pair="${AGENT_CONFIG_DIRS[${agent_type}]}"
	local config_dir="${config_pair%%:*}"
	if [[ ! -d "${config_dir}" ]]; then
		printf 'Creating agent config directory: %s\n' "${config_dir}"
		mkdir -p "${config_dir}"
	fi

	if [[ -z "${branch_name}" ]]; then
		branch_name="agentbox-$(date "+%Y-%m-%d")"
	fi

	# Sanitize branch name: replace slashes with dashes
	local sanitized_branch="${branch_name//\//-}"

	if [[ "${no_git}" -eq 1 ]]; then
		worktree_path="$(pwd)"
		printf 'Running without git — mounting current directory\n'
		# Use current directory name to make container name unique per project
		local project_name
		project_name="$(basename "$(pwd)")"
		container_name="agentbox-${project_name}-${sanitized_branch}"
		if [[ "${container_name}" =~ [[:space:]] ]]; then
			printf 'ERROR: container name contains whitespace: %q\n' "${container_name}" >&2
			exit 1
		fi
	else
		git_root="$(get_git_root)"
		worktree_path="${git_root}/agentbox-worktrees/${branch_name}"
		# Use git root directory name to make container name unique per project
		local project_name
		project_name="$(basename "${git_root}")"
		container_name="agentbox-${project_name}-${sanitized_branch}"
		if [[ "${container_name}" =~ [[:space:]] ]]; then
			printf 'ERROR: container name contains whitespace: %q\n' "${container_name}" >&2
			exit 1
		fi
	fi

	cmd="$(detect_container_cmd)"

	# Resolve docker socket path when --mount-docker-socket is requested.
	if [[ "${mount_docker_socket}" -eq 1 ]]; then
		docker_socket_path="$(resolve_docker_socket "${cmd}")"
	fi

	# Set globals for _on_exit trap
	WORKTREE_PATH_HINT="${worktree_path}"
	CONTAINER_NAME_HINT="${container_name}"
	KEEP_CONTAINER_HINT="${keep_container}"
	CMD_HINT="${cmd}"

	# If a container with this name already exists, attach to it (if running)
	# or remove it (if stopped) so we can start fresh.
	local existing_state
	existing_state="$(
		run_cmd "${cmd}" inspect "${container_name}" \
			--format '{{.State.Running}}' 2>/dev/null ||
			printf 'absent'
	)"
	if [[ "${existing_state}" == 'true' ]]; then
		printf 'Container already running — attaching...\n'
		run_cmd "${cmd}" exec --interactive --tty "${container_name}" /bin/bash
		return 0
	elif [[ "${existing_state}" != 'absent' ]]; then
		printf 'Removing stopped container %s...\n' "${container_name}"
		run_cmd "${cmd}" rm "${container_name}" 2>/dev/null || \
			printf 'WARNING: could not remove container (already gone?), continuing\n'
	fi

	if [[ "${no_git}" -eq 0 ]]; then
		if [[ "${use_stash}" -eq 1 ]]; then
			printf 'Stashing current changes...\n'
			git stash
		fi

		if [[ -d "${worktree_path}" ]]; then
			printf 'Worktree already exists at %s, reusing...\n' \
				"${worktree_path}"
		else
			printf 'Creating worktree at %s...\n' "${worktree_path}"
			local branch_flag='-b'
			if git -C "${git_root}" branch --list "${branch_name}" |
				grep -q .; then
				branch_flag=''
			fi
			if [[ -n "${branch_flag}" ]]; then
				git worktree add "${worktree_path}" -b "${branch_name}"
			else
				git worktree add "${worktree_path}" "${branch_name}"
			fi
		fi

		if [[ "${use_stash}" -eq 1 ]]; then
			printf 'Applying stash to new worktree...\n'
			git -C "${worktree_path}" stash pop
		fi
	fi

	printf 'Building container image...\n'
	run_cmd "${cmd}" build \
		--tag agentbox-image \
		--build-arg "USER_ID=$(id -u)" \
		--build-arg "GROUP_ID=$(id -g)" \
		--file "${AGENT_DIR}/Containerfile" \
		"${AGENT_DIR}"

	local container_home='/home/agentbox'
	local container_workdir='/home/agentbox/app'

	# Auto-detect devcontainer image if --image was not explicitly provided.
	if [[ -z "${custom_image}" ]] && [[ "${no_devcontainer}" -eq 0 ]]; then
		local dc_search_root
		if [[ "${no_git}" -eq 1 ]]; then
			dc_search_root="${worktree_path}"
		else
			dc_search_root="${git_root}"
		fi
		local dc_result
		dc_result="$(find_devcontainer_image "${dc_search_root}" "${cmd}")"
		if [[ -n "${dc_result}" ]]; then
			if [[ "${dc_result}" == image:* ]]; then
				custom_image="${dc_result#image:}"
				# Trim whitespace and newline
				custom_image="${custom_image#"${custom_image%%[![:space:]]*}"}"
				custom_image="${custom_image%"${custom_image##*[![:space:]]}"}"
				printf 'devcontainer: using image %s\n' "${custom_image}"
			elif [[ "${dc_result}" == dockerfile:* ]]; then
				local dc_rest dc_dockerfile dc_context
				dc_rest="${dc_result#dockerfile:}"
				dc_dockerfile="${dc_rest%% context:*}"
				dc_context="${dc_rest#* context:}"
				# Trim whitespace and newline
				dc_dockerfile="${dc_dockerfile#"${dc_dockerfile%%[![:space:]]*}"}"
				dc_dockerfile="${dc_dockerfile%"${dc_dockerfile##*[![:space:]]}"}"
				dc_context="${dc_context#"${dc_context%%[![:space:]]*}"}"
				dc_context="${dc_context%"${dc_context##*[![:space:]]}"}"
				printf 'devcontainer: building from %s (context: %s)\n' \
					"${dc_dockerfile}" "${dc_context}"
				run_cmd "${cmd}" build \
					--tag agentbox-devcontainer-image \
					--build-arg "USER_ID=$(id -u)" \
					--build-arg "GROUP_ID=$(id -g)" \
					--file "${dc_dockerfile}" \
					"${dc_context}"
				custom_image='agentbox-devcontainer-image'
			fi
		fi
	fi

	if [[ -n "${custom_image}" ]]; then
		# Step 1: build user-provided Containerfile into a named image.
		local user_image_ref="${custom_image}"
		if [[ -f "${custom_image}" ]]; then
			printf 'Building custom image from %s...\n' "${custom_image}"
			run_cmd "${cmd}" build \
				--tag agentbox-user-image \
				--file "${custom_image}" \
				"$(dirname "$(_realpath_compat "${custom_image}")")"
			user_image_ref='agentbox-user-image'
		fi

		# Step 2: build a thin wrapper image that layers the agentbox
		# environment (/home/agentbox, npm prefix, PATH) on top of the
		# user's image.  Detect what's missing and install it using the
		# image's native package manager.
		local tmp_ctx
		tmp_ctx="$(mktemp -d)"
		local wrapper="${tmp_ctx}/Containerfile"
		printf 'FROM %s\n' "${user_image_ref}" >"${wrapper}"

		# Detect missing tools and available package manager
		local has_node has_bash has_base64 pkg_mgr
		has_node=0; image_has_node "${cmd}" "${user_image_ref}" && has_node=1
		has_bash=0; image_has_command "${cmd}" "${user_image_ref}" bash && has_bash=1
		has_base64=0; image_has_command "${cmd}" "${user_image_ref}" base64 && has_base64=1
		pkg_mgr="$(detect_package_manager "${cmd}" "${user_image_ref}")"

		# Build install command if anything is missing
		local missing_items=()
		[[ "${has_node}" -eq 0 ]] && missing_items+=('node')
		[[ "${has_bash}" -eq 0 ]] && missing_items+=('bash')
		[[ "${has_base64}" -eq 0 ]] && missing_items+=('base64')

		if [[ ${#missing_items[@]} -gt 0 ]]; then
			if [[ -n "${pkg_mgr}" ]]; then
				printf 'User image lacks: %s — installing via %s\n' \
					"${missing_items[*]}" "${pkg_mgr}"

				# Map missing items to package names per package manager
				local install_cmd=''
				case "${pkg_mgr}" in
				apt-get)
					local pkgs=()
					[[ "${has_node}" -eq 0 ]] && pkgs+=('nodejs' 'npm')
					[[ "${has_bash}" -eq 0 ]] && pkgs+=('bash')
					[[ "${has_base64}" -eq 0 ]] && pkgs+=('coreutils')
					install_cmd="apt-get update && apt-get install -y --no-install-recommends ${pkgs[*]} && rm -rf /var/lib/apt/lists/*"
					;;
				dnf)
					local pkgs=()
					[[ "${has_node}" -eq 0 ]] && pkgs+=('nodejs' 'npm')
					[[ "${has_bash}" -eq 0 ]] && pkgs+=('bash')
					[[ "${has_base64}" -eq 0 ]] && pkgs+=('coreutils')
					install_cmd="dnf install -y ${pkgs[*]} && dnf clean all"
					;;
				yum)
					local pkgs=()
					[[ "${has_node}" -eq 0 ]] && pkgs+=('nodejs' 'npm')
					[[ "${has_bash}" -eq 0 ]] && pkgs+=('bash')
					[[ "${has_base64}" -eq 0 ]] && pkgs+=('coreutils')
					install_cmd="yum install -y ${pkgs[*]} && yum clean all"
					;;
				apk)
					local pkgs=()
					[[ "${has_node}" -eq 0 ]] && pkgs+=('nodejs' 'npm')
					[[ "${has_bash}" -eq 0 ]] && pkgs+=('bash')
					[[ "${has_base64}" -eq 0 ]] && pkgs+=('coreutils')
					install_cmd="apk add --no-cache ${pkgs[*]}"
					;;
				esac

				if [[ -n "${install_cmd}" ]]; then
					cat >>"${wrapper}" <<DOCKERFILE
RUN ${install_cmd}
DOCKERFILE
				fi
			else
				# No known package manager — cannot proceed
				printf 'ERROR: user image lacks %s and no supported package manager detected.\n' \
					"${missing_items[*]}" >&2
				printf 'Supported package managers: apt-get, dnf, yum, apk.\n' >&2
				printf 'If your image uses a different package manager (e.g. nix), install node,\n' >&2
				printf 'bash, and coreutils in your own Containerfile before using --image.\n' >&2
				printf 'Alternatively, pass --no-devcontainer to use the agentbox built-in image.\n' >&2
				rm -rf "${tmp_ctx}"
				return 1
			fi
		fi

		# Ensure /bin/sh exists as fallback (most images have it)
		cat >>"${wrapper}" <<'DOCKERFILE'
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN mkdir -p /home/agentbox/.npm-global /home/agentbox/.local/bin \
             /home/agentbox/.cache /home/agentbox/.ssh \
             /home/agentbox/app \
    && chown -R ${USER_ID}:${GROUP_ID} /home/agentbox
# Create user/group entry so Node.js os.userInfo() works under Docker's
# --user=<uid>:<gid> (Docker does not inject /etc/passwd automatically).
RUN getent group  ${GROUP_ID} >/dev/null 2>&1 \
    || groupadd --gid ${GROUP_ID} agentbox 2>/dev/null || true; \
    getent passwd ${USER_ID} >/dev/null 2>&1 \
    || useradd --uid ${USER_ID} --gid ${GROUP_ID} \
               --home-dir /home/agentbox --no-create-home \
               --shell /bin/bash agentbox 2>/dev/null || true
ENV HOME=/home/agentbox
ENV NPM_CONFIG_PREFIX=/home/agentbox/.npm-global
ENV PATH="/home/agentbox/.local/bin:/home/agentbox/.npm-global/bin:${PATH}"
WORKDIR /home/agentbox/app
DOCKERFILE
		printf 'Building runtime image (agentbox environment on top of user image)...\n'
		run_cmd "${cmd}" build \
			--tag agentbox-user-image \
			--build-arg "USER_ID=$(id -u)" \
			--build-arg "GROUP_ID=$(id -g)" \
			--file "${wrapper}" \
			"${tmp_ctx}"
		rm -rf "${tmp_ctx}"
		custom_image='agentbox-user-image'
	fi

	local cache_base="${AGENT_DIR}/cache/${agent_type}"
	if [[ "${refresh_cache}" -eq 1 ]]; then
		printf 'Refreshing agent tool cache at %s\n' "${cache_base}"
		chown -R "$(id -u):$(id -g)" "${cache_base}/npm-global" "${cache_base}/local" 2>/dev/null || true
		rm -rf "${cache_base}/npm-global" "${cache_base}/local"
	fi
	mkdir -p "${cache_base}/npm-global" "${cache_base}/local/bin"

	# For custom images, pre-populate the tool cache via agentbox-image so
	# the combined runtime image starts with the agent CLI already installed.
	if [[ -n "${custom_image}" ]]; then
		ensure_tool_cache "${cmd}" "${agent_type}" "${cache_base}"
	fi

	mapfile -t run_args < <(
		build_run_args \
			"${cmd}" "${worktree_path}" "${container_name}" \
			"${agent_type}" "${git_root:-}" \
			"${privileged}" "${custom_image}" \
			"${container_home}" "${container_workdir}" \
			"${keep_container}" "${docker_socket_path}"
	)

	install_cmd="${AGENT_INSTALL_CMDS[${agent_type}]}"
	cli_base="${AGENT_CLI_CMDS[${agent_type}]}"
	cli_cmd="${cli_base}"
	if [[ "${yolo}" -eq 1 ]]; then
		cli_cmd="${cli_cmd} --dangerously-skip-permissions"
	fi

	local launch_cmd
	if [[ "${autostart}" -eq 1 ]]; then
		launch_cmd="exec ${cli_cmd}"
	else
		launch_cmd='exec bash'
	fi

	# If pre_start.sh exists, base64-encode it on the host and
	# decode+run it inside the container as the very first step.
	# The base64 encoding handles multi-line content,
	# special characters, and quotes without any escaping issues.
	# `|| true` makes the whole source fallible: if a tool used inside
	# (e.g. git) is not available in the container image the session
	# still starts instead of aborting.  `set +e` resets any `set -e`
	# that the script may have activated in the current shell.
	local custom_cfg_cmd=''
	if [[ -f "${AGENT_DIR}/pre_start.sh" ]]; then
		local encoded
		encoded="$(_base64_encode "${AGENT_DIR}/pre_start.sh")"
		custom_cfg_cmd="source <(echo '${encoded}' | base64 -d 2>/dev/null || base64 -D) || true; set +e; "
	fi

	# Skip install if the CLI is already present in the persisted cache.
	local install_if_missing
	install_if_missing="command -v ${cli_base} >/dev/null 2>&1 || { ${install_cmd}; }"

	local runtime_image
	if [[ -n "${custom_image}" ]]; then
		runtime_image="${custom_image}"
	else
		runtime_image='agentbox-image'
	fi
	printf 'Runtime image:  %s\n' "${runtime_image}"
	printf 'Launch command: %s\n' "${launch_cmd}"

	# Detect which shell to use for the -c wrapper: prefer bash, fall back to sh
	local shell_cmd='/bin/bash'
	if [[ -n "${custom_image}" ]]; then
		if ! image_has_command "${cmd}" "${runtime_image}" bash; then
			if image_has_command "${cmd}" "${runtime_image}" sh; then
				printf 'WARNING: bash not found in runtime image, falling back to sh\n' >&2
				printf 'pre_start.sh will be skipped (requires bash).\n' >&2
				shell_cmd='/bin/sh'
				custom_cfg_cmd=''
				# Update launch_cmd to use sh for --no-autostart
				if [[ "${autostart}" -eq 0 ]]; then
					launch_cmd='exec sh'
				fi
			else
				printf 'ERROR: neither bash nor sh found in runtime image\n' >&2
				exit 1
			fi
		fi
	else
		# agentbox-image always has bash, but double-check
		if ! image_has_command "${cmd}" "${runtime_image}" bash; then
			shell_cmd='/bin/sh'
			custom_cfg_cmd=''
			if [[ "${autostart}" -eq 0 ]]; then
				launch_cmd='exec sh'
			fi
		fi
	fi

	if [[ "${dry_run}" -eq 1 ]]; then
		printf 'Dry run: would start container with image %s\n' "${runtime_image}"
		printf 'Command: %s run' "${cmd}"
		for arg in "${run_args[@]}"; do
			printf ' %q' "${arg}"
		done
		printf ' %q %q -c ...\n' "${runtime_image}" "${shell_cmd}"
		exit 0
	fi

	printf 'Starting agent container...\n'
	if [[ -n "${custom_image}" ]]; then
		# Cache already populated by ensure_tool_cache; skip install step.
		# mkdir -p /home/agentbox ensures the mount-point base exists in the
		# user's image before volumes are overlaid.
		if [[ "${VERBOSE}" -eq 0 ]] && [[ "${cmd}" == "docker" ]]; then
			local debug_args=("${run_args[@]}" "${runtime_image}" "${shell_cmd}" "-c" "mkdir -p /home/agentbox ${container_workdir}; ${custom_cfg_cmd}${launch_cmd}")
			printf 'DEBUG: %s run' "${cmd}" >&2
			for arg in "${debug_args[@]}"; do
				printf ' %q' "${arg}" >&2
			done
			printf '\n' >&2
		fi
		run_cmd "${cmd}" run "${run_args[@]}" "${runtime_image}" "${shell_cmd}" -c \
			"mkdir -p /home/agentbox ${container_workdir}; ${custom_cfg_cmd}${launch_cmd}"
	else
		if [[ "${VERBOSE}" -eq 0 ]] && [[ "${cmd}" == "docker" ]]; then
			local debug_args=("${run_args[@]}" "${runtime_image}" "${shell_cmd}" "-c" "${custom_cfg_cmd}${install_if_missing}; ${launch_cmd}")
			printf 'DEBUG: %s run' "${cmd}" >&2
			for arg in "${debug_args[@]}"; do
				printf ' %q' "${arg}" >&2
			done
			printf '\n' >&2
		fi
		run_cmd "${cmd}" run "${run_args[@]}" "${runtime_image}" "${shell_cmd}" -c \
			"${custom_cfg_cmd}${install_if_missing}; ${launch_cmd}"
	fi
}

# --- load default-flags ---
# Prepend flags from default-flags to $@ so CLI flags override them.
_defaults_file="${AGENT_DIR}/default-flags"
if [[ -f "${_defaults_file}" ]]; then
	_defaults=()
	while IFS= read -r _line; do
		_line="${_line%%#*}"                        # strip inline comments
		_line="${_line#"${_line%%[![:space:]]*}"}"  # ltrim whitespace
		_line="${_line%"${_line##*[![:space:]]}"}"  # rtrim whitespace
		[[ -z "${_line}" ]] && continue
		read -ra _words <<< "${_line}"
		_defaults+=("${_words[@]}")
	done < "${_defaults_file}"
	if (( ${#_defaults[@]} > 0 )); then
		set -- "${_defaults[@]}" "$@"
	fi
	unset _defaults _words _line
fi
unset _defaults_file

# --- strip global flags before dispatch ---
_filtered=()
for _arg in "$@"; do
	case "${_arg}" in
	-v | --verbose)
		VERBOSE=1
		;;
	--docker)
		FORCE_DOCKER=1
		;;
	*)
		_filtered+=("${_arg}")
		;;
	esac
done
if ((${#_filtered[@]} > 0)); then
	set -- "${_filtered[@]}"
else
	set --
fi
unset _arg _filtered

# --- dispatch ---
# All invocations directly start a session: `agentbox [BRANCH] [OPTIONS]`.
case "${1:-}" in
help | --help | -h)
	usage
	;;
*)
	# No subcommand given — forward everything directly to cmd_start.
	cmd_start "$@"
	;;
esac
