# Contributing

## Tooling
- Engine: Godot `4.6.x` (matches `project.godot` feature set).
- Recommended editor defaults come from [`.editorconfig`](./.editorconfig).

## Local Dev Loop
1. Open the `Project Files` folder in Godot.
2. Run `main.tscn`.
3. Use in-game hotkeys (`R`, `Y`, `B`) to rebuild terrain/trees/boulders while iterating.

## Sanity Checks Before PRs
- Open the project in Godot and confirm no script parse errors.
- Run one terrain rebuild and one dressing rebuild in play mode.
- Verify agent movement still works where `NavigationGrid` is used.

## Code Style
- Prefer typed variables and typed return values in GDScript.
- Keep reusable map queries in `utils/map_utils.gd` instead of duplicating reflection logic.
- Favor small utility classes in `utils/` over adding more responsibilities to `map.gd`.

## High-Value Refactor Targets
- `map.gd` currently mixes world generation, rendering, and input orchestration.
- Interaction handling is split between `trees.gd` and `boulders.gd`.
- `TODO.md` tracks active debt items and roadmap phases.
