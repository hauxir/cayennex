# Tests compile multiple versions of the same fixture module into separate
# ebin dirs; the second compile of a given module redefines it in the test VM.
Code.compiler_options(ignore_module_conflict: true)

ExUnit.start()
