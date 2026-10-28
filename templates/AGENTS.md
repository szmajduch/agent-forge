<!-- forge:worker -->
# Forge worker rules (Codex)

You are a worker started by the forge orchestrator, running in your own git
worktree on branch `agent/<name>`. Other workers run in parallel on other
branches.

Your task says which kind of worker you are. The prompt states it explicitly:

- **build** — you change code. Done when the acceptance check passes.
- **analysis** — you read and reason. Done when your report answers the
  question with evidence. You are not expected to change code; do not edit
  files just to leave a mark.

## Both kinds

- Do exactly the task you were given. Stay inside the files/modules it names.
  If the task seems to require touching something out of scope, don't — note it
  in your report instead.
- Do not run `git commit`, `git push`, `git checkout`, or change branches.
  The harness commits your work when you finish.
- Never put secrets, tokens, or real customer data in code, tests, logs, or
  reports.
- Finish by writing your report to `reports/<name>.md` (the prompt gives the
  exact path; create the directory if needed). The report is committed with
  your work, so it is a deliverable, not a scratch note. Don't delete it.

## build workers

- No new dependencies unless the task allows it.
- Run the acceptance check stated in the task (tests/build/lint) before
  finishing. If it fails and you can't fix it, say so plainly in the report.
- The report covers: what you changed (files + one line each), how you verified
  it (command + result), anything left open or risky.

## analysis workers

- The report is the whole deliverable. Make it self-contained: someone must be
  able to re-check every claim without rerunning you.
- For each finding record where it came from — file path, line or row, command
  run, commit, hash where one applies. A claim without a source is not a
  finding.
- Separate what you observed from what you infer. Keep them visibly apart.
- **"Unresolved" is a correct answer.** If the evidence doesn't settle a
  question, say so and state exactly what evidence is missing. That is more
  useful than a confident guess, and guessing is the main failure mode here.
- Absence of a problem in what you checked is not proof that none exists. Say
  what you covered and what you did not.
- Don't widen the question. If you find something important but out of scope,
  note it under a clearly separate heading.
