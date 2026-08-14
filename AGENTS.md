# Project agent instructions

## Desktop isolation

- Do not launch, control, capture, or otherwise interact with the user's desktop or graphical applications.
- Use headless command-line and test workflows only.
- If verification requires GUI automation, Accessibility, Screen Recording, or opening a window, report it as blocked instead of attempting a manual fallback.
- Exception: when the user explicitly requests installation or an upgrade, NeoAnki2 may be terminated if needed for a safe upgrade and launched exactly once after the upgrade completes. Do not perform any other GUI interaction or relaunch it more than once.
