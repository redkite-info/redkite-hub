#!/usr/bin/env bash
#
# Red Kite - the hub installer.
#
# Two lines, on a server that is NOT in the building you want to watch:
#
#     curl -sSL https://redkite.info/hub.sh -o rk-hub.sh
#     sudo bash rk-hub.sh
#
# It asks four questions, does everything else, and proves the hub is answering before it claims
# to have finished.
#
# **It used to say `sudo bash <(curl -sSL ...)`, and that does not work.** sudo closes every file
# descriptor above 2, so the process substitution is gone by the time bash looks for it and the
# whole thing dies on `/dev/fd/63: No such file or directory` before a single question is asked.
# Anybody not already root - which is most people - met that as their first experience of Red Kite.
#
# Downloading first also lets somebody read this file before running it as root, which on a script
# that installs Docker and opens two ports is a reasonable thing to want to do.
#
# ---------------------------------------------------------------------------------------------
# CHECKING THAT THIS IS OUR FILE, BEFORE YOU RUN IT AS ROOT
# ---------------------------------------------------------------------------------------------
# Between the two lines above, if you want it:
#
#     sha256sum rk-hub.sh
#     # compare with https://github.com/redkite-info/redkite-hub/blob/main/SHA256SUMS
#
# **That comparison is the only check here that survives us being compromised.** Everything this
# script does to protect you - and it does check the two files it downloads - is worth nothing if
# somebody has replaced this script, because a poisoned installer carries poisoned checks. The
# checksum is published on GitHub, which is not the machine that serves redkite.info, so an
# attacker needs both to go unnoticed.
#
# We would rather say that plainly than let a checksum served from the same host as the file do
# the work of reassurance without doing the work of proof.
#
# ---------------------------------------------------------------------------------------------
# WHY THIS EXISTS
#
# The written guide was: clone a repository, copy an env file, generate a password, edit five
# settings, bring three containers up, run a seed command, and copy a token out of the output
# before it scrolls away. Every step was a chance to stop.
#
# The people this is for are testers doing us a favour on their own hardware in their own time.
# An installer that asks four questions is not a convenience for them. It is the difference
# between somebody trying Red Kite this evening and somebody meaning to try it one day.
# ---------------------------------------------------------------------------------------------
#
# It fetches a compose file and a Caddy configuration, both public and both readable before you
# run this, at github.com/redkite-info/redkite-hub. It writes them, an .env, and nothing else.
#
# **It installs the agent on this one server, and on no other.** The hub is a server too, and the
# most obvious machine to watch is the one it is running on - so it adds itself as the first
# machine and installs smartmontools so its disks can actually be read. Nothing is installed
# anywhere else, and no inbound path is opened to any machine you own: the agent reports outwards,
# like every other agent. `--skip-self` leaves this server alone.
#
# Options, for an unattended install. With all four of --hostname, --email, --org and --yes it
# never asks anything:
#
#   --hostname NAME    the name this hub will answer to, e.g. hub.yourbusiness.co.uk
#   --email ADDRESS    your sign-in account, and where certificate notices go
#   --org NAME         your organisation, as it appears on the screens
#   --dir PATH         where to install                     (default /opt/redkite)
#   --skip-dns-check   do not verify the name points here   (you had better be sure)
#   --yes              do not ask to confirm anything
#   --skip-self        do not add this server as the first machine it watches
#   --uninstall        stop the hub and remove the containers

set -uo pipefail

# The compose file and the Caddy configuration, served from this site rather than from GitHub.
#
# They are the same files as github.com/redkite-info/redkite-hub, and that repository is still
# where to read or fork them. They are fetched from here because raw.githubusercontent.com sits
# behind a CDN with a few minutes of cache: a machine installing shortly after a fix was published
# could be handed a stale file, or a new compose file paired with an old Caddyfile. That is not
# theoretical - it happened during testing, and the install came up with no TLS at all.
#
# Served from here, the installer and the files it fetches are deployed together and cannot
# disagree with each other. They cannot disagree *silently* either: this script carries their
# checksums and refuses anything else.
#
# The public copy at github.com/redkite-info/redkite-hub carries the same three files and a
# SHA256SUMS beside them. It is there to be read, forked, and - the part that matters - compared
# against, because it is not on the machine that serves redkite.info.
readonly REPO_RAW="https://redkite.info/hub"
readonly DEFAULT_DIR="/opt/redkite"

# ---------------------------------------------------------------------------------------------
# What the two files it downloads are supposed to be
# ---------------------------------------------------------------------------------------------
# **These are baked in rather than fetched, and that is the whole point.** A checksum downloaded
# from the same host as the file it describes proves that the two arrived together, which is not a
# question anybody was asking. Carried inside this script, they say something worth saying: *these
# are the files this installer was published with.*
#
# It buys two different things:
#
#   1. **Version skew is caught.** The reason these files moved off raw.githubusercontent in the
#      first place was a CDN handing out a stale one - a new compose file paired with an old
#      Caddyfile, and an install that came up with no TLS at all. That is now a refusal with a
#      sentence rather than a broken hub nobody can explain.
#
#   2. **A partial compromise is caught.** Somebody who can change the files on the site but not
#      this script - a CDN, a cache, a misdirected DNS record, a hand slipping on a deploy - is
#      stopped here.
#
# **What it does not do, and must not be sold as doing:** it cannot defend against somebody who has
# replaced *this file*. A poisoned installer carries poisoned hashes, or no check at all. Only a
# check made somewhere this server does not control can catch that, which is why the sha256 of this
# script is published at github.com/redkite-info/redkite-hub and printed in the guide - and why the
# guide asks you to compare them before you run it as root.
#
# **If you change either file in site/hub/, these must change with it.** InstallerSealTests fails
# the build otherwise, which is the only reason that is safe to say.
readonly EXPECTED_COMPOSE_SHA256="8cd848d6348d5daee301af35cfb68c032b3274f59969c51fac03c738d7a9d1e6"
readonly EXPECTED_CADDYFILE_SHA256="ad8b22473e7f8817fc6623e80e203b1b9b9e27d4401037a814a11ff9fce68ef3"

DIR="$DEFAULT_DIR"
HOSTNAME_IN=""
EMAIL=""
ORG=""
ASSUME_YES=0
SKIP_DNS=0
UNINSTALL=0
IP_MODE=0
SKIP_SELF=0

# ---------------------------------------------------------------------------------------------
# Saying things
#
# Plain sentences, and every failure says what to do next. Pure ASCII throughout: this output
# gets saved to a file and emailed when somebody is stuck, and an em dash does not survive that
# trip.
# ---------------------------------------------------------------------------------------------
#
# **Everything goes to standard output, including the failures.**
#
# fail() used to write to stderr, which is the conventional thing and was wrong here. The two
# streams are buffered separately, so the moment this output is piped anywhere - a log file, an
# email to us, `| tee` - the lines arrive out of order. On the first clean-server run the heading
# "PROBLEM: that is an IP address" appeared four paragraphs *below* its own explanation, which
# reads like two unrelated messages.
#
# This output is one narrative meant to be read start to finish by a person. Keeping it in order
# matters more than the stream it arrives on, and the exit code is what anything automated should
# be reading anyway.
say()   { printf '%s\n' "$*"; }
step()  { printf '\n== %s\n' "$*"; }
ok()    { printf '   ok    %s\n' "$*"; }
note()  { printf '   note  %s\n' "$*"; }
fail()  { printf '\nPROBLEM  %s\n' "$*"; }

die() {
    fail "$*"
    printf '\nNothing is running that this cannot be run again over.\n'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)       HOSTNAME_IN="${2-}"; shift 2 ;;
        --email)          EMAIL="${2-}";       shift 2 ;;
        --org)            ORG="${2-}";         shift 2 ;;
        --dir)            DIR="${2-}";         shift 2 ;;
        --skip-dns-check) SKIP_DNS=1;          shift ;;
        --yes|-y)         ASSUME_YES=1;        shift ;;
        --uninstall)      UNINSTALL=1;         shift ;;
        --skip-self)      SKIP_SELF=1;         shift ;;
        -h|--help)        sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                die "I do not know the option $1. Run with --help." ;;
    esac
done

# ---------------------------------------------------------------------------------------------
# Asking
#
# **A prompt only works when there is somebody at the other end of it.**
#
# `curl ... | bash` hands the script itself to bash on standard input, so every read here would
# take a line of this file as the answer and the install would proceed with nonsense - silently,
# and looking like it worked. That is why the command at the top downloads to a file first and
# runs that: bash then reads the file, and standard input is still your keyboard.
#
# Process substitution - `bash <(curl ...)` - solves the same problem and is what this used to say.
# It cannot be used here, because it does not survive sudo: every file descriptor above 2 is closed
# and the substitution goes with them. A file works whether you are root already or not.
#
# Checked once, early, and the fix is printed rather than hinted at.
# ---------------------------------------------------------------------------------------------
INTERACTIVE=1
[[ -t 0 ]] || INTERACTIVE=0

ask() {
    local prompt="$1" default="${2-}" answer=""

    if (( ! INTERACTIVE )); then
        printf '%s' "$default"
        return 0
    fi

    if [[ -n "$default" ]]; then
        read -r -p "   $prompt [$default]: " answer </dev/tty
    else
        read -r -p "   $prompt: " answer </dev/tty
    fi

    printf '%s' "${answer:-$default}"
}

confirm() {
    (( ASSUME_YES )) && return 0
    (( INTERACTIVE )) || return 0

    local answer=""
    read -r -p "   $1 [y/N]: " answer </dev/tty
    [[ "$answer" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------------------------
# Before anything is changed
# ---------------------------------------------------------------------------------------------
preflight() {
    step "Looking at this server"

    [[ "$(uname -s)" == "Linux" ]] \
        || die "This installs on Linux. For anything else, the manual route is at github.com/redkite-info/redkite-hub"

    # Not `sudo bash <(curl ...)`: sudo closes every file descriptor above 2, so the process
    # substitution dies with them and bash reports a missing /dev/fd/63.
    [[ "$(id -u)" -eq 0 ]] \
        || die "Run this as root, or with sudo: sudo bash $0"

    command -v curl >/dev/null 2>&1 || die "curl is missing. Install it and run this again."
    ok "Linux, running as root"

    # This script's own fingerprint, printed where it lands in the transcript rather than hidden
    # behind a flag.
    #
    # **It proves nothing on its own** - a replaced installer would print whatever it liked - and
    # saying so here is the point. Its use is that it can be compared with the copy published at
    # github.com/redkite-info/redkite-hub, which is not on this company's server and cannot be
    # changed by anybody who gets into it. That comparison is the only check in this whole install
    # that survives us being compromised, so it is worth the two lines it costs.
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        local mine
        mine="$(sha_of "${BASH_SOURCE[0]}")"
        [[ -n "$mine" ]] && note "this installer is sha256 $mine"
    fi

    # Docker. Offered rather than assumed, because installing it is a bigger thing than the rest
    # of this script put together and somebody may have opinions about how.
    if ! command -v docker >/dev/null 2>&1; then
        note "Docker is not installed."
        say  ""
        say  "   Red Kite runs in containers, so it needs Docker. The official installer at"
        say  "   get.docker.com is the usual way, and this can run it for you."
        say  ""
        if confirm "Install Docker now?"; then
            curl -sSL https://get.docker.com | sh \
                || die "Installing Docker did not work. Install it yourself and run this again."
        else
            die "Install Docker, then run this again."
        fi
    fi

    docker compose version >/dev/null 2>&1 \
        || die "Docker is here but the Compose plugin is not. Install docker-compose-plugin and run this again."

    docker info >/dev/null 2>&1 \
        || die "Docker is installed but not running. Start it with: systemctl start docker"

    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo present), with compose"

    # Ports. Caddy needs both, and the failure if something else holds them is a confusing one.
    local busy=""
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.](80)$'  && busy="80"
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.](443)$' && busy="${busy:+$busy and }443"
    fi
    if [[ -n "$busy" ]]; then
        note "Something is already listening on port $busy."
        say  ""
        say  "   Caddy needs 80 and 443 to get a certificate and to serve the hub. If that is"
        say  "   another web server, stop it first. If it is an old Red Kite, this will reuse it."
        say  ""
        confirm "Carry on anyway?" || die "Stop whatever holds port $busy, then run this again."
    else
        ok "ports 80 and 443 are free"
    fi
}

# ---------------------------------------------------------------------------------------------
# Which address the DNS record should point at.
#
# **Asked before the hostname rather than after it.** Somebody who has not made the record yet
# needs the number to make it with, and until now this script told them to "add the DNS record
# first" without saying what to point it at. They then had to go and find it themselves, on a
# server they may have provisioned five minutes ago.
#
# It is the same failure documentation/Deploying-The-Hub.md calls the one ordering rule: DNS has
# to resolve before the first start, because Caddy asks Let's Encrypt for a certificate as it
# comes up and the challenge fails against a name that points nowhere. It presents as a broken
# deploy rather than a missing record, and it costs an hour every time.
#
# **The outside view is the one that matters.** On a VPS an interface address is usually the
# public one, but not always, and an A record pointing at 10.0.0.4 helps nobody. So ask outside
# first, fall back to the interfaces, and say which is which rather than guessing silently.
# ---------------------------------------------------------------------------------------------
PUBLIC_IP=""
LOCAL_IPS=""
PRIMARY_IP=""
ADDRESSES_LOOKED_UP=0

find_addresses() {
    (( ADDRESSES_LOOKED_UP )) && return 0
    ADDRESSES_LOOKED_UP=1

    # Every global v4 address, used only to recognise this server later.
    LOCAL_IPS="$(ip -o -4 addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ' | sed 's/ *$//')"

    # The one to actually offer somebody. A machine running Docker has 172.17.0.1 as well, and a
    # list that includes the bridge invites them to point a record at an address that only exists
    # inside this box. The source address of the default route is the real answer.
    PRIMARY_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
    [[ "$PRIMARY_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || PRIMARY_IP=""
    [[ -n "$PRIMARY_IP" ]] || PRIMARY_IP="${LOCAL_IPS%% *}"

    # Short timeout on purpose: this is a convenience, and an installer that hangs for half a
    # minute on a server with no outbound route is worse than one that says it could not tell.
    PUBLIC_IP="$(curl -sS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || PUBLIC_IP=""
}

# Lay out the actual choice, with this server's real numbers in it.
#
# **There are two arrangements and they are not the same product.** Both are legitimate, people
# ask for both, and the difference is not obvious from a prompt that only asks for a hostname. So
# both are spelled out here with the trade named, rather than left to be discovered after an agent
# refuses to check in.
#
# **What separates them is whether this server's own address is a private one**, not whether it
# differs from the public one. A VPS answering on a public address reaches machines anywhere, so
# the only thing it gives up is a trusted certificate. A box on 192.168.x gives up far more: it
# reaches nothing off its own network, and it sits in the same building as the machines it is
# watching, which is the one arrangement this product exists to avoid.
#
# The addresses are printed rather than described because somebody standing at this prompt has not
# got them to hand, and going to find them is where an install stalls.
say_the_address() {
    find_addresses

    local private_primary=0
    [[ "$PRIMARY_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] && private_primary=1

    local behind_nat=0
    [[ -n "$PUBLIC_IP" && -n "$PRIMARY_IP" && "$PUBLIC_IP" != "$PRIMARY_IP" ]] && behind_nat=1

    say "   There are two ways to answer this, and they are different arrangements rather than"
    say "   different spellings. Pick on what you want the hub to be able to do."
    say ""
    say "   1. A name on the internet.  The one this product is for."
    say ""
    if [[ -n "$PUBLIC_IP" ]]; then
        say "      Point an A record, say hub.yourbusiness.co.uk, at  $PUBLIC_IP"
    else
        say "      Point an A record, say hub.yourbusiness.co.uk, at this server's public address."
    fi
    if (( behind_nat )); then
        say "      Forward ports 80 and 443 on your router to this server, $PRIMARY_IP."
    else
        say "      Ports 80 and 443 on this server need to be reachable from the internet."
    fi
    say "      Let's Encrypt issues a real certificate, so agents trust it with nothing extra to"
    say "      do on any machine, and the hub can watch buildings it is not sitting in. That last"
    say "      part is the whole idea: a hub inside a building cannot tell you the building went"
    say "      off."
    say ""

    if [[ -n "$PRIMARY_IP" ]]; then
        say "   2. This server's own address, $PRIMARY_IP.  Nothing to open, nothing to register."
    else
        say "   2. This server's own address.  Nothing to open, nothing to register."
    fi
    say ""
    say "      No DNS record and no port forwarding. What it costs is the certificate: nobody"
    say "      will issue a public one for an address, so Caddy signs its own. The screens want a"
    say "      browser warning clicked through once, and every agent has to be told to trust this"
    say "      hub, which is one command per machine and a thing to remember for ever."
    say ""

    if (( private_primary )); then
        say "      $PRIMARY_IP is a private address, so this hub would also be reachable only from"
        say "      this network, and it would share the power and the broadband of the machines it"
        say "      is watching. It cannot report a failure it is sitting inside. Good for trying"
        say "      the product out. Not what it is for."
    else
        say "      Reach is the same as option 1: this address is a public one, so machines"
        say "      anywhere can check in once they have been told to trust the certificate. The"
        say "      certificate is the only difference, and a name costs nothing."
    fi
    if (( behind_nat )); then
        say ""
        say "   Note the two numbers are not the same. The world sees $PUBLIC_IP; this server"
        say "   calls itself $PRIMARY_IP. Option 1 wants the first, option 2 wants the second."
    fi
}

# ---------------------------------------------------------------------------------------------
# The four questions
# ---------------------------------------------------------------------------------------------
gather() {
    step "What this hub should be"

    if [[ -z "$HOSTNAME_IN" ]]; then
        say "   The hub needs a name of its own that points at this server - something like"
        say "   hub.yourbusiness.co.uk. Add the DNS record first if you have not yet."
        say ""
        say_the_address
        say ""
        HOSTNAME_IN="$(ask 'Hostname for this hub')"
    fi
    [[ -n "$HOSTNAME_IN" ]] || die "Without a hostname there is nothing to put a certificate on."
    HOSTNAME_IN="${HOSTNAME_IN#http://}"
    HOSTNAME_IN="${HOSTNAME_IN#https://}"
    HOSTNAME_IN="${HOSTNAME_IN%%/*}"

    # -----------------------------------------------------------------------------------------
    # An IP address, which is the obvious thing to try and does not work.
    #
    # **No public certificate authority will certify a bare IP address.** Caddy knows this, so
    # instead of asking Let's Encrypt it quietly issues its own - a certificate signed by "Caddy
    # Local Authority", which nothing on earth trusts. That is worse than an error, because the
    # screens still load once a browser warning is clicked through, so the hub looks installed.
    #
    # The agent is where it actually bites. It verifies certificates properly and has no option
    # to skip that, so every check-in fails and the machine never reports. Somebody would install
    # the hub, install an agent, and watch a machine that never turns green, with nothing
    # anywhere saying why.
    #
    # So it is named here, before any of it happens.
    # -----------------------------------------------------------------------------------------
    if [[ "$HOSTNAME_IN" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        IP_MODE=1
        say ""
        fail "$HOSTNAME_IN is an IP address, so this hub's certificate will not be trusted."
        say ""
        say "   No certificate authority will issue a certificate for a bare IP address, so Caddy"
        say "   signs its own instead. Browsers show a warning you can click through. Agents"
        say "   cannot click through anything: they verify properly and have no option to skip"
        say "   it, so a machine will not check in until it has been told to trust this hub."
        say ""
        say "   That is one command per monitored machine, and it does work - but it is a thing"
        say "   you must remember on every machine for ever, which is why a real name is better."
        say ""
        say "   You need a name. Any of these works and none costs anything:"
        say ""
        say "     - A subdomain of a domain you already own, pointed at this server."
        say "       hub.yourbusiness.co.uk is the usual answer and takes two minutes."
        say ""
        say "     - A free name from DuckDNS (duckdns.org), which is built for exactly this."
        say "       You get something like yourname.duckdns.org pointed at this server."
        say ""
        say "   Names like <ip>.nip.io resolve correctly but are a poor idea here: every user of"
        say "   nip.io in the world shares one Let's Encrypt rate limit, so the certificate often"
        say "   simply will not issue. DuckDNS does not have that problem."
        say ""
        say "   Carrying on is fine if you only want to look at the screens. The hub will run and"
        say "   you can sign in past a browser warning - but do not install an agent against it."
        say ""
        confirm "Carry on with $HOSTNAME_IN, screens only?" \
            || die "Point a name at this server, then run this again."
        note "Carrying on. Agents will not work against this hub."
    else
        [[ "$HOSTNAME_IN" == *.* ]] \
            || die "That does not look like a full name. It needs to be one the internet can resolve, like hub.yourbusiness.co.uk"
    fi

    if [[ -z "$EMAIL" ]]; then
        say ""
        say "   Your sign-in account. Certificate expiry notices go here too, so use an address"
        say "   somebody reads."
        say ""
        EMAIL="$(ask 'Your email address')"
    fi
    [[ "$EMAIL" == *@*.* ]] || die "That does not look like an email address."

    if [[ -z "$ORG" ]]; then
        say ""
        say "   Your organisation, as it will appear at the top of the screens. If you look after"
        say "   other people's machines, this is you rather than them."
        say ""
        ORG="$(ask 'Your organisation' 'My organisation')"
    fi

    ok "hub at $HOSTNAME_IN, signing in as $EMAIL"
}

# ---------------------------------------------------------------------------------------------
# Does the name actually point here?
#
# **This is the failure that costs people an evening.** Caddy asks Let's Encrypt for a
# certificate the moment it starts, and Let's Encrypt proves ownership by connecting back to
# whatever the name resolves to. If the record is missing or still points somewhere else, the
# challenge fails, Caddy retries with a growing backoff, and the hub serves nothing at all - which
# reads exactly like a broken install rather than a missing DNS record.
#
# Worth thirty seconds here to save that.
# ---------------------------------------------------------------------------------------------
check_dns() {
    (( SKIP_DNS )) && { note "Skipping the DNS check because you asked."; return 0; }
    (( IP_MODE ))  && { note "No DNS check needed: that is an address rather than a name."; return 0; }

    step "Checking that $HOSTNAME_IN points at this server"

    local resolved=""
    if command -v getent >/dev/null 2>&1; then
        resolved="$(getent ahostsv4 "$HOSTNAME_IN" 2>/dev/null | awk '{print $1; exit}')"
    fi
    if [[ -z "$resolved" ]] && command -v dig >/dev/null 2>&1; then
        resolved="$(dig +short "$HOSTNAME_IN" A 2>/dev/null | tail -1)"
    fi

    if [[ -z "$resolved" ]]; then
        fail "$HOSTNAME_IN does not resolve to anything yet."
        say  ""
        say  "   Add an A record for $HOSTNAME_IN, wait a few minutes, and run this again."
        say  "   Until it resolves, Let's Encrypt cannot issue a certificate and the hub will"
        say  "   serve nothing."
        say  ""
        say_the_address
        say  ""
        confirm "Carry on without it?" || exit 1
        return 0
    fi

    # On a VPS the public address is usually on an interface. Where it is not, ask outside.
    # Both come from find_addresses, which the hostname prompt has already called, so this costs
    # nothing the second time.
    find_addresses

    if [[ -n "$LOCAL_IPS" && " $LOCAL_IPS " == *" $resolved "* ]]; then
        ok "$HOSTNAME_IN resolves to $resolved, which is this server"
        return 0
    fi

    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" == "$resolved" ]]; then
        ok "$HOSTNAME_IN resolves to $resolved, which is this server"
        return 0
    fi

    fail "$HOSTNAME_IN resolves to $resolved, which does not look like this server."
    say  ""
    [[ -n "$PUBLIC_IP" ]] && say "   This server appears to be $PUBLIC_IP."
    say  "   If the record was only just changed it may not have caught up yet."
    say  ""
    say  "   Carrying on will start the hub, but Let's Encrypt will refuse the certificate until"
    say  "   the name points here, so nothing will be reachable over HTTPS."
    say  ""
    confirm "Carry on anyway?" || die "Point $HOSTNAME_IN at this server, then run this again."
}

# ---------------------------------------------------------------------------------------------
# Writing it out
# ---------------------------------------------------------------------------------------------
generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -d '\n'
    else
        # No openssl on a minimal image. urandom is the same entropy, and the character set is
        # trimmed so the value cannot upset a compose file or a connection string.
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40
    fi
}

# ---------------------------------------------------------------------------------------------
# Is this the file this installer was published with?
# ---------------------------------------------------------------------------------------------
# Refuses rather than warns. A warning on a screen somebody is not reading, about a file that is
# about to be run as root by Docker, is not a safety feature.
sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        printf ''
    fi
}

verify() {
    local path="$1" name="$2" expected actual

    case "$name" in
        docker-compose.yml) expected="$EXPECTED_COMPOSE_SHA256" ;;
        Caddyfile)          expected="$EXPECTED_CADDYFILE_SHA256" ;;
        *)                  return 0 ;;
    esac

    actual="$(sha_of "$path")"

    if [[ -z "$actual" ]]; then
        # Neither tool present is vanishingly rare and is not a reason to stop, but it is a reason
        # to say out loud that the check did not happen. Silence here would read as a pass.
        note "Could not check $name: this server has neither sha256sum nor openssl."
        return 0
    fi

    [[ "$actual" == "$expected" ]] && return 0

    fail "$name is not the file this installer expects."
    say  ""
    say  "  expected  $expected"
    say  "  got       $actual"
    say  ""
    say  "  Two things do this. The ordinary one is a cache or a CDN handing out a stale"
    say  "  file, in which case waiting a few minutes and running this again fixes it."
    say  ""
    say  "  The other is that the file was changed between us publishing it and you"
    say  "  downloading it. This installer will not write a compose file it cannot"
    say  "  account for, because Docker runs it as root."
    say  ""
    say  "  The published checksums are at:"
    say  "    https://github.com/redkite-info/redkite-hub/blob/main/SHA256SUMS"
    say  ""
    say  "  If they match what you have and this still fails, tell us:"
    say  "  contact@redkite.info"
    printf '\nNothing is running that this cannot be run again over.\n'
    exit 1
}

install_files() {
    step "Fetching the hub"

    mkdir -p "$DIR" || die "Could not make $DIR."

    # -sSL, never -f. With -f curl throws the body away on an error, and the body is where the
    # server says what is actually wrong.
    for f in docker-compose.yml Caddyfile; do
        curl -sSL "$REPO_RAW/$f" -o "$DIR/$f" \
            || die "Could not download $f. Check this server has outbound HTTPS."
        [[ -s "$DIR/$f" ]] || die "$f came back empty, which usually means a proxy in the way."
        verify "$DIR/$f" "$f"
        ok "$f"
    done

    if [[ -f "$DIR/.env" ]]; then
        note "There is already an .env here, so its database password is being kept."
        note "Delete $DIR/.env first if you want to start completely fresh."
        # Re-write only the settings that were asked for, leaving the password and any alerting
        # credentials alone. Losing the password would orphan the existing database volume.
        local pw
        pw="$(grep -E '^POSTGRES_PASSWORD=' "$DIR/.env" | cut -d= -f2- )"
        [[ -n "$pw" ]] || die "The existing .env has no POSTGRES_PASSWORD in it. Move it aside and run this again."
        write_env "$pw"
    else
        write_env "$(generate_password)"
    fi

    chmod 600 "$DIR/.env"
    ok ".env written, readable only by root"
}

write_env() {
    local pw="$1"
    cat > "$DIR/.env" <<EOF
# Written by the Red Kite installer. Safe to edit; run docker compose up -d afterwards.
#
# **Keep this file.** The database password below is the only way back into the data.

HUB_HOSTNAME=$HOSTNAME_IN
ADMIN_EMAIL=$EMAIL
ACME_EMAIL=$EMAIL
ORGANISATION_NAME=$ORG
POSTGRES_PASSWORD=$pw

# Which version to run. Blank means latest, which is right while you are trying it. Pin one once
# the hub is watching anything you care about, so an update is something you choose.
REDKITE_VERSION=

# Who watches the watcher. The hub pings this on a timer, and withholds the ping when its own
# sweep is not really running - so the outside service notices a hub that is up but not working,
# not just one that has stopped. Healthchecks.io's free tier is enough.
HEALTHCHECKS_PING_URL=

# Alerting. All optional, and the hub says on its own health screen when it cannot send rather
# than failing quietly. Add a channel once you have seen a machine check in.
EMAIL_PROVIDER=
ALERT_FROM_ADDRESS=
EMAIL_API_KEY=
SMTP_HOST=
SMTP_PORT=
SMTP_USERNAME=
SMTP_PASSWORD=
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM_NUMBER=
PUSHOVER_APPLICATION_TOKEN=
EOF
}

# ---------------------------------------------------------------------------------------------
# Starting it
# ---------------------------------------------------------------------------------------------
start_hub() {
    step "Starting the hub"

    cd "$DIR" || die "Could not enter $DIR."

    # -----------------------------------------------------------------------------------------
    # Pulling is checked on its own, because it fails for reasons that have nothing to do with
    # the containers and are not visible in any container log.
    #
    # The first run of this on a clean server stopped here with "unauthorized", and the message
    # that followed told the operator to read `docker compose logs` - which was empty, because no
    # container had ever been created. Pointing somebody at an empty log when the registry has
    # already said exactly what is wrong is the sort of unhelpfulness this product exists not to
    # do.
    # -----------------------------------------------------------------------------------------
    local pull_log="$DIR/.pull.log"
    if ! docker compose pull >"$pull_log" 2>&1; then
        if grep -qiE 'unauthorized|denied|manifest unknown|not found' "$pull_log"; then
            fail "The Red Kite hub image could not be downloaded."
            say  ""
            say  "   The registry at ghcr.io refused the request. That is one of two things, and"
            say  "   neither is anything you have done wrong:"
            say  ""
            say  "     - The image is not published yet. That is ours to fix, not yours."
            say  "       Write to contact@redkite.info and say the hub image is unauthorised."
            say  ""
            say  "     - This server cannot reach ghcr.io. Check outbound HTTPS is allowed, and"
            say  "       any proxy the machine is behind:"
            say  ""
            say  "           curl -sSI https://ghcr.io/v2/ | head -1"
            say  ""
            say  "   Nothing has been started. $DIR can be deleted, or left for another attempt."
            exit 1
        fi

        fail "Could not download the images needed to run the hub."
        say  ""
        tail -8 "$pull_log" | sed 's/^/   /'
        say  ""
        exit 1
    fi
    rm -f "$pull_log"
    ok "images downloaded"

    # -----------------------------------------------------------------------------------------
    # The schema goes in BEFORE anything starts serving.
    # -----------------------------------------------------------------------------------------
    # This used to happen as part of seeding, which runs after `up -d` - so on every single fresh
    # install the hub served for the better part of a minute against an empty database. The sweep
    # begins five seconds after boot, found no tables, and the first thing a new customer saw on
    # the hub screen was:
    #
    #     The last sweep failed: 42P01: relation "checks" does not exist POSITION: 672
    #
    # It recovered on the next tick and nothing was wrong. But it is a raw Postgres error on the
    # first screen somebody ever sees, on a product whose whole promise is saying plainly what it
    # knows - and "the sweep has not reported yet" is, for that minute, perfectly true and quite
    # alarming. Migrating first costs a few seconds and removes the whole episode.
    #
    # Seeding still migrates as well. It is idempotent, and a second opinion costs nothing.
    printf '   preparing the database'
    if docker compose run --rm hub --migrate >"$DIR/.migrate.log" 2>&1; then
        printf '\n'
        ok "the schema is ready"
        rm -f "$DIR/.migrate.log"
    else
        printf '\n'
        # Not fatal. Seeding will try again, and the sweep survives a schema that arrives late -
        # it did before this step existed. Saying so is better than stopping a working install.
        note "The database was not prepared ahead of time; seeding will do it instead."
        tail -4 "$DIR/.migrate.log" 2>/dev/null | sed 's/^/         /'
        rm -f "$DIR/.migrate.log"
    fi

    if ! docker compose up -d 2>&1 | sed 's/^/   /'; then
        fail "The images are here but the containers did not start."
        say  ""
        say  "   The log usually says why in one line:"
        say  ""
        say  "       cd $DIR && docker compose logs --tail 30"
        say  ""
        exit 1
    fi

    printf '   waiting for the hub to answer'
    local state=""
    for _ in $(seq 1 60); do
        state="$(docker inspect --format '{{.State.Health.Status}}' redkite-hub 2>/dev/null || echo missing)"
        [[ "$state" == "healthy" ]] && break
        printf '.'
        sleep 5
    done
    printf '\n'

    if [[ "$state" != "healthy" ]]; then
        fail "The hub started but is not answering yet (it says: $state)."
        say  ""
        say  "   It may just be slow on a small server. Give it a minute and check:"
        say  ""
        say  "       cd $DIR && docker compose ps"
        say  "       cd $DIR && docker compose logs --tail 30 hub"
        say  ""
        exit 1
    fi
    ok "the hub is running and answering"
}

# ---------------------------------------------------------------------------------------------
# The first account
#
# Seeding never overwrites, so running the installer again over a working hub is safe: the second
# run says there is already a customer here and changes nothing, rather than quietly reissuing a
# token and breaking the agents using the old one.
# ---------------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------------------
# The hub is a server too, so it is the first thing watched
# ---------------------------------------------------------------------------------------------
# A fresh hub used to finish with an empty Now screen and an instruction to go and find a machine.
# The most obvious machine in the world was the one it had just been installed on, and leaving it
# out taught people that the first screen they ever see is empty.
#
# **What this does and does not buy, because the distinction matters.** The hub watching itself
# catches *unwell* - a filling disk, a mirror running on one leg, memory going, a filesystem gone
# read-only - and those are real and worth having. It cannot catch *absent*: if this server dies,
# its agent stops checking in and the sweep that would notice is dead along with it. That is what
# the external dead-man's switch is for (step 3 of Next), and nothing here replaces it.
#
# Everything below is best-effort. **A hub that works must not fail to install because the agent
# did not.** Every failure here is a note and a sentence about what to do, never an exit.
watch_self() {
    if (( SKIP_SELF )); then
        note "Not watching this server, because --skip-self was given."
        return 0
    fi

    step "Watching this server too"

    if [[ -f /etc/redkite/agent.conf ]]; then
        note "The agent is already on this server, so it has been left exactly as it is."
        return 0
    fi

    if [[ -z "$TOKEN_OUT" ]]; then
        note "This hub already had an account, so there is no fresh token here to add a machine"
        note "with. Add this server from the Add a machine screen instead."
        return 0
    fi

    local api="https://$HOSTNAME_IN"

    # ---- can this server reach its own hub at all? -------------------------------------------
    #
    # Not a formality. A hub behind a domestic router, reached by a name pointing at the WAN
    # address, often cannot reach itself by that name - the router will not turn the packet round.
    # Better to find that out here, in one sentence, than to install an agent that never reports.
    if ! curl -sS --max-time 10 -o /dev/null "$api/health" 2>/dev/null; then
        # The ordinary cause on an IP-address hub: Caddy signed its own certificate and nothing on
        # this machine has been told to believe it. We have the root right here, so fix it.
        if docker exec redkite-caddy cat /data/caddy/pki/authorities/local/root.crt \
             > /tmp/rk-root.crt 2>/dev/null && [[ -s /tmp/rk-root.crt ]]; then
            install -m 0644 /tmp/rk-root.crt /usr/local/share/ca-certificates/redkite-hub-local.crt 2>/dev/null
            update-ca-certificates >/dev/null 2>&1
            rm -f /tmp/rk-root.crt
            ok "told this server to trust the hub's own certificate"
        fi
    fi

    if ! curl -sS --max-time 10 -o /dev/null "$api/health" 2>/dev/null; then
        note "This server cannot reach its own hub at $api, so it has not been added."
        note "That is usually a router that will not turn a packet round to itself. The hub is"
        note "fine and everything else works; add this server from the Add a machine screen."
        return 0
    fi

    # ---- smartmontools, because the agent is about to want it --------------------------------
    #
    # Installed here rather than by the agent's own installer, which deliberately does not put
    # packages on other people's machines. This one is ours, and we are already installing Docker
    # on it. Without it a disk on its way out looks exactly like a healthy one.
    if command -v smartctl >/dev/null 2>&1; then
        ok "smartmontools already here"
    else
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq smartmontools >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q smartmontools >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q smartmontools >/dev/null 2>&1
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive --quiet install smartmontools >/dev/null 2>&1
        fi

        if command -v smartctl >/dev/null 2>&1; then
            ok "smartmontools installed, so disk health can be read"
        else
            note "Could not install smartmontools. The disks will read as 'cannot see' until it is"
            note "there - which is honest, and is not the same as them being well."
        fi
    fi

    # ---- add this server as a machine --------------------------------------------------------
    local customer machine_token response name
    name="$(hostname 2>/dev/null || echo "$HOSTNAME_IN")"

    customer="$(curl -sS --max-time 15 "$api/api/v1/customers" \
        -H "Authorization: Bearer $TOKEN_OUT" 2>/dev/null \
        | grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"' | head -1 \
        | grep -oE '[0-9a-fA-F-]{36}')"

    if [[ -z "$customer" ]]; then
        note "Could not read the customer back from the hub, so this server was not added."
        note "Add it from the Add a machine screen; everything else is running."
        return 0
    fi

    response="$(curl -sS --max-time 20 -X POST "$api/api/v1/machines" \
        -H "Authorization: Bearer $TOKEN_OUT" \
        -H 'Content-Type: application/json' \
        -d "{\"customerId\":\"$customer\",\"name\":\"$name\",\"kind\":\"Server\",\"notes\":\"The hub itself. Added when the hub was installed.\"}" 2>/dev/null)"

    machine_token="$(printf '%s' "$response" | grep -oE 'rk_live_[A-Za-z0-9_-]+' | head -1)"

    if [[ -z "$machine_token" ]]; then
        note "The hub would not issue a token for this server, so it was not added:"
        printf '%s\n' "$response" | head -c 300 | sed 's/^/         /'
        note "Everything else is running. Add it from the Add a machine screen."
        return 0
    fi

    ok "added as \"$name\""

    # ---- and install the agent on it ---------------------------------------------------------
    #
    # Fetched from this hub, which is the copy that matches it. The token goes in as a parameter
    # and is never written anywhere but the agent's own config, which is root-only.
    local agent="/tmp/rk-agent-install.$$.sh"

    if ! curl -sSL --max-time 60 "$api/install.sh" -o "$agent" 2>/dev/null || [[ ! -s "$agent" ]]; then
        rm -f "$agent"
        note "Could not fetch the agent from $api/install.sh, so this server has a machine record"
        note "with nothing reporting to it. Install the agent from the Add a machine screen."
        return 0
    fi

    if bash "$agent" --hub "$api" --token "$machine_token" > /tmp/rk-agent.log 2>&1; then
        ok "the agent is installed and has sent its first check-in"
    else
        note "The agent did not install cleanly. The last few lines were:"
        tail -6 /tmp/rk-agent.log 2>/dev/null | sed 's/^/         /'
        note "The machine record exists; install the agent by hand when you have a moment."
    fi

    rm -f "$agent" /tmp/rk-agent.log
}

seed() {
    step "Creating your account"

    local out=""
    out="$(cd "$DIR" && docker compose run --rm hub --seed 2>&1)"

    TOKEN_OUT="$(printf '%s' "$out" | grep -oE 'rk_user_[A-Za-z0-9_-]+' | head -1)"

    if [[ -z "$TOKEN_OUT" ]]; then
        if printf '%s' "$out" | grep -q 'already a customer'; then
            note "This hub already has an account on it, so nothing was changed."
            note "If you have lost the sign-in token, get another with:"
            say  ""
            say  "       cd $DIR && docker compose run --rm hub --reissue-staff-token"
            say  ""
            return 0
        fi
        fail "The account was not created."
        printf '%s\n' "$out" | tail -12 | sed 's/^/   /'
        exit 1
    fi
    ok "$ORG created, with no machines yet"
}

# ---------------------------------------------------------------------------------------------
uninstall() {
    step "Removing the hub"
    [[ -d "$DIR" ]] || die "There is nothing at $DIR."

    say "   This stops and removes the containers. Your data is in a docker volume and is NOT"
    say "   deleted, so the hub can be brought back with docker compose up -d."
    say ""
    confirm "Stop and remove the Red Kite containers?" || exit 0

    ( cd "$DIR" && docker compose down ) || die "docker compose down did not work."

    # If this installer put the agent on this server, this installer takes it off again. Leaving a
    # timer behind that fires every five minutes at a hub which is no longer there would be a
    # strange thing to call "removed" - and its log would fill up saying so.
    if [[ -f /etc/redkite/agent.conf ]]; then
        say ""
        if confirm "Also remove the agent watching this server?"; then
            systemctl disable --now redkite-agent.timer redkite-probe.timer >/dev/null 2>&1
            rm -f /etc/systemd/system/redkite-agent.{timer,service} \
                  /etc/systemd/system/redkite-probe.{timer,service}
            systemctl daemon-reload >/dev/null 2>&1
            rm -rf /etc/redkite /var/log/redkite /var/lib/redkite-probe
            rm -f /usr/local/bin/redkite-agent.sh /usr/local/bin/redkite-probe
            userdel redkite >/dev/null 2>&1
            ok "the agent is gone from this server"
            note "Its machine record is still on the hub. Revoke that machine's token there if"
            note "the hub is going back up without this server on it."
        fi
    fi

    say ""
    say "Done. The files are still in $DIR and the database volume is untouched."
    say "To remove the data as well, and lose it for good:  cd $DIR && docker compose down -v"
    exit 0
}

# =============================================================================================

say "Red Kite - the hub"
say "Machines report to it. It never connects to them."

(( UNINSTALL )) && uninstall

if (( ! INTERACTIVE )) && [[ -z "$HOSTNAME_IN" || -z "$EMAIL" ]]; then
    fail "There is nobody to ask, and --hostname or --email was not given."
    say  ""
    say  "This happens when the script is piped into bash, because bash is then reading the"
    say  "script itself rather than your keyboard. Download it first and run it from a file:"
    say  ""
    say  "    curl -sSL https://redkite.info/hub.sh -o rk-hub.sh"
    say  "    sudo bash rk-hub.sh"
    say  ""
    say  "or pass what it needs and let it ask nothing:"
    say  ""
    say  "    curl -sSL https://redkite.info/hub.sh -o rk-hub.sh"
    say  "    sudo bash rk-hub.sh --hostname hub.yourbusiness.co.uk --email you@yourbusiness.co.uk --yes"
    say  ""
    exit 2
fi

TOKEN_OUT=""

preflight
gather
check_dns
install_files
start_hub
seed
watch_self

say ""
say "================================================================"
say "  Done. Your hub is at https://$HOSTNAME_IN"
say "================================================================"
say ""

if (( IP_MODE )); then
    say "  NOTE. This hub answers on an IP address, so its certificate is"
    say "  one Caddy signed itself and nothing trusts it."
    say ""
    say "    - Your browser will warn you once. That is expected here."
    say "    - An agent will refuse to check in until the machine it runs"
    say "      on trusts this hub. On the hub, take a copy of its root:"
    say ""
    say "        docker exec redkite-caddy cat \\"
    say "          /data/caddy/pki/authorities/local/root.crt > root.crt"
    say ""
    say "      then on each monitored machine, with that file copied over:"
    say ""
    say "        sudo cp root.crt \\"
    say "          /usr/local/share/ca-certificates/redkite-hub-local.crt"
    say "        sudo update-ca-certificates"
    say ""
    say "      That is proved to work. It is also one more thing to"
    say "      remember on every machine for ever, which is the real"
    say "      argument for giving the hub a name instead."
    say ""
    say "  To make it real, point a name at this server - a subdomain of"
    say "  your own domain, or a free one from duckdns.org - and run this"
    say "  again with it. Nothing here is wasted: the database, the"
    say "  settings and your account all stay exactly as they are."
    say ""
fi

say "  Red Kite is in open beta. It is useful and it is not finished."
say "  Please do not make it the only thing watching your machines yet,"
say "  and tell us where it and your existing monitoring disagree -"
say "  contact@redkite.info reaches an engineer, and reports of things"
say "  it got wrong are more welcome than praise."
say ""

# ------------------------------------------------------------------------------------------------
# The last thing on the screen, and the token is in it.
#
# **The token used to be printed above the notes**, which on a hub with an IP address put it behind
# twenty lines about certificates. By the time the install finished it was half a page up, and the
# one thing on this screen that can never be shown again was the one thing you had to scroll for.
#
# It is step one now, because signing in is step one, and because whatever is nearest the prompt is
# what gets read.
# ------------------------------------------------------------------------------------------------

say "  ----------------------------------------------------------------"
say "  Next:"
say ""

if [[ -n "$TOKEN_OUT" ]]; then
    say "    1. Open https://$HOSTNAME_IN and sign in with this token:"
    say ""
    say "           $TOKEN_OUT"
    say ""
    say "       SHOWN ONCE. The hub keeps only a hash of it and cannot"
    say "       tell you again. Copy it somewhere safe now. If it is lost:"
    say "       cd $DIR && docker compose run --rm hub --reissue-staff-token"
else
    say "    1. Open https://$HOSTNAME_IN and sign in."
fi

say ""
if [[ -f /etc/redkite/agent.conf ]]; then
    say "    2. This server is already on it, watching itself. Add the next"
    say "       machine from Add a machine - Linux, Windows or Unraid, each"
    say "       with a guide you can print."
else
    say "    2. Add a machine. The hub gives you the command to run on it,"
    say "       for Linux, Windows or Unraid, and a guide you can print."
fi
say ""
say "    3. Set HEALTHCHECKS_PING_URL in $DIR/.env - something outside"
say "       needs to watch the hub, because a monitor cannot report its"
say "       own absence. Then: cd $DIR && docker compose up -d"
say ""
