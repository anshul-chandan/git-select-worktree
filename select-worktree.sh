# select-worktree.sh -- switch between git worktrees in your current shell.
#
# Source this from ~/.zshrc or ~/.bashrc:
#
#   [ -f /path/to/select-worktree.sh ] && . /path/to/select-worktree.sh
#
# Defines two equivalent commands: `select-worktree` and its short form `swt`.
#
# These have to be shell functions rather than an executable on PATH. The
# working directory is per-process state and chdir(2) only affects the calling
# process, so a child process cannot move its parent's prompt. Any external
# program would change its own directory and then exit.
#
# Written in the zsh/bash common subset so one file serves both. That rules out
# arrays (zsh indexes from 1, bash from 0, and bash 3.2 has no associative
# arrays) and `read -p` (bash-only; zsh spells it `read "v?prompt"`).
#
# It also rules out some variable names. zsh ties several lowercase parameters
# to their uppercase counterparts, so `local path` there aliases $PATH and
# blanking it makes every external command, git included, unfindable for the
# rest of the function. Avoid path, cdpath, fpath, manpath, mailpath,
# module_path, prompt, psvar and status as local names.

__swt_err() {
	printf 'select-worktree: %s\n' "$*" >&2
}

__swt_usage() {
	cat <<'EOS'
select-worktree - switch between git worktrees in the current shell

Usage:
  select-worktree              open the interactive picker
  select-worktree <query>      switch to the worktree matching <query>
  select-worktree -            switch back to the previous worktree
  select-worktree -l, --list   list worktrees without switching
  select-worktree completion -s <shell>
                               print a completion script for zsh or bash
  select-worktree -h, --help   show this message

`swt` is an equivalent short form of every command above.

<query> is matched against branch names and worktree directory names, trying
an exact match first, then a case-insensitive one, then a substring. A query
matching several worktrees opens the picker with the query pre-filled.
EOS
}

# Shorten a leading $HOME to ~ for display.
__swt_tilde() {
	case $1 in
		"$HOME") printf '~\n' ;;
		"$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;;
		*) printf '%s\n' "$1" ;;
	esac
}

# Emit one line per usable worktree as <path><TAB><branch>.
#
# Reads the NUL-delimited porcelain form so paths containing spaces or newlines
# survive. Fields are NUL-terminated and each record ends with a second NUL,
# which arrives as an empty field and is what closes the record below.
#
# Bare worktrees are skipped: there is no working tree to enter.
__swt_records() {
	local line dir branch bare
	dir=''
	branch=''
	bare=''

	while IFS= read -r -d '' line; do
		case $line in
			'worktree '*)
				dir=${line#worktree }
				branch=''
				bare=''
				;;
			'branch '*)
				branch=${line#branch }
				branch=${branch#refs/heads/}
				;;
			detached)
				branch='(detached)'
				;;
			bare)
				bare=1
				;;
			'')
				if [ -n "$dir" ] && [ -z "$bare" ]; then
					printf '%s\t%s\n' "$dir" "$branch"
				fi
				dir=''
				branch=''
				bare=''
				;;
		esac
	done < <(git worktree list --porcelain -z 2>/dev/null)
}

# Emit one line per worktree as <path><TAB><branch><TAB><label>, where label is
# the display form: a marker for the current worktree, the branch padded to a
# common width, then the path with $HOME shortened to ~.
#
# Two passes over the records, since the padding width is only known after
# seeing every branch name.
__swt_worktrees() {
	local records current tab width line dir branch marker
	tab=$(printf '\t')

	records=$(__swt_records)
	if [ -z "$records" ]; then
		return 1
	fi
	current=$(git rev-parse --show-toplevel 2>/dev/null)

	width=0
	while IFS= read -r line; do
		branch=${line#*$tab}
		if [ ${#branch} -gt "$width" ]; then
			width=${#branch}
		fi
	done <<< "$records"

	while IFS= read -r line; do
		dir=${line%%$tab*}
		branch=${line#*$tab}
		if [ "$dir" = "$current" ]; then
			marker='*'
		else
			marker=' '
		fi
		printf '%s\t%s\t%s %-*s  %s\n' \
			"$dir" "$branch" "$marker" "$width" "$branch" "$(__swt_tilde "$dir")"
	done <<< "$records"
}

# Print the worktree list for humans. Also what the completions consume.
__swt_list() {
	local tab worktrees line
	tab=$(printf '\t')

	worktrees=$(__swt_worktrees) || {
		__swt_err 'no worktrees found'
		return 1
	}
	while IFS= read -r line; do
		printf '%s\n' "${line##*$tab}"
	done <<< "$worktrees"
}

__swt_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Filter worktree records on stdin against a query, at one precision tier.
#
#   $1  tier: exact, nocase or substr
#   $2  query
#
# Keys are the branch name and the worktree directory name. Comparisons use
# shell string operations with the query quoted inside the pattern, so glob and
# regex characters in a branch name are treated literally.
__swt_match_tier() {
	local tier query tab line dir branch base lquery lbranch lbase
	tier=$1
	query=$2
	tab=$(printf '\t')
	lquery=$(__swt_lower "$query")

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		dir=${line%%$tab*}
		branch=${line#*$tab}
		branch=${branch%%$tab*}
		base=${dir##*/}

		case $tier in
			exact)
				if [ "$branch" = "$query" ] || [ "$base" = "$query" ]; then
					printf '%s\n' "$line"
				fi
				;;
			nocase)
				lbranch=$(__swt_lower "$branch")
				lbase=$(__swt_lower "$base")
				if [ "$lbranch" = "$lquery" ] || [ "$lbase" = "$lquery" ]; then
					printf '%s\n' "$line"
				fi
				;;
			substr)
				lbranch=$(__swt_lower "$branch")
				lbase=$(__swt_lower "$base")
				case $lbranch in
					*"$lquery"*)
						printf '%s\n' "$line"
						continue
						;;
				esac
				case $lbase in
					*"$lquery"*) printf '%s\n' "$line" ;;
				esac
				;;
		esac
	done
}

# Emit the worktree records matching <query>, from the most precise tier that
# produces any hit. An exact branch match is therefore never diluted by
# substring matches elsewhere in the repo.
#
#   $1  query
#   $2  worktree records, as produced by __swt_worktrees
#
# Returns 1 when no tier matches.
__swt_match() {
	local query worktrees tier hits
	query=$1
	worktrees=$2

	for tier in exact nocase substr; do
		hits=$(printf '%s\n' "$worktrees" | __swt_match_tier "$tier" "$query")
		if [ -n "$hits" ]; then
			printf '%s\n' "$hits"
			return 0
		fi
	done
	return 1
}

# Emit every completion candidate, one per line: branch names, worktree
# directory names, and the `-` shorthand.
__swt_candidates() {
	local tab worktrees line dir branch
	tab=$(printf '\t')

	worktrees=$(__swt_worktrees) || return 1
	printf -- '-\n'
	while IFS= read -r line; do
		dir=${line%%$tab*}
		branch=${line#*$tab}
		branch=${branch%%$tab*}
		case $branch in
			'(detached)') ;;
			*) printf '%s\n' "$branch" ;;
		esac
		printf '%s\n' "${dir##*/}"
	done <<< "$worktrees" | sort -u
}

# True when a controlling terminal is available.
#
# Opening /dev/tty fails with ENXIO in a process that has no controlling
# terminal, which is the precise condition that matters here: fzf draws on
# /dev/tty and would block forever without one.
__swt_have_tty() {
	{ : < /dev/tty; } 2>/dev/null
}

# Pick a worktree with fzf, seeding its query with whatever the user typed.
#
# fzf draws on /dev/tty and writes the selection to stdout, so it needs no
# special handling to survive being called in a command substitution.
__swt_pick_fzf() {
	local worktrees query tab chosen
	worktrees=$1
	query=$2
	tab=$(printf '\t')

	chosen=$(printf '%s\n' "$worktrees" | fzf \
		--delimiter="$tab" \
		--with-nth='3..' \
		--height='~40%' \
		--no-multi \
		--exit-0 \
		--prompt='worktree> ' \
		--query="$query")
	[ -n "$chosen" ] || return 1
	printf '%s\n' "${chosen%%$tab*}"
}

# Pick a worktree from a numbered menu.
#
# The menu and prompt go to stderr because the caller reads the chosen path
# from stdout. stdin is untouched, so `read` still reaches the terminal.
# `read -p` is deliberately avoided: it is bash-only.
__swt_pick_menu() {
	local worktrees tab n i line choice
	worktrees=$1
	tab=$(printf '\t')

	n=0
	while IFS= read -r line; do
		n=$((n + 1))
		printf '%3d) %s\n' "$n" "${line##*$tab}" >&2
	done <<< "$worktrees"

	printf 'Select a worktree [1-%d], or blank to cancel: ' "$n" >&2
	IFS= read -r choice || {
		printf '\n' >&2
		return 1
	}

	case $choice in
		'')
			return 1
			;;
		*[!0-9]*)
			__swt_err "not a number: $choice"
			return 1
			;;
	esac
	if [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
		__swt_err "choice out of range: $choice"
		return 1
	fi

	i=0
	while IFS= read -r line; do
		i=$((i + 1))
		if [ "$i" -eq "$choice" ]; then
			printf '%s\n' "${line%%$tab*}"
			return 0
		fi
	done <<< "$worktrees"
	return 1
}

# Choose one worktree from <records>, seeding the picker with <query>.
# Prints the chosen path. Returns non-zero when the user cancels.
__swt_pick() {
	local worktrees query tab count
	worktrees=$1
	query=$2
	tab=$(printf '\t')

	count=$(printf '%s\n' "$worktrees" | wc -l)
	if [ "$count" -eq 1 ]; then
		printf '%s\n' "${worktrees%%$tab*}"
		return 0
	fi

	# The numbered menu is the fallback for more than a missing fzf: it also
	# covers scripts and CI, where fzf has no terminal to draw on. It reads a
	# plain line, so piped input works and EOF reads as a cancellation.
	if command -v fzf >/dev/null 2>&1 && __swt_have_tty; then
		__swt_pick_fzf "$worktrees" "$query"
	else
		__swt_pick_menu "$worktrees"
	fi
}

__swt_in_repo() {
	git rev-parse --git-dir >/dev/null 2>&1
}

__swt_completion_usage() {
	cat <<'EOS'
select-worktree completion - print a shell completion script

Usage:
  select-worktree completion -s <shell>

Flags:
  -s, --shell <shell>   zsh or bash (defaults to the shell you are running)

### zsh

Save it as `_swt` somewhere on your $fpath, before compinit runs:

	swt completion -s zsh > "$(brew --prefix)/share/zsh/site-functions/_swt"

or load it for each session, below compinit in ~/.zshrc:

	eval "$(swt completion -s zsh)"

### bash

Add this to ~/.bashrc, below the line that sources select-worktree.sh:

	eval "$(swt completion -s bash)"
EOS
}

# Mirrors the structure of cobra-generated scripts such as `gh completion`:
# the #compdef header lets compinit autoload it from $fpath, the compdef line
# registers it when eval'd, and the funcstack check runs the function only
# when zsh is invoking it as the autoloaded completer.
__swt_completion_zsh() {
	cat <<'EOS'
#compdef select-worktree swt
compdef _swt select-worktree swt

# zsh completion for select-worktree and swt.
# Generated by: swt completion -s zsh

_swt() {
	local -a candidates
	(( CURRENT == 2 )) || return 1
	candidates=(${(f)"$(select-worktree --candidates 2>/dev/null)"})
	(( ${#candidates} )) || return 1
	compadd -- $candidates
}

# don't run the completion function when being source-ed or eval-ed
if [ "$funcstack[1]" = "_swt" ]; then
	_swt "$@"
fi
EOS
}

__swt_completion_bash() {
	cat <<'EOS'
# bash completion for select-worktree and swt.
# Generated by: swt completion -s bash

_swt() {
	local cur candidates

	COMPREPLY=()
	cur=${COMP_WORDS[COMP_CWORD]}
	[ "$COMP_CWORD" -eq 1 ] || return 0

	candidates=$(select-worktree --candidates 2>/dev/null) || return 0
	[ -n "$candidates" ] || return 0

	# Split on newlines only, so a directory name containing a space stays
	# a single candidate.
	local IFS='
'
	COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
}

complete -F _swt select-worktree swt
EOS
}

__swt_completion() {
	local shell
	shell=''

	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				__swt_completion_usage
				return 0
				;;
			-s | --shell)
				if [ "$#" -lt 2 ]; then
					__swt_err "flag needs an argument: $1"
					return 1
				fi
				shell=$2
				shift 2
				;;
			--shell=*)
				shell=${1#--shell=}
				shift
				;;
			*)
				__swt_err "unknown argument for completion: $1"
				__swt_completion_usage >&2
				return 1
				;;
		esac
	done

	if [ -z "$shell" ]; then
		if [ -n "${ZSH_VERSION-}" ]; then
			shell=zsh
		else
			shell=bash
		fi
	fi

	case $shell in
		zsh) __swt_completion_zsh ;;
		bash) __swt_completion_bash ;;
		*)
			__swt_err "invalid shell \"$shell\": valid values are {zsh|bash}"
			return 1
			;;
	esac
}

# Where the previous worktree for this repo is recorded.
#
# The shared git dir is the right home for it: every linked worktree of a repo
# resolves to the same one, so `-` toggles consistently no matter which
# worktree you run it from, and the state disappears with the repo.
__swt_prev_file() {
	local common
	common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
	if [ -z "$common" ]; then
		# --path-format arrived in git 2.31; fall back for older versions.
		common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
		case $common in
			/*) ;;
			*) common=$(builtin cd -- "$common" 2>/dev/null && pwd) || return 1 ;;
		esac
	fi
	[ -n "$common" ] || return 1
	printf '%s/swt-prev\n' "$common"
}

# Print the recorded previous worktree, or explain why there isn't one.
__swt_prev() {
	local file dir
	file=$(__swt_prev_file) || {
		__swt_err 'cannot locate the git directory'
		return 1
	}
	if [ ! -f "$file" ]; then
		__swt_err 'no previous worktree recorded yet'
		return 1
	fi
	IFS= read -r dir < "$file"
	if [ -z "$dir" ]; then
		__swt_err 'no previous worktree recorded yet'
		return 1
	fi
	if [ ! -d "$dir" ]; then
		__swt_err "previous worktree no longer exists: $dir"
		return 1
	fi
	printf '%s\n' "$dir"
}

# Record <dir> as the previous worktree. Best effort: a read-only git dir
# should cost you the `-` shorthand, not the ability to switch.
__swt_set_prev() {
	local file
	file=$(__swt_prev_file) || return 0
	printf '%s\n' "$1" > "$file" 2>/dev/null || return 0
}

# Change to <dir>, first recording the worktree being left so `-` can return.
#
# Recording on every move is what makes `-` a toggle rather than a one-shot:
# coming back from B to A leaves B recorded, so the next `-` goes to B again.
# A move that would not leave the current worktree records nothing, so it
# cannot overwrite the history with the place you already are.
__swt_goto() {
	local target current
	target=$1
	current=$(git rev-parse --show-toplevel 2>/dev/null)

	if [ -n "$current" ] && [ "$target" != "$current" ]; then
		__swt_set_prev "$current"
	fi
	builtin cd -- "$target"
}

__swt_run() {
	case ${1-} in
		-h | --help)
			__swt_usage
			return 0
			;;
		completion)
			shift
			__swt_completion "$@"
			return $?
			;;
	esac

	if ! __swt_in_repo; then
		__swt_err 'not inside a git repository'
		return 1
	fi

	case ${1-} in
		-l | --list)
			__swt_list
			return $?
			;;
		--candidates)
			__swt_candidates
			return $?
			;;
	esac

	local worktrees query hits count target tab
	tab=$(printf '\t')
	worktrees=$(__swt_worktrees) || {
		__swt_err 'no worktrees found'
		return 1
	}

	if [ "$#" -eq 0 ]; then
		target=$(__swt_pick "$worktrees" '') || return 1
		__swt_goto "$target"
		return $?
	fi

	if [ "$1" = '-' ]; then
		target=$(__swt_prev) || return 1
		__swt_goto "$target"
		return $?
	fi

	query=$1
	case $query in
		-*)
			__swt_err "unknown option: $query"
			__swt_err "run 'select-worktree --help' for usage"
			return 1
			;;
	esac

	hits=$(__swt_match "$query" "$worktrees") || {
		__swt_err "no worktree matches '$query'"
		__swt_list >&2
		return 1
	}

	count=$(printf '%s\n' "$hits" | wc -l)
	if [ "$count" -eq 1 ]; then
		target=${hits%%$tab*}
	else
		target=$(__swt_pick "$hits" "$query") || return 1
	fi

	__swt_goto "$target"
}

swt() { __swt_run "$@"; }
select-worktree() { __swt_run "$@"; }
