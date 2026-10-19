# What you need

Everything to gather before the first session: the test machines, USB sticks, miners, rigs,
wallets, the Telegram test bot and the release files.

## Before you start

- Which machine: none yet. This page is the list to collect; the [Run sheet](README.md#run-sheet)
  says which session uses each item.
- Reserve shared machines before you start: see
  [Reserve the hardware](release/before-the-cut.md#reserve-the-hardware).
- Rough time: about an hour for session 1 (Prepare) once everything is at hand; finding or
  borrowing hardware can take longer.
- **Record:** at the top of the results sheet, the full commit SHA you test and, for the
  appliance, the image checksum.

Contents: [Fresh box](#fresh-box), [Upgrade box](#upgrade-box), [Appliance box](#appliance-box),
[Restore PC](#restore-pc), [USB sticks](#usb-sticks), [Miners](#miners), [Rigs](#rigs),
[Laptop](#laptop), [Phone](#phone), [QA wallets](#qa-wallets),
[Telegram test bot](#telegram-test-bot), [Release artifacts](#release-artifacts).

## Fresh box

- Ubuntu Server 24.04, AVX2 CPU, 16 GB RAM, 600 GB SSD, nothing of Pithead on it.
- Used in [section 1](diy/01-fresh-install.md).
- A virtual machine is fine: see
  [Running the DIY boxes as virtual machines](diy/sandbox-vm.md).

## Upgrade box

- A machine already running the previous release, with both chains
  [synced](README.md#glossary) and the dashboard password set.
- A virtual machine is fine: see
  [Running the DIY boxes as virtual machines](diy/sandbox-vm.md).
- Used in sections 2–11 ([the DIY route](diy/README.md)); it runs the candidate from 2.2 on.
- Its Monero node also serves as the test node for 13.15 (M16), opened to the LAN as in
  [Config D](sample-configs.md#config-d--two-machines-sharing-one-monero-node).
- 9.5 replaces its dashboard [onion](README.md#glossary) address and 11.5 clears its dashboard
  history, so do not use a box whose onion or history you need to keep.

## Appliance box

- An x86-64 UEFI PC with 16 GB RAM, ethernet, and firmware settings you can change (Secure Boot
  off).
- An internal SSD or NVMe of **600 GB or more** that may be erased. A smaller disk cannot hold
  both chains ([the appliance guide](../../appliance.md)).
- A second internal disk, for the wrong-disk check.
- Used in [section 13](appliance/README.md).

## Restore PC

- A second x86-64 UEFI PC with 16 GB RAM, wired ethernet, Secure Boot off and a disk that may be
  erased.
- Used for the restore tests in 13.14 and 13.14a
  ([appliance/13b-updates-restore-and-media.md](appliance/13b-updates-restore-and-media.md)).
- While a soak runs it is also the second appliance (see
  [Testing a debug RC on the soak box](appliance/README.md#testing-a-debug-rc-on-the-soak-box)).

## USB sticks

- One stick of **16 GB or larger** for the image, contents expendable. A smaller stick stops the
  first boot at an emergency console.
- A second stick of any size for the settings files in 13.23 and 13.24, so writing them does not
  erase the image. 13.23 erases this second stick when it partitions it.
- The appliance reads settings only from a stick the kernel reports as removable. To check a
  stick on a Linux machine, plug it in and run:

  ```bash
  lsblk -o NAME,RM
  ```

  The line for the stick must show `1` under `RM`.

## Miners

- Two machines running [XMRig](README.md#glossary), for [section 4](diy/04-connect-a-miner.md)
  (4.4 needs a second worker).
- Your own PCs are fine: nothing in section 4 changes them.

## Rigs

- Two rig-class loaner machines, with Secure Boot off, for
  [section 14](appliance/14-rigforge-rig.md). Never a production [rig](README.md#glossary), never
  someone's own PC.
- 14.1 **erases** the first one's internal disk; 14.3 runs the second from the stick.

## Laptop

- On the same network, with a normal browser and [Tor](README.md#glossary) Browser.
- A Linux machine (this laptop or another) for writing the image in 13.1.

## Phone

- For the narrow-screen check and Telegram.
- With Tor Browser (or Orbot) for S7.

## QA wallets

Payouts go to these wallets, so never use a real person's address or a donation address.

- A Monero wallet used only for QA. You need:
  - its **primary** address (starts with `4`, 95 characters);
  - one **subaddress** from it (starts with `8`);
  - its private [view key](README.md#glossary) (the Monero GUI calls it *Secret view key*).
- A second Monero QA wallet: its primary address and private view key, for the payout-change
  steps (6.4, 6.4a, 7.5).
- A Tari **mainnet** QA wallet with a dual-key address, which is what Tari Universe creates: its
  address and private view key. The public spend key is read from the address, so no spend key
  is needed (#3096).
- A single-key Tari address (about 46 characters, never funded) for the refusal in 6.4b.
- The two QA wallets should open in the official Monero GUI wallet and Tari Universe, for the
  view-key docs walk in 7.9.

## Telegram test bot

- A bot made with @BotFather, its token, and the chat id of a test chat.
- See [Telegram](../../telegram.md).

## Release artifacts

- The candidate's full commit SHA.
- The previous release tag.
- For the appliance:
  - the RC image: the candidate's debug image. The release `.img.xz` with its `.sha256` joins it
    at GA;
  - the RC update bundle: the candidate's own `.raucb`;
  - the good higher-version test bundle: a debug-variant `.raucb` with a higher version;
  - the broken (health-gate fault) test bundle M9 describes: also debug-variant, with a version
    above the good one;
  - the bench SSH key for debug images, kept in the private handoff
    ([appliance-release.md](../appliance-release.md)).

Reserve shared machines before you start: see
[Reserve the hardware](release/before-the-cut.md#reserve-the-hardware).
