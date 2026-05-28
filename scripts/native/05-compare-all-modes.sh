#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/monitoring/common-monitoring.sh"

ITERATIONS="${ITERATIONS:-3}"
FINAL_CSV="${LOG_DIR}/benchmark-results.csv"
FINAL_JSON="${LOG_DIR}/benchmark-results.json"
FINAL_MD="${LOG_DIR}/benchmark-results.md"
FINAL_SUMMARY="${LOG_DIR}/benchmark-summary.txt"

ITERATIONS="${ITERATIONS}" "${ROOT_DIR}/scripts/monitoring/07-benchmark-monitored-all.sh"
cp "${MONITORING_CSV}" "${FINAL_CSV}"

awk -F, '
NR == 1 { next }
{
  mode=$1
  count[mode]++
  startup[mode]+=$3
  first[mode]+=$5
  warm[mode]+=$6
  rss[mode]+=$8
  throughput[mode]+=$16
  p95[mode]+=$17
  image[mode]=$18
}
END {
  print "{"
  print "  \"results\": ["
  i=0
  for (mode in count) {
    i++
    printf "    {\"mode\":\"%s\",\"avgStartupMs\":%.3f,\"avgFirstRequestMs\":%.3f,\"avgWarmRequestMs\":%.3f,\"avgRssWarmupKb\":%.3f,\"avgThroughputRps\":%.3f,\"avgHttpP95Ms\":%.3f,\"imageSizeBytes\":%s}%s\n",
      mode, startup[mode]/count[mode], first[mode]/count[mode], warm[mode]/count[mode],
      rss[mode]/count[mode], throughput[mode]/count[mode], p95[mode]/count[mode],
      image[mode] == "" ? "null" : image[mode], i < length(count) ? "," : ""
  }
  print "  ]"
  print "}"
}' "${FINAL_CSV}" > "${FINAL_JSON}"

{
  echo "# Benchmark Results"
  echo
  echo "| Mode | Avg startup ms | Avg first request ms | Avg warm request ms | Avg RSS warmup KB | Avg throughput rps | Avg HTTP p95 ms | Image size bytes |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|"
  awk -F, '
  NR == 1 { next }
  {
    mode=$1; count[mode]++; startup[mode]+=$3; first[mode]+=$5; warm[mode]+=$6; rss[mode]+=$8; throughput[mode]+=$16; p95[mode]+=$17; image[mode]=$18
  }
  END {
    for (mode in count) {
      printf "| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %s |\n", mode, startup[mode]/count[mode], first[mode]/count[mode], warm[mode]/count[mode], rss[mode]/count[mode], throughput[mode]/count[mode], p95[mode]/count[mode], image[mode]
    }
  }' "${FINAL_CSV}"
} > "${FINAL_MD}"

{
  echo "Benchmark summary"
  echo "CSV: ${FINAL_CSV}"
  echo "JSON: ${FINAL_JSON}"
  echo "Markdown: ${FINAL_MD}"
  echo
  echo "Startup ranking:"
  awk -F, 'NR>1 {sum[$1]+=$3; count[$1]++} END {for (m in count) printf "%.3f %s\n", sum[m]/count[m], m}' "${FINAL_CSV}" | sort -n
  echo
  echo "Memory ranking by warm RSS KB:"
  awk -F, 'NR>1 {sum[$1]+=$8; count[$1]++} END {for (m in count) printf "%.3f %s\n", sum[m]/count[m], m}' "${FINAL_CSV}" | sort -n
  echo
  echo "Latency ranking by first request ms:"
  awk -F, 'NR>1 {sum[$1]+=$5; count[$1]++} END {for (m in count) printf "%.3f %s\n", sum[m]/count[m], m}' "${FINAL_CSV}" | sort -n
  echo
  echo "Image size ranking bytes:"
  awk -F, 'NR>1 && $18 != "" {image[$1]=$18} END {for (m in image) printf "%s %s\n", image[m], m}' "${FINAL_CSV}" | sort -n
  echo
  echo "Overall efficiency score lower is better:"
  awk -F, 'NR>1 {s[$1]+=$3; f[$1]+=$5; r[$1]+=$8; p[$1]+=$17; c[$1]++} END {for (m in c) printf "%.3f %s\n", (s[m]/c[m]) + (f[m]/c[m]*5) + (p[m]/c[m]*2) + (r[m]/c[m]/1000), m}' "${FINAL_CSV}" | sort -n
} > "${FINAL_SUMMARY}"

cat "${FINAL_SUMMARY}"
