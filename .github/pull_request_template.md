<!-- Thanks for contributing! A few quick checks before you hit submit. -->

### What this PR does

<!-- One or two sentences. -->

### Why

<!-- What problem does it solve? Link to an issue if there is one. -->

### How to test

```bash
xcodegen generate
xcodebuild -project AirAssist.xcodeproj -scheme AirAssist \
           -destination 'platform=macOS' test
```

Manual steps (if any):

1.
2.

### Checklist

- [ ] `xcodebuild test` passes locally
- [ ] I installed the pre-commit hook (`./scripts/install-hooks.sh`)
- [ ] No references to third-party commercial apps by name
- [ ] UI-facing strings use "Air Assist" (two words), not "AirAssist"
- [ ] If this adds a preference, it has a sensible default
- [ ] If this touches throttling, it was tested against a real
      `yes > /dev/null` process

### Screenshots / video

<!-- Any UI change should include a before/after. -->
