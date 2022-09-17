#!/bin/bash
#
#  STRAWBERRY MSVC GITHUB ACTION UPDATE SCRIPT
#  Copyright (C) 2022 Jonas Kvinge
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

repo="strawberrymusicplayer/strawberry-msvc-dependencies"
repodir="${HOME}/Projects/strawberry-msvc-dependencies"
ci_file=".github/workflows/build.yml"

function timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
function error() { echo "[$(timestamp)] ERROR: $*" >&2; }

function update_package() {

  local package_name
  local package_version_current
  local package_version_latest

  package_name="${1}"
  package_version_current=$(cat "${ci_file}" | sed -n "s,^  ${package_name}_version: \(.*\)\$,\1,p" | tr -d "\'")

  if [ "${package_version_current}" = "" ]; then
    echo "Could not get current version for ${package}."
    return
  fi

  case ${package_name} in
    "nasm")
      package_version_latest=$(wget -q -O- 'https://www.nasm.us/pub/nasm/releasebuilds/?C=M;O=D' | sed -n 's,.*href="\([0-9\.]*[^a-z]\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "yasm")
      package_version_latest=$(wget -q -O- 'https://github.com/yasm/yasm/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^v//g' | sort -V | tail -1)
      ;;
    "boost")
      package_version_latest=$(wget -q -O- 'https://www.boost.org/users/download/' | sed -n 's,.*/release/\([0-9][^"/]*\)/.*,\1,p' | grep -v beta | sort -V | tail -1)
      ;;
    "pkgconf")
      package_version_latest=$(wget -q -O- 'https://github.com/pkgconf/pkgconf/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^pkgconf\-//g' | sort -V | tail -1)
      ;;
    "zlib")
      package_version_latest=$(wget -q -O- 'https://zlib.net/' | sed -n 's,.*zlib-\([0-9][^>]*\)\.tar.*,\1,ip' | sort -V | tail -1)
      ;;
    "openssl")
      package_version_latest=$(wget -q -O- 'https://www.openssl.org/source/' | sed -n 's,.*openssl-\([0-9][0-9a-z.]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "gnutls")
      package_version_latest=$(wget -q -O- 'https://github.com/ShiftMediaProject/gnutls/releases' | sed -n 's,.*releases/tag/\([^"&;]*\)".*,\1,p' | sort -V | tail -1)
      ;;
    "libpng")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/p/libpng/code/ref/master/tags/' | sed -n 's,.*<a[^>]*>v\([0-9][^<]*\)<.*,\1,p' | grep -v alpha | grep -v beta | grep -v rc | sort -V | tail -1)
      ;;
    "pcre2")
      package_version_latest=$(wget -q -O- 'https://github.com/PhilipHazel/pcre2/releases' | sed -n 's,.*releases/tag/\([^"&;]*\)".*,\1,p' | sed 's/^pcre2\-//g' | sort -V | tail -1)
      ;;
    "bzip2")
      package_version_latest=$(wget -q -O- 'https://sourceware.org/pub/bzip2/' | grep 'bzip2-' | sed -n 's,.*bzip2-\([0-9][^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "xz")
      package_version_latest=$(wget -q -O- 'https://tukaani.org/xz/' | sed -n 's,.*xz-\([0-9][^>]*\)\.tar.*,\1,p' | grep -v 'alpha' | grep -v 'beta' | sort -V | tail -1)
      ;;
    "brotli")
      package_version_latest=$(wget -q -O- 'https://github.com/google/brotli/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^v//g' | sort -V | tail -1)
      ;;
    "pixmap")
      package_version_latest=$(wget -q -O- 'https://www.cairographics.org/releases/?C=M;O=D' | sed -n 's,.*"pixman-\([0-9][^"]*\)\.tar.*,\1,p' | head -1)
      ;;
    "libxml2")
      package_version_latest=$(wget -q -O- 'https://gitlab.gnome.org/GNOME/libxml2/tags' | sed -n "s,.*<a [^>]\+>v\([0-9,\.]\+\)<.*,\\1,p" | head -1)
      ;;
    "nghttp2")
      package_version_latest=$(wget -q -O- 'https://github.com/nghttp2/nghttp2/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^v//g' | sort -V | tail -1)
      ;;
    "sqlite3")
      package_version_latest=$(wget -q -O- 'https://www.sqlite.org/download.html' | sed -n 's,.*sqlite-autoconf-\([0-9][^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "libogg")
      package_version_latest=$(wget -q -O- 'https://www.xiph.org/downloads/' | sed -n 's,.*libogg-\([0-9][^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "libvorbis")
      package_version_latest=$(wget -q -O- 'https://www.xiph.org/downloads/' | sed -n 's,.*libvorbis-\([0-9][^>]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "flac")
      package_version_latest=$(wget -q -O- 'https://downloads.xiph.org/releases/flac/' | sed -n 's,.*<a href="flac-\([0-9][0-9.]*\)\.tar\.[gx]z">.*,\1,p' | sort -V | tail -1)
      ;;
    "wavpack")
      package_version_latest=$(wget -q -O- 'http://www.wavpack.com/downloads.html' | sed -n "s,.*\"wavpack-\(.*\)\.tar.*,\1,p" | sort -V | tail -1)
      ;;
    "opus")
      package_version_latest=$(wget -q -O- 'https://archive.mozilla.org/pub/opus/?C=M;O=D' | sed -n 's,.*opus-\([0-9][^>]*\)\.tar.*,\1,p' | grep -v 'alpha' | grep -v 'beta' | grep -v 'rc' | sort -V | tail -1)
      ;;
    "opusfile")
      package_version_latest=$(wget -q -O- 'https://archive.mozilla.org/pub/opus/?C=M;O=D' | sed -n 's,.*opusfile-\([0-9][^>]*\)\.tar.*,\1,p' | grep -v 'alpha' | grep -v 'beta' | sort -V | tail -1)
      ;;
    "mpg123")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/projects/mpg123/files/mpg123/' | sed -n 's,.*/projects/.*/\([0-9][^"]*\)/".*,\1,p' | head -1)
      ;;
    "lame")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/p/lame/svn/HEAD/tree/tags' | grep RELEASE_ | sed -n 's,.*RELEASE__\([0-9_][^<]*\)<.*,\1,p' | tr '_' '.' | sort -V | tail -1)
      ;;
    "twolame")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/projects/twolame/files/twolame/' | sed -n 's,^.*twolame/\([0-9][^"]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "taglib")
      package_version_latest=$(wget -q -O- 'https://github.com/taglib/taglib/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^v//g' | grep -v 'beta' | sort -V | tail -1)
      ;;
    "dlfcn")
      package_version_latest=$(wget -q -O- 'https://github.com/dlfcn-win32/dlfcn-win32/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | grep -v '^r' | sed 's/^v//g' | sort -V | tail -1)
      ;;
    "fftw")
      package_version_latest=$(wget -q -O- 'http://www.fftw.org/install/windows.html' | sed -n 's,.*fftw-\([0-9][^>]*\)\-.*\.zip.*,\1,p' | head -1)
      ;;
    "glib")
      package_version_latest=$(wget -q -O- 'https://gitlab.gnome.org/GNOME/glib/tags' | sed -n "s,.*<a [^>]\+>v\?\([0-9]\+\.[0-9.]\+\)<.*,\1,p" | sort -V | tail -1)
      ;;
    "glib_networking")
      package_version_latest=$(wget -q -O- 'https://gitlab.gnome.org/GNOME/glib-networking/tags' | sed -n "s,.*glib-networking-\([0-9]\+\.[0-9]*[0-9]*\.[^']*\)\.tar.*,\1,p" | grep -v 'alpha' | grep -v 'beta' | grep -v '\.rc' | sort -V | tail -1)
      ;;
    "libpsl")
      package_version_latest=$(wget -q -O- 'https://github.com/rockdaboot/libpsl/releases' | sed -n 's,.*releases/tag/\([^"&;]*\)".*,\1,p' | sed 's/^v//g' | sed 's/^libpsl-//g' | sort -V | tail -1)
      ;;
    "libsoup")
      package_version_latest=$(wget -q -O- 'https://gitlab.gnome.org/GNOME/libsoup/tags' | sed -n "s,.*<a [^>]\+>v\?\([0-9]\+\.[02468]\.[0-9]\+\)<.*,\1,p" | sort -V | tail -1)
      ;;
    "orc")
      package_version_latest=$(wget -q -O- 'https://cgit.freedesktop.org/gstreamer/orc/refs/tags' | sed -n "s,.*<a href='[^']*/tag/?h=[^0-9]*\\([0-9]*\.[0-9]*\.[0-9][^']*\\)'.*,\\1,p" | sort -V | tail -1)
      ;;
    "libopenmpt")
      package_version_latest=$(wget -q -O- 'https://lib.openmpt.org/files/libopenmpt/src/' | sed -n 's,.*libopenmpt-\([0-9][^>]*\)+release\.autotools\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "fdk_aac")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/projects/opencore-amr/files/fdk-aac/' | sed -n 's,.*fdk-aac-\([0-9.]*\)\.tar.*,\1,p' | sort -V | tail -1)
      ;;
    "libbs2b")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/projects/bs2b/files/libbs2b/' | sed -n 's,.*<a href="/projects/bs2b/files/libbs2b/\([0-9][^"]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "chromaprint")
      package_version_latest=$(wget -q -O- 'https://github.com/acoustid/chromaprint/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^v//g' | grep -v 'rc' | sort -V | tail -1)
      ;;
    "gstreamer")
      package_version_latest=$(wget -q -O- 'https://cgit.freedesktop.org/gstreamer/gstreamer/refs/tags' | sed -n "s,.*<a href='[^']*/tag/?h=[^0-9]*\\([0-9]\..[02468]\.[0-9][^']*\\)'.*,\\1,p" | sort -V | tail -1)
      ;;
    "icu4c")
      package_version_latest=$(wget -q -O- 'https://github.com/unicode-org/icu/releases/latest' | sed -n 's,.*releases/tag/\([^"&;]*\)".*,\1,p' | sed 's/release\-//g' | tr '\-' '\.' | sort -V | tail -1)
      ;;
    "expat")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/projects/expat/files/expat/' | sed -n 's,.*/projects/.*/\([0-9][^"]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "freetype")
      package_version_latest=$(wget -q -O- 'https://sourceforge.net/projects/freetype/files/freetype2/' | sed -n 's,.*/projects/.*/\([0-9][^"]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    "harfbuzz")
      package_version_latest=$(wget -q -O- 'https://github.com/harfbuzz/harfbuzz/releases' | sed -n 's,.*releases/tag/\([^"&;]*\)".*,\1,p' | sed 's/^v//g' | sort -V | tail -1)
      ;;
    "protobuf")
      package_version_latest=$(wget -q -O- 'https://github.com/protocolbuffers/protobuf/tags' | sed -n 's#.*releases/tag/\([^"]*\).*#\1#p' | sed 's/^v//g' | head -1)
      ;;
    "qt")
      qt_major_version=$(wget -q -O- "https://download.qt.io/official_releases/qt/" | sed -n 's,.*<a href=\"\([0-9]*\.[0-9]*\).*,\1,p' | sort -V | tail -1)
      package_version_latest=$(wget -q -O- "https://download.qt.io/official_releases/qt/${qt_major_version}/" | sed -n 's,.*href="\([0-9]*\.[0-9]*\.[^/]*\)/".*,\1,p' | sort -V | tail -1)
      ;;
    *)
      package_version_latest=
      echo "No update rule for package: ${package}"
      return
      ;;
  esac

  if [ "${package_version_latest}" = "" ]; then
    echo "Could not get latest version for ${package}."
    return
  fi

  package_version_highest=$(echo "${package_version_current} ${package_version_latest}" | tr ' ' '\n' | sort -V | tail -1)

  if [ "${package_version_highest}" = "" ]; then
    echo "Could not get highest version for ${package}."
    return
  fi

  if [ "${package_version_highest}" = "${package_version_current}" ]; then
    echo "${package_name}: ${package_version_current} is the latest"
  else
    branch="${package_name}_$(echo ${package_version_latest} | sed 's/\./_/g')"
    git branch | grep "${branch}" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      echo "${package_name}: updating from ${package_version_current} to ${package_version_latest}..."
      git checkout -b "${branch}" || exit 1
      sed -i "s,^  ${package_name}_version: .*,  ${package_name}_version: '${package_version_latest}',g" .github/workflows/build.yml || exit 1
      git commit -m "Update ${package_name}" .github/workflows/build.yml || exit 1
      git add .github/workflows/build.yml || exit 1
      git push origin "${branch}" || exit 1
      gh pr create --repo "${repo}" --head "${branch}" --base "master" --title "Update ${package_name} to ${package_version_latest}" --body "Update ${package_name} from ${package_version_current} to ${package_version_latest}" || exit 1
      git checkout . >/dev/null 2>&1 || exit 1
      if ! [ "$(git branch | head -1 | cut -d ' ' -f2)" = "master" ]; then
        git checkout master >/dev/null 2>&1 || exit 1
      fi
    fi
  fi

}

cmds="cat cut sort tr grep sed wget curl git gh"
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

if ! [ -d "${repodir}" ]; then
  echo "Missing ${repodir}"
  exit 1
fi

cd "${repodir}" || exit 1

gh auth status >/dev/null || exit 1
if [ $? -ne 0 ]; then
  error "Missing GitHub login."
  exit 1
fi

git fetch >/dev/null 2>&1 || exit 1
git checkout . >/dev/null 2>&1 || exit 1

if ! [ "$(git branch | head -1 | cut -d ' ' -f2)" = "master" ]; then
  git checkout master >/dev/null 2>&1 || exit 1
fi

git pull origin master --rebase >/dev/null || exit 1

packages=$(cat "${ci_file}" | sed -n "s,^  \(.*\)_version: .*$,\1,p" | tr '\n' ' ')

for package in ${packages}; do
  update_package "${package}"
  git checkout . >/dev/null 2>&1 || exit 1
  if ! [ "$(git branch | head -1 | cut -d ' ' -f2)" = "master" ]; then
    git checkout master >/dev/null 2>&1 || exit 1
  fi
  git pull origin master --rebase >/dev/null 2>&1 || exit 1
done
