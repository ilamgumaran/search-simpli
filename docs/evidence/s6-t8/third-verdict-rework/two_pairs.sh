#!/bin/bash
# Two site plant pairs, one after the other (two plants at a time), in sites2.noindex.
S=$HOME/workspace/repos/search-simpli-wt/S6-T8-scratch
SITES=$S/sites2.noindex bash $S/tools/site_pair.sh "$1" "$2"
[ -n "${3:-}" ] && SITES=$S/sites2.noindex bash $S/tools/site_pair.sh "$3" ${4:+"$4"}
exit 0
