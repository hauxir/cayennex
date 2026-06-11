import Config

# Tell cayennex which supervisor to reconcile on the hot path: a child added to
# its `init/1` between releases gets started on the running node, and with
# `prune: true` a child dropped from `init/1` gets terminated + deleted (the E2E
# test adds a child in v2, then removes it in v3).
config :cayennex, :supervisors, [{Myapp.RootSupervisor, Myapp.RootSupervisor, :ok, prune: true}]
