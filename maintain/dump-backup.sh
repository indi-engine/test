#!/bin/bash

# Prepare dump
source dump-prepare.sh

# Define the release tag
release="latest"

# Get releases list
list=$(gh release list)

# Check if $release exists in the list
if [[ -n "$list" && $(echo "$list" | awk -v rel="$release" '$3 == rel') ]]; then

  # Upload the dump file, overwriting any previously uploaded file
  gh release upload "$release" "$dump" --clobber

# Else
else

  # Create the release and upload the dump file
  gh release create "$release" "$dump" <<< $'\n'
fi