import Testing

/// Every e2e test lives in a suite nested in `E2E`, so they run one at a time:
/// they share `NSApplication` and its main menu.
@Suite(.serialized)
struct E2E {}
