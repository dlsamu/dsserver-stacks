# Remote administration of kjells-computer (handover M1)

Kjell's laptop (`kjells-computer`, Acer Aspire E5-575G, Linux Mint 22.3) is used on networks outside this house. It is administered over SSH across Tailscale. Since 2026-11-10 dsserver has its **own** access path, independent of the Raspberry Pi (dsoffice). Host-side details: [host-config §13](../host/docs/host-config.md).

## Access path

```
dsserver (daniel)  --Tailscale, tail96c1da.ts.net-->  kjells-computer (kjell)
ssh kjells-computer      # asks for the key passphrase; interactive use only
```

| Item | Value |
|---|---|
| dsserver node | `dsserver.tail96c1da.ts.net`, 100.69.238.56, fd7a:115c:a1e0::4e28:ee39. Key expiry **disabled** |
| Tailscale settings on dsserver | `--accept-dns=false --accept-routes=false --ssh=false --shields-up`, no exit node, no advertised routes. Incoming tailnet connections are refused (shields-up) and dropped by `dsserver_fw` (`vpn_ifaces` empty) |
| Target | user `kjell` at 100.81.116.21 (`HostKeyAlias kjells-computer`; MagicDNS is not used on dsserver) |
| Client key | `~/.ssh/kjell_admin_dsserver`, ED25519, **passphrase-protected**, `SHA256:0UcXKvRZdamW9zW/C+kxSvrLNCYhlLY1Qx3ujIqE2Dc`, comment `daniel@dsserver -> kjells-computer`. Never copied anywhere; no unattended use |
| Laptop host key | ED25519 `SHA256:7xBCTnAjcSYw4dU/M28Wbfv1n20MBTIGf0m9tUjAtNU`, taken from the Pi's trusted `known_hosts` and confirmed by the user against the Pi's own output. Stored in `~/.ssh/known_hosts_kjells-computer`; `StrictHostKeyChecking yes`, `UpdateHostKeys no` |
| Client restrictions | publickey only (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`), `IdentitiesOnly yes`, no agent or X11 forwarding |
| Laptop `authorized_keys` line | `from="100.69.238.56,fd7a:115c:a1e0::4e28:ee39",no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEP+hsttfRWsrNYNZBQWJzbXGsLceKdatakqSL2171Sk daniel@dsserver -> kjells-computer`: the key works only from dsserver's tailnet addresses. Appended (never replacing) over the Pi's connection; backup `~kjell/.ssh/authorized_keys.bak-20261110-dsserver` |
| Laptop sshd (from earlier notes) | key-only, `AllowUsers kjell`, Tailscale SSH off |
| Other key on the laptop | the Pi's `mint_kjell` (`SHA256:fo4FXs+g4DHiRC3G0sPQvdFd/4QbBkw0ZkunvAURqaE`), kept until the Pi is retired |

No password authentication, no shared private keys, no internet-facing ports, no router forwarding.

## Acceptance (2026-11-10)
- From dsserver, the user ran `ssh kjells-computer 'hostname; whoami; uptime'` → `kjells-computer`, `kjell`, uptime. The host key was checked against the Pi-supplied entry before authentication.
- The Pi's original access (`mint_kjell`, BatchMode) still works afterwards: read-only check by Claude on the Pi, reported as passed by the user on 2026-11-10.

## Recovery and revocation

| Situation | What happens | Fix |
|---|---|---|
| **Passphrase forgotten** or key file lost | The key is unusable | Generate a new key on dsserver (same procedure), append its public line through another working path (the Pi while it exists), test, then remove the old line |
| **dsserver key compromised** | Attacker still needs dsserver's tailnet IP (`from=`) and the passphrase | Remove the line from the laptop over another path: `grep -vF 'AAAAC3NzaC1lZDI1NTE5AAAAIEP+hsttfRWsrNYNZBQWJzbXGsLceKdatakqSL2171Sk' ~/.ssh/authorized_keys > ~/.ssh/ak.new && chmod 600 ~/.ssh/ak.new && mv ~/.ssh/ak.new ~/.ssh/authorized_keys` (keep a backup first). Optionally remove dsserver from the tailnet |
| **dsserver's Tailscale IP changes** (node deleted and re-added, `11-tailscale.sh rollback` + reinstall) | Login refused because of `from=` | Re-join, then update the `from=` addresses on the laptop over another path. Normal reboots and Tailscale upgrades keep the IP |
| **Laptop host key changes** (reinstall, new sshd keys) | `ssh` refuses with a host-key mismatch, before authentication | Do **not** bypass it. Get the new fingerprint out of band (Kjell reads `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, or physical access), compare, then replace the line in `~/.ssh/known_hosts_kjells-computer` |
| **Laptop logged out of Tailscale** or key expired there | Peer offline / unreachable | Needs Kjell or physical access (the laptop's key expiry is disabled per earlier notes) |
| **dsserver unavailable** | No access from dsserver | Use the Pi while it still has `mint_kjell`. **Before the Pi is retired**, add a second independent admin path (e.g. a passphrase-protected key from another of the user's machines), so dsserver does not become the single point of failure |

## Pi retirement (handover M7)
Only after dsserver has logged in successfully (done 2026-11-10) **and** a second path exists: remove `mint_kjell`'s line from the laptop's `authorized_keys`, then reinstall the Pi. That removal changes the laptop and needs the user's approval.
