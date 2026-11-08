# Translate restart lease triage

The failing supervisor restart test timed out waiting for its second fixture launch. Actual Swift 6/Foundation reproduction confirmed `Process.standardInput` retains the parent duplicate of the compute descriptor after child exit. `lease.close()` alone therefore leaves flock busy while the previous Process remains retained by an older launch task. Explicitly closing that duplicate permits the next acquisition immediately.

`GenerationComputeLease.runOwnedProcess` now creates the inherited descriptor, runs the Process and closes the parent duplicate in a defer immediately after spawn, including launch errors. Both cascade and direct speech runtime use it. The child keeps its actual dup2 descriptor until exit. Added `testExitedOwnedProcessCannotRetainParentComputeDescriptorAcrossRestart` to TranslationCascadeRuntimeTests; no timeout increase or fixture weakening.

Independent standalone actual Swift6 compiler/Foundation smoke passed: a live sleep child keeps admission after native lease close; child exit frees admission even while the old Process is explicitly retained; the next lifecycle acquires successfully. Log: cascade-lease-repro/result.log. No Xcode/DerivedData or model work was run by this agent. Parent runs the actual targeted XCTest before completion.
