@echo off
REM LibreChat 主应用镜像构建脚本（Windows CMD）
REM 用法:
REM   docker\build.bat                       使用默认 TAG: librechat-dev-api:custom
REM   docker\build.bat v0.8.8-inner          自定义 TAG: librechat-dev-api:v0.8.8-inner
setlocal

set "SCRIPT_DIR=%~dp0"
set "PROJECT_ROOT=%SCRIPT_DIR%.."

set "TAG=%1"
if "%TAG%"=="" set "TAG=custom"

set "IMAGE=librechat-dev-api:%TAG%"
set "NODE_MAX_OLD_SPACE_SIZE=6144"

REM 构建元数据（Settings -^> About 显示用；.git 被 .dockerignore 排除，必须显式传入）
set "BUILD_COMMIT="
for /f %%i in ('git -C "%PROJECT_ROOT%" rev-parse --short HEAD 2^>nul') do set "BUILD_COMMIT=%%i"
set "BUILD_BRANCH="
for /f %%i in ('git -C "%PROJECT_ROOT%" rev-parse --abbrev-ref HEAD 2^>nul') do set "BUILD_BRANCH=%%i"
set "BUILD_DATE="
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString(\"yyyy-MM-ddTHH:mm:ssZ\")"') do set "BUILD_DATE=%%i"

echo ==^> 构建上下文: %PROJECT_ROOT%
echo ==^> 镜像标签:   %IMAGE%
echo ==^> 构建元数据: commit=%BUILD_COMMIT% branch=%BUILD_BRANCH% date=%BUILD_DATE%

docker build -f "%SCRIPT_DIR%Dockerfile" -t "%IMAGE%" ^
  --build-arg "NODE_MAX_OLD_SPACE_SIZE=%NODE_MAX_OLD_SPACE_SIZE%" ^
  --build-arg "BUILD_COMMIT=%BUILD_COMMIT%" ^
  --build-arg "BUILD_BRANCH=%BUILD_BRANCH%" ^
  --build-arg "BUILD_DATE=%BUILD_DATE%" ^
  "%PROJECT_ROOT%"
if errorlevel 1 (
    echo ==^> 构建失败
    exit /b 1
)

echo ==^> 构建完成: %IMAGE%
docker image ls "%IMAGE%"
endlocal
