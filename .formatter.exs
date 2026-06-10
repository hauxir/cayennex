# Exclude test/fixtures/** — those are standalone fixture projects whose sources
# the E2E test rewrites; cayennex's formatter should not police them.
[
  inputs: [
    "{mix,.formatter}.exs",
    "lib/**/*.{ex,exs}",
    "test/**/*_test.exs",
    "test/test_helper.exs"
  ]
]
