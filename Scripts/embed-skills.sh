#!/bin/bash
# Regenerates Sources/MailMCPKit/SkillCatalog+Generated.swift from Skills/*/SKILL.md.
# Run after editing a skill; a test fails if the generated file is out of date.
set -euo pipefail
cd "$(dirname "$0")/.."
out=Sources/MailMCPKit/SkillCatalog+Generated.swift
{
  echo "// Generated from Skills/*/SKILL.md by Scripts/embed-skills.sh. Do not edit by hand."
  echo
  echo "extension SkillCatalog {"
  echo "    static let embedded: [(folder: String, content: String)] = ["
  for dir in Skills/*/; do
    name=$(basename "$dir")
    echo "        (\"$name\", #\"\"\""
    cat "$dir/SKILL.md"
    echo   # keep the file's final newline inside the literal
    echo "\"\"\"#),"
  done
  echo "    ]"
  echo "}"
} > "$out"
echo "wrote $out"
