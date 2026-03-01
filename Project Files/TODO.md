# TODO Roadmap

## Phase 1 – Planetfall Prototype
- [ ] Implement landing/evac flow with timer pressure and basic mission success/fail states.
- [ ] Build player command interface for directing redcoats and triggering scan actions on minerals/flora/fauna props.
- [ ] Stand up scanning feedback: progress bars, data logs, and quota tracking HUD.
- [ ] Integrate environmental hazard loop (e.g., toxic zones, hostile creatures) that chips away at crew safety.
- [ ] Split `PlanetMap`'s world-gen/input duties into a lightweight `SliceGenerator` plus `MissionDirector` so landing timers and hazards do not bolt onto the monolithic script (map.gd:18-222, 700-717).
- [ ] Consolidate the POI highlight/click pipelines from `trees.gd` and `boulders.gd` into a shared interaction service to give the scanning/command UI one entry point (trees.gd:8-15, boulders.gd:6-16).

## Phase 2 – Crew & Specialists
- [ ] Hook biomass loot into a replicator economy that prints replacement redcoats.
- [ ] Add specialist roles (minerologist, botanist, xenobiologist) with two expertise tiers and role-gated interactions.
- [ ] Expose extensive character customization (palette swaps, gear, insignia) tied to specialist loadouts.
- [ ] Create crew management UI for roster assignment, injuries, and evac status.
- [ ] Introduce persistent `CrewMember` data separate from the spawned Sprite2D nodes so replicator output, injuries, and perks have somewhere to live (utils/redshirt_system.gd:136-205).
- [ ] Rework `redshirt_spawner.gd`'s atlas-based outfit picker into modular body/gear layers to support palette swaps and specialist uniforms (utils/redshirt_spawner.gd:5-80).

## Phase 3 – Ship & Progression
- [ ] Design ship upgrade tree that unlocks scanners, hazard suits, and replicator efficiencies.
- [ ] Author planet generation presets with escalating deadlines and required quotas.
- [ ] Track campaign-level progress: rewards, narrative beats, and new mission unlocks.
- [ ] Persist mission analytics for post-run debrief (scan counts, casualties, resource breakdown).
- [ ] Promote the height/noise/export soup in `map.gd` into serializable `PlanetPreset` resources so ship upgrades can swap entire terrain configs instead of editing script constants (map.gd:54-170, ui/terrain_controls.gd:1-120).
- [ ] Add a run-level persistence/telemetry service that snapshots map/forest/boulder stats before every rebuild so campaign analytics have source data (map.gd:10-31, utils/terrain_builder.gd:31-112).

## Phase 4 – Content & Polish
- [ ] Replace placeholder sprites with final isometric pixel art for terrain, crew, and props.
- [ ] Add audio pass: UI beeps, scanner sweeps, ambient planet beds, evacuation alarms.
- [ ] Layer tutorial beats and narrative VO/text to onboard players into the Scan-n-Scram workflow.
- [ ] Perform balancing, optimization, and QA for the full mission loop.
- [ ] Replace the per-tree runtime outline bake with cached MultiMesh/texture batches so final art swaps stop instantiating dozens of sprites per tree (trees.gd:1-220, addons/outline/TreeOutlineFactory.gd).
- [ ] Centralize SFX/music triggers behind an audio service instead of sprinkling ad-hoc `AudioStreamPlayer`s when hazards/UI arrive, keeping the mix consistent across the campaign (no current audio layer).

## Tech Debt – Rendering & Dressing
- [ ] Finish `TreeGen._outline_entire_tree()` in `trees.gd` so groves bake to a single outlined sprite per tree and builder nodes are freed even when `trunks_root` is a separate node; right now the stub leaves dozens of Sprite2D children per tree and skips the intended outline pass.
- [ ] Replace the Sprite2D-per-voxel terrain renderer in `map.gd` with chunked TileMapLayers or MultiMesh batches so rebuilds stop instantiating tens of thousands of sprites, which currently spikes rebuild time and draw calls on every slice.

## Tech Debt – Navigation & Controls
- [ ] Give redshirts proper A* pathfinding (shared nav grid, deterministic walkability masks) so they route around obstacles instead of relying on random wandering.
