#!/bin/sh
# Inspect before running. This bootstrap never elevates privileges or downloads
# preparation models; host placement remains incomplete until provision succeeds.
set -eu

origin=${WORKSPACE_PUBLIC_ORIGIN:-https://cafe01.github.io/workspace}
release_id=''
fail() { printf 'workspace install: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: sh install-workspace.sh [--release RELEASE-ID]\n' >&2; exit 2; }
install_fault=${WORKSPACE_INSTALL_FAULT:-}
case "$install_fault" in
  ''|download|extraction|pre-activation|pointer-switch|post-activation-probe) ;;
  *) fail 'invalid WORKSPACE_INSTALL_FAULT selector' ;;
esac
inject_fault() {
  if [ "$install_fault" = "$1" ]; then
    fail "injected update fault at $1"
  fi
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --release) [ "$#" -ge 2 ] || usage; release_id=$2; shift 2 ;;
    *) usage ;;
  esac
done

os=$(uname -s); cpu=$(uname -m)
case "$os:$cpu" in
  Darwin:arm64) platform=macos; architecture=arm64; app_home="${HOME:-}/Library/Application Support/Workspace/application" ;;
  Linux:x86_64|Linux:amd64) platform=linux; architecture=x64; app_home="${XDG_DATA_HOME:-${HOME:-}/.local/share}/Workspace/application" ;;
  *) printf 'workspace install: unsupported platform %s %s (supported: macOS arm64, Ubuntu x64)\n' "$os" "$cpu" >&2; exit 2 ;;
esac
[ -n "${HOME:-}" ] && [ "${HOME#/}" != "$HOME" ] || fail 'HOME must be an absolute user-owned path'
command -v curl >/dev/null 2>&1 || fail 'curl is required by this bootstrap'
command -v tar >/dev/null 2>&1 || fail 'tar is required by this bootstrap'
command -v cmp >/dev/null 2>&1 || fail 'cmp is required by this bootstrap'
if command -v shasum >/dev/null 2>&1; then hash_cmd='shasum -a 256'; elif command -v sha256sum >/dev/null 2>&1; then hash_cmd=sha256sum; else fail 'a SHA-256 command is required'; fi

# A deliberately restricted JSON parser: no jq, Python, Dart, escaped strings,
# duplicate keys, or ambiguous values. It emits path/type/value rows consumed by
# the closed-shape validators below.
json_flatten() {
  awk '
  function die(message) { print "noncanonical JSON: " message > "/dev/stderr"; failed=1; exit 1 }
  function skip_space() { while (position <= length(source) && substr(source, position, 1) ~ /[ \t\r\n]/) position++ }
  function parse_string(    character, result) {
    if (substr(source, position, 1) != "\"") die("expected string")
    position++
    while (position <= length(source)) {
      character=substr(source, position, 1); position++
      if (character == "\"") return result
      if (character == "\\" || character == "\t" || character == "\r" || character == "\n") die("escaped or control string content")
      result=result character
    }
    die("unterminated string")
  }
  function emit(path, type, value) { print path "\t" type "\t" value }
  function parse_value(path,    character, start, word) {
    skip_space(); character=substr(source, position, 1)
    if (character == "{") { parse_object(path); return }
    if (character == "[") { parse_array(path); return }
    if (character == "\"") { emit(path, "string", parse_string()); return }
    if (character ~ /[0-9]/) {
      start=position; while (substr(source, position, 1) ~ /[0-9]/) position++
      emit(path, "number", substr(source, start, position-start)); return
    }
    word=substr(source, position, 4)
    if (word == "null") { position+=4; emit(path, "null", ""); return }
    if (word == "true") { position+=4; emit(path, "boolean", "true"); return }
    if (substr(source, position, 5) == "false") { position+=5; emit(path, "boolean", "false"); return }
    die("unsupported value at byte " position)
  }
  function parse_object(path,    key, full, character) {
    position++; emit(path, "object", ""); skip_space()
    if (substr(source, position, 1) == "}") { position++; return }
    while (1) {
      key=parse_string(); full=(path == "$" ? key : path "." key)
      if (seen[full]++) die("duplicate field " full)
      skip_space(); if (substr(source, position, 1) != ":") die("expected colon"); position++
      parse_value(full); skip_space(); character=substr(source, position, 1); position++
      if (character == "}") return
      if (character != ",") die("expected object separator")
      skip_space()
    }
  }
  function parse_array(path,    item_index, character) {
    position++; emit(path, "array", ""); skip_space(); item_index=0
    if (substr(source, position, 1) == "]") { position++; return }
    while (1) {
      parse_value(path "[" item_index "]"); item_index++; skip_space(); character=substr(source, position, 1); position++
      if (character == "]") return
      if (character != ",") die("expected array separator")
      skip_space()
    }
  }
  { source=source $0 "\n" }
  END { if (failed) exit 1; position=1; parse_value("$"); skip_space(); if (position <= length(source)) die("trailing content") }
  ' "$1"
}

json_value() {
  value=$(awk -F '\t' -v wanted="$2" -v type="$3" '$1 == wanted && $2 == type { count++; value=$3 } END { if (count != 1) exit 1; print value }' "$1") || fail "missing or ambiguous public field $2"
  printf '%s' "$value"
}

validate_catalog() {
  awk -F '\t' -v requested="$2" '
  function bad(message) { print "catalog " message > "/dev/stderr"; failed=1 }
  function index_of(path, result) { result=path; sub(/^releases\[/,"",result); sub(/\].*$/,"",result); return result+0 }
  function key_of(path, result) { result=path; sub(/^releases\[[0-9]+\]\./,"",result); return result }
  function digest(value) { return length(value)==64 && value !~ /[^0-9a-f]/ }
  function immutable(value,id) { return value ~ /^https:\/\// && value !~ /\/latest\// && value !~ /[?#]/ && index(value,id)>0 }
  {
    path=$1; type=$2; value=$3
    if (path == "$" && type == "object") next
    if (path == "product" && type == "object") next
    if (path == "releases" && type == "array") { releases_array=1; next }
    if (path ~ /^releases\[[0-9]+\]$/ && type == "object") { objects[index_of(path)]=1; next }
    if (path ~ /^releases\[[0-9]+\]\.(release_id|version|status|release_url|descriptor_url|descriptor_sha256|status_changed_at|withdrawal_reason)$/ && type == "string") { i=index_of(path); release[i,key_of(path)]=value; next }
    if (path ~ /^(schema|current_release_id|updated_at)$/ && (type == "string" || (path == "current_release_id" && type == "null"))) { root[path]=value; root_type[path]=type; next }
    if (path ~ /^product\.(product_id|display_name|channel|public_url|support_url)$/ && type == "string") { product[path]=value; next }
    bad("has unknown field or wrong type: " path)
  }
  END {
    if (root["schema"] != "product.delivery/release-catalog/v1" || !releases_array) bad("has invalid schema")
    if (product["product.product_id"] != "workspace" || product["product.display_name"] != "Workspace" || product["product.channel"] != "preview") bad("does not describe Workspace preview")
    if (product["product.public_url"] !~ /^https:\/\// || product["product.support_url"] !~ /^https:\/\// || root["updated_at"] == "") bad("has incomplete product facts")
    for (i in objects) {
      required="release_id version status release_url descriptor_url descriptor_sha256 status_changed_at"; count=split(required, fields, " ")
      for (j=1;j<=count;j++) if (release[i,fields[j]] == "") bad("release entry is incomplete")
      id=release[i,"release_id"]
      if (id !~ /^[a-z0-9][a-z0-9._-]+$/ || ids[id]++) bad("has invalid or duplicate release id")
      if (!immutable(release[i,"release_url"],id) || !immutable(release[i,"descriptor_url"],id) || !digest(release[i,"descriptor_sha256"])) bad("has mutable or invalid release reference")
      status=release[i,"status"]
      if (status != "current" && status != "superseded" && status != "withdrawn") bad("has invalid release status")
      if (status == "withdrawn" && release[i,"withdrawal_reason"] == "") bad("withdrawn release lacks reason")
      if (status != "withdrawn" && release[i,"withdrawal_reason"] != "") bad("recommended release carries withdrawal reason")
      if (status == "current") { current_count++; current_id=id }
      selected=(requested == "" ? root["current_release_id"] : requested)
      if (id == selected) { selected_count++; selected_index=i; selected_status=status }
    }
    if (root_type["current_release_id"] == "null") { if (current_count != 0) bad("null current id disagrees with status") }
    else if (current_count != 1 || current_id != root["current_release_id"]) bad("current id disagrees with status")
    if (requested == "" && root_type["current_release_id"] == "null" && current_count == 0) {
      if (failed) exit 1
      print -1
      exit 0
    }
    if (selected_count != 1 || selected_status == "withdrawn") bad("selected release is absent, ambiguous, or withdrawn")
    if (failed) exit 1
    print selected_index
  }' "$1"
}

validate_descriptor() {
  awk -F '\t' -v expected_id="$2" -v expected_version="$3" -v expected_release_url="$4" -v wanted_target="$5" '
  function bad(message) { print "descriptor " message > "/dev/stderr"; failed=1 }
  function index_of(path, result) { result=path; sub(/^artifacts\[/,"",result); sub(/\].*$/,"",result); return result+0 }
  function key_of(path, result) { result=path; sub(/^artifacts\[[0-9]+\]\./,"",result); return result }
  function digest(value) { return length(value)==64 && value !~ /[^0-9a-f]/ }
  function immutable(value,id) { return value ~ /^https:\/\// && value !~ /\/latest\// && value !~ /[?#]/ && index(value,id)>0 }
  {
    path=$1; type=$2; value=$3
    if (path == "$" && type == "object") next
    if (path == "evidence" && type == "object") next
    if (path == "artifacts" && type == "array") { artifacts_array=1; next }
    if (path ~ /^artifacts\[[0-9]+\]$/ && type == "object") { objects[index_of(path)]=1; next }
    if (path ~ /^artifacts\[[0-9]+\]\.(artifact_id|platform|architecture|system_requirements|filename|url|sha256|archive_format|content_manifest_sha256|application_layout|runtime_compatibility_id)$/ && type == "string") { i=index_of(path); artifact[i,key_of(path)]=value; next }
    if (path ~ /^artifacts\[[0-9]+\]\.size_bytes$/ && type == "number") { i=index_of(path); artifact[i,"size_bytes"]=value; next }
    if (path ~ /^(schema|product_id|display_name|channel|release_id|version|source_revision|created_at|release_url)$/ && type == "string") { root[path]=value; next }
    if (path ~ /^evidence\.(url|sha256)$/ && type == "string") { evidence[path]=value; next }
    bad("has unknown field or wrong type: " path)
  }
  END {
    if (root["schema"] != "product.delivery/product-release/v1" || !artifacts_array) bad("has invalid schema")
    if (root["product_id"] != "workspace" || root["display_name"] != "Workspace" || root["channel"] != "preview") bad("does not describe Workspace preview")
    if (root["release_id"] != expected_id || root["version"] != expected_version || root["release_url"] != expected_release_url) bad("identity disagrees with catalog")
    if (root["source_revision"] !~ /^[0-9a-f]+$/ || length(root["source_revision"]) != 40 || root["created_at"] == "") bad("has invalid immutable identity")
    if (!immutable(root["release_url"],expected_id) || !immutable(evidence["evidence.url"],expected_id) || !digest(evidence["evidence.sha256"])) bad("has invalid immutable references")
    for (i in objects) {
      required="artifact_id platform architecture system_requirements filename url sha256 size_bytes archive_format content_manifest_sha256 application_layout runtime_compatibility_id"; count=split(required, fields, " ")
      for (j=1;j<=count;j++) if (artifact[i,fields[j]] == "") bad("artifact is incomplete")
      id=artifact[i,"artifact_id"]; target=artifact[i,"platform"] "-" artifact[i,"architecture"]
      if (artifact_ids[id]++ || targets[target]++) bad("has duplicate artifact id or target")
      if (artifact[i,"filename"] ~ /[\\\/]/ || index(artifact[i,"filename"],expected_id)==0 || index(artifact[i,"filename"],target)==0) bad("artifact filename is not identity bound")
      if (!immutable(artifact[i,"url"],expected_id) || artifact[i,"url"] !~ ("/" artifact[i,"filename"] "$") || !digest(artifact[i,"sha256"]) || !digest(artifact[i,"content_manifest_sha256"])) bad("artifact has invalid immutable reference")
      if ((artifact[i,"platform"] == "windows") != (artifact[i,"archive_format"] == "zip")) bad("artifact format disagrees with platform")
      if (artifact[i,"application_layout"] != "workspace/application-v1") bad("artifact layout is unsupported")
      if (target == wanted_target) { selected_count++; selected_index=i }
    }
    if (selected_count != 1) bad("does not contain selected target exactly once")
    if (failed) exit 1
    print selected_index
  }' "$1"
}

validate_manifest() {
  awk -F '\t' -v release_id="$2" -v version="$3" -v revision="$4" -v platform="$5" -v architecture="$6" -v runtime="$7" '
  function bad(message) { print "content manifest " message > "/dev/stderr"; failed=1 }
  function index_of(path, result) { result=path; sub(/^files\[/,"",result); sub(/\].*$/,"",result); return result+0 }
  function key_of(path, result) { result=path; sub(/^files\[[0-9]+\]\./,"",result); return result }
  function digest(value) { return length(value)==64 && value !~ /[^0-9a-f]/ }
  {
    path=$1; type=$2; value=$3
    if (path == "$" && type == "object") next
    if (path == "identity" && type == "object") next
    if (path == "files" && type == "array") { files_array=1; next }
    if (path ~ /^files\[[0-9]+\]$/ && type == "object") { objects[index_of(path)]=1; next }
    if (path ~ /^files\[[0-9]+\]\.(path|sha256)$/ && type == "string") { i=index_of(path); file[i,key_of(path)]=value; next }
    if (path ~ /^files\[[0-9]+\]\.size_bytes$/ && type == "number") { i=index_of(path); file[i,"size_bytes"]=value; next }
    if (path ~ /^(schema|application_layout)$/ && type == "string") { root[path]=value; next }
    if (path ~ /^identity\.(product_id|version|release_id|source_revision|platform|architecture|runtime_compatibility_id)$/ && type == "string") { identity[path]=value; next }
    bad("has unknown field or wrong type: " path)
  }
  END {
    if (root["schema"] != "workspace.application-content/v1" || root["application_layout"] != "workspace/application-v1" || !files_array) bad("has invalid schema or layout")
    if (identity["identity.product_id"] != "workspace" || identity["identity.version"] != version || identity["identity.release_id"] != release_id || identity["identity.source_revision"] != revision || identity["identity.platform"] != platform || identity["identity.architecture"] != architecture || identity["identity.runtime_compatibility_id"] != runtime) bad("identity disagrees with descriptor")
    for (i in objects) {
      path=file[i,"path"]
      if (path == "" || file[i,"size_bytes"] == "" || !digest(file[i,"sha256"]) || path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/ || paths[path]++) bad("has invalid or duplicate file entry")
      if (path == "cli/bundle/bin/workspace") executable=1
    }
    if (length(objects) == 0 || !executable) bad("does not name the application executable")
    if (failed) exit 1
    for (i in objects) print i
  }' "$1"
}

root=$(dirname "$app_home"); releases="$app_home/releases"; pointer="$app_home/active-release"; previous="$app_home/previous-release"; shim_dir="$HOME/.local/bin"; shim="$shim_dir/workspace"
mkdir -p "$root" "$releases" "$shim_dir" || fail 'could not create user-owned application locations'
tmp=$(mktemp -d "$root/.workspace-download.XXXXXX") || fail 'could not create download staging directory'
stage=''
cleanup_staging() { [ -z "$stage" ] || rm -rf "$stage"; rm -rf "$tmp"; }
trap cleanup_staging EXIT HUP INT TERM

catalog="$tmp/catalog.json"
curl --fail --location --silent --show-error "$origin/releases/catalog.json" -o "$catalog" || fail 'could not obtain the public release catalog'
catalog_flat="$tmp/catalog.flat"; json_flatten "$catalog" > "$catalog_flat" || fail 'public release catalog is not canonical JSON'
selected=$(validate_catalog "$catalog_flat" "$release_id") || fail 'public release catalog failed closed validation'
[ "$selected" != -1 ] || fail 'no current Workspace release is available; check the public product page or support guidance'
[ -n "$release_id" ] || release_id=$(json_value "$catalog_flat" current_release_id string)
catalog_version=$(json_value "$catalog_flat" "releases[$selected].version" string)
catalog_release_url=$(json_value "$catalog_flat" "releases[$selected].release_url" string)
descriptor_url=$(json_value "$catalog_flat" "releases[$selected].descriptor_url" string)
descriptor_hash=$(json_value "$catalog_flat" "releases[$selected].descriptor_sha256" string)

descriptor_file="$tmp/product-release.json"
curl --fail --location --silent --show-error "$descriptor_url" -o "$descriptor_file" || fail 'could not obtain immutable release information'
actual_descriptor_hash=$(eval "$hash_cmd \"$descriptor_file\"" | awk '{print $1}')
[ "$actual_descriptor_hash" = "$descriptor_hash" ] || fail 'release descriptor SHA-256 verification failed'
descriptor_flat="$tmp/descriptor.flat"; json_flatten "$descriptor_file" > "$descriptor_flat" || fail 'release descriptor is not canonical JSON'
artifact_index=$(validate_descriptor "$descriptor_flat" "$release_id" "$catalog_version" "$catalog_release_url" "$platform-$architecture") || fail 'release descriptor failed closed validation'

field_path="artifacts[$artifact_index]"
filename=$(json_value "$descriptor_flat" "$field_path.filename" string)
url=$(json_value "$descriptor_flat" "$field_path.url" string)
expected_hash=$(json_value "$descriptor_flat" "$field_path.sha256" string)
expected_size=$(json_value "$descriptor_flat" "$field_path.size_bytes" number)
format=$(json_value "$descriptor_flat" "$field_path.archive_format" string)
manifest_hash=$(json_value "$descriptor_flat" "$field_path.content_manifest_sha256" string)
runtime_id=$(json_value "$descriptor_flat" "$field_path.runtime_compatibility_id" string)
source_revision=$(json_value "$descriptor_flat" source_revision string)

archive="$tmp/$filename"
curl --fail --location --silent --show-error "$url" -o "$archive" || fail 'archive download failed'
inject_fault download
[ "$(wc -c < "$archive" | tr -d ' ')" = "$expected_size" ] || fail 'archive size verification failed; keep the previous host and retry'
actual_hash=$(eval "$hash_cmd \"$archive\"" | awk '{print $1}')
[ "$actual_hash" = "$expected_hash" ] || fail 'archive SHA-256 verification failed; keep the previous host and retry'
[ "$format" = tar.gz ] || fail "unsupported archive format $format"
tar -tzf "$archive" > "$tmp/archive-members" || fail 'archive directory cannot be read'
awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ || $0 !~ /^workspace\/application-v1\// { exit 1 }' "$tmp/archive-members" || fail 'archive contains an unsafe or unexpected path'
tar -tvzf "$archive" | awk '$1 !~ /^[-d]/ { exit 1 }' || fail 'archive contains links or unsupported member types'

stage="$releases/.stage-$release_id-$$"; mkdir "$stage" || fail 'could not stage release'
tar -xzf "$archive" -C "$stage" || fail 'archive extraction failed'
inject_fault extraction
host="$stage/workspace/application-v1"; manifest="$host/content-manifest.json"
[ -x "$host/cli/bundle/bin/workspace" ] && [ -f "$manifest" ] || fail 'archive layout verification failed'
[ -z "$(find "$host" -type l -print -quit)" ] || fail 'archive layout contains a symbolic link'
actual_manifest_hash=$(eval "$hash_cmd \"$manifest\"" | awk '{print $1}')
[ "$actual_manifest_hash" = "$manifest_hash" ] || fail 'content manifest SHA-256 verification failed'
manifest_flat="$tmp/manifest.flat"; json_flatten "$manifest" > "$manifest_flat" || fail 'content manifest is not canonical JSON'
manifest_indexes=$(validate_manifest "$manifest_flat" "$release_id" "$catalog_version" "$source_revision" "$platform" "$architecture" "$runtime_id") || fail 'content manifest failed closed validation'

manifest_paths="$tmp/manifest-paths"; : > "$manifest_paths"
for index in $manifest_indexes; do
  item_path=$(json_value "$manifest_flat" "files[$index].path" string)
  item_hash=$(json_value "$manifest_flat" "files[$index].sha256" string)
  item_size=$(json_value "$manifest_flat" "files[$index].size_bytes" number)
  item="$host/$item_path"
  [ -f "$item" ] || fail "manifest file is missing: $item_path"
  [ "$(wc -c < "$item" | tr -d ' ')" = "$item_size" ] || fail "manifest size mismatch: $item_path"
  [ "$(eval "$hash_cmd \"$item\"" | awk '{print $1}')" = "$item_hash" ] || fail "manifest digest mismatch: $item_path"
  printf '%s\n' "$item_path" >> "$manifest_paths"
done
find "$host" -type f ! -name content-manifest.json | sed "s#^$host/##" | sort > "$tmp/extracted-paths"
sort "$manifest_paths" > "$tmp/expected-paths"
cmp -s "$tmp/expected-paths" "$tmp/extracted-paths" || fail 'archive contains files outside the content manifest'

version_json="$tmp/installed-version.json"
"$host/cli/bundle/bin/workspace" --json --version > "$version_json" || fail 'staged version probe failed'
version_flat="$tmp/version.flat"; json_flatten "$version_json" > "$version_flat" || fail 'staged version identity is not canonical JSON'
[ "$(json_value "$version_flat" schema_version number)" = 1 ] || fail 'staged version schema mismatch'
[ "$(json_value "$version_flat" result.product_id string)" = workspace ] || fail 'staged product identity mismatch'
[ "$(json_value "$version_flat" result.version string)" = "$catalog_version" ] || fail 'staged version identity mismatch'
[ "$(json_value "$version_flat" result.release_id string)" = "$release_id" ] || fail 'staged release identity mismatch'
[ "$(json_value "$version_flat" result.source_revision string)" = "$source_revision" ] || fail 'staged source identity mismatch'
[ "$(json_value "$version_flat" result.platform string)" = "$platform" ] || fail 'staged platform identity mismatch'
[ "$(json_value "$version_flat" result.architecture string)" = "$architecture" ] || fail 'staged architecture identity mismatch'
[ "$(json_value "$version_flat" result.runtime_compatibility_id string)" = "$runtime_id" ] || fail 'staged runtime identity mismatch'

final="$releases/$release_id"
receipt="$tmp/activation-receipt.json"
cat > "$receipt" <<EOF
{"schema":"workspace.application-activation/v1","product_id":"workspace","version":"$catalog_version","release_id":"$release_id","source_revision":"$source_revision","platform":"$platform","architecture":"$architecture","runtime_compatibility_id":"$runtime_id","archive_sha256":"$expected_hash"}
EOF
old=''; [ -f "$pointer" ] && old=$(cat "$pointer")
old_previous=''; [ -f "$previous" ] && old_previous=$(cat "$previous")
if [ -e "$final" ]; then
  [ "$old" = "$release_id" ] && [ -f "$final/activation-receipt.json" ] && cmp -s "$receipt" "$final/activation-receipt.json" || fail "release $release_id is already present but not safely reusable"
  printf 'Workspace release %s is already active and verified.\n' "$release_id"
  exit 0
fi
inject_fault pre-activation
mv "$host" "$final"; rmdir "$stage/workspace" "$stage" 2>/dev/null || true; stage=''
mv "$receipt" "$final/activation-receipt.json" || fail 'could not write activation receipt'
if [ -e "$shim" ] || [ -L "$shim" ]; then grep -q 'workspace active-release shim' "$shim" 2>/dev/null || fail "refusing to replace unrelated command at $shim"; fi
cat > "$shim" <<EOF
#!/bin/sh
# workspace active-release shim
root='$app_home'
id=\$(cat "\$root/active-release") || exit 1
exec "\$root/releases/\$id/cli/bundle/bin/workspace" "\$@"
EOF
chmod 755 "$shim"
restore_pointers() {
  if [ -n "$old" ]; then printf '%s\n' "$old" > "$pointer.restore" && mv "$pointer.restore" "$pointer"; else rm -f "$pointer"; fi
  if [ -n "$old_previous" ]; then printf '%s\n' "$old_previous" > "$previous.restore" && mv "$previous.restore" "$previous"; else rm -f "$previous"; fi
}
if [ -n "$old" ]; then printf '%s\n' "$old" > "$previous.new" && mv "$previous.new" "$previous"; else rm -f "$previous"; fi
if [ "$install_fault" = pointer-switch ]; then restore_pointers; inject_fault pointer-switch; fi
printf '%s\n' "$release_id" > "$pointer.new" && mv "$pointer.new" "$pointer"
if [ "$install_fault" = post-activation-probe ] || ! "$shim" --json --version >/dev/null 2>&1; then restore_pointers; fail 'activation probe failed; prior host remains active'; fi
printf 'Installed Workspace host %s at %s. No administrator access was requested.\n' "$release_id" "$final"
printf 'Host placement is incomplete: run workspace provision, then workspace provision --check.\n'
