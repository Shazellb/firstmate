# Test evidence: public app-flow-walkthrough skill (036fec0..8d4482d)

- changed-selection-before-fix.txt: at the base commit with the new skill file staged, `bin/fm-test-run.sh --list --changed --base HEAD` fails closed: "no changed-test mapping for source path: skills/app-flow-walkthrough/SKILL.md" (exit 2).
- changed-selection-after.txt: on the target commit, `bin/fm-test-run.sh --list --changed --base 036fec0` succeeds (exit 0) and selects the pure-contract family plus fm-documentation-audiences.test.sh.
- doc-audience-check-before-fix.txt: at base with the new skill tracked, `bin/fm-doc-audience-check.sh` fails: "unclassified: skills/app-flow-walkthrough/SKILL.md" (exit 1). On the target commit it reports ok surfaces=101.
- skill-frontmatter-manifest.txt: both public skills parse (PyYAML) with name == directory, non-empty description, user-invocable true, and no metadata.internal, so installer discovery will list them.
- fm-test-run.test.log: runner contract tests; the new "public skill source selects pure contract coverage" assertion passes. The last-but-one test aborts because ruby is not installed on this host (unrelated workflow-YAML parse).
- fm-documentation-audiences.test.log: all four inventory tests pass.
