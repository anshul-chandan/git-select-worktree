#!/usr/bin/env bash
#
# Test suite for select-worktree. Runs the whole suite under bash and zsh,
# because the point of the implementation is that one file serves both.
#
#   tests/test_select_worktree.sh
#
# The picker is exercised deterministically rather than against whatever the
# machine happens to have installed: __swt_have_tty is overridden to force the
# numbered menu, and a shell function named fzf stands in for the real one when
# the fzf branch is under test.

set -u

# ---------------------------------------------------------------- driver ----

if [ -z "${SWT_TEST_INNER:-}" ]; then
	here=$(cd -- "$(dirname -- "$0")" && pwd -P)
	overall=0
	ran=0

	for shell in bash zsh; do
		if ! command -v "$shell" >/dev/null 2>&1; then
			printf '\n===== %s: not installed, skipping =====\n' "$shell"
			continue
		fi
		printf '\n===== %s =====\n' "$shell"
		ran=$((ran + 1))
		SWT_TEST_INNER=1 "$shell" "$here/$(basename -- "$0")" || overall=1
	done

	if [ "$ran" -eq 0 ]; then
		printf 'no shells available to test with\n' >&2
		exit 1
	fi
	exit "$overall"
fi

# ------------------------------------------------------------ assertions ----

PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	printf '  ok    %s\n' "$1"
}

bad() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n          expected: %s\n          actual:   %s\n' "$1" "$2" "$3"
}

assert_eq() {
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1" "$2" "$3"
	fi
}

assert_contains() {
	case $3 in
		*"$2"*) ok "$1" ;;
		*) bad "$1" "something containing [$2]" "$3" ;;
	esac
}

# --------------------------------------------------------------- fixture ----

# pwd -P throughout: on macOS mktemp hands back a /var symlink to /private/var,
# while git reports physical paths. Comparing the two would fail spuriously.
WORK=$(cd -- "$(mktemp -d)" && pwd -P)

cleanup() {
	builtin cd /
	rm -rf "$WORK"
}
trap cleanup EXIT

git init -q "$WORK/main"
(
	cd "$WORK/main" || exit 1
	git config user.email test@example.com
	git config user.name 'select-worktree tests'
	echo hello > file.txt
	git add file.txt
	git commit -qm 'initial commit'
	git branch feature-login
	git branch release/2.0
	git worktree add -q ../wt-login feature-login
	git worktree add -q ../wt-release release/2.0
	git worktree add -q --detach ../wt-detached HEAD
) || exit 1

SRC=$(cd -- "$(dirname -- "$0")/.." && pwd -P)/select-worktree.sh
# shellcheck source=/dev/null
. "$SRC"

# Force the numbered menu for every test. The fzf branch gets its own test
# below, with a stub, so no test depends on what is installed locally.
__swt_have_tty() { return 1; }

start_in_main() {
	builtin cd "$WORK/main" || exit 1
	rm -f "$(__swt_prev_file)"
}

# ----------------------------------------------------------------- tests ----

start_in_main
out=$(swt --list)
assert_contains 'list shows the main worktree' 'main' "$out"
assert_contains 'list shows a linked worktree' 'feature-login' "$out"
assert_contains 'list shows a detached worktree' '(detached)' "$out"
assert_contains 'list marks the current worktree' '* main' "$out"

start_in_main
swt feature-login >/dev/null
assert_eq 'exact branch name switches' "$WORK/wt-login" "$PWD"

start_in_main
swt wt-release >/dev/null
assert_eq 'exact directory name switches' "$WORK/wt-release" "$PWD"

start_in_main
swt FEATURE-LOGIN >/dev/null
assert_eq 'match is case insensitive' "$WORK/wt-login" "$PWD"

start_in_main
swt login >/dev/null
assert_eq 'unique substring switches' "$WORK/wt-login" "$PWD"

start_in_main
swt 'release/2.0' >/dev/null
assert_eq 'branch name containing a slash switches' "$WORK/wt-release" "$PWD"

start_in_main
out=$(swt 'no-such-worktree' 2>&1)
assert_eq 'unmatched query does not move' "$WORK/main" "$PWD"
assert_contains 'unmatched query explains itself' 'no worktree matches' "$out"

start_in_main
out=$(swt '*' 2>&1)
assert_eq 'glob characters are literal, not patterns' "$WORK/main" "$PWD"
assert_contains 'glob query reports no match' 'no worktree matches' "$out"

# The menu writes to stderr and reads a line from stdin, so a herestring
# drives it deterministically.
start_in_main
swt wt- >/dev/null 2>&1 <<< '2'
assert_eq 'ambiguous query picks from the menu' "$WORK/wt-login" "$PWD"

start_in_main
swt >/dev/null 2>&1 <<< '4'
assert_eq 'no argument opens the menu over every worktree' "$WORK/wt-release" "$PWD"

start_in_main
swt >/dev/null 2>&1 <<< ''
assert_eq 'blank menu input cancels' "$WORK/main" "$PWD"

start_in_main
swt >/dev/null 2>&1 < /dev/null
assert_eq 'menu EOF cancels' "$WORK/main" "$PWD"

start_in_main
out=$(swt 2>&1 <<< '99')
assert_eq 'out-of-range menu input cancels' "$WORK/main" "$PWD"
assert_contains 'out-of-range input explains itself' 'out of range' "$out"

start_in_main
out=$(swt 2>&1 <<< 'abc')
assert_eq 'non-numeric menu input cancels' "$WORK/main" "$PWD"
assert_contains 'non-numeric input explains itself' 'not a number' "$out"

# ------------------------------------------------- previous worktree (-) ----

start_in_main
out=$(swt - 2>&1)
assert_eq 'dash with no history does not move' "$WORK/main" "$PWD"
assert_contains 'dash with no history explains itself' 'no previous worktree' "$out"

start_in_main
swt wt-login >/dev/null
swt - >/dev/null
assert_eq 'dash returns to where you came from' "$WORK/main" "$PWD"

swt - >/dev/null
assert_eq 'dash toggles back again' "$WORK/wt-login" "$PWD"

swt - >/dev/null
assert_eq 'dash keeps toggling' "$WORK/main" "$PWD"

start_in_main
swt wt-login >/dev/null
swt wt-login >/dev/null
swt - >/dev/null
assert_eq 'switching to the current worktree does not clobber history' "$WORK/main" "$PWD"

start_in_main
swt wt-release >/dev/null
builtin cd "$WORK/wt-login" || exit 1
assert_eq 'history is shared across linked worktrees' \
	"$WORK/main/.git/swt-prev" "$(__swt_prev_file)"

start_in_main
printf '%s\n' "$WORK/deleted-worktree" > "$(__swt_prev_file)"
out=$(swt - 2>&1)
assert_eq 'stale history does not move' "$WORK/main" "$PWD"
assert_contains 'stale history explains itself' 'no longer exists' "$out"

# ------------------------------------------------------------ both names ----

start_in_main
select-worktree feature-login >/dev/null
assert_eq 'select-worktree switches like swt' "$WORK/wt-login" "$PWD"

start_in_main
a=$(swt --list)
b=$(select-worktree --list)
assert_eq 'both names produce identical output' "$a" "$b"

# ------------------------------------------------------------ fzf branch ----

start_in_main
fzf() {
	printf '%s\n' "$@" > "$WORK/fzf-args"
	grep -- 'release' || true
}
__swt_have_tty() { return 0; }
swt wt- >/dev/null 2>&1
__swt_have_tty() { return 1; }
unset -f fzf
assert_eq 'fzf branch selects a worktree' "$WORK/wt-release" "$PWD"
assert_contains 'fzf is told the tab delimiter' '--with-nth=3..' "$(cat "$WORK/fzf-args")"
assert_contains 'fzf query is seeded with what was typed' '--query=wt-' "$(cat "$WORK/fzf-args")"

# ----------------------------------------------------------- bare repos ----

git clone -q --bare "$WORK/main" "$WORK/bare.git"
git -C "$WORK/bare.git" worktree add -q "$WORK/bare-wt" main 2>/dev/null
builtin cd "$WORK/bare-wt" || exit 1
out=$(swt --list)
assert_eq 'bare repository entry is skipped' '1' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

# ------------------------------------------------------------- non-repo ----

builtin cd "$WORK" || exit 1
out=$(swt 2>&1)
assert_contains 'outside a repository is reported' 'not inside a git repository' "$out"

out=$(swt --help 2>&1)
assert_contains 'help works outside a repository' 'switch between git worktrees' "$out"

out=$(swt --bogus-flag 2>&1)
assert_contains 'unknown flags are rejected' 'not inside a git repository' "$out"

builtin cd "$WORK/main" || exit 1
out=$(swt --bogus-flag 2>&1)
assert_contains 'unknown flags are rejected inside a repository' 'unknown option' "$out"

# ----------------------------------------------------------- completion ----

# Sourcing must never register completion; the user opts in.
if type _swt >/dev/null 2>&1; then
	bad 'sourcing does not define a completion function' '_swt undefined' 'defined'
else
	ok 'sourcing does not define a completion function'
fi
if complete -p swt >/dev/null 2>&1; then
	bad 'sourcing does not register completion' 'no complete spec for swt' "$(complete -p swt)"
else
	ok 'sourcing does not register completion'
fi

builtin cd "$WORK" || exit 1
out=$(swt completion -s zsh)
assert_contains 'zsh script prints outside a repository' '#compdef select-worktree swt' "$out"
out=$(swt completion --shell bash)
assert_contains 'bash script prints with --shell' 'complete -F _swt select-worktree swt' "$out"
out=$(swt completion --shell=bash)
assert_contains 'bash script prints with --shell=' 'complete -F _swt select-worktree swt' "$out"

if [ -n "${ZSH_VERSION-}" ]; then
	expected_default='#compdef'
else
	expected_default='complete -F _swt'
fi
out=$(swt completion)
assert_contains 'no -s prints the script for the running shell' "$expected_default" "$out"

out=$(swt completion -s tcsh 2>/dev/null)
assert_eq 'invalid shell prints nothing on stdout' '' "$out"
out=$(swt completion -s tcsh 2>&1)
assert_contains 'invalid shell lists valid values' '{zsh|bash}' "$out"

out=$(swt completion --help)
assert_contains 'completion help explains where the script goes' 'site-functions/_swt' "$out"

if command -v zsh >/dev/null 2>&1; then
	swt completion -s zsh > "$WORK/_swt.zsh"
	if zsh -n "$WORK/_swt.zsh" 2>/dev/null; then
		ok 'zsh script parses'
	else
		bad 'zsh script parses' 'no syntax errors' "$(zsh -n "$WORK/_swt.zsh" 2>&1)"
	fi

	mkdir -p "$WORK/fpath"
	cp "$WORK/_swt.zsh" "$WORK/fpath/_swt"
	out=$(zsh -f -c "fpath=($WORK/fpath \$fpath)
autoload -Uz compinit; compinit -u -d $WORK/zcd-fpath
print -r -- \"\${_comps[swt]}:\${_comps[select-worktree]}\"")
	assert_eq 'zsh script on fpath registers both names' '_swt:_swt' "$out"

	out=$(zsh -f -c "cd $WORK/main; . $SRC
fpath=($WORK/fpath \$fpath)
autoload -Uz compinit; compinit -u -d $WORK/zcd-auto
compadd() { print -r -- \"\$@\" }
CURRENT=2; _swt" 2>&1)
	assert_contains 'zsh script autoloaded from fpath offers worktrees' 'feature-login' "$out"

	out=$(zsh -f -c "cd $WORK/main; . $SRC
autoload -Uz compinit; compinit -u -d $WORK/zcd-eval
eval \"\$(swt completion -s zsh)\"
print -r -- \"\${_comps[swt]}\"
compadd() { print -r -- \"\$@\" }
CURRENT=2; _swt" 2>&1)
	assert_contains 'zsh script eval registers swt' '_swt' "$out"
	assert_contains 'zsh script eval offers worktrees' 'feature-login' "$out"
fi

if command -v bash >/dev/null 2>&1; then
	out=$(bash -c "cd $WORK/main; . $SRC
eval \"\$(swt completion -s bash)\"
COMP_WORDS=(swt fea); COMP_CWORD=1; _swt
printf '%s\n' \"\${COMPREPLY[@]}\"" 2>&1)
	assert_eq 'bash script eval completes a branch prefix' 'feature-login' "$out"
fi

# ---------------------------------------------------------------- report ----

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
