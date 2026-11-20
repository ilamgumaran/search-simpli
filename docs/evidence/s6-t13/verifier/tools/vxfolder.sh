#!/bin/bash
# S6-T13 verifier: vxfolder.sh KEEP SECONDS SCRATCH: a folder index (v2: source, file-name, state sections) updated
# in a loop by head's library while main's and head's libraries open it.
set -u
keep=$1; secs=$2; V=$3; here="$(cd "$(dirname "$0")" && pwd)"
D=$V/xproc.noindex/folder-keep-$keep; F=$V/xproc.noindex/folder-src-$keep; mkdir -p $D $F
cp -R $V/src.noindex/head/fixtures/family-folder/. $F/
export VXFOLDER=1
python3 -I $here/vxproc.py folder $V/libs/head/libsearch_simpli.dylib $D 0 $keep $F > /dev/null
python3 -I $here/vxproc.py folder $V/libs/head/libsearch_simpli.dylib $D $secs $keep $F &
python3 -I $here/vxproc.py reader $V/libs/main/libsearch_simpli.dylib $D $secs main &
python3 -I $here/vxproc.py reader $V/libs/head/libsearch_simpli.dylib $D $secs head &
wait
