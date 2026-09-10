# Working in Pithead

Pithead ships a Compose stack and a bootable appliance. The dashboard, CLI, and
image builders share configuration and control contracts.
This is the shared source for `AGENTS.md`, `CLAUDE.md`, and `.cursorrules`.

## Start here

- [Repo map](docs/dev/repo-map.md): directories, subsystem entry points, and where
  to put a change.
- [Contributing](CONTRIBUTING.md): development setup, checks, and review process.
- [Testing strategy](docs/dev/testing-strategy.md): the four test tiers; prove a
  behavior at the lowest tier that can exercise it.
- [Documentation style](docs/dev/STYLE.md): factual prose and verified commands.
- [AI workflow](docs/dev/ai-workflow.md): task routing, appliance scope, logs, and handoffs.

## Change boundaries

- Branch from `develop`; `main` holds released commits. Preserve other worktrees
  and uncommitted changes. Keep moves and behavior changes in separate commits.
- Edit CLI sources in `lib/pithead/`, then run `make`. Root `pithead` is generated
  and ignored. Slice order is significant; do not rename or nest slices casually.
- Keep a feature's implementation and tests in the corresponding feature folders.
  Add shared helpers only when multiple callers need them.
- Aim for files under 400 lines. New files must stay under 800; the existing
  [file budget](docs/dev/file-budget.tsv) only ratchets downward. Split along
  behavior boundaries, preserving transactions, locks, and operation order.
- Update imports, resource paths, test discovery, CI, and the repo map together
  when moving files. A lower test count requires an explanation.
- Keep distributed runtime filenames, module launch commands, and the public
  bootstrap URL stable. Release bundles and appliance images use explicit file lists.
  Developer tools may move with their Make, CI, documentation, and test consumers.
- Keep credentials, local topology, and raw bench evidence out of public files.
  Live integration and appliance tests need a reserved test host; unit checks do
  not authorize changes to a running stack.

## Verify

Run affected checks while editing, then `make test` before review. It includes
lint, dashboard tests (80% total coverage), frontend tests, CLI tests, Compose
checks, integration selftests, and fake-daemon contracts. Run
`make test-patch-coverage` after the dashboard suite (90% changed-line coverage).

`make lint-file-budget` checks file sizes; `make lint-pithead-build` checks the
generated CLI and ordering guards. `make test-inventory` writes the ignored test
inventory. Report skipped, unavailable, or failed checks explicitly.

Use the existing Make targets and locked tool versions. Do not weaken checks to
make a move pass. A release, image promotion, or live deployment is a separate
operation from source refactoring.

## Appliance tasks and large logs

- For an appliance task, start with `os/` and `tests/os/`. There is no
  `appliance/` directory. Name any required CLI slice or wizard module in the task
  before editing it; avoid unrelated dashboard, mining, or release work.
- Use a clean worktree and one writer per owned path. Check active work and reserve
  shared hardware before a build, KVM run, or live test. On SSH hosts read
  `~/README.md` first; keep machine-specific details in private handoffs.
- Save complete build, KVM serial, and test output to an ignored private log file.
  Do not paste or read raw dumps into model context. Run
  `bash scripts/sanitize-test-log.sh LOGFILE` and read its bounded output instead.
  For more context, select a specific line range and pipe it through the same tool.
- The sanitizer removes terminal controls and clips output. It is not a secret
  scanner, a test verdict, or permission to publish the excerpt. Preserve the raw
  file and record the command's actual exit status separately.
- A completed command is not sufficient evidence of a passing appliance. Record
  the exact source and image checksum, phases and assertions run, failures, skips,
  restoration result, and remaining manual checks.
- Hand off the owner, branch, full head SHA, changed paths, commands and results,
  private evidence locations, next action, and operator decisions. An independent
  reviewer checks the current head; a changed head needs renewed review.
