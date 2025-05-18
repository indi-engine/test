#!/bin/bash

# Prepare uploads.zip
source uploads-prepare.sh

# Define the release tag
release="latest"

# Get releases list
list=$(gh release list)

# Check if $release exists in the list
if [[ -n "$list" && $(echo "$list" | awk -v rel="$release" '$3 == rel') ]]; then

  # Upload the backup file, overwriting any previously uploaded one
  gh release upload "$release" "$uploads" --clobber

# Else create the release prior uploading the backup file
else
  gh release create "$release" "$uploads" <<< $'\n'
fi