#!/bin/bash

# Define the URL
url='https://aws.amazon.com/api/dirs/items/search?item.directoryId=aws-products&sort_by=item.additionalFields.productCategory&sort_order=asc&size=500&item.locale=en_US&tags.id=!aws-products%23type%23feature&tags.id=!aws-products%23type%23variant'

# Use curl to fetch data from the URL and store it in a variable
data=$(curl -s "$url")

# Check if curl was successful
if [ $? -ne 0 ]; then
  echo "Error: Failed to fetch data from the URL."
  exit 1
fi

markdown_file="awsproducts.md"
markdown_content="<!--
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
<!-- footer: Last updated $(date) -->

---
<!-- paginate: true -->
<!-- footer: '' -->
"
echo -e "$markdown_content" > "$markdown_file"

# TOC
markdown_content="
<!-- header: '' -->

## Product Categories
"
echo -e "$markdown_content" >> "$markdown_file"

markdown_content=$(echo $data | \
  jq -r '.items | group_by(.item.additionalFields.productCategory)[] | .[0] | "[\(.item.additionalFields.productCategory)](#\(.item.additionalFields.productNameLowercase | gsub(" ";"-") | gsub("\\(";"") | gsub("\\)";"") ))"' | \
  sed '0~10 s/$/\n\n---\n\nProduct Categories (continued...)\n/g'
  )
markdown_content+="\n\n---\n"

echo -e "$markdown_content" >> "$markdown_file"

# Data
markdown_content=$(echo $data | \
  sed -e 's/\\u003cp\\u003e//g; s/\\u003c\/p\\u003e//g; s/\\r//g; s/\\n//g; s/\?[^"]*//g;  s/\\u0026nbsp\;//g;' | \
  jq -r '.items[] | "<!-- header: \(.item.additionalFields.productCategory) -->", "## \(.item.additionalFields.productName)","\(.item.additionalFields.productSummary)", "\(.item.additionalFields.productUrl)","\n_Launched \(.item.additionalFields.launchDate)_", "\n---" ' | \
  sed '$d')

echo -e "$markdown_content" >> "$markdown_file"

echo "Markdown file '$markdown_file' has been created."
