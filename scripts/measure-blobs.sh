#!/bin/sh
# Samples a Tern blob cache directory: file count and bytes, plus files added
# and removed since the previous sample (a removal means Tern evicted). Only
# reads the directory; never deletes or modifies anything in it.
#
#   measure-blobs.sh [-i SECS] [-d SECS] [-l LABEL] DIR
#
#   -i SECS   sampling interval (default 60)
#   -d SECS   total duration (default 1200 = 20 min); 0 samples once
#   -l LABEL  label column, e.g. "before" or "after" (default "-")
#   DIR       the blob directory, e.g. <sandbox>/home/Library/Caches/Tern/blobs
#             (scripts/dev-tern.sh isolates HOME, so a sandbox has its own)
#
# Prints a tab-separated table on stdout, one row per sample:
#   label  elapsed_s  files  bytes  added  removed  added_bytes
# Run it in the background (or as a service) next to the sandbox window.

set -eu

interval=60
duration=1200
label=-
while getopts i:d:l: opt; do
	case $opt in
	i) interval=$OPTARG ;;
	d) duration=$OPTARG ;;
	l) label=$OPTARG ;;
	*)
		sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2
		exit 2
		;;
	esac
done
shift $((OPTIND - 1))
dir=${1:?measure-blobs.sh [-i SECS] [-d SECS] [-l LABEL] DIR}

work=$(mktemp -d "${TMPDIR:-/tmp}/measure-blobs.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

# listing FILE: "name size" per blob file, sorted by name.
listing() {
	if [ -d "$dir" ]; then
		find "$dir" -type f -exec stat -f '%N %z' {} + 2>/dev/null | sed "s|^$dir/||" | sort >"$1"
	else
		: >"$1"
	fi
}

listing "$work/prev"
start=$(date +%s)
printf 'label\telapsed_s\tfiles\tbytes\tadded\tremoved\tadded_bytes\n'
first=1
while :; do
	listing "$work/cur"
	now=$(date +%s)
	files=$(wc -l <"$work/cur" | tr -d ' ')
	bytes=$(awk '{ s += $2 } END { print s + 0 }' "$work/cur")
	if [ $first = 1 ]; then
		added=0 removed=0 added_bytes=0
		first=0
	else
		cut -d' ' -f1 "$work/prev" >"$work/pn"
		cut -d' ' -f1 "$work/cur" >"$work/cn"
		added=$(comm -13 "$work/pn" "$work/cn" | wc -l | tr -d ' ')
		removed=$(comm -23 "$work/pn" "$work/cn" | wc -l | tr -d ' ')
		added_bytes=$(comm -13 "$work/pn" "$work/cn" | while read -r f; do
			grep -F -- "$f " "$work/cur" | head -n 1
		done | awk '{ s += $2 } END { print s + 0 }')
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" $((now - start)) "$files" "$bytes" "$added" "$removed" "$added_bytes"
	mv "$work/cur" "$work/prev"
	[ $((now - start + interval)) -le "$duration" ] || break
	sleep "$interval"
done
