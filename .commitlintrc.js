// Conventional Commits, Angular type set -- deliberately the same set used in
// the other VTS repositories. The point of the convention is that it transfers,
// so a type that is rare here still costs nothing to keep.
//
// Unlike a documentation repository, this one ships versioned releases, so the
// type is not just description -- it is the release impact, and git-cliff reads
// it to decide what appears in the changelog and under which heading:
//
//   feat      new capability or command            -> Added
//   fix       a correction to behaviour            -> Fixed
//   perf      same behaviour, less cost            -> Changed
//   refactor  restructuring that changes no facts  -> Changed
//   revert    undoes a previous change             -> Removed
//   docs      prose only                           -> omitted from the changelog
//   test      tests only                           -> omitted
//   ci        workflows, justfile, analyzer config -> omitted
//   build     packaging and tooling manifests      -> omitted
//   chore     housekeeping, dependency bumps       -> omitted
//
// A `!` suffix or a BREAKING CHANGE footer marks a major, and is protected in
// cliff.toml so it survives even where its type would otherwise be skipped.
//
// No `scope-enum`. The natural scopes here are script names, which change as
// scripts are added, so enumerating them would turn a new script into a two-file
// change for no benefit.

export default {
  extends: ["@commitlint/config-conventional"],

  rules: {
    "type-enum": [
      2,
      "always",
      ["feat", "fix", "refactor", "perf", "revert", "ci", "build", "docs", "test", "chore"],
    ],
    "type-case": [2, "always", "lower-case"],
    "type-empty": [2, "never"],

    "scope-case": [2, "always", "lower-case"],

    "subject-empty": [2, "never"],
    "subject-case": [2, "never", ["sentence-case", "start-case", "pascal-case", "upper-case"]],
    "subject-full-stop": [2, "never", "."],

    "header-max-length": [2, "always", 120],

    "body-leading-blank": [2, "always"],
    // Disabled because the changelog parser greedy-detects any line-start
    // `Word:` in a body as a trailer boundary and false-fires on ordinary prose.
    // That disabling is costless rather than a hole: squash merges land the PR
    // title with an empty body, so no commit body ever reaches main for these
    // rules to have caught anything in.
    "body-max-line-length": [0],
    "footer-leading-blank": [0],
    "footer-max-line-length": [0],
  },
};
