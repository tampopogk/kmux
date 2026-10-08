#!/usr/bin/env bash
# End-to-end check: starts target/kmux.app on a private socket, drives it with
# target/release/kmux (the CLI), and checks the panes are really drawn (window pixels).
# Build first: scripts/build-kmux.sh && cargo build --release
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$repo_root/target/e2e"
mkdir -p "$out"
export KMUX_SOCKET="/tmp/kmux-e2e-$$.sock"
export KMUX_IGNORE_OCCLUSION=1 # render even if the window is covered
cli="$repo_root/target/release/kmux"

"$repo_root/target/kmux.app/Contents/MacOS/kmux" --bg >"$out/kmux.log" 2>&1 &
kmux_pid=$!
trap 'kill $kmux_pid 2>/dev/null || true; rm -f "$KMUX_SOCKET"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
for _ in $(seq 50); do [[ -S "$KMUX_SOCKET" ]] && break; sleep 0.1; done
[[ -S "$KMUX_SOCKET" ]] || fail "kmux did not open $KMUX_SOCKET"

# Every pane's marker text must be on screen with glyph pixels in each cell.
drawn() { # drawn NAME MARKER [COUNT]
  local snapshot
  snapshot="$(raw "{\"id\":1,\"cmd\":\"debug.snapshot\",\"args\":{\"path\":\"$out/$1.png\",\"marker\":\"$2\"}}")"
  python3 - "$snapshot" "${3:-0}" <<'PY' || fail "panes not drawn ($1): $snapshot"
import json, sys
panes = json.loads(sys.argv[1])["panes"]
assert int(sys.argv[2]) in (0, len(panes)), f"expected {sys.argv[2]} panes"
marked = [p for p in panes if p.get("marker", {}).get("found")]
assert marked and all(p["marker"]["inked"] == p["marker"]["glyphs"] > 0 for p in marked), panes
if sys.argv[2] != "0": assert len(marked) == len(panes), "every pane should show text"
PY
}
raw() { # one control-protocol request, printed as JSON
  python3 -c 'import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n"); print(s.makefile().readline().strip())' "$KMUX_SOCKET" "$1"
}
field() { python3 -c 'import json, sys; v = json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(json.dumps(v) if isinstance(v, (dict, list)) else v)' "$1"; }

# 1. A command in a new pane, a third of the window wide.
[[ "$("$cli" open --name e2e --split right --size 1/3 --cmd "printf 'KMUX E2E OK\n'; exec sleep 600")" == *"(e2e)"* ]] || fail "open did not print the pane name"
list="$("$cli" list --json)"
[[ "$(field windows.0.tabs.0.layout <<<"$list")" == '{"children": [{"pane": "p1", "size": "2/3"}, {"pane": "e2e", "size": "1/3"}], "split": "row"}' ]] \
  || fail "layout: $(field windows.0.tabs.0.layout <<<"$list")"
sleep 1.5
[[ "$(field panes.1.state <<<"$("$cli" list --json)")" == running ]] || fail "e2e is not running"

# 2. Both panes are drawn: the command's output, and the new shell's first line.
drawn two-panes "KMUX E2E OK"
drawn two-panes-shell "*" 2

# 3. A command that ends leaves its pane on screen, marked exited.
"$cli" open --name done --split down --cmd "echo bye" >/dev/null
sleep 1.5
[[ "$(field panes.2.state <<<"$("$cli" list --json)")" == exited ]] || fail "done did not exit"

# 4. Errors map to exit codes.
set +e
"$cli" close nope 2>/dev/null; [[ $? == 4 ]] || fail "unknown pane should exit 4"
"$cli" open --name e2e 2>/dev/null; [[ $? == 1 ]] || fail "a taken name should exit 1"
"$cli" zoom 2>/dev/null; [[ $? == 2 ]] || fail "missing arguments should exit 2"
set -e

# 5. Closing panes redistributes space; closing the last closes the window.
"$cli" close done >/dev/null
"$cli" close e2e >/dev/null
[[ "$(field windows.0.tabs.0.layout <<<"$("$cli" list --json)")" == '{"pane": "p1"}' ]] || fail "p1 should fill the window"
"$cli" close p1 >/dev/null
[[ "$(field windows <<<"$("$cli" list --json)")" == '[]' ]] || fail "the window should close with its last pane"

# 5b. send types a line into a terminal.
"$cli" open --name sh >/dev/null
sleep 1
"$cli" send sh "echo SENT-\$((40+2))"
sleep 1
drawn sent "SENT-42"

# 5c. A web pane opened before its server is up waits, then loads.
port=$((20000 + $$ % 20000))
"$cli" open web "localhost:$port" --name site --split down >/dev/null
sleep 1.5
web() { raw "{\"id\":1,\"cmd\":\"debug.web\",\"args\":{\"pane\":\"site\"}}"; }
mkdir -p "$out/site" && echo '<h1>KMUX WEB OK</h1>' > "$out/site/index.html"
(cd "$out/site" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server_pid=$!
trap 'kill $kmux_pid $server_pid 2>/dev/null || true; rm -f "$KMUX_SOCKET"' EXIT
for _ in $(seq 30); do [[ "$(field text <<<"$(web)")" == *"KMUX WEB OK"* ]] && break; sleep 0.5; done
[[ "$(field text <<<"$(web)")" == *"KMUX WEB OK"* ]] || fail "web pane never loaded: $(web)"
"$cli" navigate site "localhost:$port/missing" >/dev/null
[[ "$(field panes.1.url <<<"$("$cli" list --json)")" == "http://localhost:$port/missing" ]] || fail "navigate should update the url"

# Web history, only when asked for: back loads the previous page again.
echo '<h1>PAGE TWO</h1>' > "$out/site/two.html"
hw="$(field window <<<"$("$cli" open web "localhost:$port" --history --name hist --window new --json)")"
"$cli" navigate hist "localhost:$port/two.html" >/dev/null
"$cli" navigate hist --back >/dev/null
hist() { raw "{\"id\":1,\"cmd\":\"debug.web\",\"args\":{\"pane\":\"hist\"}}"; }
for _ in $(seq 20); do [[ "$(field text <<<"$(hist)")" == *"KMUX WEB OK"* ]] && break; sleep 0.25; done
[[ "$(field text <<<"$(hist)")" == *"KMUX WEB OK"* ]] || fail "back should show the first page again: $(hist)"
"$cli" navigate hist --forward >/dev/null
for _ in $(seq 20); do [[ "$(field text <<<"$(hist)")" == *"PAGE TWO"* ]] && break; sleep 0.25; done
[[ "$(field text <<<"$(hist)")" == *"PAGE TWO"* ]] || fail "forward should show page two: $(hist)"
"$cli" navigate site --back >/dev/null 2>&1 && fail "a pane without --history should refuse --back"
"$cli" close --window "$hw" >/dev/null

# 5d. Layout commands move real views: swap, resize, arrange.
"$cli" move sh --to site >/dev/null
"$cli" arrange '{"split":"row","children":[{"pane":"site","size":"1/4"},{"pane":"sh"}]}' >/dev/null
[[ "$(field windows.0.tabs.0.layout <<<"$("$cli" list --json)")" == '{"children": [{"pane": "site", "size": "1/4"}, {"pane": "sh", "size": "3/4"}], "split": "row"}' ]] \
  || fail "arrange: $(field windows.0.tabs.0.layout <<<"$("$cli" list --json)")"
"$cli" resize site 1/2 >/dev/null
drawn arranged "*"
"$cli" close --window w2 >/dev/null

# 6. Keyboard shortcuts, pressed through AppKit's key-event path.
key() { raw "{\"id\":1,\"cmd\":\"debug.key\",\"args\":{\"key\":\"$1\"}}" >/dev/null; sleep 0.4; }
state() { "$cli" list --json; }
"$cli" open --name k1 >/dev/null
key "cmd+d"
key "cmd+shift+d"
layout="$(field windows.0.tabs.0.layout <<<"$(state)")"
[[ "$layout" == '{"children": [{"pane": "k1", "size": "1/2"}, {"children": [{"pane": "p8", "size": "1/2"}, {"pane": "p9", "size": "1/2"}], "size": "1/2", "split": "column"}], "split": "row"}' ]] \
  || fail "cmd+d / cmd+shift+d layout: $layout"
[[ "$(field windows.0.focused <<<"$(state)")" == p9 ]] || fail "the new pane should take focus"
key "cmd+]"; [[ "$(field windows.0.focused <<<"$(state)")" == k1 ]] || fail "cmd+] should wrap to k1"
key "cmd+["; [[ "$(field windows.0.focused <<<"$(state)")" == p9 ]] || fail "cmd+[ should wrap back to p9"
key "cmd+shift+return"; [[ "$(field windows.0.zoomed <<<"$(state)")" == p9 ]] || fail "cmd+shift+return should zoom"
key "cmd+["; [[ "$(field windows.0.zoomed <<<"$(state)")" == None ]] || fail "moving focus should unzoom"
sleep 1
drawn three-panes "*" 3
key "cmd+t"; [[ "$(field windows.0.tabs <<<"$(state)" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" == 2 ]] || fail "cmd+t should add a tab"
key "cmd+shift+["; [[ "$(field windows.0.tabs.0.active <<<"$(state)")" == True ]] || fail "cmd+shift+[ should go to the first tab"
key "cmd+shift+]"; [[ "$(field windows.0.tabs.1.active <<<"$(state)")" == True ]] || fail "cmd+shift+] should go to the second tab"
# Double-click a tab to rename it: Enter saves, Escape cancels.
tab2="$(field windows.0.tabs.1.id <<<"$(state)")"
raw "{\"id\":1,\"cmd\":\"debug.click\",\"args\":{\"tab\":\"$tab2\",\"clicks\":2}}" >/dev/null; sleep 0.3
for k in w e b return; do key "$k"; done
[[ "$(field windows.0.tabs.1.title <<<"$(state)")" == web ]] || fail "double-click rename should name the tab web, got $(field windows.0.tabs.1.title <<<"$(state)")"
raw "{\"id\":1,\"cmd\":\"debug.click\",\"args\":{\"tab\":\"$tab2\",\"clicks\":2}}" >/dev/null; sleep 0.3
for k in x escape; do key "$k"; done
[[ "$(field windows.0.tabs.1.title <<<"$(state)")" == web ]] || fail "escape should keep the name"
key "cmd+n"; [[ "$(field windows.1.key <<<"$(state)")" == True ]] || fail "cmd+n should open a key window"
key "cmd+\`"; [[ "$(field windows.0.key <<<"$(state)")" == True ]] || fail "cmd+\` should cycle to the first window"
key "cmd+w"; [[ "$(field windows.0.tabs <<<"$(state)" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" == 1 ]] || fail "cmd+w should close the only pane in tab 2"
key "cmd+shift+w"
[[ "$(field windows <<<"$(state)" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" == 1 ]] || fail "cmd+shift+w should close the window"

# Menus: every action in the spec's table (§5) has a menu item.
menus="$(raw '{"id":1,"cmd":"debug.menu"}')"
for item in "Split Right" "Split Down" "Open URL…" "Zoom" "Move Pane to New Window" "Restart" "Close Pane" "New Tab" \
            "New Window" "Close Window" "Move Tab to New Window" "Next Window" "New Instance"; do
  [[ "$menus" == *"\"item\": \"$item\""* || "$menus" == *"\"item\":\"$item\""* ]] || fail "no menu item \"$item\""
done

# 7. Dragging: dividers snap, the ⋯ grip moves panes, tabs reorder and tear off.
drag() { last_drag="$1 → $(raw "{\"id\":1,\"cmd\":\"debug.drag\",\"args\":$1}")"; sleep 0.3; }
win() { # win ID FIELD: a field of one window in `kmux list --json`
  "$cli" list --json | python3 -c 'import json, sys
w = next(w for w in json.load(sys.stdin)["windows"] if w["id"] == sys.argv[1])
v = w
for k in sys.argv[2].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(json.dumps(v, sort_keys=True))' "$1" "$2"
}
count_windows() { "$cli" list --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["windows"]))'; }
dw="$(field window <<<"$("$cli" open --window new --name da --json)")"
"$cli" open --window "$dw" --name db --split right >/dev/null
drag '{"divider":"da","at":0.26}'
[[ "$(win "$dw" tabs.0.layout)" == '{"children": [{"pane": "da", "size": "1/4"}, {"pane": "db", "size": "3/4"}], "split": "row"}' ]] \
  || fail "divider drag should snap to 1/4: $(win "$dw" tabs.0.layout)"
drag '{"pane":"da","to":{"pane":"db","x":0.5,"y":0.95}}'
[[ "$(win "$dw" tabs.0.layout)" == '{"children": [{"pane": "db", "size": "1/2"}, {"pane": "da", "size": "1/2"}], "split": "column"}' ]] \
  || fail "dropping on the bottom edge should dock below: $(win "$dw" tabs.0.layout) ($last_drag)"
drag '{"pane":"da","to":{"pane":"db","x":0.5,"y":0.5}}'
[[ "$(win "$dw" tabs.0.layout)" == '{"children": [{"pane": "da", "size": "1/2"}, {"pane": "db", "size": "1/2"}], "split": "column"}' ]] \
  || fail "dropping in the middle should swap: $(win "$dw" tabs.0.layout)"
drag "{\"pane\":\"da\",\"to\":{\"plus\":\"$dw\"}}"
[[ "$(win "$dw" tabs.1.layout)" == '{"pane": "da"}' ]] || fail "dropping on + should open a new tab: $(win "$dw" tabs)"
first="$(win "$dw" tabs.0.id | tr -d '"')"; second="$(win "$dw" tabs.1.id | tr -d '"')"
drag "{\"tab\":\"$second\",\"to\":{\"tab\":\"$first\"}}"
[[ "$(win "$dw" tabs.0.id | tr -d '"')" == "$second" ]] || fail "dragging a tab before another should reorder: $(win "$dw" tabs)"
before="$(count_windows)"
drag "{\"tab\":\"$second\",\"to\":{\"outside\":true}}"
[[ "$(count_windows)" == $((before + 1)) ]] || fail "dragging a tab outside kmux should open a window"
drag '{"pane":"db","to":{"outside":true}}'
[[ "$(count_windows)" == $((before + 1)) ]] || fail "the last pane leaving its window should move the window, not add one"
sleep 0.5
drawn dragged "*"

# 8. Instances: a second kmux beside this one, with its own socket and
# windows. kmux run inside one of its panes controls that instance.
other="e2e$$"
other_socket="$HOME/Library/Application Support/kmux/kmux-$other.sock"
env -u KMUX_SOCKET "$repo_root/target/kmux.app/Contents/MacOS/kmux" --bg --instance "$other" >"$out/kmux-$other.log" 2>&1 &
other_pid=$!
trap 'kill $kmux_pid $server_pid $other_pid 2>/dev/null || true; rm -f "$KMUX_SOCKET"' EXIT
for _ in $(seq 50); do [[ -S "$other_socket" ]] && break; sleep 0.1; done
[[ -S "$other_socket" ]] || fail "instance $other did not open $other_socket"
[[ "$(field instance <<<"$("$cli" --instance "$other" capabilities --json)")" == "$other" ]] || fail "capabilities should name the instance"
[[ "$(env -u KMUX_SOCKET "$cli" instances)" == *" $other "* ]] || fail "kmux instances should list $other: $(env -u KMUX_SOCKET "$cli" instances)"
"$cli" --instance "$other" open --name parent --cmd "$cli open --name child --split down --no-wait; exec sleep 600" >/dev/null
for _ in $(seq 50); do [[ "$("$cli" --instance "$other" list)" == *child* ]] && break; sleep 0.1; done
[[ "$("$cli" --instance "$other" list)" == *child* ]] || fail "kmux inside a pane should reach its own instance"
[[ "$("$cli" list)" != *child* ]] || fail "the child pane went to the wrong instance"
kill "$other_pid"; wait "$other_pid" 2>/dev/null || true
[[ ! -e "$other_socket" ]] || fail "instance $other should remove its socket when it quits"

# 8b. Markdown panes: rendered with diagrams, live reload, links, a missing file.
mkdir -p "$out/docs"
cat > "$out/docs/spec.md" <<'MD'
# KMUX MD OK

Some **bold** text and a table:

| a | b |
|---|---|
| 1 | 2 |

```mermaid
flowchart LR
    A[cart] --> B[paid]
```

See [the other page](other.md).
MD
echo '# OTHER PAGE' > "$out/docs/other.md"
mdw="$(field window <<<"$("$cli" open md "$out/docs/spec.md" --name doc --window new --json)")"
mdtext() { field text <<<"$(raw "{\"id\":1,\"cmd\":\"debug.web\",\"args\":{\"pane\":\"doc\"}}")"; }
for _ in $(seq 40); do [[ "$(mdtext)" == *"KMUX MD OK"* ]] && break; sleep 0.25; done
[[ "$(mdtext)" == *"KMUX MD OK"* ]] || fail "markdown pane did not render: $(mdtext)"
[[ "$(mdtext)" != *"flowchart LR"* ]] || fail "the mermaid block should be drawn, not shown as text"
[[ "$(mdtext)" == *cart*paid* && "$(mdtext)" != *"Diagram error"* ]] || fail "the mermaid diagram should be drawn: $(mdtext)"
sleep 1
raw "{\"id\":1,\"cmd\":\"debug.snapshot\",\"args\":{\"path\":\"$out/markdown.png\"}}" >/dev/null
echo "Edited on disk" >> "$out/docs/spec.md"
for _ in $(seq 20); do [[ "$(mdtext)" == *"Edited on disk"* ]] && break; sleep 0.25; done
[[ "$(mdtext)" == *"Edited on disk"* ]] || fail "markdown pane should reload when the file changes"
"$cli" navigate doc "$out/docs/other.md" >/dev/null
for _ in $(seq 20); do [[ "$(mdtext)" == *"OTHER PAGE"* ]] && break; sleep 0.25; done
[[ "$(mdtext)" == *"OTHER PAGE"* ]] || fail "navigate should show the other file: $(mdtext)"
missing="$("$cli" open md "$out/docs/nope.md" --window "$mdw" 2>&1)" && fail "a missing file should fail"
[[ "$missing" == *"No such file"* ]] || fail "a missing file should say so: $missing"
"$cli" close --window "$mdw" >/dev/null

# 9. iOS panes: the simulator's screen in a pane, with taps and Home.
# Boots a simulator if none is (it stays booted). KMUX_E2E_IOS=0 skips this.
if [[ "${KMUX_E2E_IOS:-1}" != 0 ]] && xcrun simctl list devices available 2>/dev/null | grep -q iPhone; then
  bad="$("$cli" open ios --app com.apple.Preferences --device "No Such Phone" 2>&1)" && fail "an unknown device should fail"
  [[ "$bad" == *'Unknown device "No Such Phone"'*Available:* ]] || fail "an unknown device should list the available ones: $bad"
  "$cli" open ios --name phone --app com.apple.Preferences --window new >/dev/null || fail "the ios pane did not start"
  phone="$(field pane.id <<<"$("$cli" restart phone --json)")"
  [[ "$(field width <<<"$(raw "{\"id\":1,\"cmd\":\"debug.ios\",\"args\":{\"pane\":\"phone\"}}")")" != 0 ]] || fail "the ios pane shows no screen"
  sleep 3
  ink() { field panes.0.ink <<<"$(raw "{\"id\":1,\"cmd\":\"debug.snapshot\",\"args\":{\"path\":\"$out/ios-$1.png\"}}")"; }
  settings="$(ink settings)"
  python3 -c "import sys; sys.exit(float(sys.argv[1]) < 0.05)" "$settings" || fail "the ios pane is blank (ink $settings)"
  raw "{\"id\":1,\"cmd\":\"debug.ios\",\"args\":{\"pane\":\"phone\",\"home\":true}}" >/dev/null
  sleep 2
  [[ "$(ink home)" != "$settings" ]] || fail "Home did not change the screen"
  "$cli" close "$phone" >/dev/null
fi

echo "e2e OK (snapshot: $out/two-panes.png)"
