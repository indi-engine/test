#!/bin/bash

# Goto project root
cd $DOC

# Load functions
source maintain/functions.sh

# Define the release tag
release=${1:-latest}

# Load releases
load_releases && echo ""

# Check if $release exists in the list
if has_release "$release"; then

  # Restore dump
  echo "Restoring dump from release '$release':"
  restore_dump "$release"

# Else
else

  # Indicate the release not exist on github
  echo "Release $release does not exist on github"
fi