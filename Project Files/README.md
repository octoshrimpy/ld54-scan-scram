# Scan-n-Scram

## Overview
Scan-n-Scram is a Godot 4.5 project that prototypes a Star-Trek-inspired expedition. You command a squad of redcoats beamed onto a planet slice, racing to scan minerals, flora, and fauna before hazards force an evacuation. Biomass feeds the replicator to print new crew, so exploration, data gathering, and resource management are tightly linked.

## Current Prototype Highlights
- Procedural isometric terrain (`map.gd`) with layered dirt/stone/water and coastline accents.
- Sprite-based tree generator (`trees.gd`) that bakes branches/leaves into outlined sprites via `TreeOutlineFactory.gd`.
- Boulder cluster generator (`boulders.gd`) for additional surface dressing.
- Free-zoom, drag-pan camera (`camera_2d.gd`) tailored for isometric maps.
- Shared `utils/map_utils.gd` helpers that synchronize map projection and height queries between generators.
- Reusable grid-based pathfinding layer (`utils/navigation_grid.gd`) and agent base class (`utils/pathfinding_agent.gd`) for future fauna/crew movement.

## Controls
- `Mouse Wheel` : Zoom in/out (Camera2D).
- `Middle Mouse + Drag` : Pan camera.
- `R` : Rebuild terrain cube (`map.gd`).
- `Y` : Regenerate forests (`trees.gd`).
- `B` (or `regen_boulders` action) : Regenerate boulders (`boulders.gd`).

## Project Structure
- `main.tscn` – Entry scene, wires terrain, trees, boulders, and camera.
- `map.gd` – Procedural terrain cube generator (now declares `class_name PlanetMap` and exposes `project_iso3d`).
- `trees.gd` – Forest generator with cached map access and shared geometry helpers.
- `boulders.gd` – Stone cluster spawner using the common map utilities.
- `addons/outline/TreeOutlineFactory.gd` – SubViewport baker that outlines compound sprites.
- `shaders/OutlineSilhouette.gdshader` – Outline material used by the bakery.
- `utils/map_utils.gd` – New utility module for isometric projection, z-sorting, and terrain queries.
- `utils/navigation_grid.gd` – Shared A* grid builder that reads the terrain heights.
- `utils/pathfinding_agent.gd` – Base class for moving entities to inherit pathfinding behaviour.

## Getting Started
1. Install **Godot 4.5.x**.
2. Open this folder (`Project Files`) as a project in the Godot editor.
3. Run the default scene to view the procedural terrain, trees, and boulders. Use the hotkeys above to regenerate content while tuning parameters.

## Next Steps
The core world dressing is in place. The TODO roadmap outlines how to expand toward the full Scan-n-Scram experience: player scanning loops, specialist systems, replicator economy, and long-term ship upgrades.
