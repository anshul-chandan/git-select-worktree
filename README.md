# select-worktree

Switch between git worktrees in your current shell.

```
$ swt
  1) * main           ~/code/myproject
  2)   feature-login  ~/code/myproject-login
  3)   release/2.0    ~/code/myproject-release
Select a worktree [1-3], or blank to cancel: 2

~/code/myproject-login $
```

Run `swt` with no arguments to pick from a list. Give it part of a branch name
or directory name to jump straight there. Give it `-` to go back where you came
from, the way `cd -` and `git switch -` work.

## Install

### Homebrew

```sh
brew tap anshul-chandan/tap
brew install select-worktree
```

Then add the line brew prints to your `~/.zshrc` or `~/.bashrc`:

```sh
[ -f "$(brew --prefix)/share/select-worktree/select-worktree.sh" ] && . "$(brew --prefix)/share/select-worktree/select-worktree.sh"
```

### From a checkout

```sh
git clone https://github.com/anshul-chandan/git-select-worktree
cd git-select-worktree
./install.sh
```

`install.sh` appends the source line to your shell startup file. It only ever
appends, and it skips anything already present, so running it twice is harmless.

Either way, start a fresh shell afterwards:

```sh
exec $SHELL
```

### Tab completion (optional)

`swt completion -s <shell>` prints a completion script to stdout. The script completes branch and directory names by calling `select-worktree`.

For zsh, save it as `_swt` in a directory on your `$fpath` that is added before
`compinit` runs:

```sh
swt completion -s zsh > "<path_to_completions_directory>/_swt"
```

Or load it every session, below `compinit` in `~/.zshrc`:

```sh
eval "$(swt completion -s zsh)"
```

For bash, add this to `~/.bashrc` below the line that sources
`select-worktree.sh`:

```sh
eval "$(swt completion -s bash)"
```

Without `-s`, `swt completion` will print the script that matches your shell.

## Usage

```
select-worktree              open the picker
select-worktree <query>      switch to the worktree matching <query>
select-worktree -            switch back to the previous worktree
select-worktree -l, --list   list worktrees without switching
select-worktree completion -s <shell>
                             print a completion script for zsh or bash
select-worktree -h, --help   show usage
```

`swt` is a short form alias for `select-worktree`.

### Matching

A query is compared against branch names and worktree directory names. An
exact match is tried first, then a case-insensitive one, then a substring.

```sh
swt feature-login     # exact branch name
swt FEATURE-LOGIN     # case does not matter
swt login             # substring, if it is unambiguous
swt release/2.0       # slashes are fine
```

A query that matches several worktrees opens the picker with the query already
filled in, rather than guessing. A query that matches nothing prints the list
of candidates and changes nothing.

### Going back

`swt -` returns to the worktree you were last in. Because the worktree you are
leaving is recorded on every switch, repeated `swt -` toggles between two
worktrees.

### Picker

`fzf` is used when it is installed and a terminal is available. Otherwise, you
are presented with a numbered menu.

## Requirements

- git 2.31 or newer for `git rev-parse --path-format` (though older versions fall back to resolving the path by hand)
- zsh or bash
- `fzf` (optional)

## Tests

```sh
./tests/test_select_worktree.sh
```

The suite builds throwaway repositories with several worktrees and asserts on
`$PWD` after each kind of switch. It runs everything twice, once under bash and
once under zsh. The picker is driven through a stub rather than whatever
happens to be installed, so results do not depend on the machine.

## FAQ
### Why is this a shell function instead of a command?

The working directory belongs to a process, and `chdir` only ever affects the
process that calls it. There is no system call for changing your parent's
directory. That is why `cd` is built into the shell instead of living in
`/usr/bin`: a program could not do the job.

So a program cannot move your prompt. It would change its own directory and
then exit, taking that directory with it. Anything that claims otherwise is
either starting a nested shell underneath you or asking your shell to do the
work on its behalf.

This does the latter. You source one file so that `select-worktree` and `swt`
become functions that run inside your shell.

