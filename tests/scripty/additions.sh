#!/usr/bin/env bash
# Each case is independent, so a baseline run demonstrates every feature fails.
set -euo pipefail
if [[ $# == 0 ]]; then
  failures=0
  for feature in leaves site-index site-page join development forbid-subsections removed-skip scan-order; do
    if bash "$0" "$feature"; then echo "PASS: $feature"; else echo "FAIL: $feature"; failures=$((failures+1)); fi
  done
  [[ $failures == 0 ]]
  exit
fi
cd "$(dirname "$0")/../.."
REPO="$PWD"
ZIGAPAGOS="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ulimit -c 0
mkdir -p "$WORK/content" "$WORK/layouts" "$WORK/assets"
cat > "$WORK/zigapagos.ziggy" <<'SITE'
.site = .simple(.{
    .title = "Scripty additions",
    .host_url = "https://example.com",
    .content_dir_path = "content",
    .layouts_dir_path = "layouts",
    .assets_dir_path = "assets",
})
SITE
page() {
  local path=$1 title=$2 date=${3:-2020-01-01}
  mkdir -p "$(dirname "$WORK/content/$path")"
  printf '%s\n' '---' ".title = \"$title\"," ".date = .date(\"${date}T00:00:00\")," '.layout = "index.shtml",' '---' > "$WORK/content/$path"
}
page index.smd Home
printf '<p :text="$page.title"></p>\n' > "$WORK/layouts/index.shtml"
release() {
  (cd "$WORK" && "$ZIGAPAGOS" release --force --output=out "$@") >"$WORK/stdout" 2>"$WORK/stderr" || { cat "$WORK/stderr"; return 1; }
}
contains() { grep -qF -- "$1" "$WORK/out/index.html" || { cat "$WORK/out/index.html"; return 1; }; }
case "$1" in
leaves)
  # In each section, a subsection precedes its leaves in date order. The empty
  # section exhausts its stream without a leaf; older code returned it or ran
  # off the end while skipping it. Drafts and pre-epoch dates pin filtering
  # and avoid relying on the epoch as an initial maximum.
  page z/index.smd Z 2025-01-01
  page z/empty/index.smd Empty 2025-01-01
  page a/index.smd A 2024-01-01
  page z/new.smd New 2023-01-01
  page a/old.smd Old 1960-01-01
  page draft.smd Draft 2025-01-01
  sed -i '/.layout =/a .draft = true,' "$WORK/content/draft.smd"
  cat > "$WORK/layouts/index.shtml" <<'HTML'
<ul :loop="$site.page('').leaves()"><li :text="$loop.it.title"></li></ul>
<ol :loop="$site.page('').leaves(1)"><li :text="$loop.it.title"></li></ol>
<div id="zero" :loop="$site.page('').leaves(0)"><i :text="$loop.it.title"></i></div>
<div id="empty" :loop="$site.page('z/empty').leaves()"><i :text="$loop.it.title"></i></div>
<div id="leaf" :loop="$site.page('a/old').leaves()"><i :text="$loop.it.title"></i></div>
HTML
  release
  bun -e '
    const html = await Bun.file(process.argv[1]).text();
    const titles = [...html.matchAll(/<li>(.*?)<\/li>/g)].map(m => m[1]);
    if (JSON.stringify(titles) !== JSON.stringify(["New", "Old", "New"]) || /<i>/.test(html)) throw Error(html);
  ' "$WORK/out/index.html"
  # Empty overall tree and a huge signed integer limit must be safe too.
  rm -rf "$WORK/content/a" "$WORK/content/z" "$WORK/content/draft.smd"
  printf '<ul :loop="$page.leaves(9223372036854775807)"><li :text="$loop.it.title"></li></ul>' > "$WORK/layouts/index.shtml"
  release
  ! grep -q '<li>' "$WORK/out/index.html"
  ;;
site-index)
  printf '<p :text="$site.index().title.eql($site.page(\x27\x27).title).then(\x27true\x27, \x27false\x27)"></p>' > "$WORK/layouts/index.shtml"
  release
  contains '<p>true</p>'
  ;;
site-page)
  page foo/bar.smd Target
  cat > "$WORK/layouts/index.shtml" <<'HTML'
<p :text="$site.page('foo', 'bar').link().eql($site.page('foo/bar').link()).then('true', 'false')"></p>
<p :text="$site.page('', 'foo/', '', 'bar/').title"></p>
HTML
  release
  contains '<p>true</p>'
  contains '<p>Target</p>'
  cat > "$WORK/layouts/index.shtml" <<'HTML'
<a href="$site.page('future', 'post').link()">Future</a>
HTML
  release --allow-missing-pages
  contains 'href="/future/post/"'
  ;;
join)
  sed -i '/.layout =/a .tags = ["one", "two"],\n.custom = { "numbers": [1, 20, -3], "empty": [], "floats": [2.5] },' "$WORK/content/index.smd"
  cat > "$WORK/layouts/index.shtml" <<'HTML'
<p :text="$page.tags.join(', ')"></p>
<p :text="$page.custom.get('numbers').join('|')"></p>
<p :text="$page.custom.get('empty').join('separator')"></p>
<p :text="$page.custom.get('floats').join(',')"></p>
HTML
  release
  contains '<p>one, two</p>'
  contains '<p>1|20|-3</p>'
  contains '<p></p>'
  contains '<p>2.5</p>'
  ;;
development)
  cat > "$WORK/layouts/index.shtml" <<'HTML'
<p :text="$build.development.then('true', 'false')"></p>
HTML
  release
  contains '<p>false</p>'
  # Stop after the actual dev loop's initial render by deliberately failing
  # the custom rebuild wrapper. No listener or server teardown is needed.
  for reload in live no-live; do
    opts=()
    [[ $reload == live ]] || opts+=(--no-live-reload)
    rc=0
    { (cd "$WORK" && ZIGAPAGOS_DEV_BACKGROUND=0 "$ZIGAPAGOS" dev --ignore-lock --site=out "${opts[@]}" -- bash -c '"$1" release --force --output=out || exit; exit 23' _ "$ZIGAPAGOS") >"$WORK/dev.log" 2>&1 || rc=$?; } 2>>"$WORK/dev.log"
    # fatal.msg aborts in Debug and exits 1 in optimized builds.
    [[ $rc == 1 || $rc == 134 ]] || { cat "$WORK/dev.log"; exit 1; }
    grep -q "exit code 23" "$WORK/dev.log" || { cat "$WORK/dev.log"; exit 1; }
    contains '<p>true</p>'
  done
  # A marker inherited by read-only commands must not change their mode.
  cat > "$WORK/layouts/index.shtml" <<'HTML'
<div :if="$build.development"><p :text="$site.page('must-not-exist').title"></p></div>
HTML
  (cd "$WORK" && ZIGAPAGOS_DEVELOPMENT=1 "$ZIGAPAGOS" validate) >"$WORK/validate" 2>&1
  (cd "$WORK" && ZIGAPAGOS_DEVELOPMENT=1 "$ZIGAPAGOS" explain /) >"$WORK/explain" 2>&1
  ;;
forbid-subsections|removed-skip)
  if [[ $1 == forbid-subsections ]]; then
    sed -i '/.layout =/a .forbid_subsections = true,' "$WORK/content/index.smd"
    page foo/index.smd Child
    code=ZP_FORBIDDEN_SUBSECTION
    file=content/foo/index.smd
    row=2 col=10
    message="move this page to 'content/foo.smd'"
  else
    sed -i '/.layout =/a .skip_subdirs = false,' "$WORK/content/index.smd"
    code=ZP_REMOVED_SKIP_SUBDIRS
    file=content/index.smd
    row=5 col=1
    message="nearest replacement is 'forbid_subsections'"
  fi
  for format in text json; do
    rc=0
    (cd "$WORK" && "$ZIGAPAGOS" release --force --format="$format" --output=out) >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?
    [[ $rc == 1 ]] || { cat "$WORK/stderr"; exit 1; }
    bun -e '
      const [path, format, code, file, row, col, message] = process.argv.slice(1);
      const text = await Bun.file(path).text();
      if (format === "json") {
        const ds = text.trim().split("\n").map(l => JSON.parse(l));
        const d = ds.find(d => d.code === code);
        if (!d || d.file !== file || d.line !== +row || d.col !== +col || !d.message.includes(message)) throw Error(text);
      } else if (!text.includes(`${file}:${row}:${col}:`) || !text.includes(message)) throw Error(text);
    ' "$WORK/stderr" "$format" "$code" "$file" "$row" "$col" "$message"
  done
  if [[ $1 == forbid-subsections ]]; then
    mv "$WORK/content/foo/index.smd" "$WORK/content/foo.smd"
    rmdir "$WORK/content/foo"
    release
  fi
  ;;
scan-order)
  # Many sibling directories expose the LIFO/filesystem scan order. Invalid
  # layouts make it visible independently of date sorting and render workers.
  for names in 'a b c d e f g h i j k l m n o p' 'p o n m l k j i h g f e d c b a'; do
    rm -rf "$WORK/content"
    page index.smd Home
    for name in $names; do
      page "$name/index.smd" "$name"
      sed -i 's/index.shtml/missing.shtml/' "$WORK/content/$name/index.smd"
    done
    rc=0
    (cd "$WORK" && "$ZIGAPAGOS" release --format=json --force --output=out) >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?
    [[ $rc == 1 ]]
    bun -e '
      const ds = (await Bun.file(process.argv[1]).text()).trim().split("\n").map(l => JSON.parse(l));
      const files = ds.filter(d => d.code === "ZP_MISSING_LAYOUT").map(d => d.file);
      if (files.length !== 16 || JSON.stringify(files) !== JSON.stringify([...files].sort())) throw Error(JSON.stringify(files));
    ' "$WORK/stderr"
  done
  ;;
*) exit 2 ;;
esac
