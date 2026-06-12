# Threat Model

AI Agent Pipeline — version as of security-hardening change (2026-06-12).

---

## System Summary

`run_agent.sh` clones an arbitrary git repo into a Docker volume, starts a worker container running `opencode serve`, and sends an LLM prompt that causes opencode to execute bash commands inside the container against the cloned repo. The LLM output is untrusted. The repo contents are untrusted.

---

## Assets

| Asset | Value | Location |
|-------|-------|----------|
| LLM API key (GROQ_API_KEY) | High — billable credential with external API access | Host env var → tmpfile → Docker secret |
| Cloned repo code | Low — untrusted by design | workspace volume |
| Pipeline result output | Medium — build/test status, logs | `run_results/` on host |
| Host filesystem | High | Outside containers |
| Docker daemon | Critical | Host only |

---

## Trust Boundaries

```
[Host: run_agent.sh]  ←── trusted
        │
        │  docker exec curl  (HTTP API, port 4096 on 127.0.0.1 inside container)
        ▼
[Worker container]  ←── UNTRUSTED (executes LLM-driven arbitrary bash)
        │                   UID 1001, cap_drop ALL, no Docker socket
        │  LLM API calls
        ▼
[LLM network egress → Groq API]  ←── trusted API, untrusted responses
```

The worker container is the trust boundary. Everything inside it — repo code, LLM responses, bash tool executions — is untrusted.

---

## Threat Actors

| Actor | Motivation | Capability |
|-------|-----------|------------|
| Malicious repo | Exfiltrate secrets, escape container, persist | Code executed by LLM agent during build/test |
| Prompt injection in LLM response | Redirect agent, exfiltrate, sabotage | Crafted LLM output sent as tool call |
| Compromised dependency (npm/pip) | Supply chain — run arbitrary code at install | Executed during `npm install` / `pip install` inside worker |

---

## Threats and Mitigations

### T1 — API key exfiltration via container environment

**Threat:** Process inside container reads `OPENAI_API_KEY` from `/proc/1/environ` or `docker inspect`.

**Mitigation:** API key is NOT in container environment. It is read from `/run/secrets/groq_key` by the entrypoint and exported only to the `opencode` process. Other processes forked by the LLM agent (bash, npm, etc.) inherit the env, but the API key is `OPENAI_API_KEY=<value>` — not `GROQ_API_KEY`. The key is only useful for the LLM endpoint (which the attacker already has access to via the llm network from within the container). `docker inspect` shows no keys.

**Residual risk:** `OPENAI_API_KEY` is still in the process environment and readable from `/proc` by any process in the container as UID 1001. An attacker with code execution inside the container can read it. Full mitigation requires in-process secret handling (not bash entrypoint).

**Rating:** Medium risk, materially reduced from pre-hardening (was directly in `docker inspect`).

---

### T2 — Privilege escalation via root execution

**Threat:** LLM-driven code runs as root inside container, enabling writes to system directories, installation of tools, or capability exploitation.

**Mitigation:** Worker runs as `ocuser` (UID 1001). `no-new-privileges:true` blocks setuid/setgid escalation. `cap_drop: ALL` removes all Linux capabilities.

**Residual risk:** Container escape via kernel exploit is not mitigated at the application layer. Use gVisor/Kata Containers for kernel-level isolation if the threat model requires it.

**Rating:** Low risk (defense in depth against common escalation paths).

---

### T3 — Workspace tampering / host filesystem access

**Threat:** LLM-driven code writes outside `/workspace`, escapes volume mount, or accesses host files.

**Mitigation:** Worker has no bind mounts to host paths (only named volumes). Workspace is a Docker-managed named volume. `cap_drop: ALL` removes `CAP_DAC_OVERRIDE` — UID 1001 cannot read files owned by other UIDs.

**Residual risk:** `read_only: true` is not yet enabled (deferred). An attacker can write to any path writable by UID 1001 on the image filesystem. Key risk: replacing binaries on the writable image filesystem if the container is reused.

**Rating:** Medium risk until `read_only: true` is enabled.

---

### T4 — Shell injection via job spec inputs

**Threat:** Attacker supplies malicious `repo_url`, `commit`, or `project_type` values that inject shell commands into `run_agent.sh` via unquoted interpolation.

**Mitigation:** All three fields are validated before any Docker operations:
- `project_type`: allowlist `(nerv|eshoponweb|medplum)`
- `repo_url`: must match `^https://[a-zA-Z0-9._/:-]+$`
- `commit`: must match `^[a-zA-Z0-9._/-]+$`

**Residual risk:** Job spec is provided by a trusted operator (not a public API). Validation is defense in depth, not a primary access control.

**Rating:** Low risk.

---

### T5 — LLM network egress abuse

**Threat:** LLM-driven code uses the llm network to exfiltrate data to arbitrary internet hosts (not just the LLM API).

**Mitigation:** The llm network provides unrestricted egress. No firewall restricts the destination. Data services join the sandbox network only and have no egress.

**Residual risk:** Unrestricted egress via llm network is a known design choice (npm/pip registries need access during build). Add network-level egress filtering (squid proxy, iptables allowlist) if data exfiltration is a concern.

**Rating:** High residual risk by design. Acceptable for a dev-tool use case; not acceptable for production multi-tenant.

---

### T6 — API key tmpfile exposure on host

**Threat:** Host process reads the tmpfile containing the API key before/after cleanup.

**Mitigation:** File is in `/tmp` with a random name (mktemp). Mode is `0644` (world-readable needed for container non-root user; tmpdir has sticky bit). File is deleted in the cleanup trap (runs on EXIT including signals). Race window: between creation and cleanup.

**Residual risk:** Host processes running as the same user can read the file during the run. Mode `0644` is broader than ideal. A dedicated `seccomp` or `namespaces` approach would improve this.

**Rating:** Low risk for single-user dev host. Higher risk on multi-user or shared CI systems.

---

### T7 — Container image supply chain

**Threat:** `opencode` install script or npm plugin (`@anthonyfangqing/opencode-special-edition`) is compromised or replaced.

**Mitigation:** No image digest pinning currently. `curl -fsSL https://opencode.ai/install | bash` fetches and executes from a remote URL at build time.

**Residual risk:** Pin image digests and verify opencode binary checksum. Audit the plugin package.

**Rating:** Medium risk (standard supply chain concern; not specific to this project).

---

## Known Gaps (not yet mitigated)

| Gap | Tracking |
|-----|----------|
| `read_only: true` on worker — blocked by opencode (bun) writing to `/root/.local` | See design.md open questions |
| LLM network egress unrestricted | Known design choice; add squid/iptables if needed |
| `OPENAI_API_KEY` readable from `/proc` within container | Inherent to bash entrypoint pattern |
| No image digest pinning for opencode or base images | Supply chain hardening backlog |
| eshoponweb / medplum stacks not yet migrated to opencode | Pending stack migration |

---

## Out of Scope

- Host OS security (kernel hardening, SELinux, AppArmor)
- Multi-tenancy (this is a single-operator dev tool)
- LLM prompt injection defenses (LLM-layer concern, not infrastructure)
- Denial of service against the pipeline runner
