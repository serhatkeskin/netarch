# netarch

> A Claude Code skill for designing, implementing, and troubleshooting secure network topologies on Proxmox and VPS environments.

`netarch` helps you plan isolated subnets, configure iptables/NAT rules, and safely apply changes — with Mermaid diagrams, terminal ASCII topology maps, structured documentation, and full command logging. Includes a safe troubleshoot mode that reads before it touches anything.

---

## What it does

- **Design mode** — interviews you, draws a Mermaid topology diagram, writes `~/docs/networking.md` with subnet table and traffic policy
- **Implement mode** — SSHs into the server (or generates scp-ready scripts), applies iptables/bridge config in SSH-safe order
- **Troubleshoot mode** — runs read-only diagnostics first, presents findings, proposes a fix script, gets confirmation before applying
- **Logging** — every remote command and its output appended to `~/docs/netarch-YYYYMMDD.log`

Covers: Proxmox bridges (vmbr*), Linux NAT/MASQUERADE, DNAT port forwarding, iptables FORWARD isolation, IP forwarding, persistent rules via `netfilter-persistent`.

---

## Install (Claude Code)

```bash
git clone https://github.com/serhatkeskin/netarch ~/my_dev/skills/netarch
```

Open Claude Code in `/Users/serhat/my_dev/skills` — the skill is auto-discovered from the `skill/` subdirectory.

---

## Usage

Trigger automatically when talking about:
- Proxmox networking, vmbr bridges, VM isolation
- iptables, NAT, MASQUERADE, DNAT
- VPS subnets, network segmentation
- "my VMs can't reach the internet"

Or use the slash command: `/netarch` — `/netarch troubleshoot` for debug mode.

---

## Output files

| File | Purpose |
|------|---------|
| `~/docs/networking.md` | Architecture doc (imports diagrams) |
| `~/docs/diagrams/topology.md` | Mermaid source |
| `~/docs/diagrams/topology.svg` | Rendered SVG (via `mmdc`) |
| `~/docs/netarch-YYYYMMDD.log` | All remote commands + outputs |
| `/tmp/netarch-*.sh` | Generated setup scripts |
| `~/docs/netarch-rollback.sh` | Emergency rollback |

---

## Repository layout

```
netarch/
├── README.md
├── skill/                  # production skill
│   ├── SKILL.md
│   └── references/
│       ├── proxmox.md      # Proxmox bridge config patterns
│       └── iptables.md     # iptables rule patterns
└── workspace/              # development artifacts
    ├── evals/
    │   └── evals.json
    └── iteration-1/        # eval runs, grading, benchmark
```

---

## Development

Built with the `skill-creator` workflow. Iteration 1 results:

- `with_skill`: **100% pass rate** (19/19 assertions) across 3 eval scenarios
- `without_skill`: 64% pass rate (12/19) — main gaps: no Mermaid diagrams, no setup scripts, no SSH safety ordering
