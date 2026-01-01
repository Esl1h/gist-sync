#!/usr/bin/env bash
#===============================================================================
# gist-sync - Multi-platform gist/snippet synchronizer
#
# Syncs gists from GitHub to multiple destinations:
# GitLab, Codeberg, Gitea, Bitbucket, Keybase, and more
#
# Author: Esli
# License: MIT
# Repository: https://github.com/esli/gist-sync
#===============================================================================

set -euo pipefail

#===============================================================================
# CONSTANTS AND GLOBAL CONFIGURATION
#===============================================================================

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default directories
readonly DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gist-sync"
readonly DEFAULT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gist-sync"
readonly DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_DIR}/config.toml"

# Colors for output (disabled if not a TTY)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' RESET=''
fi

# Global state variables
declare -A CONFIG
declare -A SOURCE_CONFIG
declare -a TARGETS
declare -A GIST_CACHE
declare LOG_LEVEL=2  # 0=error, 1=warn, 2=info, 3=debug
declare DRY_RUN=false
declare CONFIG_FILE=""
declare CACHE_DIR=""

#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================

log::_output() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    printf "${color}[%s] [%-5s]${RESET} %s\n" "$timestamp" "$level" "$message" >&2
    
    # Log to file if configured
    if [[ -n "${CONFIG[log_file]:-}" ]]; then
        printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$message" >> "${CONFIG[log_file]}"
    fi
}

log::debug() {
    [[ $LOG_LEVEL -ge 3 ]] && log::_output "DEBUG" "$CYAN" "$*"
    return 0
}

log::info() {
    [[ $LOG_LEVEL -ge 2 ]] && log::_output "INFO" "$GREEN" "$*"
    return 0
}

log::warn() {
    [[ $LOG_LEVEL -ge 1 ]] && log::_output "WARN" "$YELLOW" "$*"
    return 0
}

log::error() {
    log::_output "ERROR" "$RED" "$*"
    return 0
}

log::success() {
    [[ $LOG_LEVEL -ge 2 ]] && log::_output "OK" "$GREEN" "$*"
    return 0
}

log::dry_run() {
    log::_output "DRY" "$MAGENTA" "[dry-run] $*"
    return 0
}

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

util::die() {
    log::error "$*"
    exit 1
}

util::require_command() {
    local cmd="$1"
    local package="${2:-$1}"
    
    if ! command -v "$cmd" &>/dev/null; then
        util::die "Command '$cmd' not found. Install: $package"
    fi
}

util::check_dependencies() {
    log::debug "Checking dependencies..."
    util::require_command "curl" "curl"
    util::require_command "jq" "jq"
    util::require_command "git" "git"
    
    # tomlq is part of yq
    if ! command -v tomlq &>/dev/null && ! command -v yq &>/dev/null; then
        util::die "Command 'tomlq' or 'yq' not found. Install: yq (pip install yq) or yq-go"
    fi
}

util::expand_path() {
    local path="$1"
    # Expand ~ and environment variables
    eval echo "$path"
}

util::ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log::debug "Creating directory: $dir"
        mkdir -p "$dir"
    fi
}

util::url_encode() {
    local string="$1"
    python3 -c "import urllib.parse; print(urllib.parse.quote('$string', safe=''))"
}

util::json_escape() {
    local string="$1"
    printf '%s' "$string" | jq -Rs '.'
}

util::hash_content() {
    local content="$1"
    printf '%s' "$content" | sha256sum | cut -d' ' -f1
}

util::tempfile() {
    mktemp "${CACHE_DIR}/tmp.XXXXXX"
}

#===============================================================================
# TOML PARSER
#===============================================================================

# Global to track which parser to use
declare TOML_PARSER=""

toml::detect_parser() {
    # Already detected
    [[ -n "$TOML_PARSER" ]] && return 0
    
    # Option 1: Python tomlq (from yq package via pip)
    if command -v tomlq &>/dev/null; then
        # Verify it actually works (needs jq)
        if echo '[test]' | tomlq '.' &>/dev/null; then
            TOML_PARSER="tomlq"
            log::debug "TOML parser: tomlq (Python yq)"
            return 0
        else
            log::debug "tomlq found but not working (missing jq?)"
        fi
    fi
    
    # Option 2: Go yq (mikefarah/yq) with TOML support
    if command -v yq &>/dev/null; then
        local yq_version
        yq_version=$(yq --version 2>&1 || true)
        
        # Check if it's Go yq (contains github.com/mikefarah/yq or has specific version format)
        if [[ "$yq_version" == *"mikefarah"* ]] || [[ "$yq_version" =~ ^yq\ \(https://github\.com/mikefarah/yq/\) ]]; then
            TOML_PARSER="yq-go"
            log::debug "TOML parser: yq (Go version - mikefarah)"
            return 0
        fi
        
        # Check if it's Go yq by testing -p flag
        if yq -p toml -o json <<< '[test]
key = "value"' &>/dev/null; then
            TOML_PARSER="yq-go"
            log::debug "TOML parser: yq (Go version - detected by -p flag)"
            return 0
        fi
        
        # Check if it's Python yq (wrapper around jq)
        if [[ "$yq_version" == *"jq"* ]] || yq --help 2>&1 | grep -q "jq wrapper"; then
            TOML_PARSER="yq-python"
            log::debug "TOML parser: yq (Python version)"
            return 0
        fi
    fi
    
    util::die "No TOML parser found. Install one of:
  - Go yq (recommended): https://github.com/mikefarah/yq
  - Python yq: pip install yq (also requires jq)"
}

toml::parse() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        util::die "Configuration file not found: $file"
    fi
    
    toml::detect_parser
    log::debug "Parsing configuration: $file"
}

toml::get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    
    local value=""
    
    case "$TOML_PARSER" in
        tomlq)
            value=$(tomlq -r "$key // empty" "$file" 2>/dev/null) || value=""
            ;;
        yq-python)
            value=$(yq -t -r "$key // empty" "$file" 2>/dev/null) || value=""
            ;;
        yq-go)
            # Go yq: convert TOML to JSON, then use jq
            value=$(yq -p toml -o json "$file" 2>/dev/null | jq -r "$key // empty" 2>/dev/null) || value=""
            ;;
        *)
            toml::detect_parser
            value=$(toml::get "$file" "$key" "$default")
            return $?
            ;;
    esac
    
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

toml::get_array() {
    local file="$1"
    local key="$2"
    
    case "$TOML_PARSER" in
        tomlq)
            tomlq -r "$key // [] | .[]" "$file" 2>/dev/null || true
            ;;
        yq-python)
            yq -t -r "$key // [] | .[]" "$file" 2>/dev/null || true
            ;;
        yq-go)
            yq -p toml -o json "$file" 2>/dev/null | jq -r "$key // [] | .[]" 2>/dev/null || true
            ;;
        *)
            toml::detect_parser
            toml::get_array "$file" "$key"
            ;;
    esac
}

toml::get_object() {
    local file="$1"
    local key="$2"
    
    case "$TOML_PARSER" in
        tomlq)
            tomlq "$key // {}" "$file" 2>/dev/null || echo "{}"
            ;;
        yq-python)
            yq -t "$key // {}" "$file" 2>/dev/null || echo "{}"
            ;;
        yq-go)
            yq -p toml -o json "$file" 2>/dev/null | jq "$key // {}" 2>/dev/null || echo "{}"
            ;;
        *)
            toml::detect_parser
            toml::get_object "$file" "$key"
            ;;
    esac
}

#===============================================================================
# CONFIGURATION
#===============================================================================

config::load() {
    local config_file="$1"
    
    toml::parse "$config_file"
    
    # General settings
    CONFIG[cache_dir]="$(util::expand_path "$(toml::get "$config_file" '.general.cache_dir' "$DEFAULT_CACHE_DIR")")"
    CONFIG[log_level]="$(toml::get "$config_file" '.general.log_level' 'info')"
    CONFIG[log_file]="$(toml::get "$config_file" '.general.log_file' '')"
    CONFIG[dry_run]="$(toml::get "$config_file" '.general.dry_run' 'false')"
    CONFIG[max_parallel]="$(toml::get "$config_file" '.general.max_parallel' '5')"
    CONFIG[rate_limit_interval]="$(toml::get "$config_file" '.general.rate_limit_interval' '1')"
    CONFIG[http_timeout]="$(toml::get "$config_file" '.general.http_timeout' '30')"
    
    # Set log level
    case "${CONFIG[log_level]}" in
        debug) LOG_LEVEL=3 ;;
        info)  LOG_LEVEL=2 ;;
        warn)  LOG_LEVEL=1 ;;
        error) LOG_LEVEL=0 ;;
    esac
    
    # Dry run from config or CLI
    if [[ "${CONFIG[dry_run]}" == "true" ]]; then
        DRY_RUN=true
    fi
    
    CACHE_DIR="${CONFIG[cache_dir]}"
    util::ensure_dir "$CACHE_DIR"
    
    # Expand log_file if configured
    if [[ -n "${CONFIG[log_file]}" ]]; then
        CONFIG[log_file]="$(util::expand_path "${CONFIG[log_file]}")"
        util::ensure_dir "$(dirname "${CONFIG[log_file]}")"
    fi
    
    # Source (origin)
    SOURCE_CONFIG[provider]="$(toml::get "$config_file" '.source.provider' 'github')"
    SOURCE_CONFIG[username]="$(toml::get "$config_file" '.source.username' '')"
    SOURCE_CONFIG[token]="$(toml::get "$config_file" '.source.token' '')"
    SOURCE_CONFIG[base_url]="$(toml::get "$config_file" '.source.base_url' '')"
    
    # Environment variable token takes precedence
    local env_token="${GIST_SYNC_SOURCE_TOKEN:-}"
    if [[ -n "$env_token" ]]; then
        SOURCE_CONFIG[token]="$env_token"
    fi
    
    # Filters
    SOURCE_CONFIG[visibility]="$(toml::get "$config_file" '.source.filters.visibility' 'all')"
    SOURCE_CONFIG[since]="$(toml::get "$config_file" '.source.filters.since' '')"
    SOURCE_CONFIG[include_patterns]="$(toml::get_array "$config_file" '.source.filters.include_patterns' | tr '\n' '|')"
    SOURCE_CONFIG[exclude_patterns]="$(toml::get_array "$config_file" '.source.filters.exclude_patterns' | tr '\n' '|')"
    SOURCE_CONFIG[gist_ids]="$(toml::get_array "$config_file" '.source.filters.gist_ids' | tr '\n' ' ')"
    
    # Validation
    if [[ -z "${SOURCE_CONFIG[username]}" ]]; then
        util::die "source.username not configured"
    fi
    
    if [[ -z "${SOURCE_CONFIG[token]}" ]]; then
        util::die "Source token not configured. Use source.token in config or GIST_SYNC_SOURCE_TOKEN"
    fi
    
    log::debug "Configuration loaded: provider=${SOURCE_CONFIG[provider]}, user=${SOURCE_CONFIG[username]}"
}

config::load_targets() {
    local config_file="$1"
    local target_count
    
    # Note: using "targets" (plural) for TOML array of tables
    case "$TOML_PARSER" in
        tomlq)
            target_count=$(tomlq '.targets | length' "$config_file" 2>/dev/null) || target_count=0
            ;;
        yq-go)
            target_count=$(yq -p toml -o json '.targets | length' "$config_file" 2>/dev/null) || target_count=0
            ;;
        *)
            target_count=$(toml::get "$config_file" '.targets | length' '0')
            ;;
    esac
    
    log::debug "Found $target_count targets"
    
    for ((i=0; i<target_count; i++)); do
        local enabled
        enabled="$(toml::get "$config_file" ".targets[$i].enabled" 'true')"
        
        if [[ "$enabled" != "true" ]]; then
            log::debug "Target $i disabled, skipping..."
            continue
        fi
        
        local name provider username token base_url
        name="$(toml::get "$config_file" ".targets[$i].name" "target-$i")"
        provider="$(toml::get "$config_file" ".targets[$i].provider" '')"
        username="$(toml::get "$config_file" ".targets[$i].username" '')"
        token="$(toml::get "$config_file" ".targets[$i].token" '')"
        base_url="$(toml::get "$config_file" ".targets[$i].base_url" '')"
        
        # Token from environment variable
        local env_var_name="GIST_SYNC_TARGET_${name^^}_TOKEN"
        env_var_name="${env_var_name//-/_}"
        local env_token="${!env_var_name:-}"
        if [[ -n "$env_token" ]]; then
            token="$env_token"
        fi
        
        # Sync config (flat structure - directly on target)
        local on_conflict preserve_desc visibility_mode delete_orphans
        on_conflict="$(toml::get "$config_file" ".targets[$i].on_conflict" 'update')"
        preserve_desc="$(toml::get "$config_file" ".targets[$i].preserve_description" 'true')"
        visibility_mode="$(toml::get "$config_file" ".targets[$i].visibility_mode" 'preserve')"
        delete_orphans="$(toml::get "$config_file" ".targets[$i].delete_orphans" 'false')"
        local desc_prefix desc_suffix
        desc_prefix="$(toml::get "$config_file" ".targets[$i].description_prefix" '')"
        desc_suffix="$(toml::get "$config_file" ".targets[$i].description_suffix" '')"
        
        # Bitbucket specific
        local workspace
        workspace="$(toml::get "$config_file" ".targets[$i].workspace" '')"
        
        # Keybase specific
        local team
        team="$(toml::get "$config_file" ".targets[$i].team" '')"
        
        if [[ -z "$provider" ]]; then
            log::warn "Target '$name' has no provider, skipping..."
            continue
        fi
        
        if [[ -z "$token" && "$provider" != "keybase" ]]; then
            log::warn "Target '$name' has no token, skipping..."
            continue
        fi
        
        # Store as JSON for easy access
        local target_json
        target_json=$(jq -n \
            --arg name "$name" \
            --arg provider "$provider" \
            --arg username "$username" \
            --arg token "$token" \
            --arg base_url "$base_url" \
            --arg on_conflict "$on_conflict" \
            --arg preserve_desc "$preserve_desc" \
            --arg visibility_mode "$visibility_mode" \
            --arg delete_orphans "$delete_orphans" \
            --arg desc_prefix "$desc_prefix" \
            --arg desc_suffix "$desc_suffix" \
            --arg workspace "$workspace" \
            --arg team "$team" \
            '{
                name: $name,
                provider: $provider,
                username: $username,
                token: $token,
                base_url: $base_url,
                on_conflict: $on_conflict,
                preserve_desc: $preserve_desc,
                visibility_mode: $visibility_mode,
                delete_orphans: $delete_orphans,
                desc_prefix: $desc_prefix,
                desc_suffix: $desc_suffix,
                workspace: $workspace,
                team: $team
            }')
        
        TARGETS+=("$target_json")
        log::debug "Target loaded: $name ($provider)"
    done
    
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        util::die "No enabled targets found"
    fi
    
    log::info "Loaded ${#TARGETS[@]} targets"
}

#===============================================================================
# HTTP CLIENT
#===============================================================================

http::request() {
    local method="$1"
    local url="$2"
    local token="${3:-}"
    local data="${4:-}"
    local extra_headers="${5:-}"
    
    local curl_args=(
        -s
        -X "$method"
        -H "Accept: application/json"
        -H "Content-Type: application/json"
        --max-time "${CONFIG[http_timeout]:-30}"
        -w "\n%{http_code}"
    )
    
    if [[ -n "$token" ]]; then
        curl_args+=(-H "Authorization: token $token")
    fi
    
    if [[ -n "$extra_headers" ]]; then
        while IFS= read -r header; do
            [[ -n "$header" ]] && curl_args+=(-H "$header")
        done <<< "$extra_headers"
    fi
    
    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi
    
    log::debug "HTTP $method $url"
    
    local response
    response=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || {
        log::error "HTTP request failed: $url"
        return 1
    }
    
    local http_code body
    http_code=$(tail -n1 <<< "$response")
    body=$(sed '$d' <<< "$response")
    
    log::debug "HTTP response code: $http_code"
    
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log::error "HTTP $http_code: $body"
        return 1
    fi
    
    printf '%s' "$body"
}

http::get() {
    http::request "GET" "$@"
}

http::post() {
    http::request "POST" "$@"
}

http::patch() {
    http::request "PATCH" "$@"
}

http::put() {
    http::request "PUT" "$@"
}

http::delete() {
    http::request "DELETE" "$1" "${2:-}" "" "${3:-}"
}

#===============================================================================
# PROVIDER: GITHUB (SOURCE)
#===============================================================================

github::get_base_url() {
    local base_url="${SOURCE_CONFIG[base_url]:-}"
    if [[ -n "$base_url" ]]; then
        echo "${base_url}/api/v3"
    else
        echo "https://api.github.com"
    fi
}

github::list_gists() {
    local username="${SOURCE_CONFIG[username]}"
    local token="${SOURCE_CONFIG[token]}"
    local base_url
    base_url="$(github::get_base_url)"
    
    local page=1
    local per_page=100
    local all_gists="[]"
    
    log::info "Fetching gists from $username on GitHub..."
    
    while true; do
        local url="${base_url}/users/${username}/gists?page=${page}&per_page=${per_page}"
        local response
        
        response=$(http::get "$url" "$token") || {
            log::error "Failed to list GitHub gists"
            return 1
        }
        
        local count
        count=$(jq 'length' <<< "$response")
        
        if [[ "$count" -eq 0 ]]; then
            break
        fi
        
        all_gists=$(jq -s '.[0] + .[1]' <<< "$all_gists"$'\n'"$response")
        
        log::debug "Page $page: $count gists"
        
        if [[ "$count" -lt "$per_page" ]]; then
            break
        fi
        
        ((page++))
        sleep "${CONFIG[rate_limit_interval]:-1}"
    done
    
    # Apply filters
    all_gists=$(github::apply_filters "$all_gists")
    
    local total
    total=$(jq 'length' <<< "$all_gists")
    log::info "Total gists after filters: $total"
    
    printf '%s' "$all_gists"
}

github::apply_filters() {
    local gists="$1"
    local filtered="$gists"
    
    # Filter by specific IDs
    if [[ -n "${SOURCE_CONFIG[gist_ids]}" ]]; then
        local ids_array
        ids_array=$(printf '%s' "${SOURCE_CONFIG[gist_ids]}" | tr ' ' '\n' | jq -R . | jq -s .)
        filtered=$(jq --argjson ids "$ids_array" '[.[] | select(.id as $id | $ids | index($id))]' <<< "$filtered")
        log::debug "Filter by IDs: $(jq 'length' <<< "$filtered") gists"
        printf '%s' "$filtered"
        return
    fi
    
    # Filter by visibility
    case "${SOURCE_CONFIG[visibility]}" in
        public)
            filtered=$(jq '[.[] | select(.public == true)]' <<< "$filtered")
            ;;
        private)
            filtered=$(jq '[.[] | select(.public == false)]' <<< "$filtered")
            ;;
    esac
    log::debug "Visibility filter (${SOURCE_CONFIG[visibility]}): $(jq 'length' <<< "$filtered") gists"
    
    # Filter by date
    if [[ -n "${SOURCE_CONFIG[since]}" ]]; then
        filtered=$(jq --arg since "${SOURCE_CONFIG[since]}" \
            '[.[] | select(.updated_at >= $since)]' <<< "$filtered")
        log::debug "Since filter: $(jq 'length' <<< "$filtered") gists"
    fi
    
    # Include patterns filter
    if [[ -n "${SOURCE_CONFIG[include_patterns]}" ]]; then
        local pattern="${SOURCE_CONFIG[include_patterns]}"
        pattern="${pattern%|}"  # Remove trailing |
        filtered=$(jq --arg pat "$pattern" \
            '[.[] | select((.description // "") | test($pat; "i"))]' <<< "$filtered") || filtered="$filtered"
        log::debug "Include filter: $(jq 'length' <<< "$filtered") gists"
    fi
    
    # Exclude patterns filter
    if [[ -n "${SOURCE_CONFIG[exclude_patterns]}" ]]; then
        local pattern="${SOURCE_CONFIG[exclude_patterns]}"
        pattern="${pattern%|}"
        filtered=$(jq --arg pat "$pattern" \
            '[.[] | select((.description // "") | test($pat; "i") | not)]' <<< "$filtered") || filtered="$filtered"
        log::debug "Exclude filter: $(jq 'length' <<< "$filtered") gists"
    fi
    
    printf '%s' "$filtered"
}

github::get_gist() {
    local gist_id="$1"
    local token="${SOURCE_CONFIG[token]}"
    local base_url
    base_url="$(github::get_base_url)"
    
    http::get "${base_url}/gists/${gist_id}" "$token"
}

github::get_gist_files() {
    local gist_json="$1"
    
    # Returns array of objects {filename, content, language, size}
    jq '[.files | to_entries[] | {
        filename: .key,
        content: .value.content,
        language: .value.language,
        size: .value.size,
        raw_url: .value.raw_url
    }]' <<< "$gist_json"
}

#===============================================================================
# PROVIDER: GITLAB
#===============================================================================

gitlab::get_base_url() {
    local target_json="$1"
    local base_url
    base_url=$(jq -r '.base_url // empty' <<< "$target_json")
    
    if [[ -n "$base_url" ]]; then
        echo "${base_url}/api/v4"
    else
        echo "https://gitlab.com/api/v4"
    fi
}

gitlab::list_snippets() {
    local target_json="$1"
    local base_url token
    base_url="$(gitlab::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    
    local page=1
    local per_page=100
    local all_snippets="[]"
    
    while true; do
        local url="${base_url}/snippets?page=${page}&per_page=${per_page}"
        local response
        
        # GitLab uses PRIVATE-TOKEN header
        response=$(http::get "$url" "" "" "PRIVATE-TOKEN: $token") || break
        
        local count
        count=$(jq 'length' <<< "$response")
        
        [[ "$count" -eq 0 ]] && break
        
        all_snippets=$(jq -s '.[0] + .[1]' <<< "$all_snippets"$'\n'"$response")
        
        [[ "$count" -lt "$per_page" ]] && break
        
        ((page++))
        sleep "${CONFIG[rate_limit_interval]:-1}"
    done
    
    printf '%s' "$all_snippets"
}

gitlab::find_snippet_by_title() {
    local target_json="$1"
    local title="$2"
    local snippets
    
    snippets=$(gitlab::list_snippets "$target_json")
    jq --arg title "$title" '[.[] | select(.title == $title)] | .[0] // empty' <<< "$snippets"
}

gitlab::create_snippet() {
    local target_json="$1"
    local title="$2"
    local description="$3"
    local visibility="$4"
    local files_json="$5"
    
    local base_url token
    base_url="$(gitlab::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    
    # GitLab uses visibility: public, internal, private
    local gl_visibility="$visibility"
    if [[ "$visibility" == "true" ]]; then
        gl_visibility="public"
    elif [[ "$visibility" == "false" ]]; then
        gl_visibility="private"
    fi
    
    # Build payload
    local files_array
    files_array=$(jq '[.[] | {file_path: .filename, content: .content}]' <<< "$files_json")
    
    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$description" \
        --arg vis "$gl_visibility" \
        --argjson files "$files_array" \
        '{
            title: $title,
            description: $desc,
            visibility: $vis,
            files: $files
        }')
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Create GitLab snippet: $title"
        return 0
    fi
    
    # GitLab uses PRIVATE-TOKEN header
    if http::post "${base_url}/snippets" "" "$payload" "PRIVATE-TOKEN: $token" >/dev/null; then
        log::success "Created: $title"
    else
        log::error "Failed to create: $title"
        return 1
    fi
}

gitlab::update_snippet() {
    local target_json="$1"
    local snippet_id="$2"
    local title="$3"
    local description="$4"
    local visibility="$5"
    local files_json="$6"
    
    local base_url token
    base_url="$(gitlab::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    
    local gl_visibility="$visibility"
    if [[ "$visibility" == "true" ]]; then
        gl_visibility="public"
    elif [[ "$visibility" == "false" ]]; then
        gl_visibility="private"
    fi
    
    # For update, GitLab expects actions: create, update, delete, move
    local files_array
    files_array=$(jq '[.[] | {
        action: "update",
        file_path: .filename,
        content: .content
    }]' <<< "$files_json")
    
    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$description" \
        --arg vis "$gl_visibility" \
        --argjson files "$files_array" \
        '{
            title: $title,
            description: $desc,
            visibility: $vis,
            files: $files
        }')
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Update GitLab snippet #$snippet_id: $title"
        return 0
    fi
    
    # GitLab uses PRIVATE-TOKEN header
    if http::put "${base_url}/snippets/${snippet_id}" "" "$payload" "PRIVATE-TOKEN: $token" >/dev/null; then
        log::success "Updated: $title"
    else
        log::error "Failed to update: $title"
        return 1
    fi
}

gitlab::delete_snippet() {
    local target_json="$1"
    local snippet_id="$2"
    
    local base_url token
    base_url="$(gitlab::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Delete GitLab snippet #$snippet_id"
        return 0
    fi
    
    # GitLab uses PRIVATE-TOKEN header
    if http::delete "${base_url}/snippets/${snippet_id}" "" "PRIVATE-TOKEN: $token" >/dev/null; then
        log::success "Deleted: snippet #$snippet_id"
    else
        log::error "Failed to delete: snippet #$snippet_id"
        return 1
    fi
}

#===============================================================================
# PROVIDER: GITEA / CODEBERG / FORGEJO
#===============================================================================

gitea::get_base_url() {
    local target_json="$1"
    local provider base_url
    provider=$(jq -r '.provider' <<< "$target_json")
    base_url=$(jq -r '.base_url // empty' <<< "$target_json")
    
    if [[ -n "$base_url" ]]; then
        echo "${base_url}/api/v1"
    else
        case "$provider" in
            codeberg) echo "https://codeberg.org/api/v1" ;;
            forgejo)  echo "https://forgejo.org/api/v1" ;;
            *)        echo "https://gitea.com/api/v1" ;;
        esac
    fi
}

gitea::list_snippets() {
    local target_json="$1"
    local base_url token username
    base_url="$(gitea::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    username=$(jq -r '.username' <<< "$target_json")
    
    # Gitea doesn't have native snippets API, uses repos with prefix
    # Alternative: list user repos that start with "gist-" or "snippet-"
    local url="${base_url}/users/${username}/repos?type=owner"
    local response
    
    response=$(http::get "$url" "$token") || {
        echo "[]"
        return
    }
    
    # Filter repos that are "gist-like" (e.g., start with gist-)
    jq '[.[] | select(.name | startswith("gist-") or startswith("snippet-"))]' <<< "$response"
}

gitea::find_snippet_by_name() {
    local target_json="$1"
    local name="$2"
    local base_url token username
    base_url="$(gitea::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    username=$(jq -r '.username' <<< "$target_json")
    
    local repo_name="gist-${name}"
    local url="${base_url}/repos/${username}/${repo_name}"
    
    http::get "$url" "$token" 2>/dev/null || echo ""
}

gitea::create_snippet() {
    local target_json="$1"
    local name="$2"
    local description="$3"
    local visibility="$4"
    local files_json="$5"
    
    local base_url token username
    base_url="$(gitea::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    username=$(jq -r '.username' <<< "$target_json")
    
    local repo_name="gist-${name}"
    local private="false"
    [[ "$visibility" == "false" || "$visibility" == "private" ]] && private="true"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Create Gitea repo: $repo_name"
        return 0
    fi
    
    # 1. Create repository
    local repo_payload
    repo_payload=$(jq -n \
        --arg name "$repo_name" \
        --arg desc "$description" \
        --argjson private "$private" \
        '{
            name: $name,
            description: $desc,
            private: $private,
            auto_init: true
        }')
    
    local repo_response
    repo_response=$(http::post "${base_url}/user/repos" "$token" "$repo_payload") || {
        log::error "Failed to create repository $repo_name"
        return 1
    }
    
    # 2. Add files via contents API
    local files_count
    files_count=$(jq 'length' <<< "$files_json")
    
    for ((i=0; i<files_count; i++)); do
        local filename content
        filename=$(jq -r ".[$i].filename" <<< "$files_json")
        content=$(jq -r ".[$i].content" <<< "$files_json")
        
        local content_b64
        content_b64=$(printf '%s' "$content" | base64 -w0)
        
        local file_payload
        file_payload=$(jq -n \
            --arg content "$content_b64" \
            --arg message "Add $filename" \
            '{
                content: $content,
                message: $message
            }')
        
        http::post "${base_url}/repos/${username}/${repo_name}/contents/${filename}" "$token" "$file_payload" || {
            log::warn "Failed to add file $filename"
        }
        
        sleep 0.5
    done
    
    log::success "Created: $repo_name"
}

gitea::update_snippet() {
    local target_json="$1"
    local name="$2"
    local description="$3"
    local visibility="$4"
    local files_json="$5"
    
    local base_url token username
    base_url="$(gitea::get_base_url "$target_json")"
    token=$(jq -r '.token' <<< "$target_json")
    username=$(jq -r '.username' <<< "$target_json")
    
    local repo_name="gist-${name}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Update Gitea repo: $repo_name"
        return 0
    fi
    
    # Update each file
    local files_count
    files_count=$(jq 'length' <<< "$files_json")
    
    for ((i=0; i<files_count; i++)); do
        local filename content
        filename=$(jq -r ".[$i].filename" <<< "$files_json")
        content=$(jq -r ".[$i].content" <<< "$files_json")
        
        # Get current file SHA (required for update)
        local file_info sha
        file_info=$(http::get "${base_url}/repos/${username}/${repo_name}/contents/${filename}" "$token" 2>/dev/null) || true
        sha=$(jq -r '.sha // empty' <<< "$file_info")
        
        local content_b64
        content_b64=$(printf '%s' "$content" | base64 -w0)
        
        local file_payload
        if [[ -n "$sha" ]]; then
            file_payload=$(jq -n \
                --arg content "$content_b64" \
                --arg sha "$sha" \
                --arg message "Update $filename" \
                '{
                    content: $content,
                    sha: $sha,
                    message: $message
                }')
            http::put "${base_url}/repos/${username}/${repo_name}/contents/${filename}" "$token" "$file_payload" || {
                log::warn "Failed to update file $filename"
            }
        else
            file_payload=$(jq -n \
                --arg content "$content_b64" \
                --arg message "Add $filename" \
                '{
                    content: $content,
                    message: $message
                }')
            http::post "${base_url}/repos/${username}/${repo_name}/contents/${filename}" "$token" "$file_payload" || {
                log::warn "Failed to add file $filename"
            }
        fi
        
        sleep 0.5
    done
    
    log::success "Updated: $repo_name"
}

#===============================================================================
# PROVIDER: BITBUCKET
#===============================================================================

bitbucket::get_base_url() {
    echo "https://api.bitbucket.org/2.0"
}

bitbucket::list_snippets() {
    local target_json="$1"
    local base_url token workspace
    base_url="$(bitbucket::get_base_url)"
    token=$(jq -r '.token' <<< "$target_json")
    workspace=$(jq -r '.workspace // .username' <<< "$target_json")
    
    local url="${base_url}/snippets/${workspace}"
    local all_snippets="[]"
    
    while [[ -n "$url" ]]; do
        local response
        response=$(http::get "$url" "$token") || break
        
        local snippets
        snippets=$(jq '.values // []' <<< "$response")
        all_snippets=$(jq -s '.[0] + .[1]' <<< "$all_snippets"$'\n'"$snippets")
        
        url=$(jq -r '.next // empty' <<< "$response")
        [[ -z "$url" || "$url" == "null" ]] && break
        
        sleep "${CONFIG[rate_limit_interval]:-1}"
    done
    
    printf '%s' "$all_snippets"
}

bitbucket::find_snippet_by_title() {
    local target_json="$1"
    local title="$2"
    local snippets
    
    snippets=$(bitbucket::list_snippets "$target_json")
    jq --arg title "$title" '[.[] | select(.title == $title)] | .[0] // empty' <<< "$snippets"
}

bitbucket::create_snippet() {
    local target_json="$1"
    local title="$2"
    local description="$3"
    local visibility="$4"
    local files_json="$5"
    
    local base_url token workspace
    base_url="$(bitbucket::get_base_url)"
    token=$(jq -r '.token' <<< "$target_json")
    workspace=$(jq -r '.workspace // .username' <<< "$target_json")
    
    local is_private="false"
    [[ "$visibility" == "false" || "$visibility" == "private" ]] && is_private="true"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Create Bitbucket snippet: $title"
        return 0
    fi
    
    # Bitbucket uses multipart/form-data to create snippets with files
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    # Save files temporarily
    local files_count
    files_count=$(jq 'length' <<< "$files_json")
    
    local curl_files=()
    for ((i=0; i<files_count; i++)); do
        local filename content filepath
        filename=$(jq -r ".[$i].filename" <<< "$files_json")
        content=$(jq -r ".[$i].content" <<< "$files_json")
        filepath="${tmp_dir}/${filename}"
        
        printf '%s' "$content" > "$filepath"
        curl_files+=(-F "file=@${filepath}")
    done
    
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -F "title=$title" \
        -F "is_private=$is_private" \
        "${curl_files[@]}" \
        "${base_url}/snippets/${workspace}" \
        -w "\n%{http_code}") || {
        rm -rf "$tmp_dir"
        return 1
    }
    
    rm -rf "$tmp_dir"
    
    local http_code body
    http_code=$(tail -n1 <<< "$response")
    body=$(sed '$d' <<< "$response")
    
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log::error "Bitbucket HTTP $http_code: $body"
        return 1
    fi
    
    log::success "Created Bitbucket snippet: $title"
}

bitbucket::update_snippet() {
    local target_json="$1"
    local snippet_id="$2"
    local title="$3"
    local description="$4"
    local visibility="$5"
    local files_json="$6"
    
    local base_url token workspace
    base_url="$(bitbucket::get_base_url)"
    token=$(jq -r '.token' <<< "$target_json")
    workspace=$(jq -r '.workspace // .username' <<< "$target_json")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Update Bitbucket snippet: $snippet_id"
        return 0
    fi
    
    # Similar to create, but PUT
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    local files_count
    files_count=$(jq 'length' <<< "$files_json")
    
    local curl_files=()
    for ((i=0; i<files_count; i++)); do
        local filename content filepath
        filename=$(jq -r ".[$i].filename" <<< "$files_json")
        content=$(jq -r ".[$i].content" <<< "$files_json")
        filepath="${tmp_dir}/${filename}"
        
        printf '%s' "$content" > "$filepath"
        curl_files+=(-F "file=@${filepath}")
    done
    
    curl -s -X PUT \
        -H "Authorization: Bearer $token" \
        -F "title=$title" \
        "${curl_files[@]}" \
        "${base_url}/snippets/${workspace}/${snippet_id}" >/dev/null
    
    rm -rf "$tmp_dir"
    
    log::success "Updated Bitbucket snippet: $snippet_id"
}

#===============================================================================
# PROVIDER: KEYBASE
#===============================================================================

keybase::check_available() {
    if ! command -v keybase &>/dev/null; then
        log::error "Keybase CLI not installed"
        return 1
    fi
    
    if ! keybase status &>/dev/null; then
        log::error "Keybase not logged in"
        return 1
    fi
    
    return 0
}

keybase::get_git_path() {
    local target_json="$1"
    local name="$2"
    local username team
    username=$(jq -r '.username' <<< "$target_json")
    team=$(jq -r '.team // empty' <<< "$target_json")
    
    if [[ -n "$team" ]]; then
        echo "keybase://team/${team}/gist-${name}"
    else
        echo "keybase://private/${username}/gist-${name}"
    fi
}

keybase::list_repos() {
    local target_json="$1"
    local username team
    username=$(jq -r '.username' <<< "$target_json")
    team=$(jq -r '.team // empty' <<< "$target_json")
    
    if [[ -n "$team" ]]; then
        keybase git list --team "$team" 2>/dev/null | grep -E '^gist-' || true
    else
        keybase git list 2>/dev/null | grep -E '^gist-' || true
    fi
}

keybase::create_repo() {
    local target_json="$1"
    local name="$2"
    local team
    team=$(jq -r '.team // empty' <<< "$target_json")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Create Keybase repo: gist-${name}"
        return 0
    fi
    
    if [[ -n "$team" ]]; then
        keybase git create "gist-${name}" --team "$team"
    else
        keybase git create "gist-${name}"
    fi
}

keybase::sync_files() {
    local target_json="$1"
    local name="$2"
    local files_json="$3"
    
    local git_path
    git_path="$(keybase::get_git_path "$target_json" "$name")"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log::dry_run "Sync files to Keybase: $git_path"
        return 0
    fi
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    # Clone or init
    if git clone "$git_path" "$tmp_dir" 2>/dev/null; then
        log::debug "Cloned existing repository"
    else
        cd "$tmp_dir"
        git init
        git remote add origin "$git_path"
    fi
    
    cd "$tmp_dir"
    
    # Clean and add files
    rm -f ./*
    
    local files_count
    files_count=$(jq 'length' <<< "$files_json")
    
    for ((i=0; i<files_count; i++)); do
        local filename content
        filename=$(jq -r ".[$i].filename" <<< "$files_json")
        content=$(jq -r ".[$i].content" <<< "$files_json")
        printf '%s' "$content" > "$filename"
    done
    
    git add -A
    if git diff --cached --quiet; then
        log::debug "No changes to commit"
    else
        git commit -m "Sync from gist-sync"
        git push -u origin main 2>/dev/null || git push -u origin master
    fi
    
    cd - >/dev/null
    rm -rf "$tmp_dir"
    
    log::success "Synced to Keybase: gist-${name}"
}

#===============================================================================
# MAIN SYNCHRONIZATION
#===============================================================================

sync::get_gist_identifier() {
    local gist_json="$1"
    
    # Use first file as identifier, or truncated ID
    local first_file description gist_id
    first_file=$(jq -r '.files | keys[0] // empty' <<< "$gist_json")
    description=$(jq -r '.description // empty' <<< "$gist_json")
    gist_id=$(jq -r '.id' <<< "$gist_json")
    
    # Create unique identifier based on description or filename
    if [[ -n "$description" ]]; then
        # Sanitize description for use as name
        printf '%s' "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g' | cut -c1-50
    elif [[ -n "$first_file" ]]; then
        printf '%s' "${first_file%.*}"
    else
        printf '%s' "${gist_id:0:8}"
    fi
}

sync::determine_visibility() {
    local gist_public="$1"
    local target_json="$2"
    local mode
    mode=$(jq -r '.visibility_mode' <<< "$target_json")
    
    case "$mode" in
        preserve)
            echo "$gist_public"
            ;;
        public)
            echo "true"
            ;;
        private)
            echo "false"
            ;;
        internal)
            echo "internal"
            ;;
        *)
            echo "$gist_public"
            ;;
    esac
}

sync::format_description() {
    local description="$1"
    local target_json="$2"
    local preserve prefix suffix
    
    preserve=$(jq -r '.preserve_desc' <<< "$target_json")
    prefix=$(jq -r '.desc_prefix // empty' <<< "$target_json")
    suffix=$(jq -r '.desc_suffix // empty' <<< "$target_json")
    
    if [[ "$preserve" == "true" ]]; then
        printf '%s%s%s' "$prefix" "$description" "$suffix"
    else
        printf '%s%s' "$prefix" "$suffix"
    fi
}

sync::to_gitlab() {
    local target_json="$1"
    local gist_json="$2"
    local gist_id identifier description visibility files_json
    
    gist_id=$(jq -r '.id' <<< "$gist_json")
    identifier=$(sync::get_gist_identifier "$gist_json")
    description=$(jq -r '.description // ""' <<< "$gist_json")
    description=$(sync::format_description "$description" "$target_json")
    visibility=$(sync::determine_visibility "$(jq -r '.public' <<< "$gist_json")" "$target_json")
    files_json=$(github::get_gist_files "$gist_json")
    
    local target_name
    target_name=$(jq -r '.name' <<< "$target_json")
    
    log::info "  → GitLab ($target_name): $identifier"
    
    # Find existing snippet
    local existing
    existing=$(gitlab::find_snippet_by_title "$target_json" "$identifier")
    
    local on_conflict
    on_conflict=$(jq -r '.on_conflict' <<< "$target_json")
    
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        local snippet_id
        snippet_id=$(jq -r '.id' <<< "$existing")
        
        case "$on_conflict" in
            skip)
                log::debug "    Snippet exists, skipping (on_conflict=skip)"
                return 0
                ;;
            update|replace)
                gitlab::update_snippet "$target_json" "$snippet_id" "$identifier" "$description" "$visibility" "$files_json"
                ;;
        esac
    else
        gitlab::create_snippet "$target_json" "$identifier" "$description" "$visibility" "$files_json"
    fi
}

sync::to_gitea() {
    local target_json="$1"
    local gist_json="$2"
    local identifier description visibility files_json
    
    identifier=$(sync::get_gist_identifier "$gist_json")
    description=$(jq -r '.description // ""' <<< "$gist_json")
    description=$(sync::format_description "$description" "$target_json")
    visibility=$(sync::determine_visibility "$(jq -r '.public' <<< "$gist_json")" "$target_json")
    files_json=$(github::get_gist_files "$gist_json")
    
    local target_name provider
    target_name=$(jq -r '.name' <<< "$target_json")
    provider=$(jq -r '.provider' <<< "$target_json")
    
    log::info "  → ${provider^} ($target_name): $identifier"
    
    # Check if repo exists
    local existing
    existing=$(gitea::find_snippet_by_name "$target_json" "$identifier")
    
    local on_conflict
    on_conflict=$(jq -r '.on_conflict' <<< "$target_json")
    
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        case "$on_conflict" in
            skip)
                log::debug "    Repo exists, skipping (on_conflict=skip)"
                return 0
                ;;
            update|replace)
                gitea::update_snippet "$target_json" "$identifier" "$description" "$visibility" "$files_json"
                ;;
        esac
    else
        gitea::create_snippet "$target_json" "$identifier" "$description" "$visibility" "$files_json"
    fi
}

sync::to_bitbucket() {
    local target_json="$1"
    local gist_json="$2"
    local identifier description visibility files_json
    
    identifier=$(sync::get_gist_identifier "$gist_json")
    description=$(jq -r '.description // ""' <<< "$gist_json")
    description=$(sync::format_description "$description" "$target_json")
    visibility=$(sync::determine_visibility "$(jq -r '.public' <<< "$gist_json")" "$target_json")
    files_json=$(github::get_gist_files "$gist_json")
    
    local target_name
    target_name=$(jq -r '.name' <<< "$target_json")
    
    log::info "  → Bitbucket ($target_name): $identifier"
    
    # Find existing snippet
    local existing
    existing=$(bitbucket::find_snippet_by_title "$target_json" "$identifier")
    
    local on_conflict
    on_conflict=$(jq -r '.on_conflict' <<< "$target_json")
    
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        local snippet_id
        snippet_id=$(jq -r '.id' <<< "$existing")
        
        case "$on_conflict" in
            skip)
                log::debug "    Snippet exists, skipping (on_conflict=skip)"
                return 0
                ;;
            update|replace)
                bitbucket::update_snippet "$target_json" "$snippet_id" "$identifier" "$description" "$visibility" "$files_json"
                ;;
        esac
    else
        bitbucket::create_snippet "$target_json" "$identifier" "$description" "$visibility" "$files_json"
    fi
}

sync::to_keybase() {
    local target_json="$1"
    local gist_json="$2"
    
    if ! keybase::check_available; then
        log::warn "Keybase not available, skipping..."
        return 0
    fi
    
    local identifier files_json
    identifier=$(sync::get_gist_identifier "$gist_json")
    files_json=$(github::get_gist_files "$gist_json")
    
    local target_name
    target_name=$(jq -r '.name' <<< "$target_json")
    
    log::info "  → Keybase ($target_name): $identifier"
    
    # Check if repo exists
    local existing_repos
    existing_repos=$(keybase::list_repos "$target_json")
    
    if ! grep -q "^gist-${identifier}$" <<< "$existing_repos"; then
        keybase::create_repo "$target_json" "$identifier"
    fi
    
    keybase::sync_files "$target_json" "$identifier" "$files_json"
}

sync::gist_to_target() {
    local target_json="$1"
    local gist_json="$2"
    local provider
    
    provider=$(jq -r '.provider' <<< "$target_json")
    
    case "$provider" in
        gitlab)
            sync::to_gitlab "$target_json" "$gist_json"
            ;;
        gitea|codeberg|forgejo)
            sync::to_gitea "$target_json" "$gist_json"
            ;;
        bitbucket)
            sync::to_bitbucket "$target_json" "$gist_json"
            ;;
        keybase)
            sync::to_keybase "$target_json" "$gist_json"
            ;;
        *)
            log::warn "Unsupported provider: $provider"
            ;;
    esac
}

sync::run() {
    local gists
    
    # Execute pre_sync hook if configured
    if [[ -n "${CONFIG[pre_sync]:-}" ]]; then
        log::debug "Executing pre_sync hook..."
        eval "${CONFIG[pre_sync]}" || true
    fi
    
    # List gists from source
    gists=$(github::list_gists) || {
        log::error "Failed to get gists from source"
        return 1
    }
    
    local gist_count
    gist_count=$(jq 'length' <<< "$gists")
    
    if [[ "$gist_count" -eq 0 ]]; then
        log::warn "No gists found to sync"
        return 0
    fi
    
    log::info "Starting sync of $gist_count gists to ${#TARGETS[@]} targets..."
    
    local success_count=0
    local error_count=0
    
    # Iterate over each gist
    for ((i=0; i<gist_count; i++)); do
        local gist_json gist_id gist_desc
        gist_json=$(jq ".[$i]" <<< "$gists")
        gist_id=$(jq -r '.id' <<< "$gist_json")
        gist_desc=$(jq -r '.description // "(no description)"' <<< "$gist_json")
        
        log::info "[$((i+1))/$gist_count] Gist: ${gist_desc:0:50}..."
        
        # Get full gist details (with file contents)
        local full_gist
        full_gist=$(github::get_gist "$gist_id") || {
            log::error "  Failed to get gist details $gist_id"
            ((error_count++))
            continue
        }
        
        # Sync to each target
        for target_json in "${TARGETS[@]}"; do
            if sync::gist_to_target "$target_json" "$full_gist"; then
                ((success_count++)) || true
            else
                ((error_count++)) || true
            fi
            
            # Rate limiting between targets
            sleep "${CONFIG[rate_limit_interval]:-1}"
        done
    done
    
    log::info "Sync complete: $success_count successful, $error_count errors"
    
    # Execute post_sync hook if configured
    if [[ -n "${CONFIG[post_sync]:-}" ]] && [[ "$error_count" -eq 0 ]]; then
        log::debug "Executing post_sync hook..."
        eval "${CONFIG[post_sync]}" || true
    fi
    
    # Execute on_error hook if there were errors
    if [[ -n "${CONFIG[on_error]:-}" ]] && [[ "$error_count" -gt 0 ]]; then
        log::debug "Executing on_error hook..."
        eval "${CONFIG[on_error]}" || true
    fi
    
    return $((error_count > 0 ? 1 : 0))
}

#===============================================================================
# CLI
#===============================================================================

cli::usage() {
    cat <<EOF
${BOLD}gist-sync${RESET} v${SCRIPT_VERSION} - Multi-platform gist/snippet synchronizer

${BOLD}USAGE:${RESET}
    $SCRIPT_NAME [options] [command]

${BOLD}COMMANDS:${RESET}
    sync        Synchronize gists (default)
    list        List gists from source
    targets     List configured targets
    validate    Validate configuration file

${BOLD}OPTIONS:${RESET}
    -c, --config FILE    Configuration file (default: ~/.config/gist-sync/config.toml)
    -n, --dry-run        Run without making changes
    -v, --verbose        Verbose mode (debug)
    -q, --quiet          Quiet mode (errors only)
    -h, --help           Show this help
    --version            Show version

${BOLD}ENVIRONMENT VARIABLES:${RESET}
    GIST_SYNC_SOURCE_TOKEN           Source provider token
    GIST_SYNC_TARGET_<NAME>_TOKEN    Target token (NAME in uppercase, - becomes _)

${BOLD}EXAMPLES:${RESET}
    $SCRIPT_NAME sync
    $SCRIPT_NAME --dry-run sync
    $SCRIPT_NAME -c ~/custom-config.toml sync
    $SCRIPT_NAME list
    $SCRIPT_NAME targets

${BOLD}SUPPORTED PROVIDERS:${RESET}
    Source:  github
    Target:  gitlab, gitea, codeberg, forgejo, bitbucket, keybase
EOF
}

cli::version() {
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
}

cli::list_gists() {
    local gists
    gists=$(github::list_gists) || return 1
    
    printf "\n${BOLD}%-8s  %-6s  %-20s  %s${RESET}\n" "ID" "PUBLIC" "UPDATED" "DESCRIPTION"
    printf "%s\n" "$(printf '─%.0s' {1..80})"
    
    jq -r '.[] | [.id[:8], (if .public then "yes" else "no" end), .updated_at[:10], (.description // "(no description)")[:40]] | @tsv' <<< "$gists" | \
    while IFS=$'\t' read -r id public updated desc; do
        printf "%-8s  %-6s  %-20s  %s\n" "$id" "$public" "$updated" "$desc"
    done
}

cli::list_targets() {
    printf "\n${BOLD}%-20s  %-10s  %-10s  %s${RESET}\n" "NAME" "PROVIDER" "ENABLED" "USERNAME"
    printf "%s\n" "$(printf '─%.0s' {1..60})"
    
    for target_json in "${TARGETS[@]}"; do
        local name provider username
        name=$(jq -r '.name' <<< "$target_json")
        provider=$(jq -r '.provider' <<< "$target_json")
        username=$(jq -r '.username' <<< "$target_json")
        
        printf "%-20s  %-10s  %-10s  %s\n" "$name" "$provider" "yes" "$username"
    done
}

cli::validate() {
    log::info "Validating configuration: $CONFIG_FILE"
    
    # Check if file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        util::die "File not found: $CONFIG_FILE"
    fi
    
    # Check TOML syntax
    if command -v tomlq &>/dev/null; then
        if ! tomlq '.' "$CONFIG_FILE" &>/dev/null; then
            util::die "TOML syntax error"
        fi
    else
        if ! yq -p toml '.' "$CONFIG_FILE" &>/dev/null; then
            util::die "TOML syntax error"
        fi
    fi
    
    # Load and validate
    config::load "$CONFIG_FILE"
    config::load_targets "$CONFIG_FILE"
    
    log::success "Configuration valid!"
    log::info "  Source: ${SOURCE_CONFIG[provider]} (${SOURCE_CONFIG[username]})"
    log::info "  Targets: ${#TARGETS[@]} configured"
}

cli::parse_args() {
    local command="sync"
    CONFIG_FILE="$DEFAULT_CONFIG_FILE"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                LOG_LEVEL=3
                shift
                ;;
            -q|--quiet)
                LOG_LEVEL=0
                shift
                ;;
            -h|--help)
                cli::usage
                exit 0
                ;;
            --version)
                cli::version
                exit 0
                ;;
            sync|list|targets|validate)
                command="$1"
                shift
                ;;
            *)
                util::die "Unknown option: $1"
                ;;
        esac
    done
    
    echo "$command"
}

main() {
    local command
    command=$(cli::parse_args "$@")
    
    # Check dependencies
    util::check_dependencies
    
    # Create default config directory if it doesn't exist
    util::ensure_dir "$DEFAULT_CONFIG_DIR"
    
    # Check if config exists (try multiple locations)
    if [[ ! -f "$CONFIG_FILE" ]]; then
        # Fallback 1: config.toml in script directory
        if [[ -f "${SCRIPT_DIR}/config.toml" ]]; then
            CONFIG_FILE="${SCRIPT_DIR}/config.toml"
            log::debug "Using config from script directory: $CONFIG_FILE"
        # Fallback 2: config.toml in current directory
        elif [[ -f "./config.toml" ]]; then
            CONFIG_FILE="./config.toml"
            log::debug "Using config from current directory: $CONFIG_FILE"
        else
            util::die "Configuration file not found. Searched locations:
  1. $CONFIG_FILE
  2. ${SCRIPT_DIR}/config.toml
  3. ./config.toml

Create from example: cp ${SCRIPT_DIR}/config.example.toml ${DEFAULT_CONFIG_FILE}"
        fi
    fi
    
    # Load configuration
    config::load "$CONFIG_FILE"
    config::load_targets "$CONFIG_FILE"
    
    # Execute command
    case "$command" in
        sync)
            [[ "$DRY_RUN" == "true" ]] && log::warn "Dry-run mode enabled"
            sync::run
            ;;
        list)
            cli::list_gists
            ;;
        targets)
            cli::list_targets
            ;;
        validate)
            cli::validate
            ;;
        *)
            util::die "Unknown command: $command"
            ;;
    esac
}

# Run only if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
