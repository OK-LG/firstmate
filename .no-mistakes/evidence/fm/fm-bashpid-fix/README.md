# Live validation: fm_exec_timed on stock macOS Bash 3.2 (branch fm/fm-bashpid-fix)

Reported failure: after #10, `bin/fm-timeout-lib.sh` fm_exec_timed read `$BASHPID`,
which macOS's /bin/bash 3.2 does not define, so under `set -u` every timed spawn
on the captain's Mac died and the remote second mate could not run a review turn.

A real GNU bash 3.2.0 (no BASHPID) was built in /tmp from the GNU tarball and used
as the stock interpreter; the 3.2 condition was also reproduced on this host's bash
5.2 via `BASH_ENV` that runs `unset BASHPID` in every non-interactive shell.

| file | what it shows |
| --- | --- |
| live-secondmate-no-bashpid-BASE-pre-fix.txt | the reported breakage, at the product surface: the real supervision host's engine turn logs `failed ... rc=1 ... fm-timeout-lib.sh: line 224: BASHPID: unbound variable`, no Claude turn ever runs, the wake stays unacked |
| live-secondmate-no-bashpid-FIXED.txt | same live run on this change: two real Claude engine turns handle and resume the away wakes, outcome recorded, main never woken |
| real-bash32-timed-spawn.txt | real bash 3.2 caller under `set -u`: pre-fix library dies on `BASHPID: unbound variable`, this change runs the bounded command and passes its status (3) and output through |
| real-bash32-owner-death.txt | real bash 3.2, supervision-engine shape: this change still ends the 60s-bounded command ~1s after its owner dies; the naive `${BASHPID:-$$}` fallback was still running at 15s |
| repo-test-under-real-stock-bin-bash.txt | tests/fm-timeout-lib.test.sh with /bin/bash bind-mounted to the real 3.2 in a private mount namespace: the new case's stock-bash branch fires - "both hold under the real stock bash 3 at /bin/bash, the captain's shell" |
| mutant-naive-fallback.txt | the new test fails (`not ok ... a watchdog whose owner died during startup ran on toward its bound`) when the library is mutated to `${BASHPID:-$$}` |
| timeout-lib-suite.txt | the suite on this host (bash 5.2): new case passes, stock-bash leg prints its skip note |
| real-bash32-no-sh-on-path.txt | boundary: real 3.2 with no `sh` on PATH - the bound and status still hold, but the fallback leaks `exec: sh: not found` and the owner degrades |
| live-secondmate-real-bash32-FIXED.txt | attempt to run the whole product under real 3.2: blocked before the engine by pre-existing 3.2-incompatible regexes in fm-pr-lib.sh:265 and fm-watch.sh:764 (identical at the base commit) |
