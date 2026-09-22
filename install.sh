#!/usr/bin/env bash
#
# Install select-worktree from a local checkout.
#
# This is for development and for people who do not use Homebrew. The brew
# formula does the same work; see the README.
#
# Nothing here is destructive: rc files are only appended to, and only when the
# source line is not already present, so re-running is safe.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
SHELL_FILE=$HERE/select-worktree.sh

SOURCE_LINE="[ -f \"$SHELL_FILE\" ] && . \"$SHELL_FILE\""

info() { printf '  %s\n' "$*"; }
warn() { printf '  warning: %s\n' "$*" >&2; }

if [ ! -f "$SHELL_FILE" ]; then
	printf 'missing %s; run this from a complete checkout\n' "$SHELL_FILE" >&2
	exit 1
fi

# Append $1 to the rc file $2 under the comment $3, unless an identical line
# is already there. Returns non-zero when the rc file does not exist.
add_source_line() {
	local line=$1 rc=$2 label=$3

	if [ ! -e "$rc" ]; then
		return 1
	fi
	if grep -qF -- "$line" "$rc"; then
		info "already present in $rc"
		return 0
	fi
	printf '\n# %s\n%s\n' "$label" "$line" >> "$rc"
	info "added to $rc"
}

printf '\nShell function\n'

installed_any=0
if add_source_line "$SOURCE_LINE" "$HOME/.zshrc" 'select-worktree'; then
	installed_any=1
fi
for bashrc in "$HOME/.bashrc" "$HOME/.bash_profile"; do
	if add_source_line "$SOURCE_LINE" "$bashrc" 'select-worktree'; then
		installed_any=1
		break
	fi
done

if [ "$installed_any" -eq 0 ]; then
	warn 'no ~/.zshrc, ~/.bashrc or ~/.bash_profile found'
	info 'add this line to your shell startup file by hand:'
	info "$SOURCE_LINE"
fi

cat <<EOS

Done. Start a new shell to pick this up:

    exec \$SHELL

Then try:

    select-worktree --help
    swt

Tab completion is not set up by this script. To add it, see:

    swt completion --help

EOS
