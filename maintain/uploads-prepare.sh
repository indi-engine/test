#!/bin/bash

# Goto project root
cd $DOC

# Directory where to create the zip
dir=${1:-data}

# Source dir to be zipped
source="custom/data/upload"

# Target path to the zip file
uploads="$dir/uploads.zip"

# Create $dir if it does not exist
[ -d "$dir" ] || mkdir -p "$dir"

# Delete existing zip file, if any
[ -f "$uploads" ] && rm "$uploads"

# Create backup locally
echo -n "Zipping $source/ into $uploads... "
zip -r -0 "$uploads" "$source" > /dev/null
echo " Done"
