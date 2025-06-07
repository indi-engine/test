#!/bin/bash

# Declare array of [repo name => releases qty] pairs
declare -gA releaseQty=()

# Colors
r="\e[31m" # red
g="\e[32m" # green
d="\e[0m"  # default

# Get the whole project up and running
getup() {

  # Setup the docker compose project
  docker compose up -d mysql

  # Pick LETS_ENCRYPT_DOMAIN and EMAIL_SENDER_DOMAIN from .env file, if possible
  LETS_ENCRYPT_DOMAIN=$(grep "^LETS_ENCRYPT_DOMAIN=" .env | cut -d '=' -f 2-)
  EMAIL_SENDER_DOMAIN=$(grep "^EMAIL_SENDER_DOMAIN=" .env | cut -d '=' -f 2-)
  if [[ -z "$EMAIL_SENDER_DOMAIN" ]]; then EMAIL_SENDER_DOMAIN=$LETS_ENCRYPT_DOMAIN; fi

  # If DKIM-keys are expected to be created
  if [[ ! -z "$EMAIL_SENDER_DOMAIN" ]]; then

    # Shortcuts
    container="${dir//./}-wrapper-1"
    wait="Waiting for DKIM-keys to be prepared.."

    # Wait while DKIM-keys are ready
    while ! docker exec $container sh -c "cat /etc/opendkim/trusted.hosts" | grep -q $EMAIL_SENDER_DOMAIN; do
      [[ -n $wait ]] && echo -n "$wait" && wait="" || echo -n "."
      sleep 1
    done
    echo ""

    # Print mail config
    docker exec $container bash -c "source maintain/mail-config.sh"
  fi

  # Force current directory to be the default directory
  echo "cd "$(pwd) >> /root/.bashrc

  # If .env.hard file does not yet exist - create it as a copy of .env.dist but with a pre-filled value for GH_TOKEN_CUSTOM
  if [[ ! -f ".env.hard" ]]; then
    cp ".env.dist" ".env.hard"
    GH_TOKEN_CUSTOM=$(grep "^GH_TOKEN_CUSTOM=" .env | cut -d '=' -f 2-)
    if [[ ! -z $GH_TOKEN_CUSTOM ]]; then
      sed -i "s~GH_TOKEN_CUSTOM=~&${GH_TOKEN_CUSTOM:-}~" ".env.hard"
    fi
  fi

  # If SSL cert is expected to be created
  if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then

    # Shortcut
    wait="Waiting for SSL-certificate for $LETS_ENCRYPT_DOMAIN to be prepared.."

    # If certbot is added to crontab - it means SSL step is done (successful or not)
    while ! docker compose exec apache sh -c "crontab -l 2>/dev/null | grep -q certbot"; do
      [[ -n $wait ]] && echo -n "$wait" && wait="" || echo -n "."
      sleep 1
    done
    echo ""
  fi

  # Print a newline
  echo ""

  # Print newline and URL to proceed
  echo "Open your browser: $(get_self_href)"
}

# Get URL of current instance
get_self_href() {
  echo "$(get_self_prot)://$(get_self_host)"
}

# Get current instance's protocol
get_self_prot() {

  # Setup protocol to be 'http', by default
  prot="http"

  # Pick LETS_ENCRYPT_DOMAIN from .env file, if possible
  LETS_ENCRYPT_DOMAIN=$(grep "^LETS_ENCRYPT_DOMAIN=" .env | cut -d '=' -f 2-)

  # If SSL cert was expected to be created and was really created - setup protocol to be 'https'
  if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then
    if docker compose exec apache certbot certificates | grep -q "Domains: $LETS_ENCRYPT_DOMAIN"; then
      prot="https"
    fi
  fi

  # Print protocol
  echo $prot
}

# Get current instance's host
get_self_host() {

  # Pick LETS_ENCRYPT_DOMAIN and APP_ENV from .env file
  LETS_ENCRYPT_DOMAIN=$(grep "^LETS_ENCRYPT_DOMAIN=" .env | cut -d '=' -f 2-)
  APP_ENV=$(grep "^APP_ENV=" .env | cut -d '=' -f 2-)

  # Detect host
  if [[ ! -z $LETS_ENCRYPT_DOMAIN ]]; then
    host=${LETS_ENCRYPT_DOMAIN%% *}
  elif [[ $APP_ENV == "staging" ]]; then
    host=$(curl http://ipecho.net/plain)
  else
    host="localhost"
  fi

  # Print host
  echo $host
}

# Clear last X lines
clear_last_lines() {
  for ((i = 0; i < $1; i++)); do tput cuu1 && tput el; done
}

# Ask user for some value to be inputted
read_text() {
  echo -e "$1" && echo -n "$ENV_NAME=" && while :; do
    read -r INPUT_VALUE
    if [[ $REQ == true && -z $INPUT_VALUE ]]; then
        echo -n "$ENV_NAME="
    else
        break
    fi
  done
}

# Ask user for some value to be chosen among pre-defined values for an .env-variable
# Variables choice_idx and choice_txt are globally set after this function is called
read_choice_env() {

    # Variables
    IFS=',' read -r -a choices <<< "$2"

    # Print tip
    echo -e $1

    # Print variable name with currently selected value
    echo "$ENV_NAME=${choices[$selected]}"

    # Print instruction on how to use keyboard keys
    echo "" && echo "» Use the up and down arrow keys to navigate and press Enter to select."

    # Force user to choose one among possible values
    read_choice

    # Set variable according to selection
    INPUT_VALUE="$choice_txt"

    # Clear menu
    clear_last_lines $((${#choices[@]}+2))
}

# Function to ask the user to make a choice based on an array of options
# Variables choice_idx and choice_txt are globally set after this function is called
read_choice_custom() {

    # Arguments
    tip="$1" && IFS=',' read -r -a choices <<< "$2"

    # Print tip
    echo -e $tip

    # Force user to choose one among the options
    read_choice

    # Clear only the lines containing options
    clear_last_lines $((${#choices[@]} + 1))
}

# Ask user to make a choice based on choices-array, which must be defined before calling this function
# Once user do some choice, it's 0-based index is written to the choice_idx-variable which can be evaluated
# right after this function is completed
read_choice() {

  # Variables
  local indent="" && [[ ! -z ${ENV_NAME:-} ]] && indent="  "
  local now_choice=${1:-0}
  local was_choice=0
  local key="none"

  # Print choices
  for i in "${!choices[@]}"; do
    if [ $i -eq $now_choice ]; then echo -n "$indent(•)"; else echo -n "$indent( )"; fi && echo " ${choices[$i]}"
  done

  # Force user to make a choice
  while [[ ! -z $key ]]; do

    # Remember selection
    was_choice=$now_choice

    # Capture user input (up/down/enter keys)
    read -n 1 -s key && case "$key" in
      'B') ((now_choice < ${#choices[@]} - 1)) && ((now_choice++)) || true ;;  # Down arrow key
      'A') ((now_choice > 0)) && ((now_choice--)) || true ;;                   # Up arrow key
    esac

    # Move choice
    move_choice $was_choice $now_choice ${#choices[@]}
  done

  # Setup variable to be picked from outside
  choice_idx=$now_choice
  choice_txt=${choices[$choice_idx]}
}

# Setup auxiliary variables
setup_auxiliary_variables() {

  # Delimiter to distinguish between tag name and backup date
  # within backup name i.e. 'D4 · 01 Dec 24, 22:11'
  delim=" · "

  # Get repo 'owner/name'
  repo=$(get_current_repo)

  # Get the backup prefix as a first char of APP_ENV plus first char of backup period
  # Examples:
  # - pd1 => Production instance's daily backup for 1 day ago (i.e. yesterday)
  # - dw2 => Development instance's weekly backup for 2 weeks ago
  # - sd0 => Staging instance's daily backup for today early morning
  tag_prefix=${APP_ENV:0:1}${rotation_period_name:0:1}
}

# Get current repo
get_current_repo() {

  # Get repo name from git config file
  repo=$(sed -nE 's~\s*url\s*=\s*https://([a-zA-Z0-9_\-]+@)?github\.com/([a-zA-Z0-9_\-]+/[a-zA-Z0-9_.\-]+)(\.git)?$~\2~p' ${1:-.git/config})

  # Trim trailing '.git' from repo name as this is unsupported but GitHub CLI
  echo ${repo%.git}
}

# Setup values for is_rotated_backup and rotated_qty variables
check_rotated_backup() {

  # Prepare array of [period => rotated qty] pairs out of $BACKUPS .env-variable
  declare -gA qty=() && for pair in $BACKUPS; do qty["${pair%%=*}"]="${pair#*=}"; done

  # Setup is_rotated_backup flag
  [[ -v qty["$rotation_period_name"] ]] && is_rotated_backup=1 || is_rotated_backup=0

  # Quantity of backups
  (( is_rotated_backup )) && rotated_qty=${qty["$rotation_period_name"]} && (( rotated_qty > 0 )) || rotated_qty=0

  # If it's a rotated backup having 0 as rotation qty - this means backups of such a period are disabled
  if (( is_rotated_backup && rotated_qty == 0 )); then
    exit 0
  fi
}

# Prepare array of [tag name => backup name] pairs
load_releases() {

  # Arguments
  local repo=$1
  local step=${2:-}
  local list

  # Declare array.
  # IMPORTANT: will be overwritten by any further calls of load_releases() function
  declare -gA releases=()

  # Get current repo releases list
  if [[ ! -z "$GH_TOKEN_CUSTOM" ]]; then
    list=$(gh release ls --json name,tagName -R "$repo" --jq '.[] | "\(.tagName)=\(.name)"')
  else
    list=$(curl -s "https://api.github.com/repos/$repo/releases" | jq -r '.[] | "\(.tag_name)=\(.name)"')
  fi

  # Convert into array of [release tag => release name] pairs
  if [[ ${#list} > 0 ]]; then
    while IFS="=" read -r tag name; do
      releases["$tag"]="$name"
    done < <(echo "$list")
  fi

  # Remember releases quantity for a repo
  releaseQty["$repo"]=${#releases[@]}

  # If at least one release exist for the current repo
  if (( ${#releases[@]} > 0 )); then

    # Prepare sorted_tags 0-indexed array from releases associative array
    # We do that this way because the order of keys in associative array in Bash - is NOT guaranteed
    # Sorting is done by env code index ascending and then the release visible date descending
    # Also, $default_release_tag variable is indirectly set by this function call
    sort_releases

    # If we're at the init-step - setup $init_repo and $init_release variables
    # to clarify where init-critical assets should be downloaded from
    if [[ $step == "init" ]]; then
      init_repo="$repo"
      init_release="$default_release_tag"
    fi

  # Else if there are no releases for the current repo, but we're at the init-step and no parent repo was detected so far
  elif [[ $step == "init" && -z "${parent_repo:-}" ]]; then

    # Try to detect parent repo, if:
    #  - current repo was forked or generated from that parent repo
    #  - parent repo is a public one, or is a private one but accessible with current GH_TOKEN_CUSTOM
    parent_repo=$(get_parent_repo "$repo")

    # If parent repo detected, it means current repo was recently forked or generated from it,
    # and right now it's a very first time when the whole 'docker compose'-based Indi Engine
    # instance is getting up and running for the current repo, so try to load releases of parent repo
    if [[ $parent_repo != "null" ]]; then
      load_releases "$parent_repo" "init"
    fi
  fi
}

# Prepare sorted_tags 0-indexed array from releases associative array
# We do that this way because the order of keys in associative array in Bash - is NOT guaranteed
# Sorting is done by env code index ascending and then the release visible date descending
sort_releases() {

  # Auxiliary variables
  env_codes="psd"
  rotation_period_codes="hdwmcb"
  unknown_sortable_date="000000000000"
  unknown_env_code_index="9"

  # Define an array to hold array release tags in the right order
  declare -g sorted_tags=()

  # Regex to match the tag of a rotated release prefixed with
  # an env_code of an instance from where a specific release
  # was uploaded into github
  regex="^[$env_codes][$rotation_period_codes][0-9]+$"

  # Parse the releases and assign priorities based on date
  for tag in "${!releases[@]}"; do

    # Default values
    sortable_date=$unknown_sortable_date
    env_code_index=$unknown_env_code_index

    # Match the tagName to the regex pattern
    if [[ "$tag" =~ $regex ]]; then

      # Extract the first character of a tag name
      env_code="${tag:0:1}"

      # Extract the release title (e.g., "Production · D3 · 13 Dec 24, 01:00")
      title="${releases[$tag]}"

      # Extract the date part from the title (e.g., "13 Dec 24, 01:00") and remove comma
      visible_date=${title##*" · "}
      visible_date=$(echo $visible_date | sed 's/\([0-9]\{2\}:[0-9]\{2\}\).*/\1/')
      visible_date="${visible_date/,/}"

      # Convert the date to a sortable format (YYYYMMDDHHMM)
      sortable_date=$(date -d"$visible_date" +"%Y%m%d%H%M" 2>/dev/null)

      # If date parsing failed,
      if [[ -z "$sortable_date" ]]; then sortable_date=$unknown_sortable_date; fi

      # Get index
      env_code_index="${env_codes%%$env_code*}" && env_code_index=${#env_code_index}
    fi

    # Convert the tag into a sortable expression and append to array
    sorted_tags+=("$env_code_index,$sortable_date,$tag")
  done

  # Sort the releases by index of env_code among env_codes ascending, and then by sortable_date
  IFS=$'\n' sorted_tags=($(sort -t',' -k1,1 -k1,1r -k2,2nr <<< "${sorted_tags[*]}")) && unset IFS

  # Remove env_code and sortable_date so keep only the tags themselves
  for idx in "${!sorted_tags[@]}"; do
    IFS=',' read -r _ _ tag <<< "${sorted_tags[$idx]}" && sorted_tags[$idx]=$tag
  done

  # Setup default release
  default_restore_choice
}

# Set up global default_release_idx and default_release_tag variables that will identify the release to be:
#
# - restored during the initial setup/deploy of your 'docker compose'-based Indi Engine instance
# - selected as a default choice when 'source restore' command is executed so the available restore choices are shown
#
# Logic:
#
# 1.We do already have global sorted_tags array, where all backups we have on github do appear in maximum 4 groups
#   in the following order: production tags, staging tags, development tags and any other tags. In first 3 groups
#   tags are sorted by the dates mentioned in release names, e.g. '13 Dec 24, 01:00' converted to sortable
#   format, in descending order. So the overall sorting logic is that:
#     1.production backups, if any, are at the top of the list with most recent one at the very top globally
#     2.staging backups, if any, with the most recent staging backup at the very top among such kind of backups
#     3.development backups, if any, with the most recent development backup at the very top among such kind of backups
#     4.any other backups, if any, with the non-guaranteed order among them
# 2.Priority
#   1.If we have >= 1 production backups - pick 1st, so it will be the most recent among the production ones
#   2.Else if we have >= 1 backups made by this instance i.e./or instance having same APP_ENV - pick 1st
#   3.Else pick global first in sorted_tags, whatever it is
default_restore_choice() {

  # Initial choice
  default_release_idx=-1
  default_release_tag=""

  # Current application environment code, i.e. 'p' for 'production', etc
  local our_env_code=${APP_ENV:0:1}

  # Iterate through sorted tags
  for idx in "${!sorted_tags[@]}"; do

    # Get iterated tag
    tag=${sorted_tags[$idx]}
    tag_env_code=${tag:0:1}

    # Stop iterating to prevent further changes of the defaults set above when
    # iterated tag indicates a production-release, or release uploaded by the current
    # instance or any other instance having same APP_ENV as the current instance
    if [[ $tag_env_code == "p" || $tag_env_code == $our_env_code ]]; then
      # Set default release tag and idx as iterated ones
      default_release_idx=$idx
      default_release_tag=$tag
      break
    fi
  done

  # If iteration worked till the end but no release was picked so far - pick the first among what we have
  if (( default_release_idx == -1 )); then
    default_release_idx=0
    default_release_tag=${sorted_tags[0]}
  fi
}

# Check whether release exists under given tag, and if yes - setup backup_name variable
# Note: backup = release, but term 'release' is used when we communicate to github,
# and at the same time term 'backup' - is to indicate the purpose behind usage of releases
has_release() {
  if [[ -v releases["$1"] ]]; then
    backup_name=${releases["$1"]}
  else
    backup_name=""
    return 1
  fi
}

# Delete release from github, if exists. Deletion is only applied to the backup
# that is the oldest among the ones having same period, e.g. oldest daily backup, oldest weekly backup, etc
delete_release() {

  # If backup really exists under given tag
  if has_release $1; then

    # Print that
    echo -n "exists"

    # Delete it with it's tag
    delete=$(gh release delete "$1" -y --cleanup-tag)

    # Print that
    echo ", deleted"$delete

  # Else print that backup does not exist so far
  else
    echo "does not exist"
  fi
}

# Move release from one tag to another
retag_release() {

  # If backup really exists
  if has_release $1; then

    # Print that
    echo -n "exists"

    # If backup name has middle dot, i.e. looks like 'Production · D4 · 01 Dec 24, 22:11'
    # then split name by ' · ' and keep the 3rd chunk only, as the 1st
    # one - i.e. tag name - will now different
    if echo "$backup_name" | grep -q " · " ; then
      backup_name=${backup_name##*" · "}
    fi

    # Update releases array
    point=${2:1} && unset releases["$1"] && releases["$2"]="${APP_ENV^}${delim}${point^^}${delim}${backup_name}"

    # Re-tag the currently iterated backup from $this_tag to $prev_tag,
    # so that it is kept as is, but now appears older than it was before
    # and become one step closer to the point where it will become the
    # oldest so it will be removed from github
    edit=$(gh release edit "$1" --tag="$2" --title="${releases["$2"]}")

    # Print that
    echo -n ", moved to $2"

    # If $edit is NOT an URL of the tag - print it
    [[ ! "$edit" =~ ^https?:// ]] && echo $edit;

    # Update the hash that $prev_tag is pointing to
    set_tag_hash "$2" "$(get_tag_hash $1)"

  # Else
  else
    echo "does not exist"
  fi
}

# Get hash of a given remote tag
get_tag_hash() {
  gh api repos/$repo/git/ref/tags/$1 --jq .object.sha
}

# Re-assign given tag into a new commit hash
set_tag_hash() {

  # Do set and get result
  result=$(git tag "$1" "$2" --force)$(git push "https://$GH_TOKEN_CUSTOM@github.com/$repo.git" "$1" --force 2>&1)

  # Print result
  if echo "$result" | grep -q "forced update" ; then
    echo ", $1 => ${2:0:7}"
  else
    echo ", $1 re-assign: $result"
  fi
}

# Prepare and backup current database dump and file uploads into github under the given tag
backup() {

  # Arguments
  rotation_period_name=${1:-custom}

  # Prepare $tag variable containing the right tag name for the backup.
  # If $rotation_period_name is known among the ones listed in $BACKUPS in .env file,
  # then tag name is based on $APP_ENV, $rotation_period_name and index within rotation queue,
  # else tag name is used as is, so any backup already existing under that tag will be overwritten
  prepare_backup_tag "$rotation_period_name"

  # Re-assign given tag to the latest commit
  set_tag_hash "$tag" "$(get_head)" && echo ""

  # Backup uploads and dump
  backup_uploads "$tag"
  backup_dump "$tag"
}

# Backup previously prepared database dump and file uploads into github under the given tag
backup_prepared_assets() {

  # Arguments
  rotation_period_name=${1:-custom}
  dir=${2:-data}

  # Prepare $tag variable containing the right tag name for the backup.
  # If $rotation_period_name is known among the ones listed in $BACKUPS in .env file,
  # then tag name is based on $APP_ENV, $rotation_period_name and index within rotation queue,
  # else tag name is used as is, so any backup already existing under that tag will be overwritten on github
  prepare_backup_tag "$rotation_period_name" "» "

  # Re-assign given tag to the latest commit
  set_tag_hash "$tag" "$(get_head)" && echo "» ---"

  # Backup uploads and dump
  upload_asset "$dir/uploads.zip" "$tag" "» "
  upload_asset "$dir/$MYSQL_DUMP" "$tag" "» "
}

# Backup current database dump on github into given release assets of current repo
backup_dump() {

  # Arguments
  release=$1

  # Prepare dump
  source maintain/dump-prepare.sh "" && asset="$dump"

  # Upload on github
  upload_asset "$asset" "$release"
  echo ""
}

# Backup current uploads on github into given release assets of current repo
backup_uploads() {

  # Arguments
  release=$1

  # Prepare uploads
  source maintain/uploads-prepare.sh "" && asset="$uploads"

  # Upload on github
  upload_asset "$asset" "$release"
  echo ""
}

# Upload given file on github as an asset in given release of the current repo
upload_asset() {

  # Arguments
  asset=$1
  release=$2
  p=${3:-}

  # Do upload
  msg="${p}Uploading $asset into '$(get_current_repo):$release'..."
  echo $msg
  gh release upload "$release" "$asset" --clobber
  clear_last_lines 2
  echo "$msg Done"
}

# Restore database state from the dump.sql.gz of a given release tag
# If release tag is not given - existing data/dump.sql.gz file will be used
restore_dump() {

  # Arguments
  local release="${1:-}"

  # Name of the backup file
  local file="dump.sql.gz"

  # If $release is given - download the backup file, overwriting the existing one, if any
  if [[ -n "$release" ]]; then
    local msg="Downloading $file for selected version into data/ dir..." && echo $msg
    gh release download "$release" -D data -p "$file" --clobber
    clear_last_lines 1
    echo "$msg Done"
  fi

  # Empty mysql data-dir and restart mysql to re-init using downloaded dump
  import_dump
}

# Shutdown mysql, empty data-dir and wait for mysql to re-init using pre-downloaded dump
import_dump() {

  # Shut down mysql
  export MYSQL_PWD=$MYSQL_PASSWORD
  local msg="Shutting down MySQL server..." && echo "$msg"
  mysql -h mysql -u root -e "SHUTDOWN"
  unset MYSQL_PWD

  # Wait until shutdown is really completed
  local timeout=60
  local elapsed=0
  local done="/var/lib/mysql/shutdown.done"
  while :; do
    clear_last_lines 1
    echo "$msg waiting for completion ($elapsed s)"
    sleep 1
    elapsed=$((elapsed + 1))
    if [ -f "$done" ] || [ $elapsed -ge $timeout ]; then break; fi
  done

  # If shutdown file was created by mysql-container custom-entrypoint.sh script
  if [ -f "$done" ]; then

    # It means mysqld process exited gracefully, i.e. shutdown is really completed
    clear_last_lines 1
    echo "$msg Done"

    # Empty mysql_server_data volume
    echo -n "Removing all data from MySQL server..." && rm -rf /var/lib/mysql/* && echo -e " Done"

    # Wait until re-init is really completed
    local msg="Starting MySQL server with import from data/ dir..." && echo "$msg"
    local elapsed=0
    local done="/var/lib/mysql/init.done"
    while :; do
      clear_last_lines 1
      echo "$msg ($elapsed s)"
      sleep 1
      elapsed=$((elapsed + 1))
      if [ -f "$done" ] || [ $elapsed -ge $timeout ]; then break; fi
    done
    clear_last_lines 1
    echo "$msg Done"

  # Else if shutdown is stuck somewhere - print error message and exit
  else
    echo "MySQL server shutdown timeout reached, something went wrong :("
    exit 1
  fi
}

# Restore state of custom/data/upload dir from the uploads.zip of a given release tag
# If release tag is not given - existing data/uploads.zip file will be used
restore_uploads() {

  # Arguments
  local release="${1:-}"

  # Name of the backup file
  local file="uploads.zip"

  # If $release is given - download the backup file, overwriting the existing one, if any
  if [[ -n "$release" ]]; then
    local msg="Downloading $file for selected version into data/ dir..." && echo $msg
    gh release download "$release" -D data -p "$file" --clobber
    clear_last_lines 1
    echo "$msg Done"
  fi

  # Extract
  unzip_file "data/$file" "custom/data/upload" "www-data:www-data"
}

# Set given $string at given position as $column and $lines_up relative to the current line
set_string_at() {

  # Arguments
  local string=$1
  local column=$2
  local lines_up=$3

  # 1.Save current cursor position
  # 2.Move cursor to the spoofing position
  # 3.Write the new symbol
  # 4.Restore the original cursor position
  echo -ne "\033[s"
  echo -ne "\033[${lines_up}A\033[${column}C"
  echo -n "$string"
  echo -ne "\033[u"
}

# Move visual indication of selected choice from previous choice to current choice
move_choice() {

  # Arguments
  local was=$1
  local now=$2
  local qty=$3
  local col=${4:-1}
  local val=""

  # Add the length of choices_indent only if it is defined (non-empty)
  if [[ -n "${indent:-}" ]]; then
    ((col += ${#indent}))
  fi

  # Move choice
  if [[ "$now" != "$was" ]]; then

    # Visually move choice
    set_string_at " " "$col" "$((qty-was))"
    set_string_at "•" "$col" "$((qty-now))"

    # If $ENV_NAME variable is set - it means we're choosing a value for some .env-variable
    if [[ ! -z ${ENV_NAME:-} ]]; then

      # Prepare the line to be used for re-renderiing the existing line where 'SOME_NAME=SOME_VALUE' is printed
      line="$ENV_NAME="$(printf "%-*s" $(longest_choice_length) "${choices[$now]}")

      # Do re-render
      set_string_at "$line" "-1" $((${#choices[@]}+3))
    fi
  fi
}

# Get length of longest choice
# Currently this is used to pad the'SOME_NAME=SOME_VALUE' string with white spaces
# in the terminal screen when newly selected SOME_VALUE is shorter than previously selected one
longest_choice_length() {

  # Initialize variables to track the max length and corresponding item
  local max_length=0
  local max_item=""

  # Iterate through the array
  for item in "${choices[@]}"; do

    # Get the length of the current item
    item_length=${#item}

    # Check if it's the longest so far
    if (( item_length > max_length )); then
        max_length=$item_length
        max_item=$item
    fi
  done

  # Print length of longest choice
  echo $max_length
}

# Prepare .env file out of given template file (default .env.dist) with prompting for values where needed
prepare_env() {

  # Input and output files
  DIST=${1:-".env.dist"}
  PROD=".env.prod"

  # Clear the output file
  > "$PROD"

  # Reset description and required flag
  TIP=""
  REQ=false
  enum_rex='\[enum=([a-zA-Z0-9_]+(,[a-zA-Z0-9_]+)*)\]'

  # Read the file into an array, preserving lines with spaces
  mapfile -t lines < "$DIST"

  # Process each line in the array
  for line in "${lines[@]}"; do

    # Trim leading/trailing whitespace
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # If line starts with '#'
    if [[ $line == \#* ]]; then

      # Append it to result file and to TIP variable. Also setup REQ flag and ENUM variable, if need
      TIP+="\n${line}"
      [[ $line == "# [Required"* ]] && REQ=true
      [[ $line =~ $enum_rex ]] && ENUM="${BASH_REMATCH[1]}"
      echo "$line" >> "$PROD"

    # Else if line looks like VARIABLE=...
    elif [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then

      # Split by '=' into name and default value
      local ENV_NAME=$(echo "$line" | cut -d '=' -f 1)
      local DEFAULT_VALUE=$(echo "$line" | cut -d '=' -f 2-)

      # If default value is empty
      if [[ -z $DEFAULT_VALUE ]]; then

        # Ask user to type or choose the value
        if [[ $ENUM == false ]]; then read_text "${TIP}"; else read_choice_env "${TIP}" "$ENUM"; fi

        # Trim leading and trailing whitespaces
        INPUT_VALUE=$(echo "$INPUT_VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # If the trimmed input contains whitespace - enclose in double quotes
        if [[ "$INPUT_VALUE" =~ [[:space:]] ]]; then INPUT_VALUE="\"$INPUT_VALUE\""; fi

        # Write inputted value
        echo "$ENV_NAME=$INPUT_VALUE" >> "$PROD"

      # Else write as is
      else
        echo "$ENV_NAME=$DEFAULT_VALUE" >> "$PROD"
      fi

    # Else if line is an empty line or contains only whitespaces
    elif [[ -z $line ]]; then

      # Write that line as well, and reset TIP, REQ and ENUM variables
      echo "" >> "$PROD"
      TIP=""
      REQ=false
      ENUM=false
    fi
  done

  # Rename .env.prod to .env
  mv $PROD .env
}

# Download file
gh_download() {

  # Arguments
  local repo="$1"
  local release="$2"
  local file="$3"
  local dir=${4:-data}

  # Msg
  local msg="Downloading '$file' from '$repo:$release' via GitHub"

  # Disable exit in case of error
  set +e

  # Download the $file using GitHub CLI or GitHub API based on whether GH_TOKEN_CUSTOM variable is set
  if [[ -n "$GH_TOKEN_CUSTOM" ]]; then
    echo "$msg CLI"
    local error=$(gh release download $release -D "$dir" -p "$file" -R "$repo" 2>&1)
  else
    echo "$msg API"
    local error=$(curl -L -o "$dir/$file" "https://github.com/$repo/releases/download/$release/$file" 2>&1)
  fi

  # Enable back exit in case of error
  set -e

  # If download was unsuccessful for whatever reason - print reason
  if [[ -n $error ]]; then
    echo "Downloading error: $error" >&2
    return 1
  fi
}

# Install GitHub CLI, if not yet installed
ghcli_install() {

  # If GitHub CLI is already installed - return
  if command -v gh &>/dev/null; then
    echo "GitHub CLI is already installed."
    return 0
  fi

  # Print where we're
  echo "Installing GitHub CLI..."

  # Add GPG key
  ghgpg=/usr/share/keyrings/githubcli-archive-keyring.gpg
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=$ghgpg && chmod go+r $ghgpg; then
    echo "GPG key successfully added."
  else
    echo "Error adding GPG key. Exiting."
    exit 1
  fi

  # Add package info
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$ghgpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

  # Do install
  if apt-get update && apt-get install gh -y; then
    echo "GitHub CLI installed successfully."
    return 0
  else
    echo "Error installing GitHub CLI. Exiting."
    exit 1
  fi
}

# Make sure 'custom/data/upload' dir is created and filled, if does not exist
init_uploads_if_need() {

  # Destination dir for Indi Engine uploads
  dest="custom/data/upload"

  # If that dir does not exist
  if [[ ! -d "$dest" ]]; then

    # Define file name of the asset, that is needed for creation of the above mentioned dir
    file="uploads.zip"

    # If asset file does not exist locally
    if [[ ! -f "data/$file" ]]; then

      # Load list of available releases for current repo. If no releases - load ones for parent repo, if current repo
      # was forked or generated. But anyway, $init_repo and $init_release variables will be set up to clarify where to
      # download asset from, and it will refer to either current repo, or parent repo for cases when current repo
      # has no releases so far, which might be true if it's a very first time of the instance getting up and running
      # for the current repo
      load_releases "$(get_current_repo)" "init"

      # Download it from github into data/ dir
      if [[ ! -z "${init_repo:-}" ]]; then
        echo "Asset '$file' will be downloaded from '$init_repo:$init_release'"
        gh_download "$init_repo" "$init_release" "$file"
      fi
    fi

    # If asset file does exist locally (due to it was just downloaded or it was already existing locally)
    if [[ -f "data/$file" ]]; then

      # Extract asset with recreating the destination dir and make that dir writable by Indi Engine
      unzip_file "data/$file" "$dest" "www-data:www-data"
    fi

  # Else just make uploads dir writable for Indi Engine which might be at least needed
  # if current project have been deployed from a hard copy coming from a disk storage
  # system (e.g. USB Flash Drive) that might not preserve ownership for the stored
  # files and directories, which can lead to that all files and folders copied from
  # such a hard copy into a server will have 'root' as owner, including custom/data/upload
  # dir, so it won't be writable to 'www-data'-user on behalf of which Indi Engine is working,
  # so below code is there to solve that problem
  else
    echo -n "Making $dest dir writable for Indi Engine..."
    chown -R "www-data:www-data" "$dest"
    echo -e " Done\n"
  fi
}

# If $GH_TOKEN_CUSTOM is set but there are no releases yet in the current repo due to it's
# a forked or generated repo and it's a very first time of the instance getting
# up and running for the current repo - backup current state into a very first own release,
# so that any further deployments won't rely on parent repo releases anymore
make_very_first_release_if_need() {

  # Get current repo
  current_repo="$(get_current_repo)"

  # If global releaseQty array is empty, it means load_releases() function was NOT
  # called yet, so call it now as we need to know whether current repo has releases
  if (( ${#releaseQty[@]} == 0 )); then load_releases "$current_repo"; fi

  # If current repo has no own releases so far - create very first one
  if (( releaseQty["$current_repo"] == 0 )) && [[ -n $GH_TOKEN_CUSTOM ]]; then

    # Do backup
    source backup
  fi
}

# Get parent repo
get_parent_repo() {

  # Argument #1: repo for which parent should be detected
  local repo=$1

  # Shortcut to json query
  local jq=".parent.full_name, .template_repository.full_name"
  local uri="/repos/$repo"

  # Get current repo info
  if [[ ! -z "$GH_TOKEN_CUSTOM" ]]; then
    local info=$(gh api "$uri" --jq "$jq")
  else
    local info=$(curl -s "https://api.github.com$uri" | jq -r "$jq")
  fi

  # Get global parent_repo variable and print it
  local forked_from=$(echo "$info" | head -n 1)
  local templated_from=$(echo "$info" | sed -n '2p')
  parent_repo=${forked_from:-$templated_from}
  echo $parent_repo
}

# Unzip given file into a given destination
unzip_file() {

  # Arguments
  local file=$1
  local dest=$2
  local owner=${3:-}

  # Remove existing destination dir, if any
  [[ -d $dest ]] && rm -rf "$dest"/*

  # Count total quantity of files in the archive and prepare msgs
  local qty=$(unzip -l "$file" | grep -c '^[ ]*[0-9]')
  local m1="Unzipping" && local m2="files into $dest/ dir..."

  # If we're within an interactive shell
  if [[ $- == *i* ]]; then

    # Extract with progress tracking
    unzip -o "$file" -d "$dest" | awk -v qty="$qty" -v m1="$m1" -v m2="$m2" '/extracting:/ {idx++; printf "\r%s %d of %d %s", m1, idx, qty, m2}'
    clear_last_lines 1
    echo -e "\n$m1 $qty of $qty $m2 Done"

  # Else extract with NO progress tracking
  else
    echo -n "$m1 $qty $m2" && unzip -o -q "$file" && echo " Done"
  fi

  # If $owner arg is given - apply ownership for the destination dir
  if [[ -n $owner ]]; then
    echo -n "Making that dir writable for Indi Engine..."
    chown -R "$owner" "$dest"
    echo -e " Done"
  fi
}

# Get release title by release tag
# This function expects releases are already loaded via 'gh release ls' command
get_release_title() {

  # Arguments
  local tag=$1

  # If release does not exist - print error and exit
  if [[ ! -v releases["$tag"] ]]; then
    echo "Release '$tag' not found" >&2
    exit 1
  fi

  # Get release title
  local title=$(echo -e "${releases[$tag]}" | sed -e 's/\x1b\[[0-9;]*m//g')
  title=$(echo -e "${releases[$selected]}" | cat -v | sed -E 's~\^(\[[^m]+?m|M)~~g' | sed -E 's~M-BM-7~-~g')
  length=${release_choice_title_length:-37}
  title=$(echo "${title:0:$length}")
  title="${title%"${title##*[![:space:]]}"}"
  title=$(echo "$title" | sed -E 's~ - ~ · ~g')

  # Print title
  echo $title
}

# Check if we're in an 'uncommitted_restore' state, which is true if both conditions are in place:
# 1.We're currently in a detached head state
# 2.Note of a current commit ends with ' · abc1234' where abc1234 is a first 7 chars of a commit hash
is_uncommitted_restore() {
  [[ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]] && \
  [[ "$(git notes show 2>/dev/null)" =~ \ ·\ [a-f0-9]{7}$ ]]
}

# Prepend each printed line with string given by 1st arg
prepend() {
  while read -r line; do echo "${1:-}${line}"; done
}

# Get hash of a commit where HEAD is right now
get_head() {
  git rev-parse HEAD
}

# If we're going to enter into an 'uncommitted restore' state then
# do a preliminary local backup of current state so that we'll be
# able to get back if restore will be cancelled
backup_current_state_locally() {
  if ! is_uncommitted_restore; then
    echo -e "Backing up the current version locally before restoring the selected one:"
    source maintain/uploads-prepare.sh ${1:-} | prepend "» "
    source maintain/dump-prepare.sh ${1:-} | prepend "» "
    echo ""
  fi
}

# Restore source code
restore_source() {

  # Arguments
  local release=$1
  local dir=${2:-custom}

  # Get release title
  local title=$(get_release_title $release)

  # Get commit hash for the $release
  local repo=$(get_current_repo)
  echo -n "Detecting commit hash for selected version..."
  local hash=$(get_tag_hash $release)
  echo " Done"
  echo -e "Result: $hash\n"

  # Get hash of current HEAD
  local head=$(git rev-parse HEAD)

  # Restore source code to a selected point in history
  echo -n "Restoring source code for selected version..."

  # If we are already in 'detached HEAD' (i.e. 'uncommitted restore') state
  if is_uncommitted_restore; then

    # Cleanup uncommitted changes, if any, to prevent conflict with the state to be further checked out
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git stash --quiet && git stash drop --quiet;
    fi

    # Cleanup previously applied commit note, to prevent misleading info from being shown in 'git log'
    # We do that because notes here are used as a temporary reminder of which backup was restored, but
    # the fact we're here assumes we're going to restore another backup than the currently restored one
    # and in most cases this means HEAD will be moved to another commit, so we don't need the note we've
    # added for the current commit i.e. where HEAD is at the moment, because note should be added only
    # for the most recent uncommitted restore, because when committed - note comment will be used to
    # prepare commit message for it to contain the name of backup that was finally restored, because
    # we can't rely for that on anything else, as backup tags are rotating and commit hashes are not
    # unique across tags as there might be multiple backups having tags pointing to equal commit hashes,
    # so the commit hash of a backup does NOT uniquely identify the backup
    if git notes show "$head" > /dev/null 2>&1; then git notes remove "$head" > /dev/null 2>&1; fi
  fi

  # Restore the whole repo at selected point in history
  git checkout -q "$hash" 2>&1 | prepend "» "
  echo -e " Done"

  # Apply DevOps patch so that critical files a still at the most recent state
  echo -n "Forcing DevOps-setup files to be still at the latest version..."
  git checkout master -- . ":(exclude)$dir"
  echo " Done"

  # Add note
  git notes add -m "$title · ${hash:0:7}"

  # Apply composer packages state
  echo "Setting up composer packages state:"
  composer -d custom install --no-ansi 2>&1 | grep -v " fund" | prepend "» "
  echo ""
}

# Load releases from github, force user to select one
# and set up selected-variable containing selected release's tag
release_choices() {

  # Arguments
  local to_be_done=${1:-"to be restored"}
  if [[ "${2:-0}" == "1" ]]; then
    local auto_choose="most recent"
  else
    local auto_choose=${2:-0}
  fi

  # Load releases list
  echo -n "Loading list of backup versions available on github..."
  local lerr="var/log/release_list.err"
  local list=$(script -q -c "gh release list 2> $lerr" /dev/null)
  if [[ -s "$lerr" ]]; then echo ""; cat "$lerr" >&2; exit 1; fi
  rm -f "$lerr";
  echo " Done"

  # Split $list into an array of lines
  mapfile -t lines < <(printf '%s\n' "$list")

  # Get index of 'TAG NAME' within the header line
  local header=$(echo -e "${lines[0]}" | cat -v | sed -E 's~\^(\[[^m]+?m|M)~~g') && index=${header%%"TAG NAME"*} && index=${#index}
  local up_to_type=${header%%"TYPE"*}
  release_choice_title_length=${#up_to_type}

  # Get and print header, with removing it out of the lines array
  header=$(echo -e " ?  ${lines[0]}" | perl -pe 's/\e\[[0-9;?]*[A-Za-ln-zA-Z]//g' | sed -E 's~\x1b][0-9]+;\?~~g'); unset 'lines[0]'

  # Re-index lines array
  lines=("${lines[@]}")

  # Prepare unsorted releases-array of [tag => name] pairs from raw $lines
  declare -Ag releases=()
  for idx in "${!lines[@]}"; do
    tag=$(echo -e "${lines[$idx]}" | cat -v | sed -E 's~\^(\[[^m]+?m|M)~~g' | sed -E 's/M-BM-7/-/g')
    tag=$(echo "${tag:$index}") && tag="${tag%% *}"
    releases[$tag]=${lines[$idx]}
  done

  # Prepare sorted_tags 0-indexed array from releases associative array
  # We do that this way because the order of keys in associative array in Bash - is NOT guaranteed
  # Sorting is done by env code index ascending and then the release visible date descending
  sort_releases

  # Prepare choices in the right order
  choices=() && for tag in "${sorted_tags[@]}"; do choices+=("${releases["$tag"]}"); done

  # If the most recent backup should be auto-selected - we don't ask user to choose
  if [[ "$auto_choose" = "most recent" ]]; then

    # Get text
    choice_idx=${default_release_idx}
    choice_txt=${choices[$default_release_idx]}

  # Else if arbitrary backup should be manually selected
  elif [[ "$auto_choose" = "0" ]]; then

    # Print instruction on how to use keyboard keys
    echo "Please select the version you want $to_be_done"
    echo -e "Use the ↑ and ↓ keys to navigate and press Enter to select or Ctrl+C to cancel\n"

    # Ask user to choose and set choice-variable once done
    echo "$header" && read_choice $default_release_idx
  fi

  # If it was manual choice or auto choice ofmost recent backup
  if [[ "$auto_choose" = "0" || "$auto_choose" = "most recent" ]]; then

    # Parse the tag of selected backup
    selected=$(echo -e "$choice_txt" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/·/-/g')
    selected=$(echo "${selected:$index}") && selected="${selected%% *}"
    echo ""

  # Else set up selected to be the one given as 2nd arg
  else
    echo ""
    selected="$auto_choose"
  fi
}

# Cancel source code restore, i.e. revert source code to the state which was before restore
cancel_restore_source() {

  # Print where we are
  echo -n "Cancelling source code restore..."

  # Remove notes
  git notes remove "$(get_head)" 2> /dev/null

  # Cleanup uncommitted changes, if any, to prevent conflict with the state to be further checked out
  if ! git diff --quiet || ! git diff --cached --quiet; then
      git stash --quiet && git stash drop --quiet;
  fi

  # Restore source code at master-branch
  git checkout -q master

  # Print done
  echo -e " Done"

  # Revert composer packages state
  echo "Setting up composer packages state:"
  composer -d custom install --no-ansi 2>&1 | grep -v " fund" | prepend "» "
}

# Cancel uploads restore, i.e. revert uploads to the state which was before restore
cancel_restore_uploads_and_dump() {

  # Move uploads.zip and dump.sql.gz files from data/before/ to data/
  # for those to be further picked by restore_uploads() call and mysql re-init
  src="data/before" && trg="data"
  echo -n "Moving uploads.zip and dump.sql.gz from $src/ into $trg/..."
  if [ -d $src ]; then mv -f "$src"/* "$trg"/ && rm -r "$src"; fi
  echo -e " Done\n"

  # Revert uploads to the state before restore
  # We call this function here with no 1st arg (which normally is expected to be a release tag)
  # to skip the downloading uploads.zip file from github, so that the local uploads.zip file
  # we've moved into data/ dir from data/before/ dir - will be used instead
  restore_uploads

  # Separate with new line
  echo ""

  # Revert database to the state before restore
  # We call this function here with no 1st arg (which normally is expected to be a release tag)
  # to skip the downloading dump.sql.gz file from github, so that the local dump.sql.gz file
  # we've moved into data/ dir from data/before/ dir - will be used instead
  restore_dump
}

# Prepare $tag variable containing the right tag name for the new backup and do a rotation step if need
prepare_backup_tag() {

  # Argument: name of backup rotation period, which is expected to be 'hourly', 'daily', 'weekly', 'monthly' or 'custom'
  rotation_period_name=${1:-custom}
  p=${2:-}

  # Setup auxiliary variables
  setup_auxiliary_variables

  # Setup values for is_rotated_backup and rotated_qty variables
  check_rotated_backup

  # Load releases list from github into array of [tagName => title] pairs
  # Note: $repo variable is globally set by setup_auxiliary_variables() call
  echo -n "${p}Loading list of '$rotation_period_name'-backups available on github..."
  load_releases "$repo"
  echo " Done"

  # If it's a rotated backup
  if (( is_rotated_backup )); then

    # Print a newline
    echo ""

    # Iterate over each expected backup starting from the oldest one and up to the most recent one
    for ((backup_idx=$((rotated_qty-1)); backup_idx>=0; backup_idx--)); do

      # Get the tag name for the backup at the given index
      # within the history of backups for the given period
      tag="${tag_prefix}${backup_idx}"

      # If the index refers to the oldest possible backup
      if [[ $backup_idx -eq $((rotated_qty - 1)) ]]; then

        # Print where we are
        echo -n "${p}Oldest: $tag - "

        # Delete backup (if exists)
        delete_release "$tag"

      # Else if the index refers to intermediate or even the newest
      # backup within the history of backups for the given period
      else

        # Print where we are
        if [[ $backup_idx -ne 0 ]]; then
          echo -n "${p}Newer: $tag - "
        else
          echo -n "${p}Newest: $tag - "
        fi

        # Move release (if exists) from current tag to older tag
        retag_release "$tag" "${tag_prefix}$((backup_idx + 1))"
      fi
    done

    # Prepare backup title looking like 'Production · D0 · 07 Dec 24, 14:00'
    point=${tag:1} && title="${APP_ENV^}${delim}${point^^}${delim}$(date +"%d %b %y, %H:%M")"

  # Else
  else

    # Setup tag name for non-rotated backup to be equal to 1st arg (if given) or 'latest'
    tag=${1:-latest}

    # Setup release title to be the same as tag name
    title="$tag"
  fi

  # If backup does not really exists under given tag - create it
  if ! has_release "$tag"; then
    created=$(gh release create "$tag" --title="$title" --notes="" --target="$(get_head)")
    echo -n "${p}Newest: $tag - created"
  else
    echo -n "${p}Newest: $tag - exists, will be updated"
  fi
}

# Make restored version to become the new latest
commit_restore() {

  # Print where we are
  echo "Make restored version to become the new latest:"

  # Get title and commit hash of the restored version
  echo -n "» Detecting restored version title and commit hash..."
  version=$(git notes show) && hash=$(get_head)
  echo " Done"

  # Checkout whole working dir was the latest version
  echo -n "» Switching source code to the latest version..."
  git checkout master > /dev/null 2>&1
  echo " Done"

  # However, checkout custom dir at the restored version
  echo -n "» Switching source code in custom/ dir to the restored version..."
  git restore --source "$hash" custom
  git add custom
  echo " Done"

  # Create a commit to make the restore to be a point in the project history
  # If there were no really changes in custom since restored version - we still create a commit
  # Remove that note from commit, so note is now kept in $note variable only
  echo -n "» Committing this state as a new record in source code history..."
  git commit --allow-empty -m "RESTORE COMMITTED: $version" > /dev/null
  git notes remove "$hash" 2> /dev/null
  echo " Done"

  # Push changes to remote repo, and pull back for git log to show last commit in origin/master as well
  echo ""
  git remote set-url origin https://$GH_TOKEN_CUSTOM@github.com/$(get_current_repo)
  git push
  pull=$(git pull) && [[ ! "$pull" = "Already up to date." ]] && echo -e "\n$pull";

  git remote set-url origin https://-@github.com/$(get_current_repo)

  # Print restore is now committed
  echo -e "\nRESTORE COMMITTED: ${g}${version}${d}\n"
}


# Make the original version, which was active BEFORE you've entered
# in an 'uncommitted restore' state - to be also restorable
backup_before_restore() {

  # Print where we are
  echo "Make 'before restore' version to be also restorable:"
  echo "» ---"

  # Assets dir where dump.sql.gz and uploads.zip
  # were created before restore, and still kept
  dir="data/before"

  # Backup those assets into github under 'before' tag
  backup_prepared_assets "before" "$dir"

  # Remove from local filesystem
  [ -d "$dir" ] && rm -R "$dir"

  # Print new line
  echo ""
}

mysql_entrypoint() {

  # Path to a file to be created once init is done
  done=/var/lib/mysql/init.done

  # If init is not done
  if [[ ! -f "$done" ]]; then

    # Install certain tools
    apt-get update && apt-get install -y wget curl jq

    # Print which dump is going to be imported
    echo "MYSQL_DUMP is '$MYSQL_DUMP'";

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

  # If we reached this line, it means mysql was shut down
  echo "MySQL Server has been shut down"

  # Create a file within data-dir to indicate shutdown is completed
  touch /var/lib/mysql/shutdown.done

  # Wait until shutdown is really completed
  local timeout=5
  local elapsed=0
  local data="/var/lib/mysql"
  while [ ! -z "$(ls -A $data)" ] && [ $elapsed -lt $timeout ]; do
    echo "Waiting for data-directory to be emptied... ($elapsed s)"
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # If data-directory was emptied
  if [ -z "$(ls -A $data)" ]; then

    # We assume it was done for restore
    echo "MySQL data-directory has been emptied, so initiating the restore..."

    # Re-init, assuming sql dump file(s) are present in /docker-entrypoint-initdb.d/custom/
    mysql_entrypoint "$@"
  fi
}