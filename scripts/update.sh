#!/bin/bash
#
#  STRAWBERRY MSVC GITHUB ACTION UPDATE SCRIPT
#  Copyright (C) 2022-2026 Jonas Kvinge
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

ci_file=".github/workflows/build.yaml"
curl_options="-s -f -L"

# Time limits in seconds for downloading files for checksums, so a stalled download doesn't hit the workflow timeout before the other packages are checked.
checksum_package_time_limit=600
checksum_run_time_limit=900
# Set before updating packages, no limit when empty.
checksum_run_deadline=

# Directory with the downloaded files for the package being updated.
package_files_dir=
trap 'remove_package_files' EXIT

# SSH key and known hosts for uploading to the packages server, installed by the workflow before running this script.
ssh_key_file="${HOME}/.ssh/packages_key"
ssh_known_hosts_file="${HOME}/.ssh/packages_known_hosts"

function timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
function status() { echo "[$(timestamp)] $*"; }
function error() { echo "[$(timestamp)] ERROR: $*" >&2; }

function latest_github_release() {
  curl ${curl_options} -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" -H "Authorization: Bearer ${gh_token}" "https://api.github.com/repos/$1/$2/releases/latest" | jq -r '.tag_name' | sed 's/^version-//g' | sed 's/^v//g' | sed 's/^sparsehash-//g' | sed 's/^faac-//g' | sed 's/^nettle_//g' | sort -V | head -1
}

function latest_git_commit() {
  git ls-remote "$1" HEAD | cut -f 1
}

function update_repo() {

  git fetch >/dev/null 2>&1 || exit 1
  if [ $? -ne 0 ]; then
    error "Could not fetch"
    exit 1
  fi

  git checkout . >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    error "Could not checkout ."
    exit 1
  fi

  if ! [ "$(git branch | head -1 | cut -d ' ' -f2)" = "master" ]; then
    git checkout master >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      error "Could not checkout master branch."
      exit 1
    fi
  fi

  git pull origin master --rebase >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    error "Could not pull with rebase."
    exit 1
  fi

}

function merge_prs() {

  local prs
  local pr
  local pr_json
  local pr_author
  local pr_head
  local pr_branch
  local pr_title
  local pr_update
  local package
  local review_decision
  local status_check_rollup
  local status_check_ok
  local status_check_total

  # gh pr list only returns 30 pull requests by default.
  prs=$(gh pr list --limit 1000 --json number | jq '.[].number')
  if [ "${prs}" = "" ]; then
    return
  fi

  for pr in ${prs}; do
    # Get everything in one request, so the checks below are for the same head commit that is merged.
    pr_json=$(gh pr view "${pr}" --json 'author,baseRefName,headRefName,headRefOid,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,title')
    if [ $? -ne 0 ] || [ "${pr_json}" = "" ]; then
      error "Could not get pull request ${pr}."
      continue
    fi
    pr_head=$(echo "${pr_json}" | jq -r '.headRefOid')
    if [ "${pr_head}" = "" ] || [ "${pr_head}" = "null" ]; then
      continue
    fi
    if ! [ "$(echo "${pr_json}" | jq -r '.baseRefName')" = "master" ]; then
      continue
    fi
    # Only merge dependency updates, from dependabot or created by update_package.
    pr_author=$(echo "${pr_json}" | jq -r '.author.login')
    pr_branch=$(echo "${pr_json}" | jq -r '.headRefName')
    pr_title=$(echo "${pr_json}" | jq -r '.title')
    pr_update=0
    # gh reports dependabot as app/dependabot.
    if [ "${pr_author}" = "app/dependabot" ]; then
      if [[ "${pr_branch}" == dependabot/* ]]; then
        pr_update=1
      fi
    elif [ "${pr_author}" = "${gh_username}" ] || [ "${pr_author}" = "jonaski" ]; then
      for package in $(get_packages); do
        if [[ "${pr_branch}" == "${package}_"* ]] && [[ "${pr_title}" == "Update ${package} to "* ]]; then
          pr_update=1
          break
        fi
      done
    fi
    if ! [ "${pr_update}" = "1" ]; then
      continue
    fi
    if ! [ "$(echo "${pr_json}" | jq '.isDraft')" = "false" ]; then
      continue
    fi
    if ! [ "$(echo "${pr_json}" | jq -r '.mergeable')" = "MERGEABLE" ]; then
      continue
    fi
    if ! [ "$(echo "${pr_json}" | jq -r '.mergeStateStatus')" = "CLEAN" ]; then
      continue
    fi
    review_decision=$(echo "${pr_json}" | jq -r '.reviewDecision')
    if [ ! "${review_decision}" = "" ] && [ ! "${review_decision}" = "APPROVED" ] ; then
      continue
    fi
    status_check_rollup="${pr_json}"
    status_check_ok="1"
    status_check_total=$(echo "${status_check_rollup}" | jq '.statusCheckRollup | length')
    # A new pull request can be clean before the checks are registered, so don't merge without any checks.
    if [ "${status_check_total}" = "" ] || [ "${status_check_total}" = "0" ]; then
      continue
    fi
    for ((i = 0; i < status_check_total; i++)); do
      # Use the conclusion of completed check runs, legacy commit statuses have a state instead.
      status_check=$(echo "${status_check_rollup}" | jq -r ".statusCheckRollup[${i}] | if .__typename == \"StatusContext\" then .state elif .status == \"COMPLETED\" then .conclusion else .status end")
      if ! [ "${status_check}" = "SUCCESS" ] && ! [ "${status_check}" = "NEUTRAL" ] && ! [ "${status_check}" = "SKIPPED" ]; then
        status_check_ok=0
        break
      fi
    done
    if ! [ "${status_check_ok}" = "1" ]; then
      continue
    fi
    status "Merging pull request ${pr}."
    gh pr merge -dr --match-head-commit "${pr_head}" "${pr}"
  done

}

function get_packages() {
  sed -n "s,^  \(.*\)_version: .*$,\1,p" "${ci_file}" | tr '\n' ' '
}

function update_packages() {

  local packages
  local start
  local i
  local failed=0

  read -r -a packages <<< "$(get_packages)"
  if [ "${#packages[@]}" -eq 0 ]; then
    error "No packages."
    return 1
  fi

  # Start with a different package for each 15 minute schedule, so packages later in the list also get time to download files for checksums when the downloads for earlier packages keep failing.
  start=$(( $(date +%s) / 900 % ${#packages[@]} ))
  for ((i = 0; i < ${#packages[@]}; i++)); do
    update_package "${packages[$(( (start + i) % ${#packages[@]} ))]}" || failed=1
    update_repo
  done

  # Fail after checking all packages, so a broken version check doesn't go unnoticed.
  return ${failed}

}

function update_package() {

  local package_name
  local package_version_current
  local package_version_latest
  local package_git
  local package_year
  local package_year_variable
  local package_download
  local pr_mergeable
  local branch_head

  package_name="${1}"
  package_git=0
  package_year=
  package_version_current=$(cat "${ci_file}" | sed -n "s,^  ${package_name}_version: \(.*\)\$,\1,p" | tr -d "\'")

  if [ "${package_version_current}" = "" ]; then
    error "Could not get current version for ${package}."
    return 1
  fi

  case ${package_name} in
    "nasm")
      package_version_latest=$(curl ${curl_options} 'https://www.nasm.us/pub/nasm/releasebuilds/?C=M;O=D' | sed -n 's,.*href="\([0-9\.]*[^a-z]\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "yasm")
      package_version_latest=$(latest_git_commit "https://github.com/yasm/yasm.git")
      package_git=1
      ;;
    "win_flex_bison")
      package_version_latest=$(curl ${curl_options} 'https://sourceforge.net/projects/winflexbison/files/' | sed -n 's,.*<a href=".*files\/win_flex_bison-\(.*\)\.zip\/.*,\1,p' | grep -v 'latest' | sort -V | tail -1)
      ;;
    "pkgconf")
      package_version_latest=$(curl ${curl_options} 'https://github.com/pkgconf/pkgconf/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^pkgconf\-//g' | sort -V | tail -1)
      ;;
    "zlib")
      package_version_latest=$(curl ${curl_options} 'https://zlib.net/' | sed -n 's,.*zlib-\([0-9][^>]*\)\.tar.*,\1,ip' | sort -V | tail -1)
      ;;
    "openssl")
      package_version_latest=$(curl ${curl_options} 'https://www.openssl.org/source/' | sed -n 's,.*openssl-\([0-9][0-9a-z.]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "libpng")
      package_version_latest=$(curl ${curl_options} 'https://sourceforge.net/p/libpng/code/ref/master/tags/' | sed -n 's,.*<a[^>]*>v\([0-9][^<]*\)<.*,\1,p' | grep -v alpha | grep -v beta | grep -v rc | sort -V | tail -1)
      ;;
    "libjpeg_turbo")
      package_version_latest=$(latest_github_release "libjpeg-turbo" "libjpeg-turbo")
      ;;
    "pcre2")
      package_version_latest=$(latest_github_release "PCRE2Project" "pcre2" | sed 's/^pcre2\-//g' | grep -iv rc | sort -V | tail -1)
      ;;
    "bzip2")
      package_version_latest=$(curl ${curl_options} 'https://sourceware.org/pub/bzip2/' | grep 'bzip2-' | sed -n 's,.*bzip2-\([0-9][^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "xz")
      package_version_latest=$(latest_github_release "tukaani-project" "xz")
      ;;
    "brotli")
      package_version_latest=$(latest_github_release "google" "brotli")
      ;;
    "uchardet")
      package_version_latest=$(curl ${curl_options} 'https://www.freedesktop.org/software/uchardet/releases/' | sed -n 's,.*uchardet-\([0-9][^"]*\)\.tar\.xz.*,\1,p' | sort -V | tail -1)
      ;;
    "icu4c")
      package_version_latest=$(latest_github_release "unicode-org" "icu" | sed 's/release\-//g' | tr '\-' '\.')
      ;;
    "pixman")
      package_version_latest=$(curl ${curl_options} 'https://www.cairographics.org/releases/?C=M;O=D' | sed -n 's,.*"pixman-\([0-9][^"]*\)\.tar.*,\1,p' | head -1)
      ;;
    "expat")
      package_version_latest=$(latest_github_release "libexpat" "libexpat" | sed 's/R_//g' | tr '_' '.')
      ;;
    "libxml2")
      package_version_latest=$(curl ${curl_options} 'https://gitlab.gnome.org/GNOME/libxml2/tags' | sed -n "s,.*<a [^>]\+>v\([0-9,\.]\+\)<.*,\\1,p" | head -1)
      ;;
    "nghttp2")
      package_version_latest=$(latest_github_release "nghttp2" "nghttp2")
      ;;
    "dlfcn")
      package_version_latest=$(latest_github_release "dlfcn-win32" "dlfcn-win32")
      ;;
    "libffi")
      package_version_latest=$(latest_git_commit "https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi.git")
      package_git=1
      ;;
    "libpsl")
      package_version_latest=$(latest_github_release "rockdaboot" "libpsl")
      ;;
    "orc")
      package_version_latest=$(curl ${curl_options} 'https://gstreamer.freedesktop.org/src/orc' | sed -n "s,.*orc-\([0-9]*\.[0-9]*\.[0-9]*\)\.tar\.xz.*,\\1,p" | sort -V | tail -1)
      ;;
    "sqlite3")
      # The download is in a directory for the release year, so get the year too.
      package_download=$(curl ${curl_options} 'https://www.sqlite.org/download.html' | sed -n 's,.*\([0-9]\{4\}\)/sqlite-autoconf-\([0-9][^>]*\)\.tar.*,\2 \1,p' | sort -V | tail -1)
      package_version_latest=$(echo "${package_download}" | cut -d ' ' -f 1)
      package_year=$(echo "${package_download}" | cut -d ' ' -f 2)
      ;;
    "glib")
      package_version_latest=$(curl ${curl_options} 'https://gitlab.gnome.org/GNOME/glib/tags' | sed -n "s,.*<a [^>]\+>v\?\([0-9]\+\.[0-9.]\+\)<.*,\1,p" | sort -V | tail -1)
      ;;
    "libsoup")
      package_version_latest=$(curl ${curl_options} 'https://gitlab.gnome.org/GNOME/libsoup/tags' | sed -n "s,.*<a [^>]\+>v\?\([0-9]\+\.[0-9]*[02468]\.[0-9]\+\)<.*,\1,p" | sort -V | tail -1)
      ;;
    "glib_networking")
      package_version_latest=$(latest_git_commit "https://gitlab.gnome.org/GNOME/glib-networking.git")
      package_git=1
      ;;
    "freetype")
      package_version_latest=$(curl ${curl_options} 'https://sourceforge.net/projects/freetype/files/freetype2/' | sed -n 's,.*/projects/.*/\([0-9][^"]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "harfbuzz")
      package_version_latest=$(latest_github_release "harfbuzz" "harfbuzz")
      ;;
    "libogg")
      package_version_latest=$(curl ${curl_options} 'https://www.xiph.org/downloads/' | sed -n 's,.*libogg-\([0-9][^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "libvorbis")
      package_version_latest=$(curl ${curl_options} 'https://www.xiph.org/downloads/' | sed -n 's,.*libvorbis-\([0-9][^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "flac")
      package_version_latest=$(latest_github_release "xiph" "flac")
      ;;
    "wavpack")
      package_version_latest=$(curl ${curl_options} 'https://www.wavpack.com/downloads.html' | sed -n "s,.*\"wavpack-\(.*\)\.tar.*,\1,p" | sort -V | tail -1)
      ;;
    "opus")
      package_version_latest=$(curl ${curl_options} 'https://downloads.xiph.org/releases/opus/?C=M;O=D' | sed -n 's,.*opus-\([0-9][^>]*\)\.tar.*,\1,p' | grep -v 'alpha' | grep -v 'beta' | grep -v 'rc' | sort -V | tail -1)
      ;;
    "opusfile")
      package_version_latest=$(curl ${curl_options} 'https://downloads.xiph.org/releases/opus/?C=M;O=D' | sed -n 's,.*opusfile-\([0-9][^>]*\)\.tar.*,\1,p' | grep -v 'alpha' | grep -v 'beta' | sort -V | tail -1)
      ;;
    "speex")
      package_version_latest=$(curl ${curl_options} 'https://downloads.xiph.org/releases/speex/' | sed -n 's,.*<a href="speex-\([0-9][0-9.]*\)\.tar\.[gx]z">.*,\1,p' | sort -V | tail -1)
      ;;
    "mpg123")
      package_version_latest=$(curl ${curl_options} 'https://sourceforge.net/projects/mpg123/files/mpg123/' | sed -n 's,.*/projects/.*/\([0-9][^"]*\)/".*,\1,p' | grep -v 'beta' | grep -v 'svn' | sort -V | tail -1)
      ;;
    "lame")
      package_version_latest=$(curl ${curl_options} 'https://sourceforge.net/p/lame/svn/HEAD/tree/tags' | grep RELEASE_ | sed -n 's,.*RELEASE__\([0-9_][^<]*\)<.*,\1,p' | tr '_' '.' | sort -V | tail -1)
      ;;
    "musepack")
      package_version_latest=$(curl ${curl_options} 'https://www.musepack.net/index.php?pg=src' | sed -n 's,.*musepack_src_r\([^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "libopenmpt")
      package_version_latest=$(curl ${curl_options} 'https://lib.openmpt.org/files/libopenmpt/src/' | sed -n 's,.*libopenmpt-\([0-9][^>]*\)+release\.autotools\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "libgme")
      package_version_latest=$(latest_github_release "libgme" "game-music-emu")
      ;;
    "faad2")
      package_version_latest=$(latest_github_release "knik0" "faad2")
      ;;
    "faac")
      package_version_latest=$(latest_github_release "knik0" "faac")
      ;;
    "fdk_aac")
      package_version_latest=$(curl ${curl_options} 'https://sourceforge.net/projects/opencore-amr/files/fdk-aac/' | sed -n 's,.*fdk-aac-\([0-9.]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "utfcpp")
      package_version_latest=$(latest_github_release "nemtrif" "utfcpp")
      ;;
    "taglib")
      package_version_latest=$(latest_github_release "taglib" "taglib")
      ;;
    "libbs2b")
      package_version_latest=$(curl ${curl_options} 'https://sourceforge.net/projects/bs2b/files/libbs2b/' | sed -n 's,.*<a href="/projects/bs2b/files/libbs2b/\([0-9][^"]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "libebur128")
      package_version_latest=$(latest_github_release "jiixyj" "libebur128")
      ;;
    "fftw_source")
      package_version_latest=$(curl ${curl_options} 'https://www.fftw.org/download.html' | sed -n 's,.*fftw-\([0-9][^>]*\)\.tar.*,\1,p' | head -1)
      ;;
    "fftw_mingw")
      package_version_latest=$(latest_github_release "strawberrymusicplayer" "fftw3-mingw-cross")
      ;;
    "ffmpeg")
      package_version_latest=$(git ls-remote --heads https://gitlab.freedesktop.org/gstreamer/meson-ports/ffmpeg.git | cut -d '/' -f 3 | grep '^meson-' | sed 's/^meson-//g' | sort -V | tail -1)
      ;;
    "chromaprint")
      package_version_latest=$(latest_github_release "acoustid" "chromaprint")
      ;;
    "gstreamer")
      package_version_latest=$(curl ${curl_options} 'https://gstreamer.freedesktop.org/src/gstreamer' | sed -n "s,.*gstreamer-\([0-9]\.[0-9][02468]\.[0-9]*\)\.tar\.xz.*,\\1,p" | sort -V | tail -1)
      ;;
    "gstreamer_plugins_rs")
      package_version_latest=$(git ls-remote --tags https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git | cut -d ' ' -f 2 | grep -v 'gstreamer' | cut -d '/' -f 3 | sed '/.\^/d' | sort -V | tail -1)
      ;;
    "qt")
      qt_major_version=$(curl ${curl_options} "https://download.qt.io/official_releases/qt/" | sed -n 's,.*<a href=\"\([0-9]*\.[0-9]*\).*,\1,p' | sort -V | tail -1)
      package_version_latest=$(curl ${curl_options} "https://download.qt.io/official_releases/qt/${qt_major_version}/" | sed -n 's,.*href="\([0-9]*\.[0-9]*\.[^/]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "kdsingleapplication")
      package_version_latest=$(latest_github_release "KDAB" "KDSingleApplication")
      ;;
    "qtsparkle")
      package_version_latest=$(latest_git_commit "https://github.com/jonaski/qtsparkle.git")
      package_git=1
      ;;
    "abseil_cpp")
      package_version_latest=$(latest_github_release "abseil" "abseil-cpp")
      ;;
    "protobuf")
      package_version_latest=$(latest_github_release "protocolbuffers" "protobuf")
      ;;
    "sparsehash")
      package_version_latest=$(latest_github_release "sparsehash" "sparsehash")
      ;;
    "getopt_win")
      package_version_latest=$(latest_github_release "ludvikjerabek" "getopt-win")
      ;;
    "proxy_libintl")
      package_version_latest=$(latest_github_release "frida" "proxy-libintl")
      ;;
    "jasper")
      package_version_latest=$(latest_github_release "jasper-software" "jasper")
      ;;
    "tiff")
      package_version_latest=$(curl ${curl_options} 'https://download.osgeo.org/libtiff/' | sed -n 's,.*tiff-\([0-9][0-9.]*[0-9]\)\.tar\.gz.*,\1,p' | sort -V | tail -1)
      ;;
    "libwebp")
      package_version_latest=$(curl ${curl_options} 'https://storage.googleapis.com/downloads.webmproject.org/releases/webp/index.html' | sed -n 's,.*libwebp-\([0-9]\+\.[0-9]\+\.[0-9]\+\)\.tar.gz.*,\1,p' | tail -1)
      ;;
    "pe_parse")
      package_version_latest=$(latest_github_release "trailofbits" "pe-parse")
      ;;
    "pe_util")
      package_version_latest=$(latest_git_commit "https://github.com/gsauthof/pe-util.git")
      package_git=1
      ;;
    *)
      package_version_latest=
      error "No update rule for package: ${package}"
      return 1
      ;;
  esac

  if [ "${package_version_latest}" = "" ]; then
    error "Could not get latest version for ${package}."
    return 1
  fi

  # The version is used in sed, git and gh commands, so don't allow anything else than a plain version or commit.
  if ! [[ "${package_version_latest}" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
    error "Invalid latest version for ${package}: ${package_version_latest}"
    return 1
  fi

  if ! [ "${package_year}" = "" ] && ! [[ "${package_year}" =~ ^[0-9]{4}$ ]]; then
    error "Invalid release year for ${package}: ${package_year}"
    return 1
  fi

  if [ "${package_git}" = "1" ]; then
    package_version_highest="${package_version_latest}"
  else
    package_version_highest=$(echo "${package_version_current} ${package_version_latest}" | tr ' ' '\n' | sort -V | tail -1)
  fi

  if [ "${package_version_highest}" = "" ]; then
    error "Could not get highest version for ${package}."
    return 1
  fi

  if [ "${package_version_highest}" = "${package_version_current}" ]; then
    status "${package_name}: ${package_version_current} is the latest"
  else
    branch="${package_name}_$(echo ${package_version_latest} | sed 's/\./_/g')"
    # Check all pull requests first, closed ones too, so an update that was closed on purpose isn't pushed or opened again.
    pr_count=$(gh pr list --repo "${repo}" --head "${branch}" --state all --json number --jq 'length')
    if [ $? -ne 0 ] || [ "${pr_count}" = "" ]; then
      error "Could not list pull requests for ${branch}."
      return 1
    fi
    if [ "${pr_count}" = "0" ]; then
      # Check the remote, a fresh clone in GitHub Actions doesn't have the local branches from earlier runs.
      # The branch can exist without a pull request if creating the pull request failed in an earlier run.
      if ! git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
        # A local branch that was never pushed can have commits that would be lost, so leave it alone.
        if git show-ref --verify --quiet "refs/heads/${branch}"; then
          error "${branch} exists locally but not on origin, it needs to be pushed or deleted manually."
          return 1
        fi
        status "${package_name}: updating from ${package_version_current} to ${package_version_latest}..."
        # Get the checksums first, so an update isn't pushed when the files can't be downloaded yet.
        get_package_checksums "${package_name}" "${package_version_latest}" "${package_year}" || return 1
        # Upload the files before the update is pushed, so the packages server has them when the update is merged.
        # Continue with the update if the upload fails, the packages server is only a fallback.
        upload_package_files "${package_name}"
        remove_package_files
        push_update_branch -b || exit 1
      fi
      gh pr create --repo "${repo}" --head "${branch}" --base "master" --title "Update ${package_name} to ${package_version_latest}" --body "Update ${package_name} from ${package_version_current} to ${package_version_latest}" || exit 1
    else
      # An open update pull request conflicts when master changed the same line, for example when an update to an earlier version was merged.
      # Recreate the branch from master so it can still be merged.
      pr_mergeable=$(gh pr list --repo "${repo}" --head "${branch}" --state open --json mergeable --jq '.[0].mergeable // ""')
      if [ "${pr_mergeable}" = "CONFLICTING" ]; then
        # Only recreate branches with just the generated commit and changes, so commits and edits added by hand aren't lost.
        git fetch origin "${branch}" >/dev/null 2>&1 || exit 1
        branch_head=$(git rev-parse "origin/${branch}") || exit 1
        # The local branch is reset too, so it can't have commits that aren't on origin.
        if git show-ref --verify --quiet "refs/heads/${branch}" && ! [ "$(git rev-parse "refs/heads/${branch}")" = "${branch_head}" ]; then
          error "${branch} conflicts with master and differs locally from origin, it needs to be resolved manually."
        # The generated changes include the checksums, so get them before checking the branch.
        elif ! get_package_checksums "${package_name}" "${package_version_latest}" "${package_year}"; then
          return 1
        elif update_branch_is_generated "${branch_head}"; then
          status "${package_name}: recreating ${branch} from master..."
          upload_package_files "${package_name}"
          remove_package_files
          # Only overwrite the commit that was checked.
          push_update_branch -B "--force-with-lease=${branch}:${branch_head}" || exit 1
        else
          remove_package_files
          error "${branch} conflicts with master and has other changes, it needs to be resolved manually."
        fi
      fi
    fi
  fi

}

# Uses the variables from update_package.
# Updates the version, year and checksums in the CI file, the arguments are passed to sed.
# The checksums from get_package_checksums replace the existing ones, and are put right after the version of the package.
function update_ci_file() {

  local sed_args
  local checksum

  sed_args=(-e "s,^  ${package_name}_version: .*,  ${package_name}_version: '${package_version_latest}',g")
  if ! [ "${package_year}" = "" ]; then
    sed_args+=(-e "s,^  ${package_name}_year: .*,  ${package_name}_year: '${package_year}',g")
  fi
  for checksum in "${package_checksums[@]}"; do
    sed_args+=(-e "/^  ${checksum%%=*}: /d")
  done
  for checksum in "${package_checksums[@]}"; do
    sed_args+=(-e "/^  ${package_name}_version: /a\\  ${checksum%%=*}: '${checksum#*=}'")
  done
  sed "${sed_args[@]}" "$@"

}

# Uses the variables from update_package.
# Checks that the branch only has the generated commit, and that the CI file is exactly what the update generates from the merge base, so edits added by hand aren't lost when it's recreated.
function update_branch_is_generated() {

  local branch_head
  local merge_base

  branch_head="${1}"

  [ "$(git rev-list --count "origin/master..${branch_head}")" = "1" ] || return 1
  [ "$(git log -1 --format=%s "${branch_head}")" = "Update ${package_name}" ] || return 1
  [ "$(git diff --name-only "origin/master...${branch_head}")" = "${ci_file}" ] || return 1

  merge_base=$(git merge-base origin/master "${branch_head}") || return 1
  cmp -s <(git show "${merge_base}:${ci_file}" | update_ci_file) <(git show "${branch_head}:${ci_file}") || return 1

  return 0

}

# Prints the checksum variable and download URL for each file downloaded for a package version, one per line.
# The URLs must be for the same files as the first URL for each package in the download steps in the CI file, the checksum variable is the package name with _sha256sum added.
function package_downloads() {

  local package_name="${1}"
  local v="${2}"
  local year="${3}"
  local v_short
  local mirror="downloads.sourceforge.net"

  v_short=$(echo "${v}" | cut -d '.' -f 1-2)

  case ${package_name} in
    "nasm") echo "nasm_sha256sum https://www.nasm.us/pub/nasm/releasebuilds/${v}/win64/nasm-${v}-installer-x64.exe" ;;
    "win_flex_bison") echo "win_flex_bison_sha256sum https://github.com/lexxmark/winflexbison/releases/download/v${v}/win_flex_bison-${v}.zip" ;;
    "pkgconf") echo "pkgconf_sha256sum https://github.com/pkgconf/pkgconf/archive/refs/tags/pkgconf-${v}.tar.gz" ;;
    "proxy_libintl") echo "proxy_libintl_sha256sum https://github.com/frida/proxy-libintl/archive/refs/tags/${v}/proxy-libintl-${v}.tar.gz" ;;
    "getopt_win") echo "getopt_win_sha256sum https://github.com/ludvikjerabek/getopt-win/archive/refs/tags/v${v}/getopt-win-${v}.tar.gz" ;;
    "zlib") echo "zlib_sha256sum https://github.com/madler/zlib/releases/download/v${v}/zlib-${v}.tar.gz" ;;
    "openssl") echo "openssl_sha256sum https://github.com/openssl/openssl/releases/download/openssl-${v}/openssl-${v}.tar.gz" ;;
    "libpng") echo "libpng_sha256sum https://${mirror}/project/libpng/libpng16/${v}/libpng-${v}.tar.xz" ;;
    "libjpeg_turbo") echo "libjpeg_turbo_sha256sum https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${v}/libjpeg-turbo-${v}.tar.gz" ;;
    "pcre2") echo "pcre2_sha256sum https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${v}/pcre2-${v}.tar.bz2" ;;
    "bzip2") echo "bzip2_sha256sum https://sourceware.org/pub/bzip2/bzip2-${v}.tar.gz" ;;
    "xz") echo "xz_sha256sum https://github.com/tukaani-project/xz/releases/download/v${v}/xz-${v}.tar.xz" ;;
    "brotli") echo "brotli_sha256sum https://github.com/google/brotli/archive/refs/tags/v${v}/brotli-${v}.tar.gz" ;;
    "uchardet") echo "uchardet_sha256sum https://www.freedesktop.org/software/uchardet/releases/uchardet-${v}.tar.xz" ;;
    "icu4c") echo "icu4c_sha256sum https://github.com/unicode-org/icu/releases/download/release-${v}/icu4c-${v}-sources.tgz" ;;
    "pixman") echo "pixman_sha256sum https://www.cairographics.org/releases/pixman-${v}.tar.gz" ;;
    "expat") echo "expat_sha256sum https://github.com/libexpat/libexpat/releases/download/R_${v//./_}/expat-${v}.tar.xz" ;;
    "libxml2") echo "libxml2_sha256sum https://download.gnome.org/sources/libxml2/${v_short}/libxml2-${v}.tar.xz" ;;
    "nghttp2") echo "nghttp2_sha256sum https://github.com/nghttp2/nghttp2/releases/download/v${v}/nghttp2-${v}.tar.xz" ;;
    "dlfcn") echo "dlfcn_sha256sum https://github.com/dlfcn-win32/dlfcn-win32/archive/refs/tags/v${v}/dlfcn-win32-${v}.tar.gz" ;;
    "libpsl") echo "libpsl_sha256sum https://github.com/rockdaboot/libpsl/releases/download/${v}/libpsl-${v}.tar.gz" ;;
    "orc") echo "orc_sha256sum https://gstreamer.freedesktop.org/src/orc/orc-${v}.tar.xz" ;;
    "sqlite3") echo "sqlite3_sha256sum https://sqlite.org/${year}/sqlite-autoconf-${v}.tar.gz" ;;
    "glib") echo "glib_sha256sum https://download.gnome.org/sources/glib/${v_short}/glib-${v}.tar.xz" ;;
    "libsoup") echo "libsoup_sha256sum https://download.gnome.org/sources/libsoup/${v_short}/libsoup-${v}.tar.xz" ;;
    "freetype") echo "freetype_sha256sum https://${mirror}/project/freetype/freetype2/${v}/freetype-${v}.tar.gz" ;;
    "harfbuzz") echo "harfbuzz_sha256sum https://github.com/harfbuzz/harfbuzz/releases/download/${v}/harfbuzz-${v}.tar.xz" ;;
    "jasper") echo "jasper_sha256sum https://github.com/jasper-software/jasper/releases/download/version-${v}/jasper-${v}.tar.gz" ;;
    "tiff") echo "tiff_sha256sum https://download.osgeo.org/libtiff/tiff-${v}.tar.gz" ;;
    "libwebp") echo "libwebp_sha256sum https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${v}.tar.gz" ;;
    "libogg") echo "libogg_sha256sum https://downloads.xiph.org/releases/ogg/libogg-${v}.tar.xz" ;;
    "libvorbis") echo "libvorbis_sha256sum https://downloads.xiph.org/releases/vorbis/libvorbis-${v}.tar.xz" ;;
    "flac") echo "flac_sha256sum https://github.com/xiph/flac/releases/download/${v}/flac-${v}.tar.xz" ;;
    "wavpack") echo "wavpack_sha256sum https://github.com/dbry/WavPack/releases/download/${v}/wavpack-${v}.tar.xz" ;;
    "opus") echo "opus_sha256sum https://downloads.xiph.org/releases/opus/opus-${v}.tar.gz" ;;
    "opusfile") echo "opusfile_sha256sum https://downloads.xiph.org/releases/opus/opusfile-${v}.tar.gz" ;;
    "speex") echo "speex_sha256sum https://gitlab.xiph.org/xiph/speex/-/archive/Speex-${v}/speex-Speex-${v}.tar.gz" ;;
    "mpg123") echo "mpg123_sha256sum https://${mirror}/project/mpg123/mpg123/${v}/mpg123-${v}.tar.bz2" ;;
    "lame") echo "lame_sha256sum https://${mirror}/project/lame/lame/${v}/lame-${v}.tar.gz" ;;
    "musepack") echo "musepack_sha256sum https://files.musepack.net/source/musepack_src_r${v}.tar.gz" ;;
    "libopenmpt") echo "libopenmpt_sha256sum https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-${v}+release.msvc.zip" ;;
    "libgme") echo "libgme_sha256sum https://github.com/libgme/game-music-emu/releases/download/${v}/libgme-${v}-src.tar.gz" ;;
    "faad2") echo "faad2_sha256sum https://github.com/knik0/faad2/tarball/${v}/faad2-${v}.tar.gz" ;;
    "faac") echo "faac_sha256sum https://github.com/knik0/faac/archive/refs/tags/faac-${v}.tar.gz" ;;
    "fdk_aac") echo "fdk_aac_sha256sum https://${mirror}/project/opencore-amr/fdk-aac/fdk-aac-${v}.tar.gz" ;;
    "utfcpp") echo "utfcpp_sha256sum https://github.com/nemtrif/utfcpp/archive/refs/tags/v${v}/utfcpp-${v}.tar.gz" ;;
    "taglib") echo "taglib_sha256sum https://taglib.org/releases/taglib-${v}.tar.gz" ;;
    "libbs2b") echo "libbs2b_sha256sum https://${mirror}/project/bs2b/libbs2b/${v}/libbs2b-${v}.tar.bz2" ;;
    "libebur128") echo "libebur128_sha256sum https://github.com/jiixyj/libebur128/archive/refs/tags/v${v}/libebur128-${v}.tar.gz" ;;
    "fftw_source") echo "fftw_source_sha256sum https://www.fftw.org/fftw-${v}.tar.gz" ;;
    "fftw_mingw")
      # Only x86_64 uses the MinGW binary package, arm64 builds FFTW from source.
      echo "fftw_mingw_debug_sha256sum https://github.com/strawberrymusicplayer/fftw3-mingw-cross/releases/download/${v}/fftw-x86_64-w64-mingw32-debug-${v}.tar.xz"
      echo "fftw_mingw_release_sha256sum https://github.com/strawberrymusicplayer/fftw3-mingw-cross/releases/download/${v}/fftw-x86_64-w64-mingw32-release-${v}.tar.xz"
      ;;
    "chromaprint") echo "chromaprint_sha256sum https://github.com/acoustid/chromaprint/releases/download/v${v}/chromaprint-${v}.tar.gz" ;;
    "gstreamer")
      echo "gstreamer_sha256sum https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-${v}.tar.xz"
      echo "gst_plugins_base_sha256sum https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-${v}.tar.xz"
      echo "gst_plugins_good_sha256sum https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-${v}.tar.xz"
      echo "gst_plugins_bad_sha256sum https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-${v}.tar.xz"
      echo "gst_plugins_ugly_sha256sum https://gstreamer.freedesktop.org/src/gst-plugins-ugly/gst-plugins-ugly-${v}.tar.xz"
      echo "gst_libav_sha256sum https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-${v}.tar.xz"
      ;;
    "qt")
      # Use the main Qt download server, the mirror used first in the CI file can lag behind.
      echo "qtbase_sha256sum https://download.qt.io/official_releases/qt/${v_short}/${v}/submodules/qtbase-everywhere-src-${v}.tar.xz"
      echo "qttools_sha256sum https://download.qt.io/official_releases/qt/${v_short}/${v}/submodules/qttools-everywhere-src-${v}.tar.xz"
      echo "qtimageformats_sha256sum https://download.qt.io/official_releases/qt/${v_short}/${v}/submodules/qtimageformats-everywhere-src-${v}.tar.xz"
      ;;
    "kdsingleapplication") echo "kdsingleapplication_sha256sum https://github.com/KDAB/KDSingleApplication/releases/download/v${v}/kdsingleapplication-${v}.tar.gz" ;;
    "sparsehash") echo "sparsehash_sha256sum https://github.com/sparsehash/sparsehash/archive/refs/tags/sparsehash-${v}.tar.gz" ;;
    "pe_parse") echo "pe_parse_sha256sum https://github.com/trailofbits/pe-parse/archive/refs/tags/v${v}/pe-parse-${v}.tar.gz" ;;
    # Git repositories don't have checksums.
    *) ;;
  esac

}

# Downloads a file, retrying until the deadline in seconds since the script started.
# A 404 isn't retried, since the file doesn't exist.
function download_file() {

  local url="${1}"
  local output="${2}"
  local deadline="${3}"
  local attempt
  local remaining
  local http_code

  for ((attempt = 1; attempt <= 10; attempt++)); do
    remaining=$((deadline - SECONDS))
    if [ "${remaining}" -le 0 ]; then
      return 1
    fi
    # timeout makes sure the remaining time isn't exceeded.
    # Abort a stalled transfer instead of limiting the time for each attempt, so a slow download of a large file can still finish.
    # Keep the time of the file from the server, it's kept when uploading to the packages server.
    http_code=$(timeout "${remaining}" curl -s -f -L -R --connect-timeout 60 --speed-limit 1024 --speed-time 60 -w '%{http_code}' -o "${output}" "${url}") && return 0
    if [ "${http_code}" = "404" ]; then
      error "${url} returned 404."
      return 1
    fi
    if [ "${attempt}" -lt 10 ]; then
      sleep 10
    fi
  done

  return 1

}

# Downloads the files for a package version and sets package_checksums to a list of variable=sha256.
# The files are kept in package_files_dir with the filename from the URL, so they can be uploaded to the packages server, remove them with remove_package_files.
function get_package_checksums() {

  local package_name="${1}"
  local package_version="${2}"
  local package_year="${3}"
  local key
  local url
  local file
  local sha256
  local deadline
  local remaining

  # Limit the time for all files of the package together, and for all packages in this run.
  deadline=$((SECONDS + checksum_package_time_limit))
  if ! [ "${checksum_run_deadline}" = "" ] && [ "${checksum_run_deadline}" -lt "${deadline}" ]; then
    deadline="${checksum_run_deadline}"
  fi

  package_checksums=()
  remove_package_files
  package_files_dir=$(mktemp -d) || return 1
  while read -r key url; do
    [ "${key}" = "" ] && continue
    remaining=$((deadline - SECONDS))
    if [ "${remaining}" -le 0 ]; then
      error "No time left to download ${url} for checksum, trying again in the next run."
      remove_package_files
      return 1
    fi
    status "${package_name}: downloading ${url} for checksum..."
    file="${package_files_dir}/${url##*/}"
    if ! download_file "${url}" "${file}" "${deadline}"; then
      error "Could not download ${url} for checksum."
      remove_package_files
      return 1
    fi
    if ! [ -s "${file}" ]; then
      error "Got an empty file for ${url}."
      remove_package_files
      return 1
    fi
    # Don't set a checksum for a HTML page served instead of the file.
    if head -c 1024 "${file}" | grep -qi '<html\|<!doctype'; then
      error "Got a HTML page instead of a file for ${url}."
      remove_package_files
      return 1
    fi
    sha256=$(sha256sum "${file}" | cut -d ' ' -f 1)
    if ! [[ "${sha256}" =~ ^[0-9a-f]{64}$ ]]; then
      error "Could not get checksum for ${url}."
      remove_package_files
      return 1
    fi
    package_checksums+=("${key}=${sha256}")
  done < <(package_downloads "${package_name}" "${package_version}" "${package_year}")

}

function remove_package_files() {

  if ! [ "${package_files_dir}" = "" ]; then
    rm -rf "${package_files_dir}"
    package_files_dir=
  fi

}

# Uploads the files from get_package_checksums to the packages server with rsync.
# The SSH settings are from the SSH_HOST, SSH_PORT, SSH_USER and PACKAGES_PATH environment variables, and the SSH key and known hosts files installed by the workflow.
function upload_package_files() {

  local package_name="${1}"
  local variable
  local missing=
  local ssh_command
  local files=()
  local file

  # Packages from git repositories don't have any files.
  if ! [ "${package_files_dir}" = "" ]; then
    for file in "${package_files_dir}"/*; do
      if [ -f "${file}" ]; then
        files+=("${file}")
      fi
    done
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    status "${package_name}: no files to upload to the packages server."
    return 0
  fi

  if [ "${SSH_HOST}" = "" ] && [ "${SSH_PORT}" = "" ] && [ "${SSH_USER}" = "" ] && [ "${PACKAGES_PATH}" = "" ] && ! [ -f "${ssh_key_file}" ]; then
    status "${package_name}: not uploading to the packages server, the SSH settings are not set."
    return 0
  fi

  for variable in SSH_HOST SSH_PORT SSH_USER PACKAGES_PATH; do
    if [ "${!variable}" = "" ]; then
      missing="${missing} ${variable}"
    fi
  done
  for variable in ssh_key_file ssh_known_hosts_file; do
    if ! [ -f "${!variable}" ]; then
      missing="${missing} ${!variable}"
    fi
  done
  if ! [ "${missing}" = "" ]; then
    error "Missing${missing} for uploading to the packages server."
    return 1
  fi

  if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]]; then
    error "Invalid SSH_PORT."
    return 1
  fi

  ssh_command="ssh -p ${SSH_PORT} -i ${ssh_key_file} -o IdentitiesOnly=yes -o UserKnownHostsFile=${ssh_known_hosts_file} -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=60"

  status "${package_name}: uploading ${files[*]##*/} to the packages server..."
  # Keep the times of the files, and make them readable by the web server.
  if ! timeout 600 rsync -t --chmod=F644 -e "${ssh_command}" "${files[@]}" "${SSH_USER}@${SSH_HOST}:${PACKAGES_PATH%/}/"; then
    error "Could not upload the files for ${package_name} to the packages server."
    return 1
  fi

}

# Sets the checksums for the current version of all packages in the CI file, used when checksums are missing.
function update_all_checksums() {

  local package
  local package_name
  local package_version_latest
  local package_year
  local failed=0

  for package in $(get_packages); do
    package_name="${package}"
    package_version_latest=$(sed -n "s,^  ${package_name}_version: \(.*\)\$,\1,p" "${ci_file}" | tr -d "\'")
    package_year=$(sed -n "s,^  ${package_name}_year: \(.*\)\$,\1,p" "${ci_file}" | tr -d "\'")
    if get_package_checksums "${package_name}" "${package_version_latest}" "${package_year}"; then
      remove_package_files
      update_ci_file -i "${ci_file}" || failed=1
    else
      failed=1
    fi
  done

  return ${failed}

}

# Uses the variables from update_package.
# The first argument is the checkout option, -b for a new branch or -B to recreate a checked branch, the rest are passed to git push.
function push_update_branch() {

  local checkout_option

  checkout_option="${1}"
  shift

  git checkout "${checkout_option}" "${branch}" || return 1
  update_ci_file -i "${ci_file}" || return 1
  git commit -m "Update ${package_name}" "${ci_file}" || return 1
  git push "$@" origin "${branch}" || return 1
  git checkout . >/dev/null 2>&1 || return 1
  if ! [ "$(git branch | head -1 | cut -d ' ' -f2)" = "master" ]; then
    git checkout master >/dev/null 2>&1 || return 1
  fi

}

cmds="dirname cat head tail cut sort tr grep sed cmp curl jq git gh sha256sum mktemp timeout"
cmds_missing=
for cmd in ${cmds}; do
  which "${cmd}" >/dev/null 2>&1
  if [ $? -eq 0 ] ; then
    continue
  fi
  if [ "${cmds_missing}" = "" ]; then
    cmds_missing="${cmd}"
  else
    cmds_missing="${cmds_missing}, ${cmd}"
  fi
done

if ! [ "${cmds_missing}" = "" ]; then
  error "Missing ${cmds_missing} commands."
  exit 1
fi

dir="$(dirname "$0")"

if [ "${dir}" = "" ]; then
  error "Could not get current directory."
  exit 1
fi

if ! [ -d "${dir}" ]; then
  error "Missing ${dir}"
  exit 1
fi

if ! [ -d "${dir}/../.git" ]; then
  error "Missing ${dir}/../.git"
  exit 1
fi

# Resolve to an absolute path, dirname of . is still . when run from the scripts directory.
repodir="$(cd "${dir}/.." && pwd)"

if ! [ -d "${repodir}" ]; then
  error "Missing ${repodir}."
  exit 1
fi

cd "${repodir}"
if [ $? -ne 0 ]; then
  error "Could not change directory to ${repodir}."
  exit 1
fi

# Set the checksums for the current versions, used when checksums are missing.
if [ "${1}" = "--checksums" ]; then
  update_all_checksums
  exit $?
fi

repo="${GITHUB_REPOSITORY}"
if [ "${repo}" = "" ]; then
  repo=$(git config --get remote.origin.url | sed 's,^https://github\.com/,,g' | sed 's,^git@github\.com:,,g' | sed 's/\.git$//g')
fi
if [ "${repo}" = "" ]; then
  error "Could not get repo name."
  exit 1
fi

gh auth status >/dev/null || exit 1
if [ $? -ne 0 ]; then
  error "Missing GitHub login."
  exit 1
fi

gh_username=$(gh api user --jq '.login' 2>/dev/null)
if [ "${gh_username}" = "" ] && [ -f ~/.config/gh/hosts.yml ]; then
  gh_username=$(sed -n 's,^[ ]*user: \(.*\)$,\1,p' ~/.config/gh/hosts.yml | head -1)
fi
if [ "${gh_username}" = "" ]; then
  error "Missing GitHub username."
  exit 1
fi

gh_token=$(gh auth token 2>/dev/null)
if [ "${gh_token}" = "" ]; then
  error "Missing GitHub token."
  exit 1
fi

update_repo
merge_prs

update_repo
checksum_run_deadline=$((SECONDS + checksum_run_time_limit))
update_packages
