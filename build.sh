#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

SOURCE_REPOSITORY="${ASEPRITE_REPOSITORY:-https://github.com/aseprite/aseprite.git}"
UPSTREAM_REPOSITORY="${ASEPRITE_UPSTREAM_REPOSITORY:-https://github.com/aseprite/aseprite.git}"
REQUESTED_VERSION="${ASEPRITE_VERSION:-}"
PINNED_COMMIT="${ASEPRITE_COMMIT:-}"
VERSION_SUFFIX="${DRAGLUS_VERSION_SUFFIX:-draglus-dev}"
BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
SOURCE_DIR="$ROOT_DIR/aseprite"
BUILD_DIR="$ROOT_DIR/build"

fail()
{
  echo "ERROR: $*" >&2
  exit 1
}

[[ -n "$REQUESTED_VERSION" || -n "$PINNED_COMMIT" ]] || \
  fail "set ASEPRITE_VERSION to a tag, or set ASEPRITE_COMMIT to a full SHA for an untagged commit"

SOURCE_VERSION="$REQUESTED_VERSION"
if [[ -n "$SOURCE_VERSION" && "$SOURCE_VERSION" != v* && "$SOURCE_VERSION" =~ ^[0-9] ]]; then
  SOURCE_VERSION="v$SOURCE_VERSION"
fi

case "$(uname -s)" in
  Darwin*)
    TARGET_PLATFORM=macos
    MACOS_ARCHITECTURE="${DRAGLUS_MACOS_ARCH:-${CMAKE_OSX_ARCHITECTURES:-$(uname -m)}}"
    case "$MACOS_ARCHITECTURE" in
      arm64|aarch64)
        MACOS_ARCHITECTURE=arm64
        SKIA_ARCH=arm64
        MACOS_DEPLOYMENT_TARGET="${DRAGLUS_MACOS_DEPLOYMENT_TARGET:-11.0}"
        ;;
      x86_64|x64)
        MACOS_ARCHITECTURE=x86_64
        SKIA_ARCH=x64
        MACOS_DEPLOYMENT_TARGET="${DRAGLUS_MACOS_DEPLOYMENT_TARGET:-10.14}"
        ;;
      *)
        fail "unsupported macOS architecture '$MACOS_ARCHITECTURE'; use arm64 or x86_64"
        ;;
    esac
    ;;
  Linux*)
    TARGET_PLATFORM=linux
    SKIA_ARCH=x64
    ;;
  *)
    fail "this script supports Linux and macOS only"
    ;;
esac

require_command()
{
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required"
}

for command in git cmake ninja curl unzip tar tr grep; do
  require_command "$command"
done

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  [[ ! -e "$SOURCE_DIR" ]] || fail "$SOURCE_DIR exists but is not a Git checkout"
  # Do not populate a working tree from the repository's default branch.
  # The selected tag is fetched and checked out explicitly below.
  git clone --no-checkout --recursive --tags "$SOURCE_REPOSITORY" "$SOURCE_DIR"
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

fetch_version()
{
  local remote="$1"
  local version="$2"
  git -C "$SOURCE_DIR" fetch --quiet --depth=1 --no-tags "$remote" \
    "$version:refs/remotes/$remote/$version"
}

fetch_commit()
{
  local remote="$1"
  local commit="$2"
  git -C "$SOURCE_DIR" fetch --quiet --depth=1 --no-tags "$remote" \
    "$commit:refs/remotes/$remote/$commit"
}

SOURCE_REF="$SOURCE_VERSION"
if [[ -z "$SOURCE_REF" ]]; then
  [[ "$PINNED_COMMIT" =~ ^[[:xdigit:]]{40}$ ]] || \
    fail "ASEPRITE_COMMIT must be a full 40-character commit SHA"
  SOURCE_REF="$PINNED_COMMIT"
fi

echo "Building Aseprite source $SOURCE_REF with Draglus branding"

git -C "$SOURCE_DIR" clean --quiet -fdx
git -C "$SOURCE_DIR" submodule foreach --recursive git clean -xfd

SOURCE_REMOTE=origin
if [[ -n "$SOURCE_VERSION" ]]; then
  FETCH_OK=1
  fetch_version origin "$SOURCE_VERSION" || FETCH_OK=0
else
  FETCH_OK=1
  fetch_commit origin "$PINNED_COMMIT" || FETCH_OK=0
fi
if [[ "$FETCH_OK" -eq 0 ]]; then
  [[ "$SOURCE_REPOSITORY" != "$UPSTREAM_REPOSITORY" ]] || \
    fail "Aseprite ref '$SOURCE_REF' was not found in $SOURCE_REPOSITORY"
  echo "Ref $SOURCE_REF was not found in the selected repository; trying upstream."
  ensure_upstream_remote
  if [[ -n "$SOURCE_VERSION" ]]; then
    fetch_version upstream "$SOURCE_VERSION" || \
      fail "Aseprite ref '$SOURCE_REF' was not found in either repository"
  else
    fetch_commit upstream "$PINNED_COMMIT" || \
      fail "Aseprite ref '$SOURCE_REF' was not found in either repository"
  fi
  SOURCE_REMOTE=upstream
fi

SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse "$SOURCE_REMOTE/$SOURCE_REF^{commit}" 2>/dev/null)" || \
  fail "Aseprite ref '$SOURCE_REF' did not resolve to a commit"
SOURCE_COMMIT="$(printf '%s' "$SOURCE_COMMIT" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$PINNED_COMMIT" ]]; then
  [[ "$PINNED_COMMIT" =~ ^[[:xdigit:]]{40}$ ]] || \
    fail "ASEPRITE_COMMIT must be a full 40-character commit SHA"
  PINNED_COMMIT="$(printf '%s' "$PINNED_COMMIT" | tr '[:upper:]' '[:lower:]')"
  [[ "$SOURCE_COMMIT" == "$PINNED_COMMIT" ]] || \
    fail "Aseprite ref $SOURCE_REF resolves to $SOURCE_COMMIT, expected $PINNED_COMMIT"
else
  echo "Warning: ASEPRITE_COMMIT is not set; the tag is explicit but not commit-verified."
fi

if [[ -z "$SOURCE_VERSION" ]]; then
  SOURCE_VERSION="$(git -C "$SOURCE_DIR" describe --tags --always "$SOURCE_COMMIT" 2>/dev/null || true)"
  if [[ "$SOURCE_VERSION" != v* ]]; then
    ensure_upstream_remote
    git -C "$SOURCE_DIR" fetch --quiet --tags upstream
    SOURCE_VERSION="$(git -C "$SOURCE_DIR" describe --tags --always "$SOURCE_COMMIT" 2>/dev/null || true)"
  fi
  [[ "$SOURCE_VERSION" == v* ]] || \
    fail "could not derive a release version for $SOURCE_COMMIT; set ASEPRITE_VERSION to its base tag"
  echo "Derived base version $SOURCE_VERSION from the pinned commit"
fi

echo "Using pinned Aseprite commit $SOURCE_COMMIT"
git -C "$SOURCE_DIR" reset --quiet --hard "$SOURCE_COMMIT"
git -C "$SOURCE_DIR" submodule update --init --recursive

# Apply supplied version files after resetting the source checkout. The
# generated template and declarations are optional because the cloned source
# already contains compatible upstream copies.
for file in CMakeLists.txt generated_version.h.in info.c info.h; do
  local_file=""
  if [[ "$file" == CMakeLists.txt ]]; then
    # A full Aseprite checkout also has a top-level CMakeLists.txt. The
    # version module must come from src/ver unless a root file is explicitly
    # a Draglus version module.
    if [[ -f "$ROOT_DIR/src/ver/CMakeLists.txt" ]]; then
      local_file="$ROOT_DIR/src/ver/CMakeLists.txt"
    elif [[ -f "$ROOT_DIR/CMakeLists.txt" ]] &&
         grep -q 'DRAGLUS_VERSION_SUFFIX' "$ROOT_DIR/CMakeLists.txt"; then
      local_file="$ROOT_DIR/CMakeLists.txt"
    fi
  elif [[ -f "$ROOT_DIR/src/ver/$file" ]]; then
    local_file="$ROOT_DIR/src/ver/$file"
  elif [[ -f "$ROOT_DIR/$file" ]]; then
    local_file="$ROOT_DIR/$file"
  fi

  if [[ -n "$local_file" ]]; then
    cp -f "$local_file" "$SOURCE_DIR/src/ver/$file"
  elif [[ "$file" == CMakeLists.txt ]]; then
    fail "missing Draglus version module: place it at src/ver/CMakeLists.txt"
  else
    echo "Using the checkout's upstream $file"
  fi
done

grep -q 'DRAGLUS_VERSION_SUFFIX' "$SOURCE_DIR/src/ver/CMakeLists.txt" || \
  fail "src/ver/CMakeLists.txt is not the Draglus version module; use the supplied replacement"

# Make the updater compare the upstream numeric version, while leaving the
# Draglus suffix visible in the title and About dialog.
UPDATE_PATCH="$ROOT_DIR/check_update_draglus.patch"
if [[ -f "$UPDATE_PATCH" ]]; then
  if ! grep -q 'Draglus is a display/build suffix' "$SOURCE_DIR/src/app/check_update.cpp"; then
    if git -C "$SOURCE_DIR" apply --check "$UPDATE_PATCH" >/dev/null 2>&1; then
      git -C "$SOURCE_DIR" apply "$UPDATE_PATCH"
    elif git -C "$SOURCE_DIR" apply --check --ignore-space-at-eol "$UPDATE_PATCH" >/dev/null 2>&1; then
      # A patch committed from Windows may contain CRLF line endings while
      # the Linux/macOS checkout uses LF.
      git -C "$SOURCE_DIR" apply --ignore-space-at-eol "$UPDATE_PATCH"
    else
      fail "the Draglus update-check patch does not match this Aseprite source"
    fi
  fi
else
  echo "Warning: check_update_draglus.patch not found; the updater may report the same version as newer."
fi

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
  if ! SKIA_URL="$(cd "$SOURCE_DIR" && bash laf/misc/skia-url.sh Release "$TARGET_PLATFORM" "$SKIA_ARCH" | tr -d '\r\n')"; then
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
  if [[ "$TARGET_PLATFORM" == macos ]]; then
    SKIA_ARCHIVE="Skia-macOS-Release-$SKIA_ARCH.zip"
  elif [[ "$SKIA_VERSION" == m124-* ]]; then
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
  if [[ "$TARGET_PLATFORM" == linux && "$SKIA_ARCHIVE" == *libc++* ]]; then
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

SKIA_DIR="$ROOT_DIR/.deps/skia-$SKIA_VERSION-$SKIA_ARCH"
SKIA_LIBRARY_DIR="$SKIA_DIR/out/Release-$SKIA_ARCH"
mkdir -p "$SKIA_DIR"
if [[ ! -f "$SKIA_LIBRARY_DIR/libskia.a" ]]; then
  curl --fail --location --retry 3 --retry-delay 2 \
    --output "$SKIA_DIR/$SKIA_ARCHIVE" "$SKIA_URL"
  unzip -q -o "$SKIA_DIR/$SKIA_ARCHIVE" -d "$SKIA_DIR"
fi
[[ -f "$SKIA_LIBRARY_DIR/libskia.a" ]] || \
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
  "-DSKIA_LIBRARY_DIR=$SKIA_LIBRARY_DIR"
  "-DSKIA_LIBRARY=$SKIA_LIBRARY_DIR/libskia.a"
)
if [[ "$TARGET_PLATFORM" == macos ]]; then
  cmake_args+=(
    "-DCMAKE_OSX_ARCHITECTURES=$MACOS_ARCHITECTURE"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET"
  )
fi
if [[ "${#SKIA_CXX_FLAGS[@]}" -gt 0 ]]; then
  cmake_args+=("${SKIA_CXX_FLAGS[@]}")
fi
cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --target aseprite --parallel

if [[ "$TARGET_PLATFORM" == macos ]]; then
  PACKAGE_DIR="$ROOT_DIR/aseprite-$DISPLAY_VERSION-macos-$SKIA_ARCH"
  APP_DIR="$PACKAGE_DIR/Aseprite.app"
  ARCHIVE_PATH="$ROOT_DIR/aseprite-$DISPLAY_VERSION-macos-$SKIA_ARCH.zip"
  rm -rf "$PACKAGE_DIR"
  rm -f "$ARCHIVE_PATH"
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  cp -a "$BUILD_DIR/bin/aseprite" "$APP_DIR/Contents/MacOS/aseprite"
  chmod +x "$APP_DIR/Contents/MacOS/aseprite"
  cp -a "$BUILD_DIR/bin/data" "$APP_DIR/Contents/Resources/"
  [[ ! -d "$SOURCE_DIR/docs" ]] || cp -a "$SOURCE_DIR/docs" "$APP_DIR/Contents/Resources/"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0"><dict>'
    printf '%s\n' '<key>CFBundleExecutable</key><string>aseprite</string>'
    printf '%s\n' '<key>CFBundleIdentifier</key><string>com.draglus.aseprite</string>'
    printf '%s\n' '<key>CFBundleName</key><string>Aseprite</string>'
    printf '%s\n' '<key>CFBundleDisplayName</key><string>Aseprite</string>'
    printf '%s\n' '<key>CFBundlePackageType</key><string>APPL</string>'
    printf '%s\n' '<key>CFBundleShortVersionString</key><string>'"${DISPLAY_VERSION%%-*}"'</string>'
    printf '%s\n' '<key>CFBundleVersion</key><string>'"${DISPLAY_VERSION%%-*}"'</string>'
    printf '%s\n' '<key>LSMinimumSystemVersion</key><string>'"$MACOS_DEPLOYMENT_TARGET"'</string>'
    printf '%s\n' '</dict></plist>'
  } > "$APP_DIR/Contents/Info.plist"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"
else
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
fi

if [[ -n "${GITHUB_WORKFLOW:-}" ]]; then
  rm -rf "$ROOT_DIR/github"
  mkdir -p "$ROOT_DIR/github"
  mv "$ARCHIVE_PATH" "$ROOT_DIR/github/"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "ASEPRITE_VERSION=$DISPLAY_VERSION" >> "$GITHUB_OUTPUT"
  fi
fi

echo "$TARGET_PLATFORM package ready: $DISPLAY_VERSION ($SKIA_ARCH)"
