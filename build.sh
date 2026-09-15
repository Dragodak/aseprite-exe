#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

SOURCE_REPOSITORY="${ASEPRITE_REPOSITORY:-https://github.com/aseprite/aseprite.git}"
UPSTREAM_REPOSITORY="${ASEPRITE_UPSTREAM_REPOSITORY:-https://github.com/aseprite/aseprite.git}"
REQUESTED_VERSION="${ASEPRITE_VERSION:-}"
VERSION_SUFFIX="${DRAGLUS_VERSION_SUFFIX:-draglus-dev}"
BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
SOURCE_DIR="$ROOT_DIR/aseprite"
BUILD_DIR="$ROOT_DIR/build"

fail()
{
  echo "ERROR: $*" >&2
  exit 1
}

require_command()
{
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required"
}

for command in git cmake ninja curl unzip tar tr grep; do
  require_command "$command"
done

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  [[ ! -e "$SOURCE_DIR" ]] || fail "$SOURCE_DIR exists but is not a Git checkout"
  git clone --recursive --tags "$SOURCE_REPOSITORY" "$SOURCE_DIR"
else
  git -C "$SOURCE_DIR" remote set-url origin "$SOURCE_REPOSITORY" || true
  git -C "$SOURCE_DIR" fetch --tags
fi

ensure_upstream_remote()
{
  if git -C "$SOURCE_DIR" remote get-url upstream >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" remote set-url upstream "$UPSTREAM_REPOSITORY"
  else
    git -C "$SOURCE_DIR" remote add upstream "$UPSTREAM_REPOSITORY"
  fi
}

latest_tag()
{
  git -C "$SOURCE_DIR" for-each-ref \
    --format='%(refname:strip=2)' \
    --sort=-version:refname refs/tags | head -n 1
}

fetch_version()
{
  local remote="$1"
  local version="$2"
  git -C "$SOURCE_DIR" fetch --quiet --depth=1 --no-tags "$remote" \
    "$version:refs/remotes/$remote/$version"
}

if [[ -z "$REQUESTED_VERSION" ]]; then
  REQUESTED_VERSION="$(latest_tag)"
  if [[ -z "$REQUESTED_VERSION" ]]; then
    ensure_upstream_remote
    git -C "$SOURCE_DIR" fetch --quiet --tags upstream
    REQUESTED_VERSION="$(latest_tag)"
  fi
fi
[[ -n "$REQUESTED_VERSION" ]] || fail "no Aseprite tag was found; set ASEPRITE_VERSION explicitly"

SOURCE_VERSION="$REQUESTED_VERSION"
if [[ "$SOURCE_VERSION" != v* && "$SOURCE_VERSION" =~ ^[0-9] ]]; then
  SOURCE_VERSION="v$SOURCE_VERSION"
fi

echo "Building Aseprite source $SOURCE_VERSION with Draglus branding"

git -C "$SOURCE_DIR" clean --quiet -fdx
git -C "$SOURCE_DIR" submodule foreach --recursive git clean -xfd

SOURCE_REMOTE=origin
if ! fetch_version origin "$SOURCE_VERSION"; then
  [[ "$SOURCE_REPOSITORY" != "$UPSTREAM_REPOSITORY" ]] || \
    fail "Aseprite ref '$SOURCE_VERSION' was not found in $SOURCE_REPOSITORY"
  echo "Ref $SOURCE_VERSION was not found in the selected repository; trying upstream."
  ensure_upstream_remote
  fetch_version upstream "$SOURCE_VERSION" || \
    fail "Aseprite ref '$SOURCE_VERSION' was not found in either repository"
  SOURCE_REMOTE=upstream
fi

git -C "$SOURCE_DIR" reset --quiet --hard "$SOURCE_REMOTE/$SOURCE_VERSION"
git -C "$SOURCE_DIR" submodule update --init --recursive

# Apply supplied version files after resetting the source checkout. The
# generated template and declarations are optional because the cloned source
# already contains compatible upstream copies.
for file in CMakeLists.txt generated_version.h.in info.c info.h; do
  local_file=""
  if [[ -f "$ROOT_DIR/$file" ]]; then
    local_file="$ROOT_DIR/$file"
  elif [[ -f "$ROOT_DIR/src/ver/$file" ]]; then
    local_file="$ROOT_DIR/src/ver/$file"
  fi

  if [[ -n "$local_file" ]]; then
    cp -f "$local_file" "$SOURCE_DIR/src/ver/$file"
  elif [[ "$file" == CMakeLists.txt ]]; then
    fail "missing branding file: place CMakeLists.txt beside build.sh"
  else
    echo "Using the checkout's upstream $file"
  fi
done

grep -q 'DRAGLUS_VERSION_SUFFIX' "$SOURCE_DIR/src/ver/CMakeLists.txt" || \
  fail "the local CMakeLists.txt is not the Draglus version module; use the supplied replacement"

DISPLAY_VERSION="${SOURCE_VERSION#v}"
DISPLAY_VERSION="${DISPLAY_VERSION%-dirty}"
DISPLAY_VERSION="${DISPLAY_VERSION%-draglus-dev}"
DISPLAY_VERSION="${DISPLAY_VERSION%-draglus}"
DISPLAY_VERSION="${DISPLAY_VERSION%-dev}"
[[ -z "$VERSION_SUFFIX" ]] || DISPLAY_VERSION="$DISPLAY_VERSION-$VERSION_SUFFIX"

# Newer Aseprite revisions provide the exact Skia URL in the laf submodule.
# Older stable releases use the m102 libc++ package, so keep a compatible
# fallback for the v1.3.18.x source line.
SKIA_URL="${DRAGLUS_SKIA_URL:-}"
SKIA_VERSION="${DRAGLUS_SKIA_VERSION:-}"
if [[ -z "$SKIA_VERSION" && -f "$SOURCE_DIR/laf/misc/skia-tag.txt" ]]; then
  SKIA_VERSION="$(tr -d '\r\n' < "$SOURCE_DIR/laf/misc/skia-tag.txt")"
fi
if [[ -z "$SKIA_URL" && -f "$SOURCE_DIR/laf/misc/skia-url.sh" ]]; then
  if ! SKIA_URL="$(cd "$SOURCE_DIR" && source laf/misc/skia-url.sh | xargs)"; then
    SKIA_URL=""
  fi
fi

SKIA_CXX_FLAGS=()
if [[ -z "$SKIA_URL" ]]; then
  if [[ -z "$SKIA_VERSION" ]]; then
    if [[ "$SOURCE_VERSION" == *beta* || "$SOURCE_VERSION" == main || "$SOURCE_VERSION" == beta ]]; then
      SKIA_VERSION="m124-08a5439a6b"
    else
      SKIA_VERSION="m102-861e4743af"
    fi
  fi
  if [[ "$SKIA_VERSION" == m124-* ]]; then
    SKIA_ARCHIVE="Skia-Linux-Release-x64.zip"
  else
    SKIA_ARCHIVE="Skia-Linux-Release-x64-libc++.zip"
    SKIA_CXX_FLAGS+=(
      "-DCMAKE_CXX_FLAGS:STRING=-stdlib=libc++"
      "-DCMAKE_EXE_LINKER_FLAGS:STRING=-stdlib=libc++"
    )
  fi
  SKIA_URL="https://github.com/aseprite/skia/releases/download/$SKIA_VERSION/$SKIA_ARCHIVE"
else
  SKIA_ARCHIVE="${SKIA_URL##*/}"
  SKIA_ARCHIVE="${SKIA_ARCHIVE%%\?*}"
  if [[ "$SKIA_ARCHIVE" == *libc++* ]]; then
    SKIA_CXX_FLAGS+=(
      "-DCMAKE_CXX_FLAGS:STRING=-stdlib=libc++"
      "-DCMAKE_EXE_LINKER_FLAGS:STRING=-stdlib=libc++"
    )
  fi
  [[ -n "$SKIA_ARCHIVE" ]] || fail "could not determine the Skia archive name"
fi

if [[ -z "$SKIA_VERSION" ]]; then
  SKIA_VERSION="${SKIA_URL#*download/}"
  SKIA_VERSION="${SKIA_VERSION%%/*}"
  [[ -n "$SKIA_VERSION" && "$SKIA_VERSION" != "$SKIA_URL" ]] || SKIA_VERSION=custom
fi

SKIA_DIR="$ROOT_DIR/.deps/skia-$SKIA_VERSION"
mkdir -p "$SKIA_DIR"
if [[ ! -f "$SKIA_DIR/out/Release-x64/libskia.a" ]]; then
  curl --fail --location --retry 3 --retry-delay 2 \
    --output "$SKIA_DIR/$SKIA_ARCHIVE" "$SKIA_URL"
  unzip -q -o "$SKIA_DIR/$SKIA_ARCHIVE" -d "$SKIA_DIR"
fi
[[ -f "$SKIA_DIR/out/Release-x64/libskia.a" ]] || \
  fail "Skia was downloaded but libskia.a is missing"

export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"

cmake_args=(
  -S "$SOURCE_DIR"
  -B "$BUILD_DIR"
  -G Ninja
  "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
  -DUPDATE_VERSION_WITH_GIT=ON
  "-DDRAGLUS_VERSION_SUFFIX=$VERSION_SUFFIX"
  -DLAF_BACKEND=skia
  "-DSKIA_DIR=$SKIA_DIR"
  "-DSKIA_LIBRARY_DIR=$SKIA_DIR/out/Release-x64"
)
cmake_args+=("${SKIA_CXX_FLAGS[@]}")
cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --target aseprite --parallel

PACKAGE_DIR="$ROOT_DIR/aseprite-$DISPLAY_VERSION-linux-x64"
ARCHIVE_PATH="$ROOT_DIR/aseprite-$DISPLAY_VERSION-linux-x64.tar.gz"
rm -rf "$PACKAGE_DIR"
rm -f "$ARCHIVE_PATH"
mkdir -p "$PACKAGE_DIR"
printf '%s\n' '# This file is here so Aseprite behaves as a portable program' > "$PACKAGE_DIR/aseprite.ini"
cp -a "$BUILD_DIR/bin/aseprite" "$PACKAGE_DIR/"
cp -a "$BUILD_DIR/bin/data" "$PACKAGE_DIR/"
[[ ! -d "$SOURCE_DIR/docs" ]] || cp -a "$SOURCE_DIR/docs" "$PACKAGE_DIR/"
tar -czf "$ARCHIVE_PATH" -C "$ROOT_DIR" "$(basename "$PACKAGE_DIR")"

if [[ -n "${GITHUB_WORKFLOW:-}" ]]; then
  rm -rf "$ROOT_DIR/github"
  mkdir -p "$ROOT_DIR/github"
  mv "$ARCHIVE_PATH" "$ROOT_DIR/github/"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "ASEPRITE_VERSION=$DISPLAY_VERSION" >> "$GITHUB_OUTPUT"
  fi
fi

echo "Linux package ready: $DISPLAY_VERSION"
