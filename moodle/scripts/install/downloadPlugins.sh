#!/bin/bash
#set -eo pipefail

major_minor="${MOODLE_VERSION%.*}"
plugin_index=0
moosh_php_memory_limit="${MOOSH_PHP_MEMORY_LIMIT:-512M}"

plugin_dependency_list=(
    local_wunderbyte_table # Dependency of mod_booking
    tool_certificate # Dependency of mod_coursecertificate
    qbehaviour_adaptivemultipart # Dependency of qtype_stack
    qbehaviour_dfexplicitvaildate # Dependency of qtype_stack
    qbehaviour_dfcbmexplicitvaildate # Dependency of qtype_stack
)

plugin_list=(
    # mod_booking   custom download logic from gh until it is available via marketplace/directory 
    theme_boost_union
    mod_choicegroup
    mod_coursecertificate
    mod_etherpadlite
    mod_hvp
    mod_pdfannotator
    format_remuiformat
    local_staticpage
    format_tiles
    format_topcoll
    mod_unilabel
    block_xp
    mod_zoom
    filter_filtercodes
    filter_shortcodes
    tool_heartbeat
    availability_cohort
    mod_board
    mod_checklist
    block_sharing_cart
    qtype_stack
    block_stash
    block_completion_progress
    tool_coursearchiver
    theme_adaptable
    tool_usersuspension
    tool_dynamic_cohorts
    mod_subcourse
    mod_videotime
    tool_mediatime
    auth_oidc
)

moodle_plugin_list=("${plugin_dependency_list[@]}" "${plugin_list[@]}")

cd /plugins || exit 1

# GitHub fallback map: plugin_name -> "github_user/github_repo"
# Used when the moodle.org download URL returns an empty file (e.g. broken/404 upstream).
declare -A plugin_github_repos=(
    ["local_wunderbyte_table"]="Wunderbyte-GmbH/moodle-local_wunderbyte_table"
    ["filter_filtercodes"]="michael-milette/moodle-filter_filtercodes"
)

# Plugins listed here are optional at image build time. If download and fallback
# fail, the build continues and plugin activation can still be controlled at runtime.
declare -A plugin_allow_missing=(
    ["tool_certificate"]=1
    ["qbehaviour_adaptivemultipart"]=1
    ["qbehaviour_dfexplicitvaildate"]=1
    ["qbehaviour_dfcbmexplicitvaildate"]=1
)

plugin_github_branch_fallbacks=(
    MOODLE_405_STABLE
    main
    master
)

download_plugin_github() {
    local plugin_name="$1"
    local github_repo="${plugin_github_repos[$plugin_name]}"

    if [ -z "$github_repo" ]; then
        return 1
    fi

    echo "Attempting GitHub fallback for '$plugin_name' from ${github_repo}..."

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local archive_url=""
    local tag
    tag=$(curl -sf "https://api.github.com/repos/${github_repo}/releases/latest" | jq -r '.tag_name // empty') || true

    if [ -n "$tag" ] && [ "$tag" != "null" ]; then
        archive_url="https://github.com/${github_repo}/archive/refs/tags/${tag}.zip"
        echo "Downloading '$plugin_name' from GitHub at tag ${tag}..."
        if ! curl -Lsf "$archive_url" -o "${tmp_dir}/archive.zip"; then
            echo "WARNING: GitHub tag archive download failed for '$plugin_name' (${tag}). Trying branch fallback..." >&2
            rm -f "${tmp_dir}/archive.zip"
        fi
    else
        echo "WARNING: Could not determine latest release tag for ${github_repo}. Trying branch fallback..." >&2
    fi

    if [ ! -s "${tmp_dir}/archive.zip" ]; then
        local branch
        for branch in "${plugin_github_branch_fallbacks[@]}"; do
            archive_url="https://github.com/${github_repo}/archive/refs/heads/${branch}.zip"
            echo "Trying GitHub branch fallback for '$plugin_name' on ${branch}..."
            if curl -Lsf "$archive_url" -o "${tmp_dir}/archive.zip"; then
                break
            fi
            rm -f "${tmp_dir}/archive.zip"
        done
    fi

    if [ ! -s "${tmp_dir}/archive.zip" ]; then
        echo "WARNING: GitHub archive download failed for '$plugin_name'." >&2
        rm -rf "${tmp_dir}"
        return 1
    fi

    cd "${tmp_dir}" || return 1
    unzip -q archive.zip
    rm archive.zip

    local src_dir
    src_dir=$(find . -maxdepth 1 -mindepth 1 -type d | head -1 | sed 's|^\./||')
    if [ -z "$src_dir" ]; then
        echo "WARNING: Could not find extracted directory in GitHub archive for '$plugin_name'." >&2
        cd /plugins || return 1
        rm -rf "${tmp_dir}"
        return 1
    fi

    if ! command -v zip >/dev/null 2>&1; then
        echo "WARNING: 'zip' command not found; cannot repackage '$plugin_name' from GitHub." >&2
        cd /plugins || return 1
        rm -rf "${tmp_dir}"
        return 1
    fi

    mv "${src_dir}" "${plugin_name}"
    zip -r "/plugins/${plugin_name}.zip" "${plugin_name}"

    cd /plugins || return 1
    rm -rf "${tmp_dir}"
}

check_plugin_size() {
    plugin_name=$1
    plugin_size=$(stat -c%s "/plugins/${plugin_name}.zip" 2>/dev/null || echo 0)
    if [ "$plugin_size" -eq 0 ]; then
        echo "WARNING: Moodle Plugin '$plugin_name' is empty (size 0 bytes). Trying GitHub fallback..." >&2
        rm -f "/plugins/${plugin_name}.zip"
        if ! download_plugin_github "$plugin_name"; then
            if [ -n "${plugin_allow_missing[$plugin_name]}" ]; then
                echo "WARNING: Moodle Plugin '$plugin_name' is unavailable and marked optional for image build. Continuing..." >&2
                return 0
            fi
            echo "ERROR: Moodle Plugin '$plugin_name' could not be downloaded from any source." >&2
            exit 1
        fi
        local fallback_size
        fallback_size=$(stat -c%s "/plugins/${plugin_name}.zip" 2>/dev/null || echo 0)
        if [ "$fallback_size" -eq 0 ]; then
            if [ -n "${plugin_allow_missing[$plugin_name]}" ]; then
                echo "WARNING: Moodle Plugin '$plugin_name' is still empty after fallback but marked optional for image build. Continuing..." >&2
                rm -f "/plugins/${plugin_name}.zip"
                return 0
            fi
            echo "ERROR: Moodle Plugin '$plugin_name' is still empty after GitHub fallback." >&2
            exit 1
        fi
    fi
}

download_oidc() {
    target_branch="v_45" # eLeDia currently doesn't use any tags, we always use the latest version on branch v_45

    git clone https://github.com/dBildungsplattform/dbp-moodle-plugin-oidc.git
    cd dbp-moodle-plugin-oidc/ || exit 1
    git checkout ${target_branch}
    cat auth/oidc/version.php
    # create the zip archive in the initial directory, s.t. it can be treated equally to the other plugins
    (cd auth && zip -rq ../../eledia_auth_oidc.zip oidc)
    cd ..
    rm -rf dbp-moodle-plugin-oidc/
}

download_booking() {
    target_branch="MOODLE_405_STABLE"

    git clone https://github.com/Wunderbyte-GmbH/moodle-mod_booking.git booking
    cd booking/ || exit 1
    git checkout ${target_branch}
    cat version.php
    # create the zip archive in the initial directory, s.t. it can be treated equally to the other plugins
    (cd .. && zip -rq mod_booking.zip booking)
    cd ..
    rm -rf booking/
}

download_oidc

run_moosh() {
    php -d "memory_limit=${moosh_php_memory_limit}" /usr/local/bin/moosh "$@"
}

run_moosh plugin-list > /dev/null

for plugin in "${moodle_plugin_list[@]}"; do
    if (( $plugin_index > 0 && $plugin_index % 15 == 0 )); then
        echo "Reached batch of 15 plugins. Sleeping for 60 seconds..."
        sleep 60
    fi
    run_moosh plugin-download -v "$major_minor" "$plugin"
    check_plugin_size "$plugin"
    plugin_index=$((plugin_index + 1))
done

run_moosh plugin-download -v 3.7 customfield_dynamic
check_plugin_size "customfield_dynamic"
