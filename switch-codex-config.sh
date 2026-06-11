#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
PROVIDER=""
PROVIDER_NAME=""
BASE_URL=""
TOKEN=""
MODEL=""
WIRE_API="responses"
SCRIPT_NAME="$(basename "$0")"
PROVIDER_KEYS_PASSPHRASE="switchcodex"
PROVIDER_TOKEN_ENCRYPTION="openssl-enc-aes-256-cbc-pbkdf2"
PROVIDER_TOKEN_ITERATIONS=200000

usage() {
  cat <<'EOF'
用法:
  ./switch-codex-config.sh

交互菜单:
  1) 添加/更新模型配置
  2) 查看模型配置
  3) 删除模型配置
  4) 设置当前模型配置

配置文件:
  默认修改 ~/.codex/config.toml
  可用 CODEX_CONFIG=/path/to/config.toml 指定其他配置文件

示例:
  ./switch-codex-config.sh
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

is_back_choice() {
  [[ "$1" == "b" || "$1" == "B" ]]
}

trim_input() {
  printf '%s' "$1" | LC_ALL=C sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

show_back_hint() {
  local target="${1:-上一级菜单}"
  echo "提示: 输入 b 返回${target}" >&2
}

show_restart_hint() {
  echo "请重启 codex 使新配置生效。"
}

reset_request_vars() {
  PROVIDER=""
  PROVIDER_NAME=""
  BASE_URL=""
  TOKEN=""
  MODEL=""
  WIRE_API="responses"
}

ensure_config_exists() {
  [[ -f "$CONFIG" ]] || die "配置文件不存在: $CONFIG"
}

backup_config() {
  backup_file_if_exists "$CONFIG"
}

config_dir() {
  dirname "$CONFIG"
}

auth_file() {
  printf '%s/auth.json\n' "$(config_dir)"
}

provider_keys_file() {
  printf '%s/provider-keys.json\n' "$(config_dir)"
}

backup_file_if_exists() {
  local file="$1"
  local backup
  if [[ ! -f "$file" ]]; then
    return 0
  fi

  backup="$file.bak.$(date +%Y%m%d)"
  if [[ ! -f "$backup" ]]; then
    cp "$file" "$backup"
  fi
  printf '%s\n' "$backup"
}

redact() {
  printf '[redacted]'
}

require_openssl() {
  command -v openssl >/dev/null 2>&1 || die "未找到 openssl，无法加密或解密 provider key。"
}

get_provider_keys_passphrase() {
  printf '%s' "$PROVIDER_KEYS_PASSPHRASE"
}

encrypt_provider_token() {
  local token="$1"
  local passphrase
  require_openssl
  passphrase="$(get_provider_keys_passphrase encrypt)" || return 1
  printf '%s' "$token" | CODEX_PROVIDER_KEYS_PASSPHRASE="$passphrase" openssl enc \
    -aes-256-cbc \
    -pbkdf2 \
    -iter "$PROVIDER_TOKEN_ITERATIONS" \
    -salt \
    -base64 \
    -A \
    -pass env:CODEX_PROVIDER_KEYS_PASSPHRASE
}

decrypt_provider_token() {
  local encrypted_token="$1"
  local passphrase
  require_openssl
  passphrase="$(get_provider_keys_passphrase decrypt)" || return 1
  if ! printf '%s' "$encrypted_token" | CODEX_PROVIDER_KEYS_PASSPHRASE="$passphrase" openssl enc \
    -d \
    -aes-256-cbc \
    -pbkdf2 \
    -iter "$PROVIDER_TOKEN_ITERATIONS" \
    -base64 \
    -A \
    -pass env:CODEX_PROVIDER_KEYS_PASSPHRASE; then
    echo "provider key 解密失败，请检查口令是否正确。" >&2
    return 1
  fi
}

provider_encrypted_token() {
  local provider="$1"
  local keys_file
  keys_file="$(provider_keys_file)"
  [[ -f "$keys_file" ]] || return 0

  PROVIDER_KEYS_FILE="$keys_file" PROVIDER_ID="$provider" ruby <<'RUBY'
require "json"

path = ENV.fetch("PROVIDER_KEYS_FILE")
provider = ENV.fetch("PROVIDER_ID")
data = JSON.parse(File.read(path))
value = data.dig("providers", provider, "token_encrypted")
print value if value.is_a?(String)
RUBY
}

provider_plain_token() {
  local provider="$1"
  local keys_file
  keys_file="$(provider_keys_file)"
  [[ -f "$keys_file" ]] || return 0

  PROVIDER_KEYS_FILE="$keys_file" PROVIDER_ID="$provider" ruby <<'RUBY'
require "json"

path = ENV.fetch("PROVIDER_KEYS_FILE")
provider = ENV.fetch("PROVIDER_ID")
data = JSON.parse(File.read(path))
value = data.dig("providers", provider, "token")
print value if value.is_a?(String)
RUBY
}

provider_has_token() {
  local provider="$1"
  local keys_file
  keys_file="$(provider_keys_file)"
  [[ -f "$keys_file" ]] || return 1

  PROVIDER_KEYS_FILE="$keys_file" PROVIDER_ID="$provider" ruby <<'RUBY'
require "json"

path = ENV.fetch("PROVIDER_KEYS_FILE")
provider = ENV.fetch("PROVIDER_ID")
data = JSON.parse(File.read(path))
entry = data.dig("providers", provider)
exit 1 unless entry.is_a?(Hash)
encrypted = entry["token_encrypted"]
plain = entry["token"]
has_token = (encrypted.is_a?(String) && !encrypted.empty?) || (plain.is_a?(String) && !plain.empty?)
exit(has_token ? 0 : 1)
RUBY
}

read_provider_token() {
  local provider="$1"
  local encrypted_token
  local plain_token

  encrypted_token="$(provider_encrypted_token "$provider")"
  if [[ -n "$encrypted_token" ]]; then
    decrypt_provider_token "$encrypted_token"
    return
  fi

  plain_token="$(provider_plain_token "$provider")"
  if [[ -n "$plain_token" ]]; then
    printf '%s' "$plain_token"
  fi
}

write_provider_token() {
  local provider="$1"
  local token="$2"
  local encrypted_token
  local keys_file
  local tmp_keys
  encrypted_token="$(encrypt_provider_token "$token")" || return 1
  keys_file="$(provider_keys_file)"
  mkdir -p "$(dirname "$keys_file")"
  tmp_keys="$(mktemp "${keys_file}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_keys"' EXIT

  PROVIDER_KEYS_FILE="$keys_file" \
    PROVIDER_ID="$provider" \
    PROVIDER_TOKEN_ENCRYPTED="$encrypted_token" \
    PROVIDER_TOKEN_ENCRYPTION="$PROVIDER_TOKEN_ENCRYPTION" \
    PROVIDER_TOKEN_ITERATIONS="$PROVIDER_TOKEN_ITERATIONS" \
    ruby > "$tmp_keys" <<'RUBY'
require "json"

path = ENV.fetch("PROVIDER_KEYS_FILE")
provider = ENV.fetch("PROVIDER_ID")
encrypted_token = ENV.fetch("PROVIDER_TOKEN_ENCRYPTED")
encryption = ENV.fetch("PROVIDER_TOKEN_ENCRYPTION")
iterations = ENV.fetch("PROVIDER_TOKEN_ITERATIONS").to_i

data = if File.exist?(path) && !File.empty?(path)
  JSON.parse(File.read(path))
else
  {}
end

data["providers"] = {} unless data["providers"].is_a?(Hash)
data["providers"][provider] = {} unless data["providers"][provider].is_a?(Hash)
data["providers"][provider].delete("token")
data["providers"][provider]["token_encrypted"] = encrypted_token
data["providers"][provider]["token_encryption"] = encryption
data["providers"][provider]["token_iterations"] = iterations

puts JSON.pretty_generate(data)
RUBY

  mv "$tmp_keys" "$keys_file"
  chmod 600 "$keys_file"
  trap - EXIT
}

delete_provider_token() {
  local provider="$1"
  local keys_file
  local tmp_keys
  keys_file="$(provider_keys_file)"
  [[ -f "$keys_file" ]] || return 0
  tmp_keys="$(mktemp "${keys_file}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_keys"' EXIT

  PROVIDER_KEYS_FILE="$keys_file" PROVIDER_ID="$provider" ruby > "$tmp_keys" <<'RUBY'
require "json"

path = ENV.fetch("PROVIDER_KEYS_FILE")
provider = ENV.fetch("PROVIDER_ID")
data = JSON.parse(File.read(path))
data["providers"].delete(provider) if data["providers"].is_a?(Hash)
puts JSON.pretty_generate(data)
RUBY

  mv "$tmp_keys" "$keys_file"
  chmod 600 "$keys_file"
  trap - EXIT
}

write_auth_token() {
  local token="$1"
  local file
  local tmp_auth
  file="$(auth_file)"
  mkdir -p "$(dirname "$file")"
  tmp_auth="$(mktemp "${file}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_auth"' EXIT

  CODEX_AUTH_FILE="$file" CODEX_AUTH_TOKEN="$token" ruby > "$tmp_auth" <<'RUBY'
require "json"

path = ENV.fetch("CODEX_AUTH_FILE")
token = ENV.fetch("CODEX_AUTH_TOKEN")
data = if File.exist?(path) && !File.empty?(path)
  JSON.parse(File.read(path))
else
  {}
end

data["OPENAI_API_KEY"] = token
puts JSON.pretty_generate(data)
RUBY

  mv "$tmp_auth" "$file"
  chmod 600 "$file"
  trap - EXIT
}

normalize_base_url() {
  local url="${1%/}"
  case "$url" in
    */v1)
      printf '%s\n' "$url"
      ;;
    */v1/models)
      printf '%s\n' "${url%/models}"
      ;;
    *)
      printf '%s/v1\n' "$url"
      ;;
  esac
}

models_url_for_base_url() {
  local url="${1%/}"
  printf '%s/models\n' "$url"
}

active_provider() {
  LC_ALL=C awk -F '"' '/^[[:space:]]*model_provider[[:space:]]*=/{print $2; exit}' "$CONFIG"
}

active_model() {
  LC_ALL=C awk -F '"' '/^[[:space:]]*model[[:space:]]*=/{print $2; exit}' "$CONFIG"
}

list_providers() {
  LC_ALL=C awk '
    /^\[model_providers\.[^].]+\][[:space:]]*$/ {
      provider = $0
      sub(/^\[model_providers\./, "", provider)
      sub(/\][[:space:]]*$/, "", provider)
      print provider
    }
  ' "$CONFIG"
}

provider_exists() {
  local provider="$1"
  list_providers | LC_ALL=C awk -v provider="$provider" '$0 == provider { found=1 } END { exit found ? 0 : 1 }'
}

get_provider_value() {
  local provider="$1"
  local key="$2"
  LC_ALL=C perl -Mstrict -Mwarnings - "$CONFIG" "$provider" "$key" <<'PERL'
my ($config, $provider, $key) = @ARGV;
open my $fh, "<", $config or die "open $config: $!";
my $in_section = 0;
while (my $line = <$fh>) {
  if ($line =~ /^\[model_providers\.\Q$provider\E\][ \t]*$/) {
    $in_section = 1;
    next;
  }
  if ($in_section && $line =~ /^\[/) {
    last;
  }
  if ($in_section && $line =~ /^[ \t]*\Q$key\E[ \t]*=[ \t]*(.*?)[ \t]*(?:#.*)?$/) {
    my $value = $1;
    $value =~ s/^[ \t]+|[ \t]+$//g;
    if ($value =~ /^"(.*)"$/) {
      $value = $1;
      $value =~ s/\\"/"/g;
      $value =~ s/\\\\/\\/g;
    }
    print $value;
    last;
  }
}
PERL
}

set_provider_value_if_missing() {
  local provider="$1"
  local key="$2"
  local value="$3"
  export CODEX_SWITCH_PROVIDER="$provider"
  export CODEX_SWITCH_KEY="$key"
  export CODEX_SWITCH_VALUE="$value"
  local tmp_config
  tmp_config="$(mktemp "${CONFIG}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_config"' EXIT

  LC_ALL=C LANG=C perl - "$CONFIG" > "$tmp_config" <<'PERL'
use strict;
use warnings;

my $provider = $ENV{"CODEX_SWITCH_PROVIDER"};
my $key = $ENV{"CODEX_SWITCH_KEY"};
my $value = $ENV{"CODEX_SWITCH_VALUE"};
my $config = $ARGV[0];

sub qtoml {
  my ($s) = @_;
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  return qq{"$s"};
}

open my $fh, "<", $config or die "open $config: $!";
my @lines = <$fh>;
close $fh;

my $start = -1;
for my $idx (0 .. $#lines) {
  if ($lines[$idx] =~ /^\[model_providers\.\Q$provider\E\][ \t]*$/) {
    $start = $idx;
    last;
  }
}
die "未找到 provider 配置段: [model_providers.$provider]\n" if $start < 0;

my $end = scalar @lines;
for (my $idx = $start + 1; $idx < @lines; $idx++) {
  if ($lines[$idx] =~ /^\[/) {
    $end = $idx;
    last;
  }
}

for my $idx (($start + 1) .. ($end - 1)) {
  if ($lines[$idx] =~ /^[ \t]*\Q$key\E[ \t]*=/) {
    print @lines;
    exit 0;
  }
}

splice @lines, $end, 0, "$key = " . qtoml($value) . "\n";
print @lines;
PERL

  mv "$tmp_config" "$CONFIG"
  trap - EXIT
}

parse_model_ids() {
  local input_file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '
      if type == "object" and (.data | type) == "array" then
        .data[]?.id
      elif type == "object" and (.models | type) == "array" then
        .models[]?.id
      elif type == "array" then
        .[]?.id
      else
        empty
      end
    ' "$input_file" 2>/dev/null
  else
    perl -0777 -ne 'while (/"id"[[:space:]]*:[[:space:]]*"([^"]+)"/g) { print "$1\n" }' "$input_file"
  fi
}

fetch_model_ids() {
  local models_url
  local body_tmp
  local ids_tmp
  local status
  local curl_status

  models_url="$(models_url_for_base_url "$BASE_URL")"
  body_tmp="$(mktemp "/tmp/${SCRIPT_NAME}.models-body.XXXXXX")"
  ids_tmp="$(mktemp "/tmp/${SCRIPT_NAME}.models-ids.XXXXXX")"
  trap 'rm -f "$body_tmp" "$ids_tmp"' RETURN

  echo "正在请求模型列表: $models_url" >&2
  curl_status=0
  status="$(curl -sS -L \
    --connect-timeout 8 \
    --max-time 30 \
    -o "$body_tmp" \
    -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$models_url")" || curl_status=$?

  if [[ "$curl_status" -ne 0 ]]; then
    echo "请求失败" >&2
    rm -f "$body_tmp" "$ids_tmp"
    trap - RETURN
    return 1
  fi

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "HTTP $status" >&2
    rm -f "$body_tmp" "$ids_tmp"
    trap - RETURN
    return 1
  fi

  if parse_model_ids "$body_tmp" | awk 'NF && !seen[$0]++' > "$ids_tmp" && [[ -s "$ids_tmp" ]]; then
    cat "$ids_tmp"
    rm -f "$body_tmp" "$ids_tmp"
    trap - RETURN
    return 0
  fi

  echo "响应不是可识别的模型列表 JSON" >&2

  rm -f "$body_tmp" "$ids_tmp"
  trap - RETURN
  return 1
}

select_model_interactively() {
  local models=()
  local id

  show_back_hint "上一级菜单"
  echo "正在从 $(models_url_for_base_url "$BASE_URL") 获取模型列表..." >&2
  local model_tmp
  model_tmp="$(mktemp "/tmp/${SCRIPT_NAME}.models.XXXXXX")"
  trap 'rm -f "$model_tmp"' RETURN

  local fetch_status=0
  fetch_model_ids > "$model_tmp" || fetch_status=$?
  while IFS= read -r id; do
    models+=("$id")
  done < "$model_tmp"
  rm -f "$model_tmp"
  trap - RETURN

  if [[ "$fetch_status" -ne 0 || "${#models[@]}" -eq 0 ]]; then
    echo "获取模型列表失败，可以手动输入模型名。" >&2
    printf "模型名: " >&2
    local model_raw
    IFS= read -r model_raw || return 2
    MODEL="$(trim_input "$model_raw")"
    if [[ -n "$model_raw" && -z "$MODEL" ]]; then
      echo "输入不能只包含空格。" >&2
      return 2
    fi
    if is_back_choice "$MODEL"; then
      MODEL=""
      return 2
    fi
    return
  fi

  echo "可用模型:" >&2
  local i=1
  for id in "${models[@]}"; do
    printf "  %2d) %s\n" "$i" "$id" >&2
    i=$((i + 1))
  done

  while true; do
    printf "请选择模型编号，或直接输入模型 id: " >&2
    local choice
    local choice_raw
    IFS= read -r choice_raw || return 2
    choice="$(trim_input "$choice_raw")"
    if [[ -n "$choice_raw" && -z "$choice" ]]; then
      echo "输入不能只包含空格。" >&2
      continue
    fi
    if is_back_choice "$choice"; then
      return 2
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
      MODEL="${models[$((choice - 1))]}"
      return
    fi
    if [[ -n "$choice" ]]; then
      MODEL="$choice"
      return
    fi
  done
}

choose_provider() {
  local prompt="$1"
  local providers=()
  local provider
  local providers_tmp
  local active
  local i
  local choice

  providers_tmp="$(mktemp "/tmp/${SCRIPT_NAME}.providers.XXXXXX")"
  trap 'rm -f "$providers_tmp"' RETURN
  list_providers > "$providers_tmp"
  while IFS= read -r provider; do
    providers+=("$provider")
  done < "$providers_tmp"
  rm -f "$providers_tmp"
  trap - RETURN

  if [[ "${#providers[@]}" -eq 0 ]]; then
    return 1
  fi

  active="$(active_provider)"
  show_back_hint "主菜单"
  echo "$prompt" >&2
  i=1
  for provider in "${providers[@]}"; do
    if [[ "$provider" == "$active" ]]; then
      printf "  %2d) %s（当前）\n" "$i" "$provider" >&2
    else
      printf "  %2d) %s\n" "$i" "$provider" >&2
    fi
    i=$((i + 1))
  done
  echo "   b) 返回" >&2

  while true; do
    printf "请选择 provider 编号，或直接输入 provider id: " >&2
    local choice_raw
    IFS= read -r choice_raw || return 1
    choice="$(trim_input "$choice_raw")"
    if [[ -n "$choice_raw" && -z "$choice" ]]; then
      echo "输入不能只包含空格。" >&2
      continue
    fi
    if is_back_choice "$choice"; then
      return 2
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#providers[@]} )); then
      printf '%s\n' "${providers[$((choice - 1))]}"
      return 0
    fi
    if provider_exists "$choice"; then
      printf '%s\n' "$choice"
      return 0
    fi
    echo "未找到 provider: $choice" >&2
  done
}

show_provider_configs() {
  ensure_config_exists

  local current_provider
  local provider
  local providers_tmp
  local name
  local base_url
  local wire_api
  local auth
  local token_present
  local choice

  current_provider="$(active_provider)"
  echo "配置文件: $CONFIG"
  echo "当前 provider: ${current_provider:-<无>}"
  echo

  if ! list_providers | grep -q .; then
    echo "未找到 [model_providers.xxx] 配置。"
    show_back_hint "主菜单"
    while true; do
      printf "请输入: " >&2
      IFS= read -r choice || return 0
      choice="$(trim_input "$choice")"
      if is_back_choice "$choice"; then
        return 0
      fi
    done
    return
  fi

  providers_tmp="$(mktemp "/tmp/${SCRIPT_NAME}.providers.XXXXXX")"
  trap 'rm -f "$providers_tmp"' RETURN
  list_providers > "$providers_tmp"
  while IFS= read -r provider; do
    name="$(get_provider_value "$provider" "name")"
    base_url="$(get_provider_value "$provider" "base_url")"
    wire_api="$(get_provider_value "$provider" "wire_api")"
    auth="$(get_provider_value "$provider" "requires_openai_auth")"
    token_present=0
    if provider_has_token "$provider"; then
      token_present=1
    fi

    if [[ "$provider" == "$current_provider" ]]; then
      echo "[model_providers.$provider]（当前）"
    else
      echo "[model_providers.$provider]"
    fi
    echo "  name = ${name:-<无>}"
    echo "  base_url = ${base_url:-<无>}"
    echo "  wire_api = ${wire_api:-<无>}"
    echo "  requires_openai_auth = ${auth:-<无>}"
    if [[ "$token_present" -eq 1 ]]; then
      echo "  provider key = $(redact)"
    else
      echo "  provider key = <无>"
    fi
    echo
  done < "$providers_tmp"
  rm -f "$providers_tmp"
  trap - RETURN

  show_back_hint "主菜单"
  while true; do
    printf "请输入: " >&2
    IFS= read -r choice || return 0
    choice="$(trim_input "$choice")"
    if is_back_choice "$choice"; then
      return 0
    fi
  done
}

write_provider_config() {
  export CODEX_SWITCH_PROVIDER="$PROVIDER"
  export CODEX_SWITCH_PROVIDER_NAME="$PROVIDER_NAME"
  export CODEX_SWITCH_BASE_URL="$BASE_URL"
  export CODEX_SWITCH_WIRE_API="$WIRE_API"

  local tmp_config
  tmp_config="$(mktemp "${CONFIG}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_config"' EXIT

  LC_ALL=C LANG=C perl - "$CONFIG" > "$tmp_config" <<'PERL'
use strict;
use warnings;

my $provider = $ENV{"CODEX_SWITCH_PROVIDER"};
my $provider_name = $ENV{"CODEX_SWITCH_PROVIDER_NAME"};
my $base_url = $ENV{"CODEX_SWITCH_BASE_URL"};
my $wire_api = $ENV{"CODEX_SWITCH_WIRE_API"};
my $config = $ARGV[0];

sub qtoml {
  my ($s) = @_;
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  return qq{"$s"};
}

sub set_key {
  my ($lines, $key, $value) = @_;
  my $line = "$key = " . qtoml($value) . "\n";
  for my $idx (0 .. $#$lines) {
    if ($lines->[$idx] =~ /^[ \t]*\Q$key\E[ \t]*=/) {
      $lines->[$idx] = $line;
      return;
    }
  }
  push @$lines, $line;
}

sub set_bool_key {
  my ($lines, $key, $value) = @_;
  my $line = "$key = " . ($value ? "true" : "false") . "\n";
  for my $idx (0 .. $#$lines) {
    if ($lines->[$idx] =~ /^[ \t]*\Q$key\E[ \t]*=/) {
      $lines->[$idx] = $line;
      return;
    }
  }
  push @$lines, $line;
}

sub remove_key {
  my ($lines, $key) = @_;
  @$lines = grep { $_ !~ /^[ \t]*\Q$key\E[ \t]*=/ } @$lines;
}

open my $fh, "<", $config or die "open $config: $!";
my @lines = <$fh>;
close $fh;

for (my $idx = 0; $idx < @lines; $idx++) {
  if ($lines[$idx] =~ /^\[model_providers\.\Q$provider\E\.auth\][ \t]*$/) {
    my $end = scalar @lines;
    for (my $next = $idx + 1; $next < @lines; $next++) {
      if ($lines[$next] =~ /^\[/) {
        $end = $next;
        last;
      }
    }
    splice @lines, $idx, $end - $idx;
    last;
  }
}

my $first_section = scalar @lines;
for my $idx (0 .. $#lines) {
  if ($lines[$idx] =~ /^\[/) {
    $first_section = $idx;
    last;
  }
}

my $start = -1;
my $header_re = qr/^\[model_providers\.\Q$provider\E\][ \t]*$/;
for my $idx (0 .. $#lines) {
  if ($lines[$idx] =~ $header_re) {
    $start = $idx;
    last;
  }
}

if ($start < 0) {
  push @lines, "\n" if @lines && $lines[-1] !~ /^\s*$/;
  push @lines, "[model_providers.$provider]\n";
  $start = $#lines;
}

my $end = scalar @lines;
for (my $idx = $start + 1; $idx < @lines; $idx++) {
  if ($lines[$idx] =~ /^\[/) {
    $end = $idx;
    last;
  }
}

my @section = @lines[($start + 1) .. ($end - 1)];
remove_key(\@section, "env_key");
remove_key(\@section, "env_key_instructions");
remove_key(\@section, "experimental_bearer_token");
remove_key(\@section, "model");
set_key(\@section, "name", $provider_name || $provider);
set_key(\@section, "base_url", $base_url);
set_key(\@section, "wire_api", $wire_api);
set_bool_key(\@section, "requires_openai_auth", 1);

splice @lines, $start + 1, $end - $start - 1, @section;
print @lines;
PERL

  mv "$tmp_config" "$CONFIG"
  trap - EXIT
}

add_or_update_provider() {
  ensure_config_exists

  local provider_input
  local provider_raw
  show_back_hint "主菜单"
  printf "name（将写入 [model_providers.name]）: " >&2
  IFS= read -r provider_raw || return 0
  provider_input="$(trim_input "$provider_raw")"
  if [[ -n "$provider_raw" && -z "$provider_input" ]]; then
    echo "输入不能只包含空格。"
    return 0
  fi
  if is_back_choice "$provider_input"; then
    return 0
  fi
  PROVIDER="$provider_input"

  if [[ -z "$PROVIDER" ]]; then
    echo "name 不能为空。" >&2
    return 0
  fi
  PROVIDER_NAME="${PROVIDER_NAME:-$PROVIDER}"

  local existing_base_url
  local base_url_raw
  existing_base_url="$(get_provider_value "$PROVIDER" "base_url" 2>/dev/null || true)"
  if [[ -n "$existing_base_url" ]]; then
    printf "Base URL [%s]: " "$existing_base_url" >&2
  else
    printf "Base URL: " >&2
  fi
  IFS= read -r base_url_raw || return 0
  BASE_URL="$(trim_input "$base_url_raw")"
  if [[ -n "$base_url_raw" && -z "$BASE_URL" ]]; then
    echo "输入不能只包含空格。"
    return 0
  fi
  if is_back_choice "$BASE_URL"; then
    return 0
  fi
  BASE_URL="${BASE_URL:-$existing_base_url}"

  if [[ -z "$BASE_URL" ]]; then
    echo "Base URL 不能为空。" >&2
    return 0
  fi
  BASE_URL="$(normalize_base_url "$BASE_URL")"

  local existing_encrypted_token
  local existing_plain_token
  local existing_legacy_token
  local existing_token_present=0
  local existing_token_encrypted=0
  local should_write_token=0
  local token_raw
  existing_encrypted_token="$(provider_encrypted_token "$PROVIDER" 2>/dev/null || true)"
  if [[ -n "$existing_encrypted_token" ]]; then
    existing_token_present=1
    existing_token_encrypted=1
  else
    existing_plain_token="$(provider_plain_token "$PROVIDER" 2>/dev/null || true)"
    if [[ -n "$existing_plain_token" ]]; then
      existing_token_present=1
    else
      existing_legacy_token="$(get_provider_value "$PROVIDER" "experimental_bearer_token" 2>/dev/null || true)"
      if [[ -n "$existing_legacy_token" ]]; then
        existing_token_present=1
      fi
    fi
  fi
  if [[ "$existing_token_present" -eq 1 ]]; then
    printf "Token [直接回车保留现有值]: " >&2
  else
    printf "Token: " >&2
  fi
  IFS= read -r token_raw || return 0
  TOKEN="$(trim_input "$token_raw")"
  if [[ -n "$token_raw" && -z "$TOKEN" ]]; then
    echo "输入不能只包含空格。"
    return 0
  fi
  if is_back_choice "$TOKEN"; then
    return 0
  fi
  if [[ -n "$TOKEN" ]]; then
    should_write_token=1
  elif [[ "$existing_token_encrypted" -eq 1 ]]; then
    should_write_token=0
  else
    TOKEN="${existing_plain_token:-$existing_legacy_token}"
    if [[ -n "$TOKEN" ]]; then
      should_write_token=1
    fi
  fi

  if [[ "$should_write_token" -eq 0 && "$existing_token_present" -ne 1 ]]; then
    echo "Token 不能为空。" >&2
    return 0
  fi
  if [[ "$should_write_token" -eq 1 && -z "$TOKEN" ]]; then
    echo "Token 不能为空。" >&2
    return 0
  fi

  WIRE_API="responses"
  PROVIDER_NAME="$PROVIDER"

  local backup
  local keys_backup
  backup="$(backup_config)"
  keys_backup=""
  if [[ "$should_write_token" -eq 1 ]]; then
    keys_backup="$(backup_file_if_exists "$(provider_keys_file)")"
  fi
  write_provider_config
  if [[ "$should_write_token" -eq 1 ]]; then
    write_provider_token "$PROVIDER" "$TOKEN"
  fi
  if [[ -n "$MODEL" ]]; then
    if [[ -z "$TOKEN" ]]; then
      if ! TOKEN="$(read_provider_token "$PROVIDER")"; then
        echo "provider key 解密失败，未设置当前模型。" >&2
        return 0
      fi
    fi
    write_current_provider "$PROVIDER" "$MODEL"
  fi

  echo "已更新: $CONFIG"
  echo "备份文件: $backup"
  if [[ -n "$keys_backup" ]]; then
    echo "Key 备份文件: $keys_backup"
  fi
  echo "[model_providers.$PROVIDER]"
  echo "name -> $PROVIDER_NAME"
  echo "base_url -> $BASE_URL"
  echo "provider key -> $(redact "$TOKEN")"
  echo "wire_api -> $WIRE_API"
  echo "requires_openai_auth -> true"
  if [[ -n "$MODEL" ]]; then
    echo "model_provider -> $PROVIDER"
    echo "model -> $MODEL"
  fi
  show_restart_hint
}

delete_provider() {
  ensure_config_exists

  local provider
  local status=0
  provider="$(choose_provider "请选择要删除的 provider:")" || status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 2 ]]; then
      return 0
    fi
    echo "未找到 provider。" >&2
    return 0
  fi

  show_back_hint "主菜单"
  printf "确定删除 [model_providers.%s] 吗？输入 yes 继续: " "$provider" >&2
  local confirm
  IFS= read -r confirm || return 0
  confirm="$(trim_input "$confirm")"
  if [[ -z "$confirm" ]]; then
    echo "已取消。"
    return 0
  fi
  if is_back_choice "$confirm"; then
    return 0
  fi
  if [[ "$confirm" != "yes" ]]; then
    echo "已取消。"
    return 0
  fi

  local was_active=0
  if [[ "$(active_provider)" == "$provider" ]]; then
    was_active=1
  fi

  local backup
  local keys_backup
  backup="$(backup_config)"
  keys_backup="$(backup_file_if_exists "$(provider_keys_file)")"

  export CODEX_DELETE_PROVIDER="$provider"
  local tmp_config
  tmp_config="$(mktemp "${CONFIG}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_config"' EXIT

  LC_ALL=C LANG=C perl - "$CONFIG" > "$tmp_config" <<'PERL'
use strict;
use warnings;

my $provider = $ENV{"CODEX_DELETE_PROVIDER"};
my $config = $ARGV[0];
open my $fh, "<", $config or die "open $config: $!";
my @lines = <$fh>;
close $fh;

my $skip = 0;
for my $line (@lines) {
  if ($line =~ /^\[model_providers\.\Q$provider\E(?:\.[^\]]+)?\][ \t]*$/) {
    $skip = 1;
    next;
  }
  if ($line =~ /^\[/) {
    $skip = 0;
  }
  print $line unless $skip;
}
PERL

  mv "$tmp_config" "$CONFIG"
  trap - EXIT
  delete_provider_token "$provider"

  echo "已删除 [model_providers.$provider]"
  echo "备份文件: $backup"
  if [[ -n "$keys_backup" ]]; then
    echo "Key 备份文件: $keys_backup"
  fi

  if [[ "$was_active" -eq 1 ]]; then
    if list_providers | grep -q .; then
      echo "删除的是当前 provider，请选择一个替代 provider。" >&2
      set_current_provider
    else
      echo "警告：删除的是当前 provider，并且已经没有可用 provider。" >&2
    fi
  fi
}

write_current_provider() {
  local provider="$1"
  local model="$2"
  export CODEX_CURRENT_PROVIDER="$provider"
  export CODEX_CURRENT_MODEL="$model"

  local tmp_config
  tmp_config="$(mktemp "${CONFIG}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_config"' EXIT

  LC_ALL=C LANG=C perl - "$CONFIG" > "$tmp_config" <<'PERL'
use strict;
use warnings;

my $provider = $ENV{"CODEX_CURRENT_PROVIDER"};
my $model = $ENV{"CODEX_CURRENT_MODEL"};
my $config = $ARGV[0];

sub qtoml {
  my ($s) = @_;
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  return qq{"$s"};
}

sub set_key {
  my ($lines, $key, $value) = @_;
  my $line = "$key = " . qtoml($value) . "\n";
  for my $idx (0 .. $#$lines) {
    if ($lines->[$idx] =~ /^[ \t]*\Q$key\E[ \t]*=/) {
      $lines->[$idx] = $line;
      return;
    }
  }
  push @$lines, $line;
}

open my $fh, "<", $config or die "open $config: $!";
my @lines = <$fh>;
close $fh;

my $first_section = scalar @lines;
for my $idx (0 .. $#lines) {
  if ($lines[$idx] =~ /^\[/) {
    $first_section = $idx;
    last;
  }
}

my @root = @lines[0 .. ($first_section - 1)];
set_key(\@root, "model_provider", $provider);
set_key(\@root, "model", $model);
splice @lines, 0, $first_section, @root;
print @lines;
PERL

  mv "$tmp_config" "$CONFIG"
  trap - EXIT
}

set_current_provider() {
  ensure_config_exists

  local provider
  local model
  local backup

  local status=0
  provider="$(choose_provider "请选择要设为当前使用的 provider:")" || status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 2 ]]; then
      return 0
    fi
    echo "未找到 provider。" >&2
    return 0
  fi

  BASE_URL="$(get_provider_value "$provider" "base_url")"
  if [[ -z "$BASE_URL" ]]; then
    echo "[model_providers.$provider] 缺少 base_url 或 provider key，无法获取模型列表。"
    return 0
  fi

  if provider_has_token "$provider"; then
    if ! TOKEN="$(read_provider_token "$provider")"; then
      echo "provider key 解密失败，未更新 auth.json。" >&2
      return 0
    fi
  else
    TOKEN="$(get_provider_value "$provider" "experimental_bearer_token" 2>/dev/null || true)"
  fi
  if [[ -z "$TOKEN" ]]; then
    echo "[model_providers.$provider] 缺少 base_url 或 provider key，无法获取模型列表。"
    return 0
  fi

  BASE_URL="$(normalize_base_url "$BASE_URL")"
  MODEL=""
  if ! select_model_interactively; then
    return 0
  fi
  model="$MODEL"

  local auth_backup
  backup="$(backup_config)"
  auth_backup="$(backup_file_if_exists "$(auth_file)")"
  write_current_provider "$provider" "$model"
  write_auth_token "$TOKEN"

  echo "已更新: $CONFIG"
  echo "备份文件: $backup"
  if [[ -n "$auth_backup" ]]; then
    echo "Auth 备份文件: $auth_backup"
  fi
  echo "model_provider -> $provider"
  echo "model -> $model"
  echo "auth.json OPENAI_API_KEY -> $(redact "$TOKEN")"
  show_restart_hint
}

show_menu() {
  ensure_config_exists

  while true; do
    echo >&2
    cat >&2 <<'EOF'
请选择操作:
  1) 添加模型配置
  2) 查看模型配置
  3) 删除模型配置
  4) 设置当前模型
  q) 退出
EOF

    printf "请选择: " >&2
    local choice
    local choice_raw
    IFS= read -r choice_raw || exit 0
    choice="$(trim_input "$choice_raw")"
    if [[ -n "$choice_raw" && -z "$choice" ]]; then
      echo "输入不能只包含空格。" >&2
      continue
    fi

    case "$choice" in
      1)
        reset_request_vars
        add_or_update_provider
        ;;
      2)
        show_provider_configs
        ;;
      3)
        delete_provider
        ;;
      4)
        set_current_provider
        ;;
      q|Q)
        exit 0
        ;;
      *)
        echo "未知选项: $choice" >&2
        ;;
    esac
  done
}

main() {
  if [[ $# -gt 0 ]]; then
    echo "此脚本只支持交互模式，不再支持命令行参数。" >&2
    usage >&2
    exit 2
  fi

  show_menu
}

main "$@"
