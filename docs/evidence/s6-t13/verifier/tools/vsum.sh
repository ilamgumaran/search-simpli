#!/bin/zsh
# summary of one plant log: the counts, each failing test (name and reason) and the verifier sweeps that were not whole
L=$HOME/workspace/repos/search-simpli-wt/S6-T13-vscratch/plants/$1.log
echo "== $1: $(grep -E '^exit=' $L) $(grep -E 'passed; [0-9]+ skipped|All [0-9]+ tests passed' $L | tail -1)"
grep -oE "S6-T13[^.]{0,90}[^.]*\.\.\.(FAIL \([A-Za-z]+\)|expected .{0,120})" $L | sed -E 's/^(.{70}).*\.\.\./\1 ... /'
grep -oE "VSWEEP [a-z_]+ publish delta -?[0-9]: [0-9]+ points, [1-9][0-9]* not whole; .{0,90}" $L
grep -oE "V[BCDE] [a-z_ ]+: [A-Za-z0-9 /]+" $L | grep -vE "VB .*: Truncated$|VC .*: old$|VD (empty|one) .*: Truncated$|VD dir .*: IsDir$|VE cut: Truncated$|VE flipped: ChecksumMismatch$|VE documents: InvalidDocumentSection$|VE lexical: InvalidLexicalSection$"
true
