#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Loren Weith
#
# version.sh - print what this checkout builds as: the version, the branch and
# the commit date, one per line. The Makefile embeds them in the image.
#
#   at tag vX.Y.Z, clean          X.Y.Z+gHASH
#   N commits past vX.Y.Z         X.Y.(Z+1)-dev.N+gHASH   (a pre-release of the
#                                 next patch, so it sorts above X.Y.Z)
#   uncommitted changes           ... +gHASH.dirty
#   no vX.Y.Z tag reachable       0.0.0-dev.N+gHASH (N = commits in the history)
#   not a git checkout            0.0.0+unknown
#
# Only plain vMAJOR.MINOR.PATCH tags count. The commit date (not the build
# time) keeps a clean commit's image byte-identical from build to build.

cd "$(dirname "$0")" || exit 1
# this directory must be the checkout's top, not a copy inside some other repo
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$(pwd -P)" ]; then
	printf '%s\n' 0.0.0+unknown unknown unknown
	exit 0
fi

dirty=
git diff --quiet HEAD -- 2>/dev/null || dirty=.dirty
hash=g$(git rev-parse --short=7 HEAD)

d=$(git describe --tags --long --abbrev=7 --match 'v[0-9]*.[0-9]*.[0-9]*' \
	--exclude 'v*-*' HEAD 2>/dev/null)
if [ -n "$d" ]; then
	rest=${d%-g*}           # vX.Y.Z-N
	n=${rest##*-}
	v=${rest%-*}
	v=${v#v}
	if [ "$n" -eq 0 ]; then
		version=$v+$hash$dirty
	else
		major=${v%%.*}
		minor=${v#*.}
		minor=${minor%%.*}
		patch=${v##*.}
		version=$major.$minor.$((patch + 1))-dev.$n+$hash$dirty
	fi
else
	version=0.0.0-dev.$(git rev-list --count HEAD)+$hash$dirty
fi

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = HEAD ] && branch=detached

printf '%s\n' "$version" "$branch" "$(git log -1 --format=%cs HEAD)"
