#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin/agentbox"
PATH_MARKER='# agentbox'

FILES_TO_COPY=(
  'Containerfile'
  'agentbox.sh'
  'auto_envs.sh'
  'custom_configs.sh'
  'setup.sh'
)

function usage()
{
  printf 'Usage: setup.sh <command>\n'
  printf '\n'
  printf 'Commands:\n'
  printf '  install    Copy files to %s\n' "${INSTALL_DIR}"
  printf '             and add agentbox to PATH\n'
  printf '  uninstall  Remove %s and PATH entry\n' "${INSTALL_DIR}"
  printf '  help       Show this help message\n'
}

function detect_rc_file()
{
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "${shell_name}" in
    zsh)
      printf '%s' "${HOME}/.zshrc"
      ;;
    bash)
      printf '%s' "${HOME}/.bashrc"
      ;;
    *)
      printf '%s' "${HOME}/.profile"
      ;;
  esac
}

function cmd_install()
{
  printf 'Installing agentbox to %s...\n' "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"

  local f
  for f in "${FILES_TO_COPY[@]}"; do
    local src="${SCRIPT_DIR}/${f}"
    if [[ -f "${src}" ]]; then
      cp "${src}" "${INSTALL_DIR}/${f}"
      printf '  copied %s\n' "${f}"
    else
      printf '  WARNING: %s not found, skipping\n' "${f}" >&2
    fi
  done

  mv "${INSTALL_DIR}/agentbox.sh" "${INSTALL_DIR}/agentbox"
  chmod +x "${INSTALL_DIR}/agentbox"

  local rc_file
  rc_file="$(detect_rc_file)"

  if grep --quiet --fixed-strings "${PATH_MARKER}" "${rc_file}" 2>/dev/null; then
    printf 'PATH already configured in %s\n' "${rc_file}"
  else
    printf '\n%s begin\n' "${PATH_MARKER}" >> "${rc_file}"
    printf 'export PATH="${HOME}/.local/bin/agentbox:${PATH}"\n' \
      >> "${rc_file}"
    printf '%s end\n' "${PATH_MARKER}" >> "${rc_file}"
    printf 'Added PATH entry to %s\n' "${rc_file}"
  fi

  printf '\nDone! Restart your shell or run:\n'
  printf '  source %s\n' "${rc_file}"
}

function cmd_uninstall()
{
  if [[ -d "${INSTALL_DIR}" ]]; then
    rm --recursive --force "${INSTALL_DIR}"
    printf 'Removed %s\n' "${INSTALL_DIR}"
  else
    printf 'Nothing to remove: %s does not exist\n' "${INSTALL_DIR}"
  fi

  local rc_file
  rc_file="$(detect_rc_file)"

  if grep --quiet --fixed-strings "${PATH_MARKER}" "${rc_file}" 2>/dev/null; then
    local tmp inside_block
    tmp="$(mktemp)"
    inside_block=0
    while IFS= read -r line; do
      if [[ "${line}" == *"${PATH_MARKER} begin"* ]]; then
        inside_block=1
        continue
      fi
      if [[ "${line}" == *"${PATH_MARKER} end"* ]]; then
        inside_block=0
        continue
      fi
      if [[ "${inside_block}" -eq 0 ]]; then
        printf '%s\n' "${line}" >> "${tmp}"
      fi
    done < "${rc_file}"
    mv "${tmp}" "${rc_file}"
    printf 'Removed PATH entry from %s\n' "${rc_file}"
  else
    printf 'No PATH entry found in %s\n' "${rc_file}"
  fi

  printf 'Uninstall complete.\n'
}

case "${1:-help}" in
  install)
    cmd_install
    ;;
  uninstall)
    cmd_uninstall
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
