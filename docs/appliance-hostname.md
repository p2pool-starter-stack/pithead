# Appliance name

The coordinator wizard's **Name this machine** field sets `dashboard.host`.

Use 1–63 ASCII letters, digits or hyphens, starting and ending with a letter or digit.
New coordinators default to `pithead`. RigForge-only installs keep their worker-name field.
A reinstall that keeps everything retains the saved configuration, including its name.

For a name such as `garden-box`, the appliance uses the lowercase hostname `garden-box`
and serves the dashboard at `https://garden-box.local`. The certificate covers that name
and the permitted local addresses; the dashboard header uses the same name. After a name
change, open the new address. The browser must trust a new self-signed certificate.

Rigs whose pool uses the old machine name stop mining after a rename. Use **Set up again**
on each affected rig and change its pool to the new name on port `3333`. Rigs using an
unchanged IP address or another coordinator keep their pool setting.

To rename an installed appliance, set `dashboard.host` to a hostname label and run
`cd /data/pithead && ./pithead apply` at the console. Dashboard [Configuration](configuration.md) changes
also require its approval policy to permit the commit. A successful apply refreshes the
machine's hostname and mDNS announcement. Preview and dry-run leave them alone.
The saved configuration restores the name during boot, including after an OS update;
the read-only system partition holds no separate hostname setting.

Existing `auto` settings retain the current hostname and display as `auto` in the wizard.
Saved dotted DNS names and IP addresses remain dashboard certificate addresses when kept;
the wizard offers an optional name to replace them. Docker installations keep their host's
identity when `dashboard.host` changes.
