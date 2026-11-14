# Appliance name

The coordinator wizard's **Name this machine** field sets `dashboard.host`.

Use 1–63 lowercase letters, digits or hyphens, starting and ending with a letter or digit;
`auto` and `localhost` are reserved. The browser wizard and the server refuse a name that breaks
it, and the setup prompt asks again, all with one message. The field is prefilled with the
default name, and an empty answer at the setup prompt keeps it; new coordinators default to `pithead`. A RigForge rig has one name:
its worker name is also its hostname and its `<name>.local` address, checked by the same rule
and the same collision warning, and the rig card repeats the warning. A reinstall that keeps everything retains the saved configuration,
including its name. If another machine on your network already answers `<name>.local`, setup
warns before claiming the name and the credentials card repeats the warning.

For a name such as `garden-box`, the appliance uses the lowercase hostname `garden-box`
and serves the dashboard at `https://garden-box.local`. The certificate covers that name
and the permitted local addresses; the dashboard header uses the same name. After a name
change, open the new address. The browser must trust a new self-signed certificate.

Rigs whose pool uses the old machine name stop mining after a rename. Use **Set up again**
on each affected rig and change its pool to the new name on port `3333`. Rigs using an
unchanged IP address or another coordinator keep their pool setting.

To rename a rig, use **Set up again** and change its name. The name is the worker name, so
the rig gets a new control token and the Pithead's adopted entry for the old name goes stale.
Adopt the rig again from the coordinator's Workers view with the new card's token. A saved
worker name that is not a hostname label leaves the hostname at the image default; an
older name with capitals is lowercased.

**A DIY machine is named by its OS hostname, not by setup.** To rename one: change the OS
hostname (`hostnamectl set-hostname <name>`), run `./pithead apply`, then repoint any rigs
pinned to the old name. `./pithead doctor` warns when the rendered dashboard address no longer
matches the machine's hostname while `dashboard.host` is `auto`. The local certificate
authority is unchanged, so clients keep trusting the existing root.

To rename an installed appliance, set `dashboard.host` to a hostname label and run
`cd /data/pithead && ./pithead apply` at the console. Dashboard [Configuration](configuration.md) changes
also require its approval policy to permit the commit. A successful apply refreshes the
machine's hostname and mDNS announcement. Preview and dry-run leave them alone.
The saved configuration restores the name during boot, including after an OS update;
the read-only system partition holds no separate hostname setting.

Existing `auto` settings retain the current hostname; the wizard prefills them with the
platform's default name instead of showing `auto`.
Saved dotted DNS names and IP addresses remain dashboard certificate addresses when kept;
the wizard offers an optional name to replace them. Docker installations keep their host's
identity when `dashboard.host` changes.
