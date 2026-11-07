# Independent modern wrapper test bundle

This fixed directory is the version2 selected-test source on both branches.
It contains modern canonical16+16 and the full modern additive suite, including
reload regressions. It requires a compatible modern product and verified payload;
an old product lacking reload APIs is not silently exempted.

Ordinary tests remain in tests/Wss.CSharpImplementation.Tests. Profile preparation
preserves main legacy10 and its complete original suite without compiling this
directory. No product/payload adoption is implied. Selected activation remains
separate, requires authenticated Core context, and is not enabled by this manifest.

The reviewed generated runner compiles only these C# source files. There is no
selectable project/validator/build configuration. Update this bundle explicitly
when adding selected regressions; ordinary coverage remains independently required.
