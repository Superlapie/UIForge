# Platform policy

UIForge targets **Windows** as its primary end-user platform. **Linux** is also first-class and commonly used for development.

Changes to filesystem, process, path, CLI, locking, transaction, scene-loading, or packaging behavior must be verified on **native Windows and native Linux CI** before release.

## Release-blocking expectations

- Windows-native Godot behavior is release-blocking.
- Linux-native Godot behavior is release-blocking.
- Python portable tests are supplemental; they do not substitute for native GDScript/Godot tests on either platform.
- Linux behavior does **not** define the production portability contract by itself.

## CI jobs

| Job | Platform | Scope |
|-----|----------|-------|
| `portable-linux` | Ubuntu | Python portable suite |
| `portable-windows` | Windows | Python Windows trust tests |
| `godot-linux` | Ubuntu | Full native Godot suite via `./scripts/test` |
| `godot-windows` | Windows | Native trust suite via `./scripts/test_trust` |

Do not treat Windows-native filesystem or trust gaps as acceptable documented deviations unless they truly cannot reasonably be solved.
