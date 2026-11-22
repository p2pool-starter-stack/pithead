#!/bin/sh
awk -v m="$2" '$1 == m && $2 ~ /^v/ { print $2; exit } $1 == "require" && $2 == m { print $3; exit }' "$1"
