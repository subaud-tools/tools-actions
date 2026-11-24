// Fails on any tracked SKILL.md that pi would skip or warn about, reading it
// exactly as pi does: pi's front-matter split (dist/utils/frontmatter.js), the
// npm `yaml` package's parse(), and pi's rules for a declared skill
// (loadSkillFromFile, validateName and validateDescription in
// dist/core/skills.js). Messages are pi's own.
//
// Run from the repo root (cwd). Files: `git ls-files -z '*SKILL.md'`, those
// named exactly SKILL.md. Exit 0: every file loads cleanly. Exit 1: one or
// more fail, each reported as a GitHub error annotation and a plain line.
// Exit 2: the check itself could not run.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { basename, dirname } from "node:path";
import { parse } from "yaml";

const MAX_NAME_LENGTH = 64;
const MAX_DESCRIPTION_LENGTH = 1024;

// pi: normalizeNewlines(stripBom(content)), then from the opening --- to the
// first "\n---" after it. Front matter text starts on file line 2.
function extractFrontmatter(content) {
  const normalized = content.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  if (!normalized.startsWith("---")) return { problem: "no front matter: the file must start with a --- line" };
  const endIndex = normalized.indexOf("\n---", 3);
  if (endIndex === -1) return { problem: "front matter has no closing --- line" };
  return { yamlString: normalized.slice(4, endIndex) };
}

// The file line of a top-level key in the front matter, else 1.
function keyLine(yamlString, key) {
  const lines = yamlString.split("\n");
  const re = new RegExp(`^${key}\\s*:`);
  const i = lines.findIndex((l) => re.test(l));
  return i === -1 ? 1 : i + 2;
}

function validateName(name) {
  const errors = [];
  if (name.length > MAX_NAME_LENGTH) errors.push(`name exceeds ${MAX_NAME_LENGTH} characters (${name.length})`);
  if (!/^[a-z0-9-]+$/.test(name)) errors.push("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)");
  if (name.startsWith("-") || name.endsWith("-")) errors.push("name must not start or end with a hyphen");
  if (name.includes("--")) errors.push("name must not contain consecutive hyphens");
  return errors;
}

function validateDescription(description) {
  if (typeof description !== "string" || description.trim() === "") return ["description is required"];
  if (description.length > MAX_DESCRIPTION_LENGTH) {
    return [`description exceeds ${MAX_DESCRIPTION_LENGTH} characters (${description.length})`];
  }
  return [];
}

// Every problem pi would report for one SKILL.md, as { line, message }.
function checkFile(path) {
  let content;
  try {
    content = readFileSync(path, "utf-8");
  } catch (error) {
    return [{ line: 1, message: error instanceof Error ? error.message : "failed to read skill file" }];
  }
  const problems = [];
  const { problem, yamlString } = extractFrontmatter(content);
  let frontmatter = {};
  if (problem) {
    // pi reads no front matter here, then validates an empty one.
    problems.push({ line: 1, message: problem });
  } else if (yamlString) {
    try {
      frontmatter = parse(yamlString) ?? {};
    } catch (error) {
      // pi skips the skill with the parse error as its warning.
      const at = error?.linePos?.[0]?.line;
      return [{ line: at ? at + 1 : 2, message: error instanceof Error ? error.message : "failed to parse skill file" }];
    }
  }
  const fm = yamlString ?? "";
  for (const message of validateDescription(frontmatter.description)) {
    problems.push({ line: message.startsWith("description exceeds") ? keyLine(fm, "description") : 1, message });
  }
  const frontmatterName = typeof frontmatter.name === "string" ? frontmatter.name : undefined;
  const name = frontmatterName || basename(dirname(path));
  for (const message of validateName(name)) {
    problems.push({ line: frontmatterName ? keyLine(fm, "name") : 1, message });
  }
  return problems;
}

// GitHub workflow-command escaping, so a multi-line message stays one annotation.
const escapeData = (s) => s.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
const escapeProp = (s) => escapeData(s).replace(/:/g, "%3A").replace(/,/g, "%2C");

let listed;
try {
  listed = execFileSync("git", ["ls-files", "-z", "--", "*SKILL.md"], { encoding: "utf-8" });
} catch (error) {
  console.error(`::error::skill-check: git ls-files failed (run from inside a git repository): ${error.message}`);
  process.exit(2);
}
const files = listed.split("\0").filter((p) => p && basename(p) === "SKILL.md");

let failed = 0;
for (const path of files) {
  const problems = checkFile(path);
  if (problems.length === 0) continue;
  failed++;
  for (const { line, message } of problems) {
    console.log(`::error file=${escapeProp(path)},line=${line}::${escapeData(message)}`);
    console.log(`${path}:${line}: ${message}`);
  }
}
if (failed > 0) {
  console.log(`skill-check: ${failed} of ${files.length} SKILL.md files fail: pi would skip them or warn`);
  process.exit(1);
}
console.log(`skill-check: ${files.length} SKILL.md files checked, all load in pi`);
