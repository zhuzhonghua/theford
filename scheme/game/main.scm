;; main.scm — The Ford (渡口) game logic: module manifest.
;;
;; Layer rule (plan_oss_edu_game.md section 3.1):
;;   Godot is presentation and world queries: rendering, input, collision,
;;   pathfinding, UI.
;;   Scheme is the scheduling layer: quest state, NPC schedules, dialogue and
;;   everything that feeds the LLM. It never duplicates world geometry; when it
;;   needs walkability or a path it asks Godot through the bridge.
;;   The LLM turns topics into NPC lines. It proposes; Scheme decides.
;;
;; API used by scripts/game_bridge.gd (defined in the modules below):
;;   game:set-model-path path   (llm.scm)
;;   game:set-ai-quality level  (llm.scm) off|low|medium|high; returns engine-info
;;   game:boot                  (llm.scm)
;;   game:npc-ids               (npcs.scm)
;;   game:topics npc-id         (talk.scm)
;;   game:greet npc-id          (talk.scm)
;;   game:take item-type        (inventory.scm) put one thing into the bag
;;   game:talk npc-id topic     (talk.scm)
;;   game:tick                  (time.scm) advance one tick, returns game:status
;;   game:debug-set-time        (gm.scm) jump the clock, returns game:status
;;   game:debug-advance         (gm.scm) advance N minutes, returns game:status
;;   game:debug-set-weather     (gm.scm) pin/clear weather, returns game:status
;;   game:status                (here) quest text + ore carried + clock + weather
;;   game:quests                (quest.scm) xp + completions + quest log rows
;;   game:quest-target id       (quest.scm) E interaction advances a target objective
;;   game:people                (here) id + current anchor + activity per npc
;;   game:gm-plan text          (gm.scm) LLM turns free text into one GM command
;;   game:reload                (here) re-read data files, reset state
;;   game:register-entities     (entities.scm) replace the per-map entity registry
;;   game:use actor target      (rules.scm) F verb: tool on target, returns effects
;;   game:handle actor target   (rules.scm) E verb on a sign/chest, returns effects
;;   game:bag                   (inventory.scm) bag rows + equipped hand-slot tool
;;   game:equip item-type       (inventory.scm) put a carried tool in the hand slot
;;   game:unequip               (inventory.scm) empty the hand slot (tool stays in bag)
;;   game:container id          (containers.scm) open container view, or #f
;;   game:transfer id from item all  (containers.scm) move a stack to the other side
;;   game:close-container id    (containers.scm) dismiss the container panel
;;   game:drain-effects         (rules.scm) effects queued by tick hooks
;;   game:hp                    (combat.scm) player (hp max-hp down?) for hearts
;;   game:creature-bite c t     (combat.scm) a creature bites a target via the rules
;;   game:debug-hurt n          (combat.scm) deterministic damage (GM/acceptance)
;;
;; Playable without a model: when *use-llm* is #f every NPC falls back to
;; the canned reply table, and the quest still completes end to end.
;;
;; Modules (each may be read on its own; require caches by module name):
;;   data/world.scm   world parameters (seed, start, startHour, params)
;;   data/types.scm   is-a type hierarchy (actor/…, item/…, fixture/…), is-a
;;   data/maps.scm    map-level names: anchors, portals, zone, music, npc roster
;;   data/catalog.scm asset path mapping: characters, music, sfx, items
;;   data/dialogue.scm shared talk text: topic labels, utterances, prompt template
;;   data/quests.scm  quest definitions: objectives + stages + rewards (two chains)
;;   data/people.scm  roster: names, personas, canned lines, schedules (see npcs.scm)
;;   data/rules.scm   rule table: host selector + condition tree + effect list
;;   util.scm   data DSL (table/table-ref) + string/list helpers, alists
;;   entities.scm runtime registry: id -> (type hp tags props); transforms keep props
;;   inventory.scm item stacks: counts, slot capacity, hand equipment slot
;;   containers.scm container contents: slots, transfers, panel view
;;   rules.scm  event dispatch: specificity, condition tree, effect ops, tick stages
;;   llm.scm    optional scmllama plumbing, prompt output cleanup, streaming
;;   gm.scm     optional debug module: deterministic clock/weather, NL->command
;;   npcs.scm   npc lookups (display/persona/lines/schedule) over data/people.scm
;;   quest.scm  multi-quest state machine, objectives, rewards/xp, history
;;   time.scm   clock + weather: tick counter, calendar, seeded weather, PRNG
;;   talk.scm   topic menu, greetings, prompt building, learned lines
;;
;; The village map/NPC placement is authored in Godot (scenes/world.tscn);
;; Scheme only owns game state.

(require "game.util")
(require "game.data.world")
(require "game.data.types")
(require "game.data.maps")
(require "game.data.catalog")
(require "game.data.dialogue")
(require "game.data.quests")
(require "game.time")
(require "game.llm")
(require "game.npcs")
(require "game.quest")
(require "game.talk")
(require "game.entities")
(require "game.rules")
(require "game.combat")
(require "game.containers")
(require "game.data.rules")
; Optional debug module (see gm.scm). Remove this line and the file to ship
; without the GM console; nothing else references it.
(require "game.gm")

;; ---- aggregated status -------------------------------------------------------
;; (quest-text carried day hour minute weather) — one reply feeds the whole HUD.

(define (game:status)
  (append (list (quest-text) (ore-carried)) (time-status)))

;; ---- npc schedules -----------------------------------------------------------
;; (id anchor activity) per villager at the current clock hour. Anchor names are
;; "map:anchor" strings; Godot resolves them to pixel positions. Deciding who is
;; where stays here; walking the body is the presentation layer's job.

(define (game:people)
  (let* ((now (clock-at *tick*))
         (hour (cadr now)))
    (map (lambda (npc)
           (let ((plan (npc-plan npc hour)))
             (list (symbol->string npc) (car plan) (cadr plan))))
         *npcs*)))

;; ---- dev hot reload ----------------------------------------------------------
;; Forget every data module, read it again, then reset quest, talk and time state.
;; Editing a line in data/*.scm takes effect on the next turn, no restart.
;; Order matters: dialogue defines *default-topics* which quests appends to.

(define *data-modules*
  '("game.data.world"
    "game.data.types"
    "game.data.maps"
    "game.data.catalog"
    "game.data.dialogue"
    "game.data.quests"
    "game.data.people"
    "game.data.rules"))

(define (reload-modules! mods)
  (when (not (null? mods))
    (require-clear! (car mods))
    (require (car mods))
    (reload-modules! (cdr mods))))

(define (game:reload)
  ;; re-requiring maps.scm re-runs (define *current-map* 'village), so save
  ;; and restore the map the player is actually on; otherwise portals on the
  ;; current map stop resolving after a hot reload.
  (let ((saved-map *current-map*))
    (reload-modules! *data-modules*)
    (set! *current-map* saved-map))
  (rebuild-rules!)
  (reset-effects!)
  (report-schedule-problems)
  (reset-quest!)
  (reset-talk!)
  (reset-time!)
  ;; A hot reload is "boot again": the bag is run-time state, so the player
  ;; starts empty instead of keeping items from the previous data set.
  (bag-empty!)
  ;; So are container contents — an emptied chest refills on a fresh boot.
  ;; (Map travel keeps them; only a reload returns the world to its start.)
  (reset-containers!)
  ;; Entities are run-time state too. A stump (or an emptied chest) from the
  ;; previous session must not survive: Godot re-registers the authored scene
  ;; right after this call, repopulating the registry with starting values.
  (reset-entities!)
  (game:status))
