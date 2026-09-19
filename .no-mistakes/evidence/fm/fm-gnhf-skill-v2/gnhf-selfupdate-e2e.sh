#!/usr/bin/env bash
# E2E: tracked gnhf skill survives fresh install, reaches secondmate worktrees,
# and no longer blocks the guarded fast-forward self-update (bin/fm-ff-lib.sh ff_target).
set -eu
SRC=$1; OLD=$2; BASE=$3; TARGET=$4
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$W/origin.git"
git -C "$SRC" push -q "$W/origin.git" "$BASE:refs/heads/main"
git --git-dir="$W/origin.git" symbolic-ref HEAD refs/heads/main
. "$SRC/bin/fm-ff-lib.sh"
SKILL=.agents/skills/gnhf/SKILL.md

echo "== BEFORE (origin main = base $BASE): captain home holds gnhf as an untracked local file =="
git clone -q "$W/origin.git" "$W/home"; git -C "$W/home" reset -q --hard "$OLD"
mkdir -p "$W/home/.agents/skills/gnhf"; git -C "$SRC" show "$TARGET:$SKILL" > "$W/home/$SKILL"
git -C "$W/home" status --porcelain
ff_target "$W/home" firstmate origin
echo "FF_STATUS=$FF_STATUS"

echo; echo "== Fresh install at base: skill absent =="
git clone -q "$W/origin.git" "$W/fresh-base"; test -e "$W/fresh-base/$SKILL" && echo present || echo "absent: $SKILL"

echo; echo "== AFTER (origin main = target $TARGET) =="
git -C "$SRC" push -q "$W/origin.git" "$TARGET:refs/heads/main"
git clone -q "$W/origin.git" "$W/fresh"
echo "fresh install tracks: $(git -C "$W/fresh" ls-files "$SKILL")"
echo "fresh install status: '$(git -C "$W/fresh" status --porcelain)' (empty = clean)"
echo "frontmatter: $(sed -n 2p "$W/fresh/$SKILL")"

echo; echo "-- captain home (untracked copy removed, as the tracked file replaces it) self-updates --"
rm -f "$W/home/$SKILL"; rmdir "$W/home/.agents/skills/gnhf"
FETCHED=""  # a later /updatefirstmate run is a new process with a fresh fetch memo
ff_target "$W/home" firstmate origin
echo "FF_STATUS=$FF_STATUS FF_INSTR=$FF_INSTR"
echo "home tracks after update: $(git -C "$W/home" ls-files "$SKILL"); status: '$(git -C "$W/home" status --porcelain)'"

echo; echo "-- secondmate home (detached worktree lease at old commit) syncs to local HEAD --"
git -C "$W/home" worktree add -q --detach "$W/sm" "$OLD"
ff_target "$W/sm" fm-sm1 "$(git -C "$W/home" rev-parse HEAD)" yes
echo "FF_STATUS=$FF_STATUS; secondmate sees: $(git -C "$W/sm" ls-files "$SKILL")"
