#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

SOURCE_REPOSITORY="${ASEPRITE_REPOSITORY:-https://github.com/aseprite/aseprite.git}"
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

for command in git cmake ninja curl unzip tar tr; do
  require_command "$command"
done

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  [[ ! -e "$SOURCE_DIR" ]] || fail "$SOURCE_DIR exists but is not a Git checkout"
  git clone --recursive --tags "$SOURCE_REPOSITORY" "$SOURCE_DIR"
else
  git -C "$SOURCE_DIR" remote set-url origin "$SOURCE_REPOSITORY" || true
  git -C "$SOURCE_DIR" fetch --tags
fi

if [[ -z "$REQUESTED_VERSION" ]]; then
  REQUESTED_VERSION="$(git -C "$SOURCE_DIR" tag --sort=-creatordate | head -n 1)"
fi
[[ -n "$REQUESTED_VERSION" ]] || fail "no Aseprite tag was found; set ASEPRITE_VERSION explicitly"

SOURCE_VERSION="$REQUESTED_VERSION"
if [[ "$SOURCE_VERSION" != v* ]] && \
   git -C "$SOURCE_DIR" show-ref --verify --quiet "refs/tags/v$SOURCE_VERSION"; then
  SOURCE_VERSION="v$SOURCE_VERSION"
fi

echo "Building Aseprite source $SOURCE_VERSION with Draglus branding"

git -C "$SOURCE_DIR" clean --quiet -fdx
git -C "$SOURCE_DIR" submodule foreach --recursive git clean -xfd
git -C "$SOURCE_DIR" fetch --quiet --depth=1 --no-tags origin \
  "$SOURCE_VERSION:refs/remotes/origin/$SOURCE_VERSION"
git -C "$SOURCE_DIR" reset --quiet --hard "origin/$SOURCE_VERSION"
git -C "$SOURCE_DIR" submodule update --init --recursive

# Apply the supplied version module after resetting the upstream checkout.
for file in CMakeLists.txt generated_version.h.in info.c info.h; do
  [[ -f "$ROOT_DIR/$file" ]] || fail "missing local version file: $ROOT_DIR/$file"
  cp -f "$ROOT_DIR/$file" "$SOURCE_DIR/src/ver/$file"
done

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
