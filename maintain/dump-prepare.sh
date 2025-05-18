#!/bin/bash

# Shortcuts
dir=${1:-data}
host=mysql
user=$MYSQL_USER
pass=$MYSQL_PASSWORD
name=$MYSQL_DATABASE
dump="$dir/$MYSQL_DUMP"

# Goto project root
cd $DOC

# Trim .gz from dump filename
sql=$(echo "$dump" | sed 's/\.gz$//')

# Put password into env to solve the warning message:
# 'mysqldump: [Warning] Using a password on the command line interface can be insecure.'
export MYSQL_PWD=$pass

# Export dump
[ -d "$dir" ] || mkdir -p "$dir"
echo -n "Exporting $(basename "$sql") into $dir/ dir..."
mysqldump --single-transaction -h $host -u $user -y $name -r $sql
echo " Done"

# Unset from env
unset MYSQL_PWD

# Gzip dump
echo -n "Gzipping $(basename "$sql")..."
gzip -f $sql
echo " Done"