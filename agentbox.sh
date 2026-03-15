#!/usr/bin/env bash
set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${AGENT_DIR}/.agentbox-state"
VERBOSE=0

# Agent type → host config dir
declare -A AGENT_CONFIG_DIRS=(
	['claude-code']="${HOME}/.claude"
	['qwen-code']="${HOME}/.qwen"
	['opencode-ai']="${HOME}/.opencode"
)

# Agent type → container config dir
declare -A AGENT_CONTAINER_DIRS=(
	['claude-code']='/home/devbox/.claude'
	['qwen-code']='/home/devbox/.qwen'
	['opencode-ai']='/home/devbox/.opencode'
)

# Agent type → npm install command
declare -A AGENT_INSTALL_CMDS=(
	['claude-code']='npm install -g @anthropic-ai/claude-code@latest'
	['qwen-code']='npm install -g @qwen-code/qwen-code@latest'
	['opencode-ai']='npm i -g opencode-ai'
)

# Agent type → CLI binary to launch after install
declare -A AGENT_CLI_CMDS=(
	['claude-code']='claude'
	['qwen-code']='qwen'
	['opencode-ai']='opencode'
)

function usage() {
	printf 'Usage: agentbox <command> [options]\n'
	printf '\n'
	printf 'Commands:\n'
	printf '  start [BRANCH] [OPTIONS]  Start a new agent session\n'
	printf '  stop                      Stop the current agent session\n'
	printf '  resume                    Resume a running agent session\n'
	printf '  help                      Show this help message\n'
	printf '\n'
	printf 'Start options:\n'
	printf '  BRANCH                    Branch name'
	printf ' (default: agentbox-<date>)\n'
	printf '  -s, --use-stash           Stash current changes and apply\n'
	printf '                            to the new worktree\n'
	printf '  --agent <type>            Agent type (default: claude-code)\n'
	printf '                            Options: claude-code, qwen-code,\n'
	printf '                            opencode-ai\n'
	printf '  --no-autostart            Do not launch the agent CLI\n'
	printf '                            automatically (drops into bash)\n'
	printf '  --no-devbox               Skip devbox shell even if\n'
	printf '                            devbox.json is present\n'
	printf '  --dangerously-skip-permissions\n'
	printf '                            Run agent in yolo mode\n'
	printf '                            (off by default)\n'
	printf '  --no-git                  Run without a git repository.\n'
	printf '                            Mounts the current directory;\n'
	printf '                            skips worktree and branch creation\n'
	printf '\nGlobal options:\n'
	printf '  -v, --verbose             Print container commands before\n'
	printf '                            running them\n'
}

function print_worktree_hint()
{
	local path="${1}"
	printf '\n'
	printf 'The agent session ended. Code changes are in:\n'
	printf '  %s\n' "${path}"
	printf 'Review the changes there before merging into your main branch.\n'
}

# Print the worktree hint on any exit so changes are never silently lost.
function _on_exit()
{
	if [[ -f "${STATE_FILE}" ]]; then
		# shellcheck source=/dev/null
		source "${STATE_FILE}"
		if [[ -n "${WORKTREE_PATH:-}" ]]; then
			print_worktree_hint "${WORKTREE_PATH}"
		fi
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
	if command -v podman >/dev/null 2>&1; then
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

function read_state() {
	if [[ ! -f "${STATE_FILE}" ]]; then
		printf 'ERROR: no active session (state file not found)\n' >&2
		printf 'Hint: run "agent start" to begin a new session\n' >&2
		exit 2 # ENOENT
	fi
	# shellcheck source=/dev/null
	source "${STATE_FILE}"
}

function check_no_active_session() {
	local cmd running
	if [[ ! -f "${STATE_FILE}" ]]; then
		return 0
	fi
	# shellcheck source=/dev/null
	source "${STATE_FILE}"
	cmd="$(detect_container_cmd)"
	running="$(
		run_cmd "${cmd}" inspect "${CONTAINER_NAME}" \
			--format '{{.State.Running}}' 2>/dev/null ||
			printf 'false'
	)"
	if [[ "${running}" == 'true' ]]; then
		printf 'ERROR: an agent session is already active\n' >&2
		printf 'Hint: run "agent resume" to attach or' >&2
		printf ' "agent stop" to stop it\n' >&2
		exit 16 # EBUSY
	fi
}

function build_run_args() {
	local cmd="${1}"
	local worktree_path="${2}"
	local container_name="${3}"
	local agent_type="${4}"
	local config_dir container_config_dir
	local -a args

	config_dir="${AGENT_CONFIG_DIRS[${agent_type}]}"
	container_config_dir="${AGENT_CONTAINER_DIRS[${agent_type}]}"

	args=(
		'--interactive'
		'--tty'
		'--network=host'
		"--name=${container_name}"
		'--env=HOME=/home/devbox'
		'--env=CLAUDE_CONFIG_DIR=/home/devbox/.claude'
	)

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

	args+=("--volume=${worktree_path}:/home/devbox/app${selinux}")
	args+=("--volume=${config_dir}:${container_config_dir}${selinux}")

	# SSH keys (read-only)
	if [[ -f "${HOME}/.ssh/id_rsa" ]]; then
		args+=(
			"--volume=${HOME}/.ssh/:/home/devbox/.ssh/:ro"
		)
	fi
	if [[ -f "${HOME}/.ssh/known_hosts" ]]; then
		args+=(
			"--volume=${HOME}/.ssh/known_hosts:/home/devbox/.ssh/known_hosts:ro"
		)
	fi

	if [[ -d "${AGENT_DIR}/skills" ]]; then
		args+=(
			"--volume=${AGENT_DIR}/skills:/home/devbox/app/skills${selinux}"
		)
	fi
	if [[ -d "${AGENT_DIR}/workflows" ]]; then
		args+=(
			"--volume=${AGENT_DIR}/workflows:/home/devbox/app/workflows${selinux}"
		)
	fi

	# Forward host env vars listed in auto_envs.sh into the container.
	# Lines starting with # and blank lines are ignored.
	if [[ -f "${AGENT_DIR}/auto_envs.sh" ]]; then
		local var_name
		while IFS= read -r var_name; do
			# Strip inline comments and surrounding whitespace
			var_name="${var_name%%#*}"
			var_name="${var_name//[[:space:]]/}"
			[[ -z "${var_name}" ]] && continue
			if [[ -v "${var_name}" ]]; then
				args+=("--env=${var_name}=${!var_name}")
			fi
		done < "${AGENT_DIR}/auto_envs.sh"
	fi

	printf '%s\n' "${args[@]}"
}

function cmd_start() {
	local branch_name=''
	local use_stash=0
	local agent_type='claude-code'
	local autostart=1
	local use_devbox=1
	local yolo=0
	local no_git=0
	local git_root worktree_path container_name cmd
	local install_cmd cli_cmd
	local -a run_args

	while [[ $# -gt 0 ]]; do
		case "${1}" in
		-s | --use-stash)
			use_stash=1
			shift
			;;
		--agent)
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
		--no-devbox)
			use_devbox=0
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
		printf 'Valid types: claude-code, qwen-code, opencode-ai\n' >&2
		exit 22 # EINVAL
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

	check_no_active_session
	cmd="$(detect_container_cmd)"

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

	# Write state file before launching container
	cat >"${STATE_FILE}" <<EOF
CONTAINER_NAME=${container_name}
WORKTREE_PATH=${worktree_path}
BRANCH_NAME=${branch_name}
AGENT_TYPE=${agent_type}
GIT_ROOT=${git_root:-}
NO_GIT=${no_git}
EOF

	mapfile -t run_args < <(
		build_run_args \
			"${cmd}" "${worktree_path}" "${container_name}" \
			"${agent_type}"
	)

	install_cmd="${AGENT_INSTALL_CMDS[${agent_type}]}"
	cli_cmd="${AGENT_CLI_CMDS[${agent_type}]}"
	if [[ "${yolo}" -eq 1 ]]; then
		cli_cmd="${cli_cmd} --dangerously-skip-permissions"
	fi

	# If the container already exists, resume or remove it
	local existing_state
	existing_state="$(
		run_cmd "${cmd}" inspect "${container_name}" \
			--format '{{.State.Running}}' 2>/dev/null ||
			printf 'absent'
	)"

	if [[ "${existing_state}" == 'true' ]]; then
		printf 'Container already running — resuming...\n'
		run_cmd "${cmd}" exec --interactive --tty "${container_name}" /bin/bash
		return 0
	elif [[ "${existing_state}" != 'absent' ]]; then
		printf 'Removing stopped container %s...\n' "${container_name}"
		run_cmd "${cmd}" rm "${container_name}"
	fi

	# Auto-detect devbox: check for devbox.json in the worktree
	local has_devbox=0
	if [[ "${use_devbox}" -eq 1 ]] &&
		[[ -f "${worktree_path}/devbox.json" ]]; then
		has_devbox=1
		printf 'devbox.json detected — will run inside devbox shell\n'
	fi

	local launch_cmd
	if [[ "${has_devbox}" -eq 1 ]] && [[ "${autostart}" -eq 1 ]]; then
		launch_cmd="devbox shell --command '${cli_cmd}'"
	elif [[ "${has_devbox}" -eq 1 ]]; then
		launch_cmd='devbox shell'
	elif [[ "${autostart}" -eq 1 ]]; then
		launch_cmd="exec ${cli_cmd}"
	else
		launch_cmd='exec bash'
	fi

	# If custom_configs.sh exists, base64-encode it on the host and
	# decode+run it inside the container as the very first step.
	# The base64 encoding handles multi-line content, 
	# special characters, and quotes without any escaping issues.
	local custom_cfg_cmd=''
	if [[ -f "${AGENT_DIR}/custom_configs.sh" ]]; then
		local encoded
		encoded="$(base64 --wrap=0 "${AGENT_DIR}/custom_configs.sh")"
		custom_cfg_cmd="source <(echo '${encoded}' | base64 --decode); "
	fi

	printf 'Starting agent container...\n'
	run_cmd "${cmd}" run "${run_args[@]}" agentbox-image /bin/bash -c \
		"${custom_cfg_cmd}${install_cmd}; ${launch_cmd}"
}

function cmd_stop() {
	local cmd answer
	read_state
	cmd="$(detect_container_cmd)"

	printf 'Stopping container %s...\n' "${CONTAINER_NAME}"
	run_cmd "${cmd}" stop "${CONTAINER_NAME}" 2>/dev/null || true
	run_cmd "${cmd}" rm "${CONTAINER_NAME}" 2>/dev/null || true

	# Remove state file before exit so the EXIT trap does not double-print.
	# The hint is printed explicitly here instead.
	local worktree_path_snapshot="${WORKTREE_PATH}"
	rm --force "${STATE_FILE}"
	printf 'Session stopped.\n'
	if [[ -n "${worktree_path_snapshot}" ]]; then
		print_worktree_hint "${worktree_path_snapshot}"
	fi
}

function cmd_resume() {
	local cmd running
	read_state
	cmd="$(detect_container_cmd)"
	running="$(
		run_cmd "${cmd}" inspect "${CONTAINER_NAME}" \
			--format '{{.State.Running}}' 2>/dev/null ||
			printf 'false'
	)"

	if [[ "${running}" != 'true' ]]; then
		printf 'ERROR: container %s is not running\n' \
			"${CONTAINER_NAME}" >&2
		printf 'Hint: run "agent start" to start a new session\n' >&2
		exit 3 # ESRCH
	fi

	run_cmd "${cmd}" exec --interactive --tty "${CONTAINER_NAME}" /bin/bash
}

# --- strip global flags before dispatch ---
_filtered=()
for _arg in "$@"; do
	case "${_arg}" in
	-v | --verbose)
		VERBOSE=1
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
case "${1:-help}" in
start)
	shift
	cmd_start "$@"
	;;
stop)
	cmd_stop
	;;
resume)
	cmd_resume
	;;
help | --help | -h)
	usage
	;;
*)
	printf 'Unknown command: %s\n' "${1}" >&2
	usage
	exit 1
	;;
esac
