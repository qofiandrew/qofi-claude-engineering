#!/usr/bin/env bash
# Atomic lock publication/release must never expose an ownerless lock or delete ABA state.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/bin/atomic-directory-lock.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/atomic-directory-lock.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  PASS  $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }
eq(){ [ "$1" = "$2" ] && ok "$3" || bad "$3 (expected [$1], got [$2])"; }
mode(){ stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

LOCK="$TMP/one.lock"
printf '123\n' | /usr/bin/python3 -I -B "$HELPER" "$LOCK" owner
eq 123 "$(cat "$LOCK/owner")" "published lock contains its complete owner"
eq 700 "$(mode "$LOCK")" "published lock directory is mode 0700"
eq 600 "$(mode "$LOCK/owner")" "published owner is mode 0600"
printf '456\n' | /usr/bin/python3 -I -B "$HELPER" "$LOCK" owner >/dev/null 2>&1; RC=$?
eq 17 "$RC" "rename-no-replace refuses a second publisher"
eq 123 "$(cat "$LOCK/owner")" "losing publisher cannot replace the owner"

echo "=== concurrent publication has one complete winner ==="
RACE="$TMP/race.lock"; : > "$TMP/results"
i=1
while [ "$i" -le 16 ]; do
  (printf '%s\n' "$i" | /usr/bin/python3 -I -B "$HELPER" "$RACE" owner >/dev/null 2>&1; echo "$?" >> "$TMP/results") &
  i=$((i+1))
done
wait
eq 1 "$(grep -c '^0$' "$TMP/results")" "exactly one concurrent publisher wins"
eq 15 "$(grep -c '^17$' "$TMP/results")" "every concurrent loser observes the existing lock"
case "$(cat "$RACE/owner")" in ''|*[!0-9]*) bad "winner owner is complete" ;; *) ok "winner owner is complete" ;; esac

echo "=== authority-bearing parent must be private and ACL-free ==="
UNSAFE_PARENT="$TMP/group-writable"; mkdir -m 770 "$UNSAFE_PARENT"
printf 'unsafe\n' | /usr/bin/python3 -I -B "$HELPER" "$UNSAFE_PARENT/no.lock" owner >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && [ ! -e "$UNSAFE_PARENT/no.lock" ] && ok "group-writable parent is refused before publication" || bad "group-writable parent is refused before publication"
if [ "$(uname -s)" = Darwin ]; then
  ACL_PARENT="$TMP/acl-parent"; mkdir -m 700 "$ACL_PARENT"
  chmod +a "everyone allow add_file,add_subdirectory,delete_child" "$ACL_PARENT"
  printf 'unsafe\n' | /usr/bin/python3 -I -B "$HELPER" "$ACL_PARENT/no.lock" owner >/dev/null 2>&1; RC=$?
  [ "$RC" -ne 0 ] && [ ! -e "$ACL_PARENT/no.lock" ] && ok "extended-ACL parent is refused before publication" || bad "extended-ACL parent is refused before publication"
  chmod -N "$ACL_PARENT"
fi

echo "=== exact exchange release is inode/token bound ==="
JSON_LOCK="$TMP/json.lock"
TOKEN="123e4567-e89b-42d3-a456-426614174000"
OWNER="$(printf '{"token":"%s","pid":123}\n' "$TOKEN")"
printf '%s\n' "$OWNER" | /usr/bin/python3 -I -B "$HELPER" "$JSON_LOCK" owner.json
read -r LD LI OD OI HASH <<EOF
$(/usr/bin/python3 -I -B - "$JSON_LOCK" <<'PY'
import hashlib,os,sys
p=sys.argv[1]; l=os.lstat(p); o=os.lstat(p+'/owner.json'); raw=open(p+'/owner.json','rb').read()
print(l.st_dev,l.st_ino,o.st_dev,o.st_ino,hashlib.sha256(raw).hexdigest())
PY
)
EOF
/usr/bin/python3 -I -B "$HELPER" release "$JSON_LOCK" owner.json "$LD" "$LI" "$OD" "$OI" "$HASH" "$TOKEN"
[ ! -e "$JSON_LOCK" ] && ok "exact release removes the exchanged owner inode" || bad "exact release removes the exchanged owner inode"
[ -z "$(find "$TMP" -maxdepth 1 \( -name '.json.lock.release.*' -o -name '.json.lock.released.*' \) -print -quit)" ] && ok "successful release leaves no tombstone artifact" || bad "successful release leaves no tombstone artifact"

PLAIN_LOCK="$TMP/plain.lock"
printf '123\n' | /usr/bin/python3 -I -B "$HELPER" "$PLAIN_LOCK" owner
read -r LD LI OD OI HASH <<EOF
$(/usr/bin/python3 -I -B - "$PLAIN_LOCK" <<'PY'
import hashlib,os,sys
p=sys.argv[1]; l=os.lstat(p); o=os.lstat(p+'/owner'); raw=open(p+'/owner','rb').read()
print(l.st_dev,l.st_ino,o.st_dev,o.st_ino,hashlib.sha256(raw).hexdigest())
PY
)
EOF
/usr/bin/python3 -I -B "$HELPER" release "$PLAIN_LOCK" owner "$LD" "$LI" "$OD" "$OI" "$HASH" -
[ ! -e "$PLAIN_LOCK" ] && ok "hash-bound release supports the plain lifecycle owner" || bad "hash-bound release supports the plain lifecycle owner"

printf '%s\n' "$OWNER" | /usr/bin/python3 -I -B "$HELPER" "$JSON_LOCK" owner.json
read -r LD LI OD OI HASH <<EOF
$(/usr/bin/python3 -I -B - "$JSON_LOCK" <<'PY'
import hashlib,os,sys
p=sys.argv[1]; l=os.lstat(p); o=os.lstat(p+'/owner.json'); raw=open(p+'/owner.json','rb').read()
print(l.st_dev,l.st_ino,o.st_dev,o.st_ino,hashlib.sha256(raw).hexdigest())
PY
)
EOF
mv "$JSON_LOCK" "$TMP/original.lock"
printf '%s\n' "$OWNER" | /usr/bin/python3 -I -B "$HELPER" "$JSON_LOCK" owner.json
/usr/bin/python3 -I -B "$HELPER" release "$JSON_LOCK" owner.json "$LD" "$LI" "$OD" "$OI" "$HASH" "$TOKEN" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "replacement lock inode refuses exact release" || bad "replacement lock inode refuses exact release"
[ -d "$JSON_LOCK" ] && [ -d "$TMP/original.lock" ] && ok "ABA refusal removes neither lock" || bad "ABA refusal removes neither lock"

echo "atomic-directory-lock: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
