# TODO Roadmap

## Phase 1 – Planetfall Prototype
- [ ] Implement landing/evac flow with timer pressure and basic mission success/fail states.
- [ ] Build player command interface for directing redcoats and triggering scan actions on minerals/flora/fauna props.
- [ ] Stand up scanning feedback: progress bars, data logs, and quota tracking HUD.
- [ ] Integrate environmental hazard loop (e.g., toxic zones, hostile creatures) that chips away at crew safety.

## Phase 2 – Crew & Specialists
- [ ] Hook biomass loot into a replicator economy that prints replacement redcoats.
- [ ] Add specialist roles (minerologist, botanist, xenobiologist) with two expertise tiers and role-gated interactions.
- [ ] Expose extensive character customization (palette swaps, gear, insignia) tied to specialist loadouts.
- [ ] Create crew management UI for roster assignment, injuries, and evac status.

## Phase 3 – Ship & Progression
- [ ] Design ship upgrade tree that unlocks scanners, hazard suits, and replicator efficiencies.
- [ ] Author planet generation presets with escalating deadlines and required quotas.
- [ ] Track campaign-level progress: rewards, narrative beats, and new mission unlocks.
- [ ] Persist mission analytics for post-run debrief (scan counts, casualties, resource breakdown).

## Phase 4 – Content & Polish
- [ ] Replace placeholder sprites with final isometric pixel art for terrain, crew, and props.
- [ ] Add audio pass: UI beeps, scanner sweeps, ambient planet beds, evacuation alarms.
- [ ] Layer tutorial beats and narrative VO/text to onboard players into the Scan-n-Scram workflow.
- [ ] Perform balancing, optimization, and QA for the full mission loop.

## Tech Debt – Redshirts & Map Sync
- [x] Refresh `RedshirtAgent` map bounds (and pause wandering) whenever the planet node rebuilds so `_map_dims` and `_map_ref` never go stale.
- [x] Cache iso projections/height samples inside `_build_hop_segments()` to avoid repeated `MapUtils` queries per hop segment.
- [x] Rework `RedshirtSpawner` to avoid scanning every tile each spawn; cache land cells or short-circuit once enough dry cells are gathered.
- [x] Detect planet refreshes, despawn existing redshirts, and respawn them once the new terrain is ready.
- [x] Add a Star Trek–style beam-down effect at the spawn epicenter when new redshirts materialize.

## Tech Debt – Rendering & Dressing
- [ ] Finish `TreeGen._outline_entire_tree()` in `trees.gd` so groves bake to a single outlined sprite per tree and builder nodes are freed even when `trunks_root` is a separate node; right now the stub leaves dozens of Sprite2D children per tree and skips the intended outline pass.
- [ ] Replace the Sprite2D-per-voxel terrain renderer in `map.gd` with chunked TileMapLayers or MultiMesh batches so rebuilds stop instantiating tens of thousands of sprites, which currently spikes rebuild time and draw calls on every slice.
- [x] Thread `PlanetMap.rng_seed` into `TreeGen`, `BoulderGen`, and `RedshirtSpawner` so new slices are reproducible—each generator currently randomizes independently via global RNG, making a saved seed insufficient to recreate a planet's dressing.

## Tech Debt – Navigation & Controls
- [ ] Have `PlanetMap` emit a `map_rebuilt` signal and let `NavigationGrid` / `PathfindingAgent` listen so cached walkability masks and path targets rebuild automatically instead of pathing on stale grids after a new slice.
- [x] Implement a proper iso-to-grid `world_to_cell()` helper (either on `PlanetMap` or `NavigationGrid`) so `PathfindingAgent.world_to_cell()` stops brute-forcing every cell in the region on each call (`utils/pathfinding_agent.gd`).
- [ ] Give redshirts proper A* pathfinding (shared nav grid, deterministic walkability masks) so they route around obstacles instead of relying on random wandering.
