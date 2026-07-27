# SSH Roadmap

## Current state

The first three foundation steps are implemented in the current working tree:

1. Define a versioned, secret-free provider record schema.
2. Separate provider behavior from the validation and publication core on
   Linux, macOS, WSL, and Windows.
3. Move Bitwarden behind the provider contract and separate provider choice,
   identity backend, and private-key policy.

This foundation should be stabilized and released before another provider is
declared supported.

## Proposed roadmap

### 4. Stabilize the provider contract

Turn the current internal boundary into a documented contract that another
adapter can implement safely.

Candidate deliverables:

- A provider authoring guide covering capabilities, lifecycle, errors, and
  secret-handling rules.
- A reusable conformance suite that runs the same behavioral tests against each
  adapter.
- Test fixtures for host records, Git-signing records, malformed output,
  provider failures, missing agent identities, and private-key export.
- An explicit compatibility policy for schema and adapter protocol versions.

Decision gate: confirm that the contract works without Bitwarden-specific
assumptions before adding a second provider.

### 5. Add one agent-first provider

Implement **1Password** as the preferred second-provider pilot. It is the
closest match to the current model because it has a cross-platform CLI, stores
SSH key items, and provides an SSH agent.

Start with `identity_backend=agent` and `private_key_policy=never`. Private-key
export should remain unsupported unless its behavior can meet the same explicit
consent, staging, permissions, and cleanup guarantees as Bitwarden disk mode.

Decision gate:

- Confirm stable CLI fields and machine-readable output on Linux, macOS, and
  Windows.
- Confirm reliable mapping between listed public keys and agent identities.
- Confirm authentication can fail closed without exposing session material.
- Require parity tests on POSIX shell, Windows PowerShell 5.1, and PowerShell 7.

### 6. Evaluate a local/offline provider

Run a focused **KeePassXC** spike before committing to a full adapter. It is the
strongest local-first candidate because it is cross-platform and can integrate
with an SSH agent, but its entry conventions are less standardized than
dedicated SSH-key item types.

The spike should answer:

- Can records be discovered non-interactively without weakening database
  security?
- Can public keys and destination metadata be mapped consistently?
- Can agent matching work on all supported platforms?
- Is a documented SSHwitch entry convention acceptable to users?
- Does the result justify the maintenance and setup complexity?

Decision gate: either promote KeePassXC to a supported provider or publish the
spike findings and stop without carrying experimental code.

### 7. Decide how extensible providers should be

After two real providers exercise the contract, choose one distribution model:

1. **Built-in adapters** — safest and simplest; every provider ships and is
   reviewed with SSHwitch.
2. **Manually installed adapters** — more flexible, but requires a strict
   discovery path, ownership checks, protocol negotiation, and clear trust
   warnings.
3. **External command protocol** — most extensible, but substantially expands
   the trusted-code and supply-chain boundary.

The default recommendation is to keep adapters built in until demand proves
that third-party extensions are worth the security cost.

Decision gate: write a short threat model before loading any adapter code from
outside the installed SSHwitch package.

### 8. Consider credential sources beyond stored SSH keys

Signed SSH certificates are a promising direction, but they are not just
another record provider. Systems such as HashiCorp Vault's SSH secrets engine
issue short-lived credentials and introduce renewal, expiry, principals, and
online availability.

Treat certificate issuers as a separate future contract instead of forcing them
into provider schema version 1.

Possible candidates:

- HashiCorp Vault SSH secrets engine.
- Smallstep SSH certificates.
- Cloud or organization-specific SSH certificate authorities.

Decision gate: validate real demand and design expiry/renewal behavior before
changing the provider schema.

### 9. Operational and product improvements

These ideas are independent and can be prioritized separately:

- `doctor` command for provider, agent, filesystem, and Git-signing diagnostics.
- Preview/diff output showing host aliases and settings that would change,
  without displaying secrets.
- Profiles or tags for selecting subsets such as work, personal, or production.
- Multiple-provider composition with explicit precedence and collision rules.
- Structured, secret-safe status output for automation.
- Backup/rollback inspection for the last known-good generation.
- Provider-neutral naming cleanup and migration from the original Bitwarden
  branding.

Multiple-provider composition should wait until at least two single-provider
adapters are stable; otherwise its merge semantics would be designed without
enough evidence.

## Provider candidate assessment

| Candidate | Fit | Best initial mode | Main concern | Recommendation |
|---|---|---|---|---|
| 1Password | High | Agent, never export | CLI/agent behavior and field mapping must be verified across platforms | Build next |
| KeePassXC | Medium-high | Agent, never export | No single standard entry layout; automation and unlock UX need a spike | Evaluate after 1Password |
| pass/gopass | Medium on Unix, low on Windows | Disk/export | Weak cross-platform parity and no unified SSH-item model | Community demand only |
| HashiCorp Vault | High for organizations, different model | Short-lived certificates | Requires issuance and renewal semantics, not stored-key sync | Separate future architecture |
| Cloud secret managers | Low-medium | Disk/export | Generic secret storage, cloud authentication, and private-key persistence | Do not prioritize |
| Termius and similar clients | Low today | Unknown | Limited stable automation surface and unclear agent interoperability | Reassess if APIs mature |

Provider status should mean more than “an adapter can parse output.” A supported
provider must preserve fail-closed publication, secret-free canonical records,
agent identity verification, deterministic generation, cross-platform parity,
and automated conformance coverage.

## Suggested assessment order

When work resumes:

1. Stabilize and release the provider-neutral Bitwarden implementation.
2. Validate the contract through a 1Password proof of concept.
3. Decide whether 1Password should become a supported adapter.
4. Run the KeePassXC feasibility spike.
5. Reassess extension/distribution strategy using evidence from those adapters.
6. Prioritize diagnostics, profiles, multi-provider composition, or certificate
   issuers based on actual user demand.

For each phase, assess user value, platform parity, security-boundary growth,
maintenance burden, testability, and migration impact before approving
implementation.
