# Tests compile multiple versions of the same fixture module into separate
# ebin dirs; the second compile of a given module redefines it in the test VM.
Code.compiler_options(ignore_module_conflict: true)

# The :e2e suite boots real OTP releases and is slow; it runs in its own CI job
# (mix test --include e2e), not the default fast suite.
ExUnit.start(exclude: [:e2e])
