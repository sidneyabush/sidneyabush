#!/usr/bin/env bash
set -euo pipefail

OWNER="${1:-sidneyabush}"
PROJECT_QUERY="${2:-sidneys-tasks}"
LIMIT="${3:-500}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_PATH="${ROOT_DIR}/README.md"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

AUTH_STATUS="$(gh auth status -h github.com 2>&1 || true)"
if ! printf '%s\n' "${AUTH_STATUS}" | grep -Eq "(project|read:project)"; then
  cat >&2 <<'EOF'
Missing GitHub Projects scope.
Run this once, then rerun this script:
  gh auth refresh -h github.com -s read:project
EOF
  exit 1
fi

PROJECTS_JSON="${TMP_DIR}/projects.json"
gh project list --owner "${OWNER}" --limit 100 --format json > "${PROJECTS_JSON}"

PROJECT_NUMBER=""
if [[ "${PROJECT_QUERY}" =~ ^[0-9]+$ ]]; then
  PROJECT_NUMBER="${PROJECT_QUERY}"
else
  PROJECT_NUMBER="$(jq -r --arg q "${PROJECT_QUERY}" '
    map(select((.title // "") | ascii_downcase == ($q | ascii_downcase))) | .[0].number // empty
  ' "${PROJECTS_JSON}")"

  if [[ -z "${PROJECT_NUMBER}" ]]; then
    PROJECT_NUMBER="$(jq -r --arg q "${PROJECT_QUERY}" '
      map(select((.title // "") | ascii_downcase | contains($q | ascii_downcase))) | .[0].number // empty
    ' "${PROJECTS_JSON}")"
  fi
fi

if [[ -z "${PROJECT_NUMBER}" ]]; then
  echo "Project not found: ${PROJECT_QUERY}" >&2
  echo "Available projects:" >&2
  jq -r '.[] | "- \(.title) (#\(.number))"' "${PROJECTS_JSON}" >&2
  exit 1
fi

PROJECT_TITLE="$(jq -r --argjson n "${PROJECT_NUMBER}" '
  map(select(.number == $n)) | .[0].title // "Project \($n)"
' "${PROJECTS_JSON}")"
PROJECT_URL="$(jq -r --argjson n "${PROJECT_NUMBER}" '
  map(select(.number == $n)) | .[0].url // ""
' "${PROJECTS_JSON}")"

ITEMS_JSON="${TMP_DIR}/items.json"
gh project item-list "${PROJECT_NUMBER}" --owner "${OWNER}" --limit "${LIMIT}" --format json > "${ITEMS_JSON}"

GENERATED_CONTENT="${TMP_DIR}/generated_links.md"
jq -r '
  def strip_punct:
    gsub("[,.;)]+$"; "");

  def all_urls:
    [.. | strings | select(test("https?://")) | strip_punct] | unique;

  def item_title:
    (.content.title // .title // .content.url // ("Item " + (.id // "unknown")));

  [
    .[] | {
      title: item_title,
      urls: ((all_urls + [(.content.url // empty)]) | map(select(length > 0)) | unique)
    } | select((.urls | length) > 0)
  ] as $items
  |
  ($items | map(.urls[]) | unique) as $all_unique
  |
  if ($items | length) == 0 then
    "No links found in project items."
  else
    "Unique links found: \($all_unique | length)\n"
    + ($all_unique | to_entries | map("- [Link \(.key + 1)](\(.value))") | join("\n"))
    + "\n\n"
    + ($items | to_entries | map(
        "### \(.value.title | gsub("\n"; " "))\n"
        + (.value.urls | to_entries | map("- [Link \(.key + 1)](\(.value))") | join("\n"))
      ) | join("\n\n"))
  end
' "${ITEMS_JSON}" > "${GENERATED_CONTENT}"

REPLACEMENT_BLOCK="${TMP_DIR}/replacement_block.md"
{
  echo "<!-- PROJECT_LINKS_START -->"
  echo "_Last refreshed: $(date -u '+%Y-%m-%d %H:%M UTC')_"
  echo
  if [[ -n "${PROJECT_URL}" ]]; then
    echo "Project: [${PROJECT_TITLE}](${PROJECT_URL})"
  else
    echo "Project: ${PROJECT_TITLE}"
  fi
  echo
  cat "${GENERATED_CONTENT}"
  echo "<!-- PROJECT_LINKS_END -->"
} > "${REPLACEMENT_BLOCK}"

if ! grep -q '^<!-- PROJECT_LINKS_START -->$' "${README_PATH}" || ! grep -q '^<!-- PROJECT_LINKS_END -->$' "${README_PATH}"; then
  echo "README markers not found. Expected PROJECT_LINKS_START/END markers." >&2
  exit 1
fi

README_NEW="${TMP_DIR}/README.new"
awk -v replacement_file="${REPLACEMENT_BLOCK}" '
  BEGIN {
    while ((getline line < replacement_file) > 0) {
      repl = repl line ORS
    }
  }
  $0 == "<!-- PROJECT_LINKS_START -->" {
    print repl
    in_block = 1
    next
  }
  $0 == "<!-- PROJECT_LINKS_END -->" {
    in_block = 0
    next
  }
  !in_block { print }
' "${README_PATH}" > "${README_NEW}"

mv "${README_NEW}" "${README_PATH}"
echo "Updated ${README_PATH} with project links from ${PROJECT_TITLE} (#${PROJECT_NUMBER})."
