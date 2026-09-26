## Checklist

- [ ] Fail-closed preserved (`failure_mode_allow: false` on enforcement; no `Continue` after ModSec/FFI Err)
- [ ] Pins reviewed (`versions.lock.md` — Envoy / ModSec / CRS / connector)
- [ ] Tests run: `pin-check` + `rust-quality` (and Mac/dispatch notes if CRS / fail-mode / H2 touched)
- [ ] README / AGENTS updated if behavior or agent rules changed
