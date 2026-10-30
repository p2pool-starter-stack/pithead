# Appliance name

The appliance uses `dashboard.host` to choose the dashboard name and local network address.

A fresh installation uses `dashboard.host: auto`, which derives the name from the machine hostname.
An existing explicit `dashboard.host` value remains in effect. The setup flow does not ask for a
machine name. The ordinary image hostname may remain `pithead`; that does not change the
configuration default of `auto`.

For a name such as `garden-box`, the appliance serves the dashboard at
`https://garden-box.local`. The certificate covers that name and the permitted local addresses;
the dashboard header uses the same name. After changing the name, open the new address. The browser
must trust the new self-signed certificate.

Rigs whose pool uses the old machine name stop mining after a rename. Use **Set up again** on each
affected rig and change its pool to the new name on port `3333`. Rigs using an unchanged IP address
or another coordinator keep their pool setting.

To rename an installed appliance, set `dashboard.host` to a hostname label and run
`cd /data/pithead && ./pithead apply` at the console. Dashboard [Configuration](configuration.md)
changes also require its approval policy to permit the commit. A successful apply refreshes the
machine's hostname and mDNS announcement. Preview and dry-run leave them alone. The saved
configuration restores the name during boot, including after an OS update; the read-only system
partition holds no separate hostname setting.

Saved dotted DNS names and IP addresses remain dashboard certificate addresses when kept. Docker
installations keep their host identity when `dashboard.host` changes.
