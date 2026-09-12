# Red Kite — your own hub

[Red Kite](https://redkite.info) watches machines by listening for them. Each machine sends an
outbound heartbeat every few minutes, and **the alarm is the absence of that message, not the
presence of one** — so a server that loses power, loses its line, or is simply switched off is
noticed either way.

This repository is how you run the hub those machines report to. It is three containers and one
`.env` file, and it takes about twenty minutes from a bare server.

**Nothing here ever connects to a monitored machine.** Agents reach the hub; the hub does not reach
agents. That is why the machines you watch need no port forwarding, no VPN, no static address and
no inbound firewall rule.

---

## Before you start

**You need a server that is not in the building you are watching.**

This is the one rule worth arguing about, so here is the reasoning: if the hub shares its power,
its switch or its broadband with the machines it watches, then the event you most need to hear
about is the event that takes the hub down too. It is the fire that takes out the server room, the
power cut, the failed router. A monitor inside that blast radius goes quiet at exactly the moment
it should be shouting.

A £5-a-month VPS anywhere else is the whole requirement. It needs very little:

| | |
|---|---|
| Server | 1 vCPU, 1GB RAM, 20GB disk. The smallest tier at any host is enough |
| Operating system | Anything that runs Docker. Ubuntu LTS is the easy answer |
| Software | Docker and the Compose plugin |
| A name | A hostname you control, pointed at the server — `hub.yourbusiness.co.uk` |
| A mailbox | For certificate notices, and later for alerts |

You will also need **port 80 and port 443 open inbound**. Port 80 is not optional even though
everything real happens on 443: the certificate challenge uses it.

---

## 1 · Point the name at the server first

Add an `A` record for your chosen hostname pointing at the server's address, and **wait for it to
resolve before going any further**:

```bash
dig +short hub.yourbusiness.co.uk        # must return the server's address
```

This matters more than it looks. Caddy asks Let's Encrypt for a certificate the moment it starts,
and Let's Encrypt proves you own the name by connecting back to it. If the record is not there yet,
the challenge fails, Caddy retries with a growing backoff, and the hub serves nothing at all. **It
reads like a broken deployment rather than a missing DNS record**, and people lose an evening to it.

---

## 2 · Get the files

```bash
git clone https://github.com/redkite-info/redkite-hub.git
cd redkite-hub
```

---

## Verifying the installer, if you used it

Most people stand a hub up with the one-line installer rather than by hand:

```bash
curl -sSL https://redkite.info/hub.sh -o rk-hub.sh
sudo bash rk-hub.sh
```

That script is fetched from **redkite.info**, and it runs as root. This repository is the place to
check it against, because **it is not the machine that serves redkite.info** — somebody who gets
into that server cannot change what is here as well.

```bash
sha256sum rk-hub.sh
```

Compare the result with the `hub.sh` line in [SHA256SUMS](SHA256SUMS). The copy of `hub.sh` in this
repository is the same file, so you can also read it before you run it.

The installer carries the checksums of `docker-compose.yml` and `Caddyfile` inside itself and
refuses to write either if it does not match — that catches a stale CDN copy, or a change made to
the site alone. **It cannot catch a replaced installer**, because a poisoned one would carry
poisoned checksums. The comparison above is the only check that survives that, which is why it is
worth the ten seconds.

---

## 3 · Fill in the settings

```bash
cp .env.example .env
nano .env
```

Only four settings are required:

| Setting | What |
|---|---|
| `HUB_HOSTNAME` | The name from step 1 |
| `ADMIN_EMAIL` | Your sign-in account. You will get a token for it in step 5 |
| `ACME_EMAIL` | Where certificate expiry notices go. A mailbox somebody reads |
| `POSTGRES_PASSWORD` | Generate it — see below |

**Generate the database password rather than inventing one.** This database holds your machine list
and your hashed agent tokens:

```bash
openssl rand -base64 32
```

Everything else in the file is optional and can wait. Alerting in particular is better added after
you have seen a machine check in, so that you are debugging one thing at a time.

---

## 4 · Start it

```bash
docker compose up -d
```

The first start pulls three images and asks Let's Encrypt for a certificate. Give it a minute, then:

```bash
docker compose ps                        # all three should be running, hub healthy
curl -sI https://hub.yourbusiness.co.uk/health | head -1
```

You want `HTTP/2 200`. If you get a certificate error, it is almost always DNS — go back to step 1
and check the record really resolves from outside your own network.

---

## 5 · Create your account

The hub starts with an empty database. This creates your organisation and your sign-in token:

```bash
docker compose run --rm hub --seed
```

It prints something like:

```
Ready. Bartons Engineering has been created, with no machines yet.

  Sign-in token for sam@bartonsengineering.co.uk:

    rk_user_V7Rdq0r6LUyHWqHkLsMkXVNuCyUuXr9ph3f7JZ1k0Q0

  Shown once. The hub keeps only a hash and cannot tell you this again.
```

**Copy it now.** The hub stores only a hash and genuinely cannot tell you what it was. If it is
lost, issue another:

```bash
docker compose run --rm hub --reissue-staff-token
```

Running `--seed` twice is safe. It never overwrites — the second run says so and changes nothing,
because a command that quietly reissues tokens is a command that breaks every agent using the old
one.

---

## 6 · Sign in and add your first machine

Open `https://hub.yourbusiness.co.uk` and sign in with the token.

The hub starts with **no machines**, deliberately: a machine that exists but never checks in would
raise a critical incident about twenty minutes later, and a false alarm is a poor first thing for a
monitoring system to say.

Add a machine on the screens, and the hub gives you the command to run on it. The agents are
[published in full](https://github.com/redkite-info/redkite-agent) so you can read one before you
run it.

| Platform | How |
|---|---|
| Unraid | Community Applications, or the [template](https://github.com/redkite-info/redkite-unraid-templates) |
| Linux | A shell script on a systemd timer |
| Windows | PowerShell on a scheduled task |

Once it has checked in, the machine turns green on the Now screen. **If it does not, the hub tells
you what it has and has not heard** rather than guessing.

---

## 7 · Set up something to watch the hub

**Please do not skip this.** A monitor cannot report its own absence — that is the exact gap Red
Kite exists to close, and it is the one gap the hub cannot close for itself. If the hub dies, every
machine goes quiet and nothing tells you, because the thing that would have told you is the thing
that died.

Make a check at [Healthchecks.io](https://healthchecks.io) (the free tier is plenty), put its ping
URL in `.env` as `HEALTHCHECKS_PING_URL`, and restart:

```bash
docker compose up -d hub
```

The hub pings it on a timer, and **withholds the ping whenever the sweep is not genuinely running**
— so the outside service notices a hub that is up but not actually working, not just one that has
stopped.

---

## Running it

```bash
docker compose ps                  # what is running
docker compose logs -f hub         # follow the hub's log
docker compose restart hub         # after changing .env
docker compose down                # stop, keeping all data
```

### Updating

```bash
docker compose pull
docker compose up -d
```

Migrations run automatically on start. **Back the database up first** — see below.

Once the hub is watching anything you care about, pin a version in `.env` so that an update is
something you choose rather than something that arrives:

```
REDKITE_VERSION=0.4.0
```

### Backing up

The whole hub is one database. This is the backup:

```bash
docker compose exec -T db pg_dump -U redkite redkite | gzip > redkite-$(date +%F).sql.gz
```

Keep it somewhere that is not this server. **A backup nobody has ever restored is not a backup** —
restore one into a throwaway container once, so you find out now rather than on the day it matters.

---

## What the hub knows about your machines

Figures, never content. No file names, no user names, no process command lines, no log message
text, no drive serial numbers. The test applied to anything new is: *if this database leaked, what
would the owner mind?*

[What we watch](https://redkite.info/what-we-watch.html) is the complete inventory.

Everything stays on your server. There is no account with us, nothing phones home, and we cannot
see your hub or your machines.

---

## Honest status

Red Kite is in open beta. It is useful and it is not finished, and those two facts belong together
in any description of it. It is provided as-is, with no warranty.

**Please do not make this the only thing watching your machines yet.** Run it alongside whatever
you already have and tell us where the two disagree — that is what the beta is for.

Known limits today:

- Threshold alerting is **being built**. The deep readings — SMART, RAID, filesystems, memory
  errors — are gathered and shown, but they do not yet raise incidents on their own. Silence does.
- Per-customer screens and alert routing by customer are **being built**. The tenancy filter is
  enforced in the database from the first migration; the screens are not there yet.
- No alerting provider credentials have been exercised against a real inbox or handset by us. The
  senders are written and the hub says loudly when it cannot send.

---

## Licences

**This repository is MIT** — the compose file, the Caddy configuration and these instructions. Fork
it, correct it, adapt it.

**The hub image is [PolyForm Shield 1.0.0](https://github.com/redkite-info/redkite-agent/blob/main/LICENSE.md)**:
run it, in your own business or on behalf of your own customers, but not to provide a product that
competes with Red Kite. That is not an open source licence and is not presented as one.

The hub's source is not published. The agent's is — because that is the part that runs unattended
on machines you own, and you are entitled to read it before you run it.

---

## Something wrong?

`contact@redkite.info` reaches an engineer rather than a ticket queue. Reports of things Red Kite
got wrong are more welcome than praise.

Useful things to include:

```bash
docker compose ps
docker compose logs --tail 50 hub
```
