#!/bin/bash

#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

# Terminate on error
set -e

# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/nethserver}"
# Configure the image name
reponame="ns8-openclaw"

# Create a new empty container image
container=$(buildah from scratch)

# Reuse existing nodebuilder-openclaw container, to speed up builds
if ! buildah containers --format "{{.ContainerName}}" | grep -q nodebuilder-openclaw; then
    echo "Pulling NodeJS runtime..."
    buildah from --name nodebuilder-openclaw -v "${PWD}:/usr/src:Z" docker.io/library/node:24.11.1-slim
fi

echo "Build static UI files with node..."
buildah run \
    --workingdir=/usr/src/ui \
    --env="NODE_OPTIONS=--openssl-legacy-provider" \
    nodebuilder-openclaw \
    sh -c "yarn install && yarn build"

# Add imageroot directory to the container image
buildah add "${container}" imageroot /imageroot
buildah add "${container}" ui/dist /ui
# Setup the entrypoint, ask to reserve one TCP port with the label and set a rootless container
buildah config --entrypoint=/ \
    --label="org.nethserver.authorizations=traefik@node:routeadm" \
    --label="org.nethserver.tcp-ports-demand=1" \
    --label="org.nethserver.rootfull=0" \
    --label="org.nethserver.images=${repobase}/openclaw:${IMAGETAG:-latest}" \
    "${container}"
# Commit the image in Docker format for broader Podman compatibility on NS8 nodes
buildah commit --format docker "${container}" "${repobase}/${reponame}"
buildah commit --format docker "${container}" "${repobase}/${reponame}:${IMAGETAG:-latest}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

##########################
##      OpenClaw      ##
##########################
echo "[*] Build OpenClaw container"
reponame="openclaw"
pushd openclaw
buildah build --force-rm --no-cache --jobs "$(nproc)" \
	--tag "${repobase}/${reponame}" \
	--tag "${repobase}/${reponame}:${IMAGETAG:-latest}"
popd

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

#
# Setup CI when pushing to Github. 
# Warning! docker::// protocol expects lowercase letters (,,)
if [[ -n "${CI}" ]]; then
    # Set output value for Github Actions
    printf "images=%s\n" "${images[*],,}" >> "${GITHUB_OUTPUT}"
else
    # Just print info for manual push
    printf "Publish the images with:\n\n"
    for image in "${images[@],,}"; do printf "  buildah push %s docker://%s:%s\n" "${image}" "${image}" "${IMAGETAG:-latest}" ; done
    printf "\n"
fi
