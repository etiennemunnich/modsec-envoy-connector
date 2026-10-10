# Security scan (ASH)

CI runs AWS Automated Security Helper **v3.7.1** in local mode on pull requests and on `main`. The job is **report-only** (`fail_on_findings: false`). Findings are uploaded as the `ash-results` artifact and do not fail the build.

Scanners, config, and the local run: [docs/ash.md](../ash.md).

```bash
alias ash="uvx git+https://github.com/awslabs/automated-security-helper.git@v3.7.1"
ash --mode local
```
