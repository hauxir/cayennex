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
| A child **added** to a managed supervisor | ✅ started at runtime (opt-in, see below) |
| A child **removed** from a managed supervisor | ✅ terminated at runtime with `prune: true`; otherwise reported and left running |
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

## Adding or removing a service in a supervisor without a restart

A relup hot-loads new *code*, but because cayennex strips the supervisor
`code_change` (the same strip that preserves state), OTP never re-runs your
supervisor's `init/1` — so a child you **add** to a root supervisor between
releases is compiled and loaded onto the node but never *started*, and a child
you **remove** keeps running. The upgrade goes green but the supervision tree is
unchanged.

`Cayennex.Supervisors` closes that gap at runtime. List the supervisors it
should manage:

```elixir
# config/runtime.exs (or config.exs)
config :cayennex, :supervisors, [
  Myapp.RootSupervisor,                            # registered name == callback module
  {MyName, Myapp.OtherSupervisor, :ok},            # {registered_name, callback_module, init_arg}
  {Myapp.PoolSupervisor, Myapp.PoolSupervisor, :ok, prune: true}  # also terminate removed children
]
```

After every `Cayennex.Upgrade.install/1`, cayennex asks each listed supervisor's
freshly hot-loaded `init/1` for its desired children, diffs against what's
actually running (`Supervisor.which_children/1`), and `start_child`s the
additions — logging `==> reconcile <Sup>: started [...]`.

**Removal is opt-in, per supervisor.** By default reconcile is *add-only*: a
child dropped from `init/1` is reported (`removed_kept`) but never terminated, on
the assumption it may hold the live connections this node exists to keep. Pass
`prune: true` (the 4th element of the full `{name, module, init_arg, opts}` form)
and cayennex will instead `terminate_child` + `delete_child` the dropped children
— logging `==> reconcile <Sup>: pruned [...]`. Only enable it for supervisors
where terminating a removed child is actually safe.

Neither adding nor pruning can block the install: a failure to start *or* prune
a child prints a greppable `RECONCILE_FAILED` marker and reconcile moves on —
your healthcheck should confirm the service is up (or gone), just as it confirms
the version.

Two requirements:

- The supervisor must be a **named `use Supervisor` (or `:supervisor`) module**
  with an `init/1` — an inline `Supervisor.start_link([...], ...)` in your
  `Application` has no callback module to re-consult.
- The configured `init_arg` must match what you pass to `Supervisor.start_link/3`
  (it's what `init/1` turns into the child list; irrelevant if `init/1` ignores it).

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
