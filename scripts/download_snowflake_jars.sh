#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JARS_DIR="${ROOT_DIR}/jars"

SPARK_CONNECTOR_VERSION="${SPARK_CONNECTOR_VERSION:-3.1.8}"
SNOWFLAKE_JDBC_VERSION="${SNOWFLAKE_JDBC_VERSION:-3.28.0}"
SCALA_BINARY_VERSION="${SCALA_BINARY_VERSION:-2.12}"
MAVEN_BASE_URL="${MAVEN_BASE_URL:-https://repo1.maven.org/maven2}"

SPARK_CONNECTOR_FILE="spark-snowflake_${SCALA_BINARY_VERSION}-${SPARK_CONNECTOR_VERSION}.jar"
SNOWFLAKE_JDBC_FILE="snowflake-jdbc-${SNOWFLAKE_JDBC_VERSION}.jar"

download_file() {
  local url="$1"
  local output_path="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$output_path"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output_path" "$url"
  else
    echo "Neither curl nor wget is available. Install one of them and rerun this script." >&2
    exit 1
  fi
}

mkdir -p "$JARS_DIR"

find "$JARS_DIR" -maxdepth 1 -type f \( -name 'snowflake-jdbc-*.jar' -o -name "spark-snowflake_${SCALA_BINARY_VERSION}-*.jar" \) ! -name "$SPARK_CONNECTOR_FILE" ! -name "$SNOWFLAKE_JDBC_FILE" -delete

if [[ ! -f "${JARS_DIR}/${SPARK_CONNECTOR_FILE}" ]]; then
  echo "Downloading ${SPARK_CONNECTOR_FILE}"
  download_file \
    "${MAVEN_BASE_URL}/net/snowflake/spark-snowflake_${SCALA_BINARY_VERSION}/${SPARK_CONNECTOR_VERSION}/${SPARK_CONNECTOR_FILE}" \
    "${JARS_DIR}/${SPARK_CONNECTOR_FILE}"
else
  echo "Using cached ${SPARK_CONNECTOR_FILE}"
fi

if [[ ! -f "${JARS_DIR}/${SNOWFLAKE_JDBC_FILE}" ]]; then
  echo "Downloading ${SNOWFLAKE_JDBC_FILE}"
  download_file \
    "${MAVEN_BASE_URL}/net/snowflake/snowflake-jdbc/${SNOWFLAKE_JDBC_VERSION}/${SNOWFLAKE_JDBC_FILE}" \
    "${JARS_DIR}/${SNOWFLAKE_JDBC_FILE}"
else
  echo "Using cached ${SNOWFLAKE_JDBC_FILE}"
fi

echo
echo "JARs ready in ${JARS_DIR}:"
ls -1 "${JARS_DIR}"
