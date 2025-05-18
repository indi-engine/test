#!/bin/bash

# Goto project root
cd $DOC

# Load functions
source maintain/functions.sh

# Load releases and set up $default_release_tag
load_releases && echo ""

# Get current repo
repo=$(get_current_repo)

# Define the release tag
release=${1:-$default_release_tag}

# If given release exists in current repo
if has_release "$release"; then

  # Do restore
  echo "Restoring uploads from release '$repo:$release' ..."
  restore_uploads "$release"

# Else indicate the release not exist on github
else
  echo "Release '$repo:$release' does not exist on github"
fi