# cayennex 🌶️

Naive hot-code upgrades for `mix release`.

`mix release` deliberately ships **no** hot-upgrade story — José Valim dropped
appup/relup support because real OTP hot upgrades are fragile and most teams are
better served by rolling/blue-green restarts. cayennex is for the case where a
restart is *not* acceptable: a single, stateful, massively-realtime node where a
restart drops every live connection. It lets you load **changed code _and_
changed/new dependency applications** onto the running node without a restart.

It is intentionally **naive**: it does the OTP code/dep swap, but throws away the
state-migration ceremony.

## The opinion

A textbook OTP relup does `suspend → code_change → resume` for stateful
processes and `brutal_purge`s old code. cayennex rewrites the generated relup
(`Cayennex.Relup.harden/1`):

- `brutal_purge → soft_purge` — a process still running old code is **not**
  killed; the upgrade just proceeds (and the install reports `:old_processes`,
  which your deploy script turns into a full-deploy fallback).
- **strip `suspend` / `resume` / `code_change`** — no state migration. New code
  runs against the **old** in-process state.

This buys simplicity and avoids cascade-killing live processes, at one price:

> **New code must tolerate old state.** If you change the shape of a struct held
> in a GenServer's state and the new code assumes the new shape, that process
> crashes on its next message. Change behaviour freely; be careful changing what
> a process *remembers*.

This is the right trade only if you don't need state migration. If you do, use
[castle](https://hex.pm/packages/castle) or
[jellyfish](https://hex.pm/packages/jellyfish) instead.

## What it does / doesn't handle on the hot path

| Change | Hot-upgraded? |
|---|---|
| Your own module code (add / change / delete) | ✅ |
| A changed or newly-added dependency application | ✅ |
| GenServer **state shape** changes | ⚠️ no migration — new code must tolerate old state |
| ERTS (Erlang/OTP) version change | ❌ `{:error, :erts_changed}` → full deploy |

## Usage

### 1. Release config (`mix.exs`)

```elixir
defp releases do
  [
    my_app: [
      include_erts: true,
      # release_handler + systools must be on the node:
      applications: [sasl: :permanent],
      # finalize writes releases/RELEASES and releases/<vsn>/my_app.tar.gz:
      steps: [:assemble, &Cayennex.Steps.finalize/1]
    ]
  ]
end
```

A normal `mix release` now also produces a complete ship tarball at
`releases/<vsn>/my_app.tar.gz` and the `RELEASES` index `release_handler` needs.

### 2. Build an upgrade

```bash
MIX_ENV=prod mix release.hot --upfrom=<old_vsn> --old-tarball=<path-to-old.tar.gz>
```

This assembles the new release, overlays the old one from `--old-tarball`,
generates and hardens `releases/<new>/relup`, and repackages the tarball with the
relup inside. It exits non-zero on `{:error, :erts_changed}` so your deploy
script can fall back to a full deploy.

### 3. Install on the running node

Ship the upgrade tarball to `$RELEASE_ROOT/releases/<new_vsn>/my_app.tar.gz`,
then:

```bash
bin/my_app rpc 'Cayennex.Upgrade.install("<new_vsn>")'
```

`install/1` never halts the node — it returns `:ok` / `{:error, reason}` and
prints a greppable `UPGRADE_FAILED` marker. **Your deploy script's post-install
version check is the source of truth**; on failure (including `:old_processes`),
fall back to a full restart deploy.

## Operational notes (read these)

- **Old-code accumulation.** The BEAM keeps at most two versions of a module.
  A long-lived, *idle* process pinned to old code blocks the next upgrade's
  `soft_purge` → forced full deploy. Busy processes migrate to new code on their
  next message; consider poking idle long-lived processes after an upgrade, and
  measure exposure with `:erlang.check_process_code/2`.
- **Verify, then roll back.** A hot upgrade can install green and then crash-loop
  minutes later (new code meets incompatible old state). A version re-check
  alone won't catch that — watch for post-install instability and roll back.
- **No closures in long-lived state.** An anonymous function captured under old
  code keeps running old code after an upgrade. Don't stash `fn`s in GenServer
  state you expect to upgrade.

## Lineage

The appup/relup generation is ported from
[Distillery](https://github.com/bitwalker/distillery) (appup BEAM-diffing,
relup via `:systools`), adapted to `mix release` layout and hardened for naive
upgrades. The install path is ported from Distillery's runtime control, minus
the peer/halt machinery.

## License

MIT
