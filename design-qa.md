# Design QA

- Reference: selected option 2 plus the supplied Xiaomi remote photograph.
- Main layout: passed — native macOS sidebar, large Chinese status header, physical remote ordering, and right-side key inspector.
- Core navigation: passed — remote, app switcher, presets, permissions/startup, and advanced HID debugger are separated.
- Ordinary-user language: passed — engineering fields are absent from the main page and remain in HID debugger.
- Accessibility: passed — native controls, labels, help text, keyboard focus, and Reduce Motion disables nonessential scale, slide, breathing, shake, and fade animations.
- Motion: passed — physical key bounce, inspector transition, save checkmark, dictation pulse, error-only shake, Overlay fade, and app-switcher carousel are UI-only feedback after action dispatch.
- Build gate: Debug BUILD SUCCEEDED; HID manager and matching device both opened successfully during the visual run.

final result: passed
