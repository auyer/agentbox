#!/usr/bin/env bash
set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
FORCE_DOCKER=0
declare -a EXTRA_MOUNTS=()

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

function usage() {
	printf 'Usage: agentbox [BRANCH] [OPTIONS]\n'
	printf '       agentbox start [BRANCH] [OPTIONS]\n'
	printf '\n'
	printf 'Commands:\n'
	printf '  start [BRANCH] [OPTIONS]  Start a new agent session (default)\n'
	printf '  help                      Show this help message\n'
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
	printf '  --no-git                  Run without a git repository.\n'
	printf '                            Mounts the current directory;\n'
	printf '                            skips worktree and branch creation\n'
	printf '  --mount <host:container>  Mount a host path into the container.\n'
	printf '                            Container path starting with ./ is\n'
	printf '                            relative to the container workdir.\n'
	printf '                            Can be specified multiple times.\n'
	printf '  --refresh-cache           Remove cached agent install for this\n'
	printf '                            agent type, then reinstall on start\n'
	printf '  --privileged              Run the container in privileged mode\n'
	printf '                            (enables Docker-in-Docker and full\n'
	printf '                            device access; off by default)\n'
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
	args+=("--user=$(id --user):$(id --group)")
	if [[ "${cmd}" == 'podman' ]]; then
		args+=('--userns=keep-id')
		selinux=':z'
	fi
	if [[ "${privileged}" -eq 1 ]]; then
		args+=('--privileged')
	fi

	args+=("--volume=${worktree_path}:${container_workdir}${selinux}")


	# Persist npm global + ~/.local installs across sessions (per agent type).
	local cache_base="${AGENT_DIR}/cache/${agent_type}"
	args+=("--volume=${cache_base}/npm-global:/home/agentbox/.npm-global${selinux}")
	args+=("--volume=${cache_base}/local:/home/agentbox/.local${selinux}")

	args+=("--volume=${config_dir}:${container_config_dir}${selinux}")

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

# Return 0 if the given image has node in PATH, non-zero otherwise.
# Usage: image_has_node <cmd> <image_ref>
function image_has_node() {
	local cmd="${1}"
	local image_ref="${2}"
	run_cmd "${cmd}" run --rm "${image_ref}" \
		node --version >/dev/null 2>&1
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
		abs_dockerfile="$(realpath "${spec_dir}/${dockerfile_rel}")"
		abs_context="$(realpath "${spec_dir}/${ctx_rel}")"
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
	local keep_container=0
	local no_devcontainer=0
	local custom_image=''
	local git_root worktree_path container_name cmd
	local install_cmd cli_base cli_cmd
	local -a run_args

	# Load defaults from defaults.conf
	agent_type='claude-code'
	if [[ -f "${AGENT_DIR}/defaults.conf" ]]; then
		# shellcheck source=/dev/null
		source "${AGENT_DIR}/defaults.conf"
		agent_type="${DEFAULT_AGENT:-claude-code}"
	fi

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
		--no-git)
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
		branch_name="agentbox-$(date --iso-8601)"
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
	else
		git_root="$(get_git_root)"
		worktree_path="${git_root}/agentbox-worktrees/${branch_name}"
		# Use git root directory name to make container name unique per project
		local project_name
		project_name="$(basename "${git_root}")"
		container_name="agentbox-${project_name}-${sanitized_branch}"
	fi

	cmd="$(detect_container_cmd)"

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
		--build-arg "USER_ID=$(id --user)" \
		--build-arg "GROUP_ID=$(id --group)" \
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
				printf 'devcontainer: using image %s\n' "${custom_image}"
			elif [[ "${dc_result}" == dockerfile:* ]]; then
				local dc_rest dc_dockerfile dc_context
				dc_rest="${dc_result#dockerfile:}"
				dc_dockerfile="${dc_rest%% context:*}"
				dc_context="${dc_rest#* context:}"
				printf 'devcontainer: building from %s (context: %s)\n' \
					"${dc_dockerfile}" "${dc_context}"
				run_cmd "${cmd}" build \
					--tag agentbox-devcontainer-image \
					--build-arg "USER_ID=$(id --user)" \
					--build-arg "GROUP_ID=$(id --group)" \
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
				"$(dirname "$(realpath "${custom_image}")")"
			user_image_ref='agentbox-user-image'
		fi

		# Step 2: build a thin wrapper image that layers the agentbox
		# environment (/home/agentbox, npm prefix, PATH) on top of the
		# user's image.  If the user's image lacks node we also COPY the
		# node runtime from agentbox-image so the agent CLI works.
		local tmp_ctx
		tmp_ctx="$(mktemp -d)"
		local wrapper="${tmp_ctx}/Containerfile"
		printf 'FROM %s\n' "${user_image_ref}" >"${wrapper}"
		if ! image_has_node "${cmd}" "${user_image_ref}"; then
			printf 'User image lacks node — copying from agentbox-image\n'
			cat >>"${wrapper}" <<'DOCKERFILE'
COPY --from=agentbox-image /usr/local/bin/node /usr/local/bin/
COPY --from=agentbox-image /usr/local/bin/npm  /usr/local/bin/
COPY --from=agentbox-image /usr/local/bin/npx  /usr/local/bin/
COPY --from=agentbox-image /usr/local/lib/node_modules /usr/local/lib/node_modules/
DOCKERFILE
		fi
		cat >>"${wrapper}" <<'DOCKERFILE'
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN mkdir -p /home/agentbox/.npm-global /home/agentbox/.local/bin \
             /home/agentbox/.cache /home/agentbox/.ssh \
             /home/agentbox/app \
    && chown -R ${USER_ID}:${GROUP_ID} /home/agentbox
ENV HOME=/home/agentbox
ENV NPM_CONFIG_PREFIX=/home/agentbox/.npm-global
ENV PATH="/home/agentbox/.local/bin:/home/agentbox/.npm-global/bin:${PATH}"
WORKDIR /home/agentbox/app
DOCKERFILE
		printf 'Building runtime image (agentbox environment on top of user image)...\n'
		run_cmd "${cmd}" build \
			--tag agentbox-user-image \
			--build-arg "USER_ID=$(id --user)" \
			--build-arg "GROUP_ID=$(id --group)" \
			--file "${wrapper}" \
			"${tmp_ctx}"
		rm -rf "${tmp_ctx}"
		custom_image='agentbox-user-image'
	fi

	local cache_base="${AGENT_DIR}/cache/${agent_type}"
	if [[ "${refresh_cache}" -eq 1 ]]; then
		printf 'Refreshing agent tool cache at %s\n' "${cache_base}"
		rm -rf "${cache_base}"
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
			"${keep_container}"
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
		encoded="$(base64 --wrap=0 "${AGENT_DIR}/pre_start.sh")"
		custom_cfg_cmd="source <(echo '${encoded}' | base64 --decode) || true; set +e; "
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
	printf 'Starting agent container...\n'
	if [[ -n "${custom_image}" ]]; then
		# Cache already populated by ensure_tool_cache; skip install step.
		# mkdir -p /home/agentbox ensures the mount-point base exists in the
		# user's image before volumes are overlaid.
		run_cmd "${cmd}" run "${run_args[@]}" "${runtime_image}" /bin/bash -c \
			"mkdir -p /home/agentbox ${container_workdir}; ${custom_cfg_cmd}${launch_cmd}"
	else
		run_cmd "${cmd}" run "${run_args[@]}" "${runtime_image}" /bin/bash -c \
			"${custom_cfg_cmd}${install_if_missing}; ${launch_cmd}"
	fi
}

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
# "agentbox [ARGS...]" is equivalent to "agentbox start [ARGS...]".
# "start" is kept as an explicit alias for backwards compatibility.
case "${1:-}" in
start)
	shift
	cmd_start "$@"
	;;
help | --help | -h)
	usage
	;;
*)
	# No subcommand given, or first arg is a branch name / option:
	# forward everything directly to cmd_start.
	cmd_start "$@"
	;;
esac
