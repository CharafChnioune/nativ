# CI compiler compatibility

The full local Xcode 27.2 build and native tests passed. The Xcode 26.6 CI
compiler then crashed during IR generation in `GenerationPlaybackCoordinator`,
while emitting `@$sSdScA_pSgIeAghyg_SdIeAghn_TR` (the Double actor-method
reabstraction thunk). The failure was in workflow run 42528911219, job
128878700878, at source revision 457303607fe36e639391464d7527a58e0066101f.

Both seek sliders used a bound actor method directly as `Binding`'s setter.
They now use an explicit closure calling the same method. This keeps seek,
clamping and actor ownership unchanged while avoiding the failing conversion.
No compiler version, validation requirement or test is disabled. The final
exact-revision Xcode 26.6 CI result is required before merging; a passing local
27.2 build alone does not establish compatibility with that compiler.
