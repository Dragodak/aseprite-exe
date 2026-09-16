@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0"
pushd "%ROOT%" || exit /b 1

set "PATH=%ProgramFiles%\7-Zip;%PATH%"
if not defined ASEPRITE_REPOSITORY set "ASEPRITE_REPOSITORY=https://github.com/aseprite/aseprite.git"
if not defined ASEPRITE_UPSTREAM_REPOSITORY set "ASEPRITE_UPSTREAM_REPOSITORY=https://github.com/aseprite/aseprite.git"
if not defined DRAGLUS_VERSION_SUFFIX set "DRAGLUS_VERSION_SUFFIX=draglus-dev"
if not defined ASEPRITE_VERSION goto :missing_version

set "SOURCE_VERSION=!ASEPRITE_VERSION!"
if not "!SOURCE_VERSION:~0,1!"=="v" set "SOURCE_VERSION=v!SOURCE_VERSION!"

where /q git.exe || goto :missing_git
where /q curl.exe || goto :missing_curl

if exist "%ProgramFiles%\7-Zip\7z.exe" (
  set "SZIP=%ProgramFiles%\7-Zip\7z.exe"
) else (
  where /q 7za.exe || goto :missing_7zip
  set "SZIP=7za.exe"
)

rem *** Visual Studio environment ***

where /Q cl.exe
if errorlevel 1 (
  set "__VSCMD_ARG_NO_LOGO=1"
  if not exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" goto :missing_visual_studio
  for /f "tokens=*" %%i in ('"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath') do set "VS=%%i"
  if not defined VS goto :missing_visual_studio
  call "!VS!\VC\Auxiliary\Build\vcvarsall.bat" amd64
  if errorlevel 1 goto :fail
)

rem *** Ninja ***

where /q ninja.exe
if errorlevel 1 (
  curl.exe -fL --retry 3 -o ninja-win.zip https://github.com/ninja-build/ninja/releases/download/v1.13.1/ninja-win.zip || goto :fail
  "%SZIP%" x -bb0 -y ninja-win.zip >nul 2>nul || goto :fail
  del /q ninja-win.zip >nul 2>nul
)

rem *** Clone or update Aseprite ***

if not exist "aseprite\.git" (
  if exist "aseprite" goto :invalid_checkout
  rem Keep the working tree empty until the explicit tag is fetched below.
  git clone --no-checkout --recursive --tags "%ASEPRITE_REPOSITORY%" aseprite || goto :fail
) else (
  git -C aseprite remote set-url origin "%ASEPRITE_REPOSITORY%" >nul 2>nul
  git -C aseprite fetch --tags || goto :fail
)

echo Building Aseprite source !SOURCE_VERSION! with Draglus branding

git -C aseprite clean --quiet -fdx || goto :fail
git -C aseprite submodule foreach --recursive git clean -xfd || goto :fail
set "SOURCE_REMOTE=origin"
git -C aseprite fetch --quiet --depth=1 --no-tags origin "!SOURCE_VERSION!:refs/remotes/origin/!SOURCE_VERSION!"
if errorlevel 1 (
  if /i "%ASEPRITE_REPOSITORY%"=="%ASEPRITE_UPSTREAM_REPOSITORY%" goto :fail
  echo Ref !SOURCE_VERSION! was not found in the selected repository; trying upstream.
  git -C aseprite remote get-url upstream >nul 2>nul
  if errorlevel 1 git -C aseprite remote add upstream "%ASEPRITE_UPSTREAM_REPOSITORY%"
  git -C aseprite fetch --quiet --depth=1 --no-tags upstream "!SOURCE_VERSION!:refs/remotes/upstream/!SOURCE_VERSION!" || goto :fail
  set "SOURCE_REMOTE=upstream"
)

set "SOURCE_COMMIT="
for /f "delims=" %%c in ('git -C aseprite rev-parse "!SOURCE_REMOTE!/!SOURCE_VERSION!^{commit}" 2^>nul') do set "SOURCE_COMMIT=%%c"
if not defined SOURCE_COMMIT goto :missing_commit
if defined ASEPRITE_COMMIT if /I not "!SOURCE_COMMIT!"=="!ASEPRITE_COMMIT!" goto :commit_mismatch
if not defined ASEPRITE_COMMIT echo Warning: ASEPRITE_COMMIT is not set; the tag is explicit but not commit-verified.
echo Using pinned Aseprite commit !SOURCE_COMMIT!
git -C aseprite reset --quiet --hard "!SOURCE_COMMIT!" || goto :fail
git -C aseprite submodule update --init --recursive || goto :fail

rem Apply supplied version files after resetting the source checkout.
set "VERSION_CMAKE="
if exist "%ROOT%src\ver\CMakeLists.txt" (
  set "VERSION_CMAKE=%ROOT%src\ver\CMakeLists.txt"
) else if exist "%ROOT%CMakeLists.txt" (
  findstr /C:"DRAGLUS_VERSION_SUFFIX" "%ROOT%CMakeLists.txt" >nul
  if not errorlevel 1 set "VERSION_CMAKE=%ROOT%CMakeLists.txt"
)
if not defined VERSION_CMAKE goto :missing_branding
copy /Y "!VERSION_CMAKE!" "aseprite\src\ver\CMakeLists.txt" >nul || goto :fail
findstr /C:"DRAGLUS_VERSION_SUFFIX" "aseprite\src\ver\CMakeLists.txt" >nul || goto :missing_branding

rem Make the updater compare the upstream numeric version while keeping the
rem Draglus suffix visible in the title and About dialog.
if exist "%ROOT%check_update_draglus.patch" (
  findstr /C:"Draglus is a display/build suffix" "aseprite\src\app\check_update.cpp" >nul
  if errorlevel 1 (
    git -C aseprite apply --check "%ROOT%check_update_draglus.patch" >nul 2>nul
    if errorlevel 1 (
      rem Allow a CRLF patch from a Windows checkout to apply to an LF file.
      git -C aseprite apply --check --ignore-space-at-eol "%ROOT%check_update_draglus.patch" >nul 2>nul || goto :update_patch_mismatch
      git -C aseprite apply --ignore-space-at-eol "%ROOT%check_update_draglus.patch" || goto :fail
    ) else git -C aseprite apply "%ROOT%check_update_draglus.patch" || goto :fail
  )
) else echo Warning: check_update_draglus.patch not found; the updater may report the same version as newer.

if exist "%ROOT%src\ver\generated_version.h.in" (
  copy /Y "%ROOT%src\ver\generated_version.h.in" "aseprite\src\ver\generated_version.h.in" >nul || goto :fail
) else if exist "%ROOT%generated_version.h.in" (
  copy /Y "%ROOT%generated_version.h.in" "aseprite\src\ver\generated_version.h.in" >nul || goto :fail
) else echo Using the checkout's upstream generated_version.h.in

if exist "%ROOT%src\ver\info.c" (
  copy /Y "%ROOT%src\ver\info.c" "aseprite\src\ver\info.c" >nul || goto :fail
) else if exist "%ROOT%info.c" (
  copy /Y "%ROOT%info.c" "aseprite\src\ver\info.c" >nul || goto :fail
) else echo Using the checkout's upstream info.c

if exist "%ROOT%src\ver\info.h" (
  copy /Y "%ROOT%src\ver\info.h" "aseprite\src\ver\info.h" >nul || goto :fail
) else if exist "%ROOT%info.h" (
  copy /Y "%ROOT%info.h" "aseprite\src\ver\info.h" >nul || goto :fail
) else echo Using the checkout's upstream info.h

rem Calculate the user-visible version without Git's dirty marker.
set "DISPLAY_VERSION=!SOURCE_VERSION!"
if "!DISPLAY_VERSION:~0,1!"=="v" set "DISPLAY_VERSION=!DISPLAY_VERSION:~1!"
set "DISPLAY_VERSION=!DISPLAY_VERSION:-dirty=!"
set "DISPLAY_VERSION=!DISPLAY_VERSION:-draglus-dev=!"
set "DISPLAY_VERSION=!DISPLAY_VERSION:-draglus=!"
set "DISPLAY_VERSION=!DISPLAY_VERSION:-dev=!"
if not "!DRAGLUS_VERSION_SUFFIX!"=="" set "DISPLAY_VERSION=!DISPLAY_VERSION!-!DRAGLUS_VERSION_SUFFIX!"

rem *** Download Skia ***

set "SKIA_VERSION="
if exist "aseprite\laf\misc\skia-tag.txt" set /p SKIA_VERSION=<"aseprite\laf\misc\skia-tag.txt"
if not defined SKIA_VERSION (
  if /i not "!SOURCE_VERSION:beta=!"=="!SOURCE_VERSION!" (
    set "SKIA_VERSION=m124-08a5439a6b"
  ) else (
    set "SKIA_VERSION=m102-861e4743af"
  )
)

if not exist "skia-!SKIA_VERSION!\out\Release-x64" (
  mkdir "skia-!SKIA_VERSION!" 2>nul
  pushd "skia-!SKIA_VERSION!" || goto :fail
  curl.exe -fL --retry 3 -o Skia-Windows-Release-x64.zip "https://github.com/aseprite/skia/releases/download/!SKIA_VERSION!/Skia-Windows-Release-x64.zip" || (popd & goto :fail)
  "%SZIP%" x -y Skia-Windows-Release-x64.zip >nul 2>nul || (popd & goto :fail)
  popd
)

rem *** Build Aseprite ***

if exist build rmdir /s /q build

set "LINK=opengl32.lib"
cmake.exe ^
  -G Ninja ^
  -S aseprite ^
  -B build ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ^
  -DCMAKE_POLICY_DEFAULT_CMP0074=NEW ^
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW ^
  -DCMAKE_POLICY_DEFAULT_CMP0092=NEW ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
  -DENABLE_CCACHE=OFF ^
  -DOPENSSL_USE_STATIC_LIBS=TRUE ^
  -DUPDATE_VERSION_WITH_GIT=ON ^
  -DDRAGLUS_VERSION_SUFFIX=!DRAGLUS_VERSION_SUFFIX! ^
  -DLAF_BACKEND=skia ^
  -DSKIA_DIR=%CD%\skia-!SKIA_VERSION! ^
  -DSKIA_LIBRARY_DIR=%CD%\skia-!SKIA_VERSION!\out\Release-x64 ^
  -DSKIA_OPENGL_LIBRARY=
if errorlevel 1 goto :fail

ninja.exe -C build
if errorlevel 1 goto :fail

rem *** Create a portable Windows package ***

set "OUTPUT_DIR=aseprite-!DISPLAY_VERSION!-windows-x64"
if exist "!OUTPUT_DIR!" rmdir /s /q "!OUTPUT_DIR!"
mkdir "!OUTPUT_DIR!" || goto :fail
echo # This file is here so Aseprite behaves as a portable program>"!OUTPUT_DIR!\aseprite.ini"
xcopy /E /I /Q /Y "aseprite\docs" "!OUTPUT_DIR!\docs\" >nul || goto :fail
copy /Y "build\bin\aseprite.exe" "!OUTPUT_DIR!\aseprite.exe" >nul || goto :fail
xcopy /E /I /Q /Y "build\bin\data" "!OUTPUT_DIR!\data\" >nul || goto :fail

if defined GITHUB_WORKFLOW (
  if exist github rmdir /s /q github
  mkdir github || goto :fail
  move /Y "!OUTPUT_DIR!" github\ >nul || goto :fail
  if defined GITHUB_OUTPUT echo ASEPRITE_VERSION=!DISPLAY_VERSION!>>"!GITHUB_OUTPUT!"
)

echo Windows package ready: !DISPLAY_VERSION!
popd
exit /b 0

:missing_git
echo ERROR: git.exe not found
goto :fail
:missing_curl
echo ERROR: curl.exe not found
goto :fail
:missing_7zip
echo ERROR: 7-Zip installation or 7za.exe not found
goto :fail
:missing_visual_studio
echo ERROR: Visual Studio with the Native Desktop workload was not found
goto :fail
:invalid_checkout
echo ERROR: aseprite exists but is not a Git checkout
goto :fail
:missing_version
echo ERROR: ASEPRITE_VERSION must be set to an explicit Aseprite release tag (for example v1.3.18.5)
goto :fail
:missing_commit
echo ERROR: the selected Aseprite tag did not resolve to a commit
goto :fail
:commit_mismatch
echo ERROR: Aseprite tag !SOURCE_VERSION! resolves to !SOURCE_COMMIT!, expected !ASEPRITE_COMMIT!
goto :fail
:missing_branding
echo ERROR: missing Draglus version module at src\ver\CMakeLists.txt
goto :fail
:update_patch_mismatch
echo ERROR: the Draglus update-check patch does not match this Aseprite source
goto :fail
:fail
popd
exit /b 1
