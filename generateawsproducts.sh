#!/usr/bin/env bash
#
# Generates awsproducts.md, a Marp slide deck of every product listed on
# https://aws.amazon.com/products/
#
# Usage: ./generateawsproducts.sh [saved-api-response.json]
#   With no argument the product list is fetched live. Pass a saved API
#   response to test offline.
#
# Data source: the "products-cards-interactive-aws-products-ams" directory is
# what the "Search All AWS Products" section of aws.amazon.com/products renders.
# The older "aws-products" directory stopped being updated in April 2025.

set -euo pipefail

readonly API_URL='https://aws.amazon.com/api/dirs/items/search?item.directoryId=products-cards-interactive-aws-products-ams&item.locale=en_US&size=1000&tags.id=GLOBAL%23local-tags-aws-products-type%23service'
readonly MARKDOWN_FILE='awsproducts.md'
readonly MIN_PRODUCTS=150        # refuse to publish a near-empty deck
readonly CATEGORIES_PER_SLIDE=10

die() { echo "Error: $*" >&2; exit 1; }

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
done

tmp_json=$(mktemp)
tmp_md=$(mktemp "${MARKDOWN_FILE}.XXXXXX")
trap 'rm -f "$tmp_json" "$tmp_md"' EXIT

# --- Fetch ------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
  cp "$1" "$tmp_json"
else
  curl -fsS --retry 3 --retry-delay 5 --max-time 60 -o "$tmp_json" "$API_URL" \
    || die "failed to fetch $API_URL"
fi

total=$(jq -r '.metadata.totalHits // 0' "$tmp_json" 2>/dev/null) \
  || die "response is not valid JSON."
returned=$(jq '.items | length' "$tmp_json")

(( returned >= total )) || die "API returned $returned of $total items; pagination is needed."
(( returned >= MIN_PRODUCTS )) || die "only $returned products returned (expected at least $MIN_PRODUCTS)."

# --- Transform ----------------------------------------------------------------

# Shared jq definitions. Each product is normalised to
# {title, summary, url, year, category}.
read -r -d '' JQ_LIB <<'JQ' || true
# Card badges are free text and inconsistent, so map them onto one set of names.
def badge_categories: {
  "Aerospace Satellite": "Satellite",
  "Artificial Intelligence (AI)": "Artificial Intelligence",
  "Data & Analytics": "Analytics",
  "End-User Computing (EUC)": "End User Computing",
  "Front End Web & Mobile, Serverless": "Front-End Web & Mobile",
  "Games": "Game Tech",
  "Machine Learning": "Artificial Intelligence",
  "Machine Learning vs Deep Learning": "Artificial Intelligence",
  "Management Governance": "Management & Governance",
  "Management Tools": "Management & Governance",
  "Migration": "Migration & Modernization",
  "Networking": "Networking & Content Delivery",
  "Networking-Content-Delivery": "Networking & Content Delivery",
  "Security": "Security, Identity & Compliance",
  "Security & Identity": "Security, Identity & Compliance"
};

# Fallback for cards with no badge: the GLOBAL#aws-tech-category tag.
def tag_categories: {
  "ai-ml": "Artificial Intelligence",
  "analytics": "Analytics",
  "app-integration": "Application Integration",
  "application-integration": "Application Integration",
  "arch-strategy": "Architecture Strategy",
  "blockchain": "Blockchain",
  "business-apps": "Business Applications",
  "compute": "Compute",
  "containers": "Containers",
  "cost-mgmt": "Cloud Financial Management",
  "databases": "Databases",
  "devtools": "Developer Tools",
  "euc": "End User Computing",
  "iot": "Internet of Things",
  "machine-learning": "Artificial Intelligence",
  "media-services": "Media Services",
  "mgmt-govern": "Management & Governance",
  "migration": "Migration & Modernization",
  "mobile": "Front-End Web & Mobile",
  "networking-content-dev": "Networking & Content Delivery",
  "quantum": "Quantum Technologies",
  "satellite": "Satellite",
  "security-identity-compliance": "Security, Identity & Compliance",
  "serverless": "Serverless",
  "storage": "Storage"
};

def trim_ws: sub("^\\s+"; "") | sub("\\s+$"; "");

def tag_values($prefix): [.tags[]?.id | select(startswith($prefix)) | ltrimstr($prefix)];

# Strip HTML tags and decode the entities that appear in summaries.
def clean_text:
  (. // "")
  | gsub("<[^>]*>"; "")
  | gsub("&nbsp;"; " ")
  | gsub("&ndash;"; "–")
  | gsub("&mdash;"; "—")
  | gsub("&(rsquo|lsquo|apos|#39);"; "'")
  | gsub("&(ldquo|rdquo|quot);"; "\"")
  | gsub("&lt;"; "<")
  | gsub("&gt;"; ">")
  | gsub("&amp;"; "&")
  | gsub("\\s+"; " ")
  | trim_ws;

# Escape characters Markdown would otherwise interpret.
def md: gsub("(?<c>[\\\\`*_\\[\\]<>])"; "\\\(.c)");

# Drop tracking parameters (?did=ap_card&trk=ap_card) and make links absolute.
def clean_url:
  (. // "") | trim_ws | sub("[?#].*$"; "")
  | if startswith("/") then "https://aws.amazon.com" + . else . end;

def category:
  ( .item.additionalFields.badge // ""
    | (fromjson? // {}) | (.value // [])
    | map(trim_ws | select(. != "")) | first
  ) as $badge
  | (tag_values("GLOBAL#aws-tech-category#") | first) as $tag
  | if $badge then
      # One card has a podcast episode title as its badge.
      if ($badge | startswith("Generative")) then "Artificial Intelligence"
      else badge_categories[$badge] // $badge end
    elif $tag then tag_categories[$tag] // $tag
    else "Other"
    end;

def products:
  [ .items[]
    | .item.additionalFields as $f
    | { title:    ($f.title | clean_text),
        summary:  ($f.body | clean_text),
        url:      ($f.ctaLink | clean_url),
        year:     (tag_values("GLOBAL#local-tags-year#") | first),
        category: category }
    | select(.title != "")
  ]
  # The directory holds some duplicate cards (e.g. two "AWS DevOps Agent").
  | unique_by(.title | ascii_downcase)
  | sort_by(.category, (.title | ascii_downcase));
JQ

# Builds the table of contents and one slide per product. TOC entries link to
# slide numbers (#N), which Marp sets as the id of each slide.
read -r -d '' JQ_MAIN <<'JQ' || true
products as $products
| ($products | group_by(.category)) as $groups
| ((($groups | length) + $per_slide - 1) / $per_slide | floor) as $toc_slides
| ( reduce $groups[] as $g (
      { slide: (2 + $toc_slides), out: [] };
      .out += [{ name: $g[0].category, count: ($g | length), slide: .slide }]
      | .slide += ($g | length) )
  | .out ) as $categories
| [ range(0; $toc_slides) as $i
    | ( if $i == 0 then "<!-- header: '' -->\n\n## Product Categories\n\n"
        else "## Product Categories (continued)\n\n" end )
      + ( [ $categories[$i * $per_slide : ($i + 1) * $per_slide][]
            | "[\(.name | md)](#\(.slide)) (\(.count))" ]
          | join("\n") )
  ]
  + [ $products[]
      | "<!-- header: \(.category | tojson) -->\n\n## \(.title | md)\n\n\(.summary | md)\n\n\(.url)"
        + (if .year then "\n\n_Launched \(.year)_" else "" end) ]
| join("\n\n---\n\n")
JQ

# --- Write ----------------------------------------------------------------------

cat > "$tmp_md" <<EOF
<!--
marp: true
title: AWS Products
theme: default
class: invert
paginate: true
backgroundImage: 'linear-gradient(to bottom, #232f3e, #1a232e)'
-->

<style>
a { color: #f7a226 }
header,footer { color: #fff }
</style>

<!-- paginate: skip -->
# AWS Products
Generated from https://aws.amazon.com/products

[![w:48](img/github-mark-white.svg)](https://github.com/peterneave/awsproducts)
<!-- footer: Last updated $(date -u '+%d %B %Y %H:%M UTC') -->

---
<!-- paginate: true -->
<!-- footer: '' -->

EOF

jq -r --argjson per_slide "$CATEGORIES_PER_SLIDE" "$JQ_LIB $JQ_MAIN" "$tmp_json" >> "$tmp_md"

chmod 644 "$tmp_md"
mv "$tmp_md" "$MARKDOWN_FILE"

# --- Report ---------------------------------------------------------------------

jq -r "$JQ_LIB"' products | "\(length) products in \(map(.category) | unique | length) categories."' "$tmp_json"

uncategorised=$(jq -r "$JQ_LIB"' products[] | select(.category == "Other") | .title' "$tmp_json")
if [[ -n "$uncategorised" ]]; then
  echo "Warning: no category found for these products (listed under 'Other'):" >&2
  sed 's/^/  - /' <<< "$uncategorised" >&2
fi

echo "Markdown file '$MARKDOWN_FILE' has been created."
