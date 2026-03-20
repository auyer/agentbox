FROM docker.io/jetpackio/devbox:latest

ARG USER_ID=1000
ARG GROUP_ID=1000

USER root
RUN apt update && apt install -y \
	nodejs \
	npm \
	git \
	openssh-client \
	curl

# Remap the devbox user/group to match the host caller so that
# volume-mounted files are accessible without any chowning.
RUN groupmod --non-unique --gid "${GROUP_ID}" devbox \
	&& usermod --non-unique --uid "${USER_ID}" devbox \
	&& chown --recursive "${USER_ID}:${GROUP_ID}" /home/devbox

USER devbox

ENV IS_devbox=1
ENV HOME=/home/devbox

# Point npm global prefix to a user-writable dir so that
# `npm install -g` never requires root or sudo.
RUN npm config set prefix /home/devbox/.npm-global
ENV PATH="/home/devbox/.local/bin:/home/devbox/.npm-global/bin:${PATH}"

RUN mkdir -p /home/devbox/.cache \
	/home/devbox/.config \
	/home/devbox/.ssh \
	/home/devbox/.local/bin

WORKDIR /home/devbox/app/
