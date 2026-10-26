#!/bin/sh
# Looks for personal data and secrets that must not be published: home-directory paths, private
# keys and common API key / token formats (the same kinds Tether masks in its archive). Searches
# tracked and untracked files (not ignored ones). Test data builds fake secrets at run time from
# pieces, so none is written out in the repository.
cd "$(dirname "$0")/.." || exit 2
status=0

paths=$(git grep --untracked -nIE '/Users/[A-Za-z]|/home/[a-z]+/' -- ':!Makefile' ':!CLAUDE.md' ':!scripts/privacy.sh' \
	| grep -vE '/(Users|home)/(user|example|me|you|name)/')
if [ -n "$paths" ]; then
	echo "$paths"
	echo "Personal paths found above — remove them before committing."
	status=1
fi

secrets=$(git grep --untracked -nIE \
	-e 'BEGIN [A-Z ]*PRIVATE KEY' \
	-e '(AKIA|ASIA)[0-9A-Z]{16}' \
	-e 'gh[pousr]_[A-Za-z0-9]{36}' -e 'github_pat_[A-Za-z0-9_]{22}' \
	-e 'glpat-[A-Za-z0-9_-]{20}' \
	-e 'sk-ant-[A-Za-z0-9_-]{20}' -e 'sk-(proj-|svcacct-|admin-)?[A-Za-z0-9]{32}' \
	-e 'AIza[0-9A-Za-z_-]{35}' \
	-e 'xox[abposr]-[0-9A-Za-z-]{10}' -e 'hooks\.slack\.com/services/T' \
	-e '(sk|rk)_live_[0-9A-Za-z]{16}' \
	-e 'npm_[A-Za-z0-9]{36}' -e 'hf_[A-Za-z0-9]{30}' \
	-e 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.' \
	-- ':!scripts/privacy.sh')
if [ -n "$secrets" ]; then
	echo "$secrets"
	echo "Private keys or API tokens found above — remove them before committing (and revoke them if they were real)."
	status=1
fi

[ $status -eq 0 ] && echo "No personal paths, private keys or API tokens found."
exit $status
