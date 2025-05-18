#!/bin/bash
set -eu -o pipefail

# Make everything written to the stdout and stderr to be also written to a log file
exec > >(tee -a /var/log/mysql/container.log) 2>&1

# Path to a file to be created once init is done
done=/var/lib/mysql/init.done

# If init is not done
if [[ ! -f "$done" ]]; then

  # Install certain tools
  apt-get update && apt-get install -y wget curl jq

  # Print which dump is going to be imported
  echo "MYSQL_DUMP is '$MYSQL_DUMP'";

  # Load functions
  source /usr/local/bin/functions.sh

  # Change dir
  cd /docker-entrypoint-initdb.d

  # Array of other sql files to be imported
  declare -a import=("maxwell.sql")

  # Split MYSQL_DUMP on whitespace into an array
  IFS=' ' read -ra dumpA <<< "$MYSQL_DUMP"

  # Empty dumps counter
  empty=0

  # Missing dumps counter
  missing=0

  # Downloaded/copied dumps counter, to be used in filename prefix to preserve import order
  prefix=0

  # Foreach dump
  for dump in "${dumpA[@]}"; do

    # If dump is an URL
    if [[ $dump == http* ]]; then

      # Extract the filename from the URL and add counter-prefix
      name="$prefix-$(basename "$dump")"

      # Download it right here
      echo "Fetching remote MySQL dump from '$dump' into local '$name' ..." && wget --no-check-certificate -O "$name" "$dump"

      # Increment saved dumps counter
      prefix=$((prefix + 1))

    # Else assume it's a local path pointing to some file inside
    # /docker-entrypoint-initdb.d/custom/ directory mapped as a volume
    # from data/ directory on the docker host machine
    else

      # Shortcut
      local="custom/$dump"

      # If that local dump file does NOT really exists in data/ directory on host machine
      # e.g does NOT exist in custom/ directory in mysql-container due to bind volume mapping
      if [[ ! -f "$local" ]]; then

        # If GH_TOKEN_CUSTOM variable is set - install GitHub CLI
        if [[ ! -z "$GH_TOKEN_CUSTOM" ]]; then
          ghcli_install
          export GH_TOKEN="$GH_TOKEN_CUSTOM"
        fi

        # Load list of available releases for current repo. If no releases - load ones for parent repo, if current repo
        # was forked or generated. But anyway, $init_repo and $init_release variables will be set up to clarify where to
        # download asset from, and it will refer to either current repo, or parent repo for cases when current repo
        # has no releases so far, which might be true if it's a very first time of the instance getting up and running
        # for the current repo
        if (( ${#releaseQty[@]} == 0 )); then
          load_releases "$(get_current_repo ".gitconfig")" "init"
        fi

        # Download it from github into data/ dir
        if [[ ! -z "${init_repo:-}" ]]; then
          echo "Asset '$dump' will be downloaded from '$init_repo:$init_release'"
          gh_download "$init_repo" "$init_release" "$dump" "custom"
        fi
      fi

      # If that local dump file really exists in data/ directory on host machine
      # e.g exists  in custom/ directory in mysql-container due to bind volume mapping
      if [ -f "$local" ]; then

        # If that local dump file is not empty
        if [ -s "$local" ]; then

          # Copy that file here for it to be imported, as files from subdirectories are ignored while import
          cp "$local" "$prefix-$dump" && echo "File '/docker-entrypoint-initdb.d/$local' copied to the level up"

          # Increment saved dumps counter
          prefix=$((prefix + 1))

        # Else
        else

          # Print warning
          echo "[Warning] Local SQL dump file '$dump' is empty"

          # Increment empty dumps counter
          empty=$((empty + 1))
        fi

      # Else if that local dump file does not really exist
      else

        # Increment missing dumps counter
        missing=$((missing + 1))
      fi
    fi
  done

  # If no dump(s) were given by MYSQL_DUMP-variable or all are empty/missing
  if [ $(( ${#dumpA[@]} - empty - missing )) -eq 0 ]; then

    # Print info
    echo "None of SQL dump file(s) not found, assuming blank Indi Engine instance setup"

    # Use system.sql
    import+=("system.sql.gz")
  fi

  # Feed system token to GitHub CLI
  GH_TOKEN="$GH_TOKEN_SYSTEM"

  # Foreach file to be imported in addition to file(s) in MYSQL_DUMP
  for filename in "${import[@]}"; do

    # Relative path of the downloaded file
    local="custom/$filename"

    # If file does not exist - download it
    if [ ! -f "$local" ]; then
      gh_download "indi-engine/system" "default" "${filename}" "custom"
    fi

    # Copy that file here for it to be imported, as files from subdirectories are ignored while import
    cp "$local" "$filename" && echo "File '/docker-entrypoint-initdb.d/$local' copied to the level up"
  done

  # Spoof mysql user name inside maxwell.sql, if need
  [[ $MYSQL_USER != "custom" ]] && sed -i "s~custom~$MYSQL_USER~" maxwell.sql

  # Сopy 'mysql' and 'mysqldump' command-line utilities into it, so that we can share
  # those two binaries with apache-container to be able to export/import sql-files
  src="/usr/bin"
  vmd="/usr/bin/volumed"
  cp "$src/mysql"     "$vmd/mysql"
  cp "$src/mysqldump" "$vmd/mysqldump"

  # Append touch-command to create an empty '/var/lib/mysql/init.done'-file after init is done to use in healthcheck
  sed -i 's~Ready for start up."~&\n\t\t\ttouch /var/lib/mysql/init.done~' /usr/local/bin/docker-entrypoint.sh
fi

# Call the original entrypoint script
/usr/local/bin/docker-entrypoint.sh "$@"
