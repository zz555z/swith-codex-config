#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
PROVIDER=""
PROVIDER_NAME=""
BASE_URL=""
TOKEN="${CODEX_TOKEN:-}"
MODEL=""
WIRE_API=""
DRY_RUN=0
SCRIPT_NAME="$(basename "$0")"
MENU_MODE=0

usage() {
  cat <<'EOF'
用法:
  ./switch-codex-config.sh
  ./switch-codex-config.sh --base-url URL --model MODEL [--token TOKEN]
  CODEX_TOKEN=TOKEN ./switch-codex-config.sh --base-url URL --model MODEL

交互菜单:
  1) 添加/更新模型配置
  2) 查看模型配置
  3) 删除模型配置
  4) 设置当前模型配置
  5) 应用 Codex 启动加速 hosts 配置

选项:
  --config PATH       Codex 配置文件路径。默认: ~/.codex/config.toml
  --provider NAME     provider 名称，会写成 [model_providers.NAME]，同时 name = "NAME"
  --name NAME         等同于 --provider NAME，保留用于兼容旧调用
  --base-url URL      新的 provider base_url
  --token TOKEN       新的 experimental_bearer_token。建议使用 CODEX_TOKEN 或 --token-stdin。
  --token-stdin       从标准输入读取 token
  --model MODEL       兼容旧用法：添加/更新 provider 后，同时设为顶层 Codex model。
                     交互菜单添加配置时不需要填写 model。
  --wire-api VALUE    provider wire_api 值。默认: responses
  --dry-run           只显示将要修改的内容，不写入文件
  -h, --help          显示帮助

示例:
  ./switch-codex-config.sh
  ./switch-codex-config.sh --provider custom --base-url https://muyuan.do/v1 --model gpt-5.5 --token-stdin
  CODEX_TOKEN='sk-...' ./switch-codex-config.sh --provider custom --base-url https://new.sharedchat.cc/codex --model gpt-5.5 --wire-api responses
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

can_prompt() {
  [[ "$MENU_MODE" -eq 1 || -t 0 ]]
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
  TOKEN="${CODEX_TOKEN:-}"
  MODEL=""
  WIRE_API=""
  DRY_RUN=0
}

menu_error_or_die() {
  if [[ "$MENU_MODE" -eq 1 ]]; then
    echo "$*" >&2
    return 0
  fi
  die "$*"
}

ensure_config_exists() {
  [[ -f "$CONFIG" ]] || die "配置文件不存在: $CONFIG"
}

backup_config() {
  local backup
  backup="$CONFIG.backup.$(date +%Y%m%d_%H%M%S).$SCRIPT_NAME"
  cp "$CONFIG" "$backup"
  printf '%s\n' "$backup"
}

redact() {
  printf '[redacted]'
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
  local token
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
    token="$(get_provider_value "$provider" "experimental_bearer_token")"

    if [[ "$provider" == "$current_provider" ]]; then
      echo "[model_providers.$provider]（当前）"
    else
      echo "[model_providers.$provider]"
    fi
    echo "  name = ${name:-<无>}"
    echo "  base_url = ${base_url:-<无>}"
    echo "  wire_api = ${wire_api:-<无>}"
    echo "  requires_openai_auth = ${auth:-<无>}"
    if [[ -n "$token" ]]; then
      echo "  experimental_bearer_token = $(redact "$token")"
    else
      echo "  experimental_bearer_token = <无>"
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
  export CODEX_SWITCH_TOKEN="$TOKEN"
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
my $token = $ENV{"CODEX_SWITCH_TOKEN"};
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
remove_key(\@section, "model");
set_key(\@section, "name", $provider_name || $provider);
set_key(\@section, "base_url", $base_url);
set_key(\@section, "experimental_bearer_token", $token);
set_key(\@section, "wire_api", $wire_api);
set_bool_key(\@section, "requires_openai_auth", 0);

splice @lines, $start + 1, $end - $start - 1, @section;
print @lines;
PERL

  mv "$tmp_config" "$CONFIG"
  trap - EXIT
}

add_or_update_provider() {
  ensure_config_exists

  if [[ -z "$PROVIDER" ]] && can_prompt; then
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
  fi

  if [[ -z "$PROVIDER" ]]; then
    menu_error_or_die "name 不能为空。请使用 --provider NAME 或在交互模式中输入。"
    return 0
  fi
  PROVIDER_NAME="${PROVIDER_NAME:-$PROVIDER}"

  if [[ -z "$BASE_URL" ]] && can_prompt; then
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
  fi

  if [[ -z "$BASE_URL" ]]; then
    menu_error_or_die "Base URL 不能为空。请使用 --base-url URL 或在交互模式中输入。"
    return 0
  fi
  BASE_URL="$(normalize_base_url "$BASE_URL")"

  if [[ -z "$TOKEN" ]] && can_prompt; then
    local existing_token
    local token_raw
    existing_token="$(get_provider_value "$PROVIDER" "experimental_bearer_token" 2>/dev/null || true)"
    if [[ -n "$existing_token" ]]; then
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
    TOKEN="${TOKEN:-$existing_token}"
  fi

  if [[ -z "$TOKEN" ]]; then
    menu_error_or_die "Token 不能为空。请使用 --token、--token-stdin 或 CODEX_TOKEN。"
    return 0
  fi

  WIRE_API="responses"
  PROVIDER_NAME="$PROVIDER"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "配置文件: $CONFIG"
    echo "[model_providers.$PROVIDER].name -> $PROVIDER_NAME"
    echo "[model_providers.$PROVIDER].base_url -> $BASE_URL"
    echo "[model_providers.$PROVIDER].experimental_bearer_token -> $(redact "$TOKEN")"
    echo "[model_providers.$PROVIDER].wire_api -> $WIRE_API"
    echo "[model_providers.$PROVIDER].requires_openai_auth -> false"
    if [[ -n "$MODEL" ]]; then
      echo "model_provider -> $PROVIDER"
      echo "model -> $MODEL"
    fi
    exit 0
  fi

  local backup
  backup="$(backup_config)"
  write_provider_config
  if [[ -n "$MODEL" ]]; then
    write_current_provider "$PROVIDER" "$MODEL"
  fi

  echo "已更新: $CONFIG"
  echo "备份文件: $backup"
  echo "[model_providers.$PROVIDER]"
  echo "name -> $PROVIDER_NAME"
  echo "base_url -> $BASE_URL"
  echo "experimental_bearer_token -> $(redact "$TOKEN")"
  echo "wire_api -> $WIRE_API"
  echo "requires_openai_auth -> false"
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
  backup="$(backup_config)"

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

  echo "已删除 [model_providers.$provider]"
  echo "备份文件: $backup"

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
  TOKEN="$(get_provider_value "$provider" "experimental_bearer_token")"
  if [[ -z "$BASE_URL" || -z "$TOKEN" ]]; then
    echo "[model_providers.$provider] 缺少 base_url 或 experimental_bearer_token，无法获取模型列表。"
    return 0
  fi

  BASE_URL="$(normalize_base_url "$BASE_URL")"
  MODEL=""
  if ! select_model_interactively; then
    return 0
  fi
  model="$MODEL"

  backup="$(backup_config)"
  write_current_provider "$provider" "$model"

  echo "已更新: $CONFIG"
  echo "备份文件: $backup"
  echo "model_provider -> $provider"
  echo "model -> $model"
  show_restart_hint
}

apply_fast_start_hosts() {
  local comment="# Codex fast-start workaround: make Statsig fail fast when ab.chatgpt.com is unreachable"
  local entry="127.0.0.1 ab.chatgpt.com"

  if grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+ab\.chatgpt\.com([[:space:]]|$)' /etc/hosts; then
    echo "hosts 加速配置已存在: $entry"
    return
  fi

  local tmp_hosts
  tmp_hosts="$(mktemp "/tmp/${SCRIPT_NAME}.hosts.XXXXXX")"
  trap 'rm -f "$tmp_hosts"' RETURN

  cp /etc/hosts "$tmp_hosts"
  {
    printf '\n%s\n' "$comment"
    printf '%s\n' "$entry"
  } >> "$tmp_hosts"

  if [[ -w /etc/hosts ]]; then
    cp "$tmp_hosts" /etc/hosts
  else
    echo "需要 sudo 权限更新 /etc/hosts。" >&2
    sudo cp "$tmp_hosts" /etc/hosts
  fi

  rm -f "$tmp_hosts"
  trap - RETURN
  echo "已添加 hosts 加速配置: $entry"
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
  5) 提升启动速度（hosts 加速配置）
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
      5)
        apply_fast_start_hosts
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
  local arg_count=$#

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG="${2:?missing value for --config}"
        shift 2
        ;;
      --provider)
        PROVIDER="${2:?missing value for --provider}"
        shift 2
        ;;
      --name)
        PROVIDER="${2:?missing value for --name}"
        shift 2
        ;;
      --base-url|--baseurl)
        BASE_URL="${2:?missing value for --base-url}"
        shift 2
        ;;
      --token)
        TOKEN="${2:?missing value for --token}"
        shift 2
        ;;
      --token-stdin)
        if ! IFS= read -r TOKEN; then
          echo "从标准输入读取 token 失败" >&2
          exit 2
        fi
        shift
        ;;
      --model)
        MODEL="${2:?missing value for --model}"
        shift 2
        ;;
      --wire-api)
        WIRE_API="${2:?missing value for --wire-api}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ "$arg_count" -eq 0 ]]; then
    MENU_MODE=1
    show_menu
  else
    MENU_MODE=0
    add_or_update_provider
  fi
}

main "$@"
