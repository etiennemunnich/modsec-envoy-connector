# Security scan (ASH)

CI runs [AWS Automated Security Helper](https://github.com/awslabs/automated-security-helper) **v3.7.1** in local mode on pull requests and on `main` ([`.github/workflows/ash.yml`](../.github/workflows/ash.yml)). Config is [`.ash/.ash.yaml`](../.ash/.ash.yaml). The severity threshold is `MEDIUM`.

The job is report-only. `fail_on_findings` is `false`, so findings are uploaded as the `ash-results` artifact and do not fail the build. Set `fail_on_findings: true` in `.ash/.ash.yaml` when findings should fail the job.

Local mode runs the scanners ASH installs itself (Bandit, Checkov, Semgrep, detect-secrets, npm-audit). Grype, Syft, cfn-nag, cdk-nag, and OpenGrep are skipped unless they are already on `PATH`.

To run the same scan locally (Python 3.10+, [uv](https://docs.astral.sh/uv/)):

```bash
alias ash="uvx git+https://github.com/awslabs/automated-security-helper.git@v3.7.1"
ash --mode local
```

`pipx install` or `pip install` of that same git URL also works. Reports are written to `.ash/ash_output/` (gitignored). `ash config validate` checks the config file.
