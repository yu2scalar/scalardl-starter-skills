#!/usr/bin/env bash
# plan-009 W3 — direct javac build for SmokeAsset.java + SmokeAssetFunction.java.
#
# Why this exists alongside build.gradle:
#   Gradle requires a JDK with a 'JAVA_COMPILER' capability. Some Linux
#   distros (e.g. Ubuntu 24.04) ship `openjdk-17-jre` separately from
#   `openjdk-17-jdk`. If only the JRE is installed, Gradle's toolchain
#   resolver errors out with "Toolchain installation ... does not provide
#   the required capabilities: [JAVA_COMPILER]". javac (from any JDK) +
#   `--release 17` produces equivalent bytecode without the toolchain
#   indirection.
#
# Inputs:
#   - JAVA_HOME or javac on PATH (any JDK >= 17 works; tested on JDK 21)
#   - Local Gradle cache populated with scalardl-java-client-sdk:3.13.0 and
#     its transitive deps (preflight assumes this; if missing, run any
#     `gradle build` on a project that depends on that SDK first to
#     populate the cache, or run `./gradlew compileJava` here once)
#
# Output (commit-friendly path — replaces any prior committed bytecode):
#   - prebuilt/com/example/contracts/SmokeAsset.class
#   - prebuilt/com/example/functions/SmokeAssetFunction.class
#   - prebuilt/sha256.txt  (records SHA-256 of both .class files)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

OUT_DIR="${SCRIPT_DIR}/prebuilt"
rm -rf "${OUT_DIR}" && mkdir -p "${OUT_DIR}"

# --- locate jars in gradle cache -------------------------------------------
GRADLE_CACHE="${HOME}/.gradle/caches/modules-2/files-2.1"
if [ ! -d "${GRADLE_CACHE}" ]; then
  echo "ERROR: gradle cache not found at ${GRADLE_CACHE}" >&2
  echo "       Run \`gradle compileJava\` here once (or any gradle build that depends on scalardl-java-client-sdk:3.13.0) to populate the cache." >&2
  exit 1
fi

# Find one jar matching a coordinate prefix. Picks the lexicographically
# first hit (Gradle's cache stores one jar per version under a hash dir).
find_jar () {
  local coord="$1"   # e.g. "com.scalar-labs/scalardl-java-client-sdk/3.13.0"
  find "${GRADLE_CACHE}/${coord}" -name "*.jar" 2>/dev/null \
    | grep -v -- '-sources.jar' | grep -v -- '-javadoc.jar' \
    | head -1
}

require_jar () {
  local label="$1" coord="$2"
  local jar
  jar=$(find_jar "${coord}")
  if [ -z "${jar}" ]; then
    echo "ERROR: missing dependency ${label} (${coord}) in gradle cache" >&2
    return 1
  fi
  echo "${jar}"
}

# Build classpath. Versions match plan-008 D13 (target 3.13.0) + jackson
# versions vendored by SDK 3.13.0 transitively.
CP_PARTS=()
CP_PARTS+=("$(require_jar 'scalardl-client-sdk' 'com.scalar-labs/scalardl-java-client-sdk/3.13.0')")
# scalardl-common holds JacksonBasedContract / JacksonBasedFunction / Ledger /
# Database / Asset / ContractContextException — separate jar from the SDK.
CP_PARTS+=("$(require_jar 'scalardl-common'     'com.scalar-labs/scalardl-common/3.13.0')")
CP_PARTS+=("$(require_jar 'scalardb-api'        'com.scalar-labs/scalardb/3.14.0')")
CP_PARTS+=("$(require_jar 'jackson-databind'    'com.fasterxml.jackson.core/jackson-databind/2.19.4')")
# jackson-annotations + jackson-core are transitively required by jackson-databind
CP_PARTS+=("$(find "${GRADLE_CACHE}/com.fasterxml.jackson.core/jackson-annotations" -name '*.jar' 2>/dev/null | grep -v sources | grep -v javadoc | head -1)")
CP_PARTS+=("$(find "${GRADLE_CACHE}/com.fasterxml.jackson.core/jackson-core" -name '*.jar' 2>/dev/null | grep -v sources | grep -v javadoc | head -1)")
# javax.annotation.Nullable lives in jsr305, NOT javax.annotation-api (which
# is JSR-250 only — @PostConstruct etc., no Nullable).
CP_PARTS+=("$(require_jar 'jsr305 (for @Nullable)' 'com.google.code.findbugs/jsr305/3.0.2')")

CLASSPATH_STR=$(IFS=:; echo "${CP_PARTS[*]}")

echo "Classpath:"
for p in "${CP_PARTS[@]}"; do echo "  ${p}"; done

# --- compile ---------------------------------------------------------------
echo
echo "Compiling with javac --release 17"
javac --release 17 \
  -cp "${CLASSPATH_STR}" \
  -d "${OUT_DIR}" \
  contracts/SmokeAsset.java \
  functions/SmokeAssetFunction.java

# --- verify + record SHA-256 ----------------------------------------------
{
  echo "# SHA-256 of compiled sample bytecode (plan-009 W3)"
  echo "# Build host: $(uname -srm)"
  echo "# Built at:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# javac:      $(javac --version 2>&1)"
  echo
  ( cd "${OUT_DIR}" && find . -name '*.class' -exec sha256sum {} + | sort )
} > "${OUT_DIR}/sha256.txt"

echo
echo "Built:"
find "${OUT_DIR}" -name '*.class' | sort
echo
echo "SHA-256 recorded at ${OUT_DIR}/sha256.txt"
