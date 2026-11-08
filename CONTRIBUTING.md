# Contributing

Pull requests are welcome when they preserve the project's safety boundaries.

1. Do not add firmware, proprietary binaries, private keys, credentials, real
   device identifiers, private inventory archives, or local configuration.
2. Do not weaken fail-closed guards, request allowlists, rollback, or
   `verify-clean` checks.
3. Add an offline regression test for every changed branch.
4. Run the client suite with
   `python -m unittest discover -s client/tests -t client -v`.
5. Run the production controller harness with
   `pwsh -NoProfile -File tests/run_full_matter_controller_audit.ps1`.
6. Run publication and link checks from `tools/`.

Hardware tests must remain explicit opt-in procedures. They must never run in
CI or as an implicit part of an offline test command.
