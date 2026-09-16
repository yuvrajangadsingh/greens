#!/bin/bash
# GitLab and Git-only source providers. Sourced by sync.sh after its privacy gate.

gitlab_api() {
  local endpoint="$1" output="$2" attempt parsed="$2.parsed"
  for attempt in 1 2 3; do
    if greens_run glab api --hostname "$GITLAB_HOST" "$endpoint" --paginate > "$output.raw"; then
      if jq -s 'if all(.[]; type == "array") then add else .[0] end' "$output.raw" > "$parsed"; then
        mv "$parsed" "$output"
        rm -f "$output.raw"
        return 0
      fi
      rm -f "$parsed"
    fi
    [[ "$attempt" == 3 ]] || sleep "$((attempt * 2))"
  done
  log "ERROR: GitLab request failed; checkpoint was not advanced: $endpoint"
  return 1
}

gitlab_records() {
  local mode="$1" input="$2" kind="${3:-}"
  jq -c --arg mode "$mode" --arg kind "$kind" --arg host "$GITLAB_HOST" \
    --arg path "$project_path" --argjson project "$project_id" \
    --argjson user "$gitlab_user_id" --argjson since "$since_epoch" \
    --argjson until "$run_epoch" -f "$SCRIPT_DIR/lib/gitlab.jq" "$input"
}

gitlab_collect_object() {
  local kind="$1" objects="$2" iid="$3" output="$4"
  : > "$output"
  if [[ ",$ACTIVITY_TYPES," == *,comments,* ]]; then
    gitlab_api "projects/$project_id/$objects/$iid/discussions?per_page=100" "$output.discussions" || return 1
    gitlab_records discussions "$output.discussions" "$kind" >> "$output" || return 1
    rm -f "$output.discussions"
  fi
  if [[ ",$ACTIVITY_TYPES," == *,state_changes,* || ",$ACTIVITY_TYPES," == *,merges,* ]]; then
    gitlab_api "projects/$project_id/$objects/$iid/resource_state_events?per_page=100" "$output.states" || return 1
    gitlab_records states "$output.states" "$kind" >> "$output" || return 1
    rm -f "$output.states"
  fi
}

greens_discover_sources() {
  local gitpath repodir url identity host
  while IFS= read -r -d '' gitpath; do
    repodir="$(dirname "$gitpath")"
    case "$repodir/" in "$CACHE_DIR/"*|"$MIRROR_DIR/"*) continue ;; esac
    url="$(git -C "$repodir" config remote.origin.url 2>/dev/null || true)"
    identity="$(greens_remote_identity "$url")" || continue
    if [[ "$SOURCE_PROVIDER" == gitlab ]]; then
      host="${identity%%/*}"
      [[ "$host" == "${GITLAB_REMOTE_HOST:-${GITLAB_HOST%%:*}}" || "$host" == "${GITLAB_HOST%%:*}" ]] || continue
      identity="$GITLAB_HOST/${identity#*/}"
    else
      [[ "$url" == "$REMOTE_PREFIX"* ]] || continue
    fi
    printf '%s\t%s\n' "$identity" "$url"
  done < <(greens_find_git_entries "$WORK_DIR" "${SCAN_MODE:-recursive}")
}

greens_mixed_discover_checkouts() {
  local dir gitpath repodir url identity host rest organization i aliases api canonical
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || { log "WARN: work directory is unavailable: $dir" >&2; continue; }
    while IFS= read -r -d '' gitpath; do
      repodir="$(dirname "$gitpath")"
      case "$repodir/" in "$CACHE_DIR/"*|"$MIRROR_DIR/"*) continue ;; esac
      url="$(git -C "$repodir" config remote.origin.url 2>/dev/null || true)"
      identity="$(greens_remote_identity "$url")" || continue
      host="${identity%%/*}"; rest="${identity#*/}"; organization="${rest%%/*}"
      for ((i=1; i<=SOURCE_COUNT; i++)); do
        [[ "$(greens_indexed_value "$i" ORGANIZATION)" == "$organization" ]] || continue
        aliases="$(greens_indexed_value "$i" REMOTE_HOSTS)"
        case ",$aliases," in *",$host,"*) ;; *) continue ;; esac
        api="$(greens_indexed_value "$i" API_HOST)"
        canonical="$api/${identity#*/}"
        printf '%s\t%s\t%s\t%s\n' "$i" "$canonical" "$url" "$repodir"
        break
      done
    done < <(greens_find_git_entries "$dir" "${SCAN_MODE:-recursive}")
  done <<< "$WORK_DIRS" | LC_ALL=C sort -t $'\t' -k2,2 -k4,4 -u
}

greens_mixed_discover_sources() {
  greens_mixed_discover_checkouts | cut -f1-3 | LC_ALL=C sort -t $'\t' -k2,2 -u
}

github_api_records() {
  local kind="$1" output="$2" owner_type="$3" query date_field label qualifier
  case "$owner_type" in
    User) qualifier="user:$SOURCE_ORGANIZATION" ;;
    Organization) qualifier="org:$SOURCE_ORGANIZATION" ;;
    *) log "ERROR: unsupported GitHub owner type for $SOURCE_API_HOST/$SOURCE_ORGANIZATION: $owner_type"; return 1 ;;
  esac
  case "$kind" in
    prs) query="type:pr author:$SOURCE_USERNAME $qualifier created:>=$since_date"; date_field=created_at; label="prs" ;;
    issues) query="type:issue author:$SOURCE_USERNAME $qualifier created:>=$since_date"; date_field=created_at; label="issues" ;;
    reviews) query="type:pr reviewed-by:$SOURCE_USERNAME $qualifier updated:>=$since_date"; date_field=updated_at; label="reviews" ;;
    *) return 1 ;;
  esac
  if ! greens_gh_api_as "$SOURCE_API_HOST" "$SOURCE_USERNAME" --paginate -X GET search/issues \
      -f q="$query" -f per_page=100 > "$output.raw"; then
    log "ERROR: GitHub request failed for $SOURCE_API_HOST/$SOURCE_ORGANIZATION"
    return 1
  fi
  jq -sc --arg host "$SOURCE_API_HOST" --arg org "$SOURCE_ORGANIZATION" \
    --arg kind "$label" --arg date_field "$date_field" --argjson since "$since_epoch" --argjson until "$run_epoch" '
    [.[].items[]?] | unique_by(.id)[] |
    .[$date_field] as $date | ($date|fromdateiso8601) as $epoch |
    select($epoch >= $since and $epoch <= $until) |
    {key:($host+"/"+$org+"/github/"+$kind+"/"+(.id|tostring)+(if $kind=="reviews" then "/"+$date else "" end)),epoch:$epoch,date:($date|sub("Z$";" +0000")|sub("T";" ")),kind:$kind,project:(.repository_url|split("/repos/")|last)}' \
    "$output.raw"
}

greens_source_access_mode() {
  local mode
  mode="$(greens_indexed_value "$1" ACCESS_MODE)"
  printf '%s\n' "${mode:-remote}"
}

greens_persist_local_source() {
  local source_index="$1" access_key="SOURCE_${1}_ACCESS_MODE" types_key="SOURCE_${1}_ACTIVITY_TYPES"
  printf -v "$access_key" '%s' local
  printf -v "$types_key" '%s' commits
  greens_save_config "$CONFIG_FILE" "$access_key" "$types_key"
}

greens_is_interactive() {
  [[ -t 0 && -t 1 ]]
}

greens_offer_local_fallback() {
  local source_index="$1" reason="$2" answer api organization
  api="$(greens_indexed_value "$source_index" API_HOST)"; organization="$(greens_indexed_value "$source_index" ORGANIZATION)"
  log "ERROR: remote access failed for $api/$organization: $reason"
  if ! greens_is_interactive; then
    log "Run greens interactively to approve local-only commit collection for this source."
    return 1
  fi
  printf "Use local commit history only for all %s/%s repositories and save this choice? (y/N): " "$api" "$organization" >&2
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 1
  greens_persist_local_source "$source_index" || { log "ERROR: could not save local-only mode"; return 1; }
  log "Saved $api/$organization as local-only (commits only)."
}

greens_validate_local_sources() {
  local checkouts="$1" source_index mode types api organization
  for ((source_index=1; source_index<=SOURCE_COUNT; source_index++)); do
    mode="$(greens_source_access_mode "$source_index")"
    [[ "$mode" == local ]] || continue
    types="$(greens_indexed_value "$source_index" ACTIVITY_TYPES)"
    [[ "$types" == commits ]] || { log "ERROR: local source $source_index only supports ACTIVITY_TYPES=commits"; return 1; }
    if ! awk -F '\t' -v source="$source_index" '$1 == source { found=1; exit } END { exit !found }' "$checkouts"; then
      api="$(greens_indexed_value "$source_index" API_HOST)"; organization="$(greens_indexed_value "$source_index" ORGANIZATION)"
      log "ERROR: no matching checkout remains for local source $api/$organization"
      return 1
    fi
  done
}

greens_preflight_mixed_sources() {
  local sources="$1" source_index identity url mode provider api username types key encoded api_user api_done
  while IFS=$'\t' read -r source_index identity url; do
    mode="$(greens_source_access_mode "$source_index")"
    types="$(greens_indexed_value "$source_index" ACTIVITY_TYPES)"
    if [[ "$mode" == local ]]; then
      [[ "$types" == commits ]] || { log "ERROR: local source $source_index only supports ACTIVITY_TYPES=commits"; return 1; }
      continue
    fi
    [[ "$mode" == remote ]] || { log "ERROR: invalid access mode for source $source_index: $mode"; return 1; }
    if ! GIT_TERMINAL_PROMPT=0 GREENS_FETCH_TIMEOUT=15 greens_run git ls-remote "$url" HEAD >/dev/null 2>&1; then
      greens_offer_local_fallback "$source_index" "Git remote is unreachable" || return 1
      continue
    fi
    [[ "$types" != commits ]] || continue
    provider="$(greens_indexed_value "$source_index" PROVIDER)"; api="$(greens_indexed_value "$source_index" API_HOST)"; username="$(greens_indexed_value "$source_index" USERNAME)"
    api_done="$RUN_TMP/preflight-api-$source_index.done"
    if [[ "$provider" == github ]]; then
      if [[ ! -f "$api_done" ]]; then
        if ! gh auth status --active --hostname "$api" >/dev/null 2>&1 ||
           [[ "$(GREENS_FETCH_TIMEOUT=15 greens_gh_api_as "$api" "$username" user --jq .login 2>/dev/null || true)" != "$username" ]]; then
          greens_offer_local_fallback "$source_index" "GitHub API authentication is unavailable" || return 1
          continue
        fi
        : > "$api_done"
      fi
    elif [[ "$provider" == gitlab ]]; then
      if [[ ! -f "$api_done" ]]; then
        api_user="$RUN_TMP/preflight-user-$source_index"
        if ! command -v glab >/dev/null || ! GREENS_FETCH_TIMEOUT=15 greens_run glab api --hostname "$api" user > "$api_user" 2>/dev/null ||
           [[ "$(jq -r .username "$api_user" 2>/dev/null)" != "$username" ]]; then
          greens_offer_local_fallback "$source_index" "GitLab API authentication is unavailable" || return 1
          continue
        fi
        : > "$api_done"
      fi
      if [[ "$(greens_source_access_mode "$source_index")" == remote ]]; then
        key="$(printf '%s' "$identity" | greens_hash)"; encoded="$(jq -nr --arg path "${identity#*/}" '$path|@uri')"
        if ! GREENS_FETCH_TIMEOUT=15 greens_run glab api --hostname "$api" "projects/$encoded" > "$RUN_TMP/preflight-project-$key" 2>/dev/null; then
          greens_offer_local_fallback "$source_index" "GitLab project API is unavailable" || return 1
        fi
      fi
    fi
  done < "$sources"
}

greens_mirror_mixed_records() {
  local records="$1" publish="$2" mirror_branch ref marker msg activity_key activity_date activity_epoch
  local pending=0 today
  today="$(date '+%Y-%m-%d')"
  [[ -z "$(git -C "$MIRROR_DIR" status --porcelain)" ]] || { log "ERROR: mirror has local changes"; return 1; }
  mirror_branch="$(git -C "$MIRROR_DIR" symbolic-ref --short HEAD)" || return 1
  ref="refs/remotes/origin/$mirror_branch"
  if git -C "$MIRROR_DIR" rev-parse --verify "$ref" >/dev/null 2>&1; then
    if ! git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then git -C "$MIRROR_DIR" reset --hard "$ref" --quiet
    elif git -C "$MIRROR_DIR" merge-base --is-ancestor HEAD "$ref"; then git -C "$MIRROR_DIR" merge --ff-only "$ref" --quiet
    elif ! git -C "$MIRROR_DIR" merge-base --is-ancestor "$ref" HEAD; then log "ERROR: mirror diverged from its remote"; return 1; fi
  fi
  { git -C "$MIRROR_DIR" log --format=%B HEAD 2>/dev/null || true; } |
    sed -n 's/^Greens-Activity: \([0-9a-f]\{64\}\)$/\1/p' | sort -u > "$RUN_TMP/known"
  : > "$RUN_TMP/legacy-epochs"
  if [[ "${GREENS_LEGACY_TIMESTAMPS:-0}" == 1 ]]; then
    git -C "$MIRROR_DIR" log --format=%at --author="<$MIRROR_EMAIL>" 2>/dev/null | sort -u > "$RUN_TMP/legacy-epochs"
  elif git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1 && [[ ! -s "$RUN_TMP/known" ]]; then
    log "ERROR: destination history has no activity IDs; rerun setup to migrate a legacy greens configuration."
    return 1
  fi
  jq -r '[.key,.date,.epoch]|@tsv' "$records" > "$RUN_TMP/to-mirror"
  while IFS=$'\t' read -r activity_key activity_date activity_epoch; do
    marker="$(printf '%s' "$activity_key" | greens_hash)"
    grep -qxF "$marker" "$RUN_TMP/known" && continue
    grep -qxF "$activity_epoch" "$RUN_TMP/legacy-epochs" && continue
    msg="$(printf 'sync\n\nGreens-Activity: %s' "$marker")"
    GIT_AUTHOR_DATE="$activity_date" GIT_COMMITTER_DATE="$activity_date" \
      GIT_AUTHOR_NAME="$MIRROR_NAME" GIT_AUTHOR_EMAIL="$MIRROR_EMAIL" GIT_COMMITTER_NAME="$MIRROR_NAME" GIT_COMMITTER_EMAIL="$MIRROR_EMAIL" \
      git -C "$MIRROR_DIR" -c user.name="$MIRROR_NAME" -c user.email="$MIRROR_EMAIL" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit --allow-empty --quiet -m "$msg"
    pending="$((pending + 1))"
  done < "$RUN_TMP/to-mirror"
  log "Activity records: $(wc -l < "$records" | tr -d ' '); added: $pending"
  if [[ "$(mirror_visibility)" == private && "$pending" -gt 0 && "$(scan_repo_readme_state "$MIRROR_DIR")" != foreign ]]; then
    {
      printf '# Work Contributions Mirror\n\n## Overview\n\nTimestamp-only contributions from configured sources.\n\n## Repository Breakdown\n\n| Repository | Activities |\n|---|---:|\n'
      jq -sr 'group_by(.project)[] | "| " + (.[0].project|gsub("[|<>]";"")) + " | " + (length|tostring) + " |"' "$records"
      printf '\n## Sync Info\n\nSource: mixed providers\n\nGenerated by [greens](https://github.com/yuvrajangadsingh/greens)\n'
    } > "$MIRROR_DIR/README.md"
    git -C "$MIRROR_DIR" add README.md
    if ! git -C "$MIRROR_DIR" diff --cached --quiet; then
      GIT_AUTHOR_NAME=greens-status GIT_AUTHOR_EMAIL=status@greens.local GIT_COMMITTER_NAME=greens-status GIT_COMMITTER_EMAIL=status@greens.local \
        git -C "$MIRROR_DIR" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit --quiet -m "Update sync status"
    fi
  fi
  if git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    [[ "${GREENS_PUSH_FORCE:-0}" != 1 ]] || { log "ERROR: mixed sources never force-push"; return 1; }
    greens_run git -C "$MIRROR_DIR" push origin "HEAD:refs/heads/$mirror_branch"
  fi
  while IFS=$'\t' read -r from to; do mkdir -p "$(dirname "$to")"; mv "$from" "$to"; done < "$publish"
  printf '%s\n' "$today" > "$SUCCESS_STAMP_FILE.tmp.$$"; mv "$SUCCESS_STAMP_FILE.tmp.$$" "$SUCCESS_STAMP_FILE"
  log "Done."
}

greens_mixed_sync() {
  local sources checkouts source_index identity url key bare source_file state_scope state_dir checkpoint_file repodir
  local SOURCE_PROVIDER SOURCE_API_HOST SOURCE_ORGANIZATION SOURCE_USERNAME EMAILS SINCE ACTIVITY_TYPES ACCESS_MODE
  local GITLAB_HOST GITLAB_USERNAME project_path project_id project_features gitlab_user_id api_enabled
  local since_epoch since_date run_epoch lower updated old_types checkpoint kind objects iid object_file pid failed count event_file owner_type
  local -a workers
  umask 077
  command -v jq >/dev/null || { log "ERROR: install jq"; return 1; }
  [[ "${COPY_MESSAGES:-0}" == 0 ]] || { log "ERROR: indexed mixed sources support timestamp-only commits; set COPY_MESSAGES=0"; return 1; }
  checkouts="$RUN_TMP/mixed-checkouts"; greens_mixed_discover_checkouts > "$checkouts"
  sources="$RUN_TMP/mixed-sources"; cut -f1-3 "$checkouts" | LC_ALL=C sort -t $'\t' -k2,2 -u > "$sources"
  greens_validate_local_sources "$checkouts" || return 1
  [[ -s "$sources" ]] || { log "ERROR: no repositories match the configured sources"; return 1; }
  run_epoch="$(date +%s)"; : > "$RUN_TMP/collected"; : > "$RUN_TMP/publish"
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2}"
  greens_preflight_mixed_sources "$sources" || return 1
  while IFS=$'\t' read -r source_index identity url; do
    SOURCE_PROVIDER="$(greens_indexed_value "$source_index" PROVIDER)"; SOURCE_API_HOST="$(greens_indexed_value "$source_index" API_HOST)"
    SOURCE_ORGANIZATION="$(greens_indexed_value "$source_index" ORGANIZATION)"; SOURCE_USERNAME="$(greens_indexed_value "$source_index" USERNAME)"
    EMAILS="$(greens_indexed_value "$source_index" EMAILS)"; SINCE="$(greens_indexed_value "$source_index" SINCE)"; ACTIVITY_TYPES="$(greens_indexed_value "$source_index" ACTIVITY_TYPES)"; ACCESS_MODE="$(greens_source_access_mode "$source_index")"
    since_epoch="$(greens_epoch "$SINCE")" || { log "ERROR: invalid SINCE for source $source_index"; return 1; }; since_date="${SINCE%% *}"
    project_path="${identity#*/}"; key="$(printf '%s' "$identity" | greens_hash)"; bare="$CACHE_DIR/$key.git"; source_file="$RUN_TMP/$key.records"; : > "$source_file"
    state_scope="$(printf '%s\n' "$SOURCE_PROVIDER" "$SOURCE_API_HOST" "$SOURCE_ORGANIZATION" "$SOURCE_USERNAME" "$EMAILS" "$SINCE" "$ACTIVITY_TYPES" "$ACCESS_MODE" | greens_hash)"
    state_dir="$CACHE_DIR/activity-state/$(greens_scheduler_id)-$state_scope"; checkpoint_file="$state_dir/$key.checkpoint"
    [[ ! -f "$state_dir/$key.jsonl" ]] || cat "$state_dir/$key.jsonl" >> "$source_file"
    log "Collecting $SOURCE_PROVIDER $project_path"
    if [[ ",$ACTIVITY_TYPES," == *,commits,* ]]; then
      if [[ "$ACCESS_MODE" == local ]]; then
        while IFS= read -r repodir; do
          git -C "$repodir" log --all --format='%H%x09%at%x09%ai%x09%ae'
        done < <(awk -F '\t' -v id="$identity" '$2==id {print $4}' "$checkouts") |
          jq -Rrc --arg identity "$identity" --arg path "$project_path" --arg emails "$EMAILS" --argjson since "$since_epoch" --argjson until "$run_epoch" '
          split("\t")|select(length==4)|. as $r|($emails|ascii_downcase|split(",")|map(gsub("^\\s+|\\s+$";""))) as $e|select(($e|index($r[3]|ascii_downcase))!=null)|(.[1]|tonumber) as $t|select($t >= $since and $t <= $until)|{key:($identity+"/commit/"+.[0]),epoch:$t,date:.[2],kind:"commits",project:$path}' >> "$source_file"
      else
        if [[ ! -d "$bare" ]]; then git init --bare --quiet "$bare"; git --git-dir="$bare" remote add origin "$url"; fi
        git --git-dir="$bare" remote set-url origin "$url"
        if [[ "$SOURCE_PROVIDER" == gitlab ]]; then
          greens_run git --git-dir="$bare" fetch --quiet --prune --filter=blob:none origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' '+refs/merge-requests/*/head:refs/merge-requests/*/head'
        else greens_run git --git-dir="$bare" fetch --quiet --prune --filter=blob:none origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'; fi
        git --git-dir="$bare" log --all --format='%H%x09%at%x09%ai%x09%ae' |
          jq -Rrc --arg identity "$identity" --arg path "$project_path" --arg emails "$EMAILS" --argjson since "$since_epoch" --argjson until "$run_epoch" '
          split("\t")|select(length==4)|. as $r|($emails|ascii_downcase|split(",")|map(gsub("^\\s+|\\s+$";""))) as $e|select(($e|index($r[3]|ascii_downcase))!=null)|(.[1]|tonumber) as $t|select($t >= $since and $t <= $until)|{key:($identity+"/commit/"+.[0]),epoch:$t,date:.[2],kind:"commits",project:$path}' >> "$source_file"
      fi
    fi
    if [[ "$SOURCE_PROVIDER" == github && "$ACTIVITY_TYPES" != commits && ! -f "$RUN_TMP/github-api-$source_index.done" ]]; then
      command -v gh >/dev/null || { log "ERROR: install gh"; return 1; }
      gh auth status --active --hostname "$SOURCE_API_HOST" >/dev/null 2>&1 || { log "ERROR: gh is not authenticated for $SOURCE_API_HOST"; return 1; }
      [[ "$(greens_gh_api_as "$SOURCE_API_HOST" "$SOURCE_USERNAME" user --jq .login)" == "$SOURCE_USERNAME" ]] || { log "ERROR: gh actor mismatch for $SOURCE_API_HOST"; return 1; }
      owner_type="$(greens_gh_api_as "$SOURCE_API_HOST" "$SOURCE_USERNAME" "users/$SOURCE_ORGANIZATION" --jq .type)" || return 1
      for kind in prs issues reviews; do case ",$ACTIVITY_TYPES," in *,$kind,*) github_api_records "$kind" "$RUN_TMP/$key-$kind" "$owner_type" >> "$source_file" ;; esac; done
      : > "$RUN_TMP/github-api-$source_index.done"
    fi
    if [[ "$SOURCE_PROVIDER" == gitlab && "$ACTIVITY_TYPES" != commits ]]; then
      command -v glab >/dev/null || { log "ERROR: install glab"; return 1; }
      GITLAB_HOST="$SOURCE_API_HOST"; GITLAB_USERNAME="$SOURCE_USERNAME"; api_enabled=1
      if [[ -f "$RUN_TMP/preflight-user-$source_index" ]]; then cp "$RUN_TMP/preflight-user-$source_index" "$RUN_TMP/user-$source_index"; else gitlab_api user "$RUN_TMP/user-$source_index"; fi
      gitlab_user_id="$(jq -er .id "$RUN_TMP/user-$source_index")"
      [[ "$(jq -r .username "$RUN_TMP/user-$source_index")" == "$GITLAB_USERNAME" ]] || { log "ERROR: glab actor mismatch for $GITLAB_HOST"; return 1; }
      if [[ -f "$RUN_TMP/preflight-project-$key" ]]; then cp "$RUN_TMP/preflight-project-$key" "$RUN_TMP/project-$key"; else gitlab_api "projects/$(jq -nr --arg path "$project_path" '$path|@uri')" "$RUN_TMP/project-$key"; fi
      project_id="$(jq -er .id "$RUN_TMP/project-$key")"; project_features="$(jq -r '[(.merge_requests_enabled != false),(.issues_enabled != false)]|join(",")' "$RUN_TMP/project-$key")"
      lower="$since_epoch"; old_types=""
      if [[ -f "$checkpoint_file" ]]; then read -r checkpoint old_types < "$checkpoint_file"; [[ "$checkpoint" =~ ^[0-9]+$ && "$old_types" == "$ACTIVITY_TYPES:$since_epoch:$project_features" ]] && lower="$((checkpoint - 86400))"; fi
      updated="$(greens_utc_date "$lower")"
      if [[ ",$ACTIVITY_TYPES," == *,approvals,* ]]; then event_file="$RUN_TMP/events-$key"; gitlab_api "users/$gitlab_user_id/events?after=${updated%%T*}&per_page=100&sort=asc" "$event_file"; gitlab_records events "$event_file" >> "$source_file"; fi
      for kind in mrs issues; do
        [[ "$kind" == mrs ]] && objects=merge_requests || objects=issues
        case ",$ACTIVITY_TYPES," in *,$kind,*|*,comments,*|*,state_changes,*) ;; *,merges,*) [[ "$kind" == mrs ]] || continue ;; *) continue ;; esac
        if [[ "$kind" == issues && "$project_features" == *,false ]] || [[ "$kind" == mrs && "$project_features" == false,* ]]; then
          log "  $objects are disabled for this project; skipping that resource."
          continue
        fi
        gitlab_api "projects/$project_id/$objects?scope=all&state=all&updated_after=$updated&per_page=100" "$RUN_TMP/objects-$key-$kind"
        gitlab_records objects "$RUN_TMP/objects-$key-$kind" "$kind" >> "$source_file"
        jq -r '.[].iid' "$RUN_TMP/objects-$key-$kind" > "$RUN_TMP/iids-$key-$kind"; workers=(); count=0
        while IFS= read -r iid; do object_file="$RUN_TMP/$key-$kind-$iid.notes"; (trap - EXIT; gitlab_collect_object "$kind" "$objects" "$iid" "$object_file") & workers+=("$!"); count="$((count+1))"; if [[ "${#workers[@]}" == 4 ]]; then failed=0; for pid in "${workers[@]}"; do wait "$pid" || failed=1; done; [[ "$failed" == 0 ]] || return 1; workers=(); fi; done < "$RUN_TMP/iids-$key-$kind"
        failed=0; for pid in ${workers[@]+"${workers[@]}"}; do wait "$pid" || failed=1; done; [[ "$failed" == 0 ]] || return 1
        while IFS= read -r iid; do cat "$RUN_TMP/$key-$kind-$iid.notes" >> "$source_file"; done < "$RUN_TMP/iids-$key-$kind"
      done
      printf '%s %s:%s:%s\n' "$run_epoch" "$ACTIVITY_TYPES" "$since_epoch" "$project_features" > "$RUN_TMP/$key.checkpoint"
    else printf '%s %s:%s:true,true\n' "$run_epoch" "$ACTIVITY_TYPES" "$since_epoch" > "$RUN_TMP/$key.checkpoint"; fi
    jq -sc --arg types "$ACTIVITY_TYPES" --argjson since "$since_epoch" --argjson until "$run_epoch" '
      ($types|split(",")) as $types |
      unique_by(.key) | map(select(.epoch >= $since and .epoch <= $until and (.kind as $kind | $types | index($kind))))[]' \
      "$source_file" > "$RUN_TMP/$key.jsonl"
    cat "$RUN_TMP/$key.jsonl" >> "$RUN_TMP/collected"
    printf '%s\t%s\n%s\t%s\n' "$RUN_TMP/$key.jsonl" "$state_dir/$key.jsonl" "$RUN_TMP/$key.checkpoint" "$state_dir/$key.checkpoint" >> "$RUN_TMP/publish"
  done < "$sources"
  jq -sc 'unique_by(.key)|sort_by(.epoch,.key)[]' "$RUN_TMP/collected" > "$RUN_TMP/records"
  greens_mirror_mixed_records "$RUN_TMP/records" "$RUN_TMP/publish"
}

greens_provider_sync() {
  local SOURCE_PROVIDER="${SOURCE_PROVIDER:-gitlab}"
  local since_epoch run_epoch state_dir sources identity url key bare source_file
  local project_id project_path gitlab_user_id=0 api_enabled=0 checkpoint lower updated
  local kind iid objects event_file mirror_branch ref msg marker
  local pending=0 activity_date activity_key old_types today
  local count failed object_file pid state_scope project_features
  local -a workers
  local GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
  local GITLAB_USERNAME="${GITLAB_USERNAME:-}"
  umask 077
  command -v jq >/dev/null || { log "ERROR: install jq for this source provider"; return 1; }
  [[ -d "$WORK_DIR" ]] || { log "ERROR: WORK_DIR does not exist"; return 1; }
  [[ "$COPY_MESSAGES" == 0 ]] || { log "ERROR: GitLab/Git-only providers support generic messages only; set COPY_MESSAGES=0."; return 1; }
  since_epoch="$(greens_epoch "$SINCE")" || { log "ERROR: invalid SINCE (use YYYY-MM-DD or YYYY-MM-DD HH:MM:SS)"; return 1; }
  run_epoch="$(date +%s)"
  today="$(date '+%Y-%m-%d')"
  sources="$RUN_TMP/sources"
  greens_discover_sources | LC_ALL=C sort -t $'\t' -k1,1 -u > "$sources"
  [[ -s "$sources" ]] || { log "ERROR: no matching repositories found"; return 1; }
  if [[ "$SOURCE_PROVIDER" == gitlab && "$ACTIVITY_TYPES" != commits ]]; then
    command -v glab >/dev/null || { log "ERROR: install and authenticate glab for GitLab activity"; return 1; }
    api_enabled=1
    gitlab_api user "$RUN_TMP/user"
    if [[ -n "$GITLAB_USERNAME" ]]; then
      [[ "$(jq -r .username "$RUN_TMP/user")" == "$GITLAB_USERNAME" ]] || {
        log "ERROR: glab is authenticated as a different GitLab user"; return 1;
      }
    fi
    gitlab_user_id="$(jq -er .id "$RUN_TMP/user")"
  fi
  # Never mix cached activity from different configurations or source actors.
  state_scope="$(printf '%s\n' "$SOURCE_PROVIDER" "$GITLAB_HOST" "$gitlab_user_id" "$EMAILS" | greens_hash)"
  state_dir="$CACHE_DIR/activity-state/$(greens_scheduler_id)-$state_scope"
  mkdir -p "$state_dir"
  # Never prompt in a scheduled run. Existing SSH configuration still applies.
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2}"
  : > "$RUN_TMP/collected"
  while IFS=$'\t' read -r identity url; do
    key="$(printf '%s' "$identity" | greens_hash)"
    project_path="${identity#*/}"
    bare="$CACHE_DIR/$key.git"
    source_file="$RUN_TMP/$key.records"
    : > "$source_file"
    if [[ -f "$state_dir/$key.jsonl" ]]; then cat "$state_dir/$key.jsonl" >> "$source_file"; fi
    project_id=0
    project_features=true,true
    if [[ "$api_enabled" == 1 ]]; then
      gitlab_api "projects/$(jq -nr --arg path "$project_path" '$path|@uri')" "$RUN_TMP/project"
      project_id="$(jq -er .id "$RUN_TMP/project")"
      project_features="$(jq -r '[(.merge_requests_enabled != false),(.issues_enabled != false)]|join(",")' "$RUN_TMP/project")"
    fi
    log "Collecting $project_path"
    if [[ ",$ACTIVITY_TYPES," == *,commits,* ]]; then
      if [[ ! -d "$bare" ]]; then git init --bare --quiet "$bare"; git --git-dir="$bare" remote add origin "$url"; fi
      git --git-dir="$bare" remote set-url origin "$url"
      # MR refs retain commits from deleted source branches when GitLab retains them.
      if [[ "$SOURCE_PROVIDER" == gitlab ]]; then
        greens_run git --git-dir="$bare" fetch --quiet --prune --filter=blob:none origin \
          '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' \
          '+refs/merge-requests/*/head:refs/merge-requests/*/head'
      else
        greens_run git --git-dir="$bare" fetch --quiet --prune --filter=blob:none origin \
          '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
      fi
      # Filter the AUTHOR date explicitly: git log --since filters committer dates.
      git --git-dir="$bare" log --all --format='%H%x09%at%x09%ai%x09%ae' |
        jq -Rrc --arg identity "$identity" --arg path "$project_path" --arg emails "$EMAILS" \
          --argjson since "$since_epoch" --argjson until "$run_epoch" '
          split("\t") | select(length == 4) |
          . as $row | ($emails|ascii_downcase|split(",")|map(gsub("^\\s+|\\s+$";""))) as $emails |
          select(($emails|index($row[3]|ascii_downcase)) != null) |
          (.[1]|tonumber) as $time | select($time >= $since and $time <= $until) |
          {key: ($identity+"/commit/"+.[0]), epoch:$time,date:.[2],kind:"commits",project:$path}' >> "$source_file"
    fi
    if [[ "$api_enabled" == 1 ]]; then
      lower="$since_epoch"
      # Changing activity selection must backfill newly selected types.
      if [[ -f "$state_dir/$key.checkpoint" ]]; then
        read -r checkpoint old_types < "$state_dir/$key.checkpoint"
        if [[ "$checkpoint" =~ ^[0-9]+$ && "$old_types" == "$ACTIVITY_TYPES:$since_epoch:$project_features" && "$checkpoint" -gt "$((since_epoch + 86400))" ]]; then
          lower="$((checkpoint - 86400))"
        fi
      fi
      updated="$(greens_utc_date "$lower")"
      if [[ "$lower" == "$since_epoch" ]]; then
        log "Backfilling available GitLab history; deleted objects and expired approval events cannot be recovered."
      fi
      if [[ ",$ACTIVITY_TYPES," == *,approvals,* ]]; then
        # The server's feed is only authoritative for available approval history.
        event_file="$RUN_TMP/events"
        gitlab_api "users/$gitlab_user_id/events?after=${updated%%T*}&per_page=100&sort=asc" "$event_file"
        gitlab_records events "$event_file" >> "$source_file"
      fi
      for kind in mrs issues; do
        if [[ "$kind" == mrs ]]; then objects=merge_requests; else objects=issues; fi
        case ",$ACTIVITY_TYPES," in
          *,"$kind",*|*,comments,*|*,state_changes,*) ;;
          *,merges,*) [[ "$kind" == mrs ]] || continue ;;
          *) continue ;;
        esac
        if [[ "$kind" == issues && "$project_features" == *,false ]] ||
           [[ "$kind" == mrs && "$project_features" == false,* ]]; then
          log "  $objects are disabled for this project; skipping that resource."
          continue
        fi
        gitlab_api "projects/$project_id/$objects?scope=all&state=all&updated_after=$updated&per_page=100" "$RUN_TMP/objects"
        gitlab_records objects "$RUN_TMP/objects" "$kind" >> "$source_file"
        jq -r '.[].iid' "$RUN_TMP/objects" > "$RUN_TMP/iids"
        workers=(); count=0
        log "Checking $(wc -l < "$RUN_TMP/iids" | tr -d ' ') updated $objects"
        while IFS= read -r iid; do
          object_file="$RUN_TMP/$key-$kind-$iid.notes"
          # Four bounded workers keep first backfills practical without an
          # unbounded burst of API calls. Each writes its own private output.
          (trap - EXIT; gitlab_collect_object "$kind" "$objects" "$iid" "$object_file") &
          workers+=("$!")
          count="$((count + 1))"
          if [[ "${#workers[@]}" == 4 ]]; then
            failed=0
            for pid in "${workers[@]}"; do wait "$pid" || failed=1; done
            [[ "$failed" == 0 ]] || return 1
            workers=()
          fi
          if [[ "$((count % 40))" == 0 ]]; then log "  Checked $count $objects"; fi
        done < "$RUN_TMP/iids"
        failed=0
        for pid in ${workers[@]+"${workers[@]}"}; do wait "$pid" || failed=1; done
        [[ "$failed" == 0 ]] || return 1
        while IFS= read -r iid; do
          cat "$RUN_TMP/$key-$kind-$iid.notes" >> "$source_file"
          rm -f "$RUN_TMP/$key-$kind-$iid.notes"
        done < "$RUN_TMP/iids"
      done
    fi
    jq -sc 'unique_by(.key)[]' "$source_file" > "$RUN_TMP/$key.jsonl"
    cat "$RUN_TMP/$key.jsonl" >> "$RUN_TMP/collected"
    printf '%s %s:%s:%s\n' "$run_epoch" "$ACTIVITY_TYPES" "$since_epoch" "$project_features" > "$RUN_TMP/$key.checkpoint"
  done < "$sources"
  jq -sc --arg types "$ACTIVITY_TYPES" --argjson since "$since_epoch" '
    ($types|split(",")) as $types |
    unique_by(.key) | map(select(.epoch >= $since and (.kind as $k|$types|index($k)))) |
    sort_by(.epoch,.key)[]' "$RUN_TMP/collected" > "$RUN_TMP/records"
  # Only update a clean, attached default branch. No force pushes in normal sync.
  [[ -z "$(git -C "$MIRROR_DIR" status --porcelain)" ]] || { log "ERROR: mirror has local changes"; return 1; }
  mirror_branch="$(git -C "$MIRROR_DIR" symbolic-ref --short HEAD)" || return 1
  ref="refs/remotes/origin/$mirror_branch"
  if git -C "$MIRROR_DIR" rev-parse --verify "$ref" >/dev/null 2>&1; then
    if ! git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
      git -C "$MIRROR_DIR" reset --hard "$ref" --quiet
    elif git -C "$MIRROR_DIR" merge-base --is-ancestor HEAD "$ref"; then
      git -C "$MIRROR_DIR" merge --ff-only "$ref" --quiet
    elif ! git -C "$MIRROR_DIR" merge-base --is-ancestor "$ref" HEAD; then
      log "ERROR: mirror diverged from its remote; refusing to rewrite history"; return 1
    fi
  fi
  { git -C "$MIRROR_DIR" log --format=%B HEAD 2>/dev/null || true; } |
    sed -n 's/^Greens-Activity: \([0-9a-f]\{64\}\)$/\1/p' | sort -u > "$RUN_TMP/known"
  # Old timestamp-only histories need a fresh destination or an explicit resync.
  if git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1 && [[ ! -s "$RUN_TMP/known" ]]; then
    log "ERROR: destination has history without activity IDs. Use an empty mirror for the new provider."
    return 1
  fi
  jq -r '[.key,.date]|@tsv' "$RUN_TMP/records" > "$RUN_TMP/to-mirror"
  while IFS=$'\t' read -r activity_key activity_date; do
    marker="$(printf '%s' "$activity_key" | greens_hash)"
    grep -qxF "$marker" "$RUN_TMP/known" && continue
    msg="$(printf 'sync\n\nGreens-Activity: %s' "$marker")"
    GIT_AUTHOR_DATE="$activity_date" GIT_COMMITTER_DATE="$activity_date" \
      GIT_AUTHOR_NAME="$MIRROR_NAME" GIT_AUTHOR_EMAIL="$MIRROR_EMAIL" \
      GIT_COMMITTER_NAME="$MIRROR_NAME" GIT_COMMITTER_EMAIL="$MIRROR_EMAIL" \
      git -C "$MIRROR_DIR" -c user.name="$MIRROR_NAME" -c user.email="$MIRROR_EMAIL" \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null commit --allow-empty --quiet -m "$msg"
    pending="$((pending + 1))"
  done < "$RUN_TMP/to-mirror"
  log "Activity records: $(wc -l < "$RUN_TMP/records" | tr -d ' '); added: $pending"
  if [[ "$(mirror_visibility)" == private && "$pending" -gt 0 && "$(scan_repo_readme_state "$MIRROR_DIR")" != foreign ]]; then
    {
      printf '# Work Contributions Mirror\n\n## Overview\n\nTimestamp-only contributions from configured sources.\n\n## Repository Breakdown\n\n| Repository | Activities |\n|---|---:|\n'
      jq -sr 'group_by(.project)[] | "| " + (.[0].project|gsub("[|<>]";"")) + " | " + (length|tostring) + " |"' "$RUN_TMP/records"
      printf '\n## Sync Info\n\nSource: %s\n\nGenerated by [greens](https://github.com/yuvrajangadsingh/greens)\n' "$SOURCE_PROVIDER"
    } > "$MIRROR_DIR/README.md"
    git -C "$MIRROR_DIR" add README.md
    if ! git -C "$MIRROR_DIR" diff --cached --quiet; then
      GIT_AUTHOR_NAME=greens-status GIT_AUTHOR_EMAIL=status@greens.local \
      GIT_COMMITTER_NAME=greens-status GIT_COMMITTER_EMAIL=status@greens.local \
        git -C "$MIRROR_DIR" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit --quiet -m "Update sync status"
    fi
  fi
  if git -C "$MIRROR_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    if [[ "${GREENS_PUSH_FORCE:-0}" == 1 ]]; then
      log "ERROR: the new providers never force-push; use an empty destination"; return 1
    fi
    greens_run git -C "$MIRROR_DIR" push origin "HEAD:refs/heads/$mirror_branch"
  fi
  # All collection and the push succeeded: publish local normalized state.
  while IFS=$'\t' read -r identity url; do
    key="$(printf '%s' "$identity" | greens_hash)"
    mv "$RUN_TMP/$key.jsonl" "$state_dir/$key.jsonl"
    mv "$RUN_TMP/$key.checkpoint" "$state_dir/$key.checkpoint"
  done < "$sources"
  printf '%s\n' "$today" > "$SUCCESS_STAMP_FILE.tmp.$$"
  mv "$SUCCESS_STAMP_FILE.tmp.$$" "$SUCCESS_STAMP_FILE"
  log "Done."
}
