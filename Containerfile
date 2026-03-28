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

