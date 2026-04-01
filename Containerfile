FROM docker.io/node:trixie-slim

ARG USER_ID=1000
ARG GROUP_ID=1000

USER root
RUN apt update && apt install -y \
	git \
	openssh-client \
	curl \
	jq

ENV HOME=/home/agentbox

# Point npm global prefix to a user-writable dir so that
# `npm install -g` never requires root or sudo.
RUN npm config set prefix /home/agentbox/.npm-global
ENV PATH="/home/agentbox/.local/bin:/home/agentbox/.npm-global/bin:${PATH}"

RUN mkdir -p /home/agentbox/.cache \
	/home/agentbox/.config \
	/home/agentbox/.ssh \
	/home/agentbox/.local/bin \
	/home/agentbox/.npm-global
RUN chown -R ${USER_ID}:${GROUP_ID} /home/agentbox

# Create the agentbox user/group for the target UID/GID so that
# Node.js os.userInfo() and similar syscalls succeed when the container
# runs as --user=<host-uid>:<host-gid> (Docker does not inject /etc/passwd
# entries automatically the way podman --userns=keep-id does).
RUN getent group  ${GROUP_ID} >/dev/null 2>&1 \
    || groupadd --gid ${GROUP_ID} agentbox 2>/dev/null || true; \
    getent passwd ${USER_ID} >/dev/null 2>&1 \
    || useradd --uid ${USER_ID} --gid ${GROUP_ID} \
               --home-dir /home/agentbox --no-create-home \
               --shell /bin/bash agentbox 2>/dev/null || true

