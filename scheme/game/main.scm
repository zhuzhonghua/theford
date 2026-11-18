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
;;   game:boot                  (llm.scm)
;;   game:npc-ids               (npcs.scm)
;;   game:topics npc-id         (talk.scm)
;;   game:greet npc-id          (talk.scm)
;;   game:take-ore              (quest.scm)
;;   game:talk npc-id topic     (talk.scm)
;;   game:tick                  (time.scm) advance one tick, returns game:status
;;   game:debug-set-time        (gm.scm) jump the clock, returns game:status
;;   game:debug-advance         (gm.scm) advance N minutes, returns game:status
;;   game:debug-set-weather     (gm.scm) pin/clear weather, returns game:status
;;   game:status                (here) quest text + ore + clock + weather
;;   game:people                (here) id + current anchor + activity per npc
;;   game:gm-plan text          (gm.scm) LLM turns free text into one GM command
;;   game:reload                (here) re-read data files, reset state
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
;;   data/quests.scm  quest definitions: objectives + stages (smith-ore chain)
;;   data/people.scm  roster: names, personas, canned lines, schedules (see npcs.scm)
;;   util.scm   data DSL (table/table-ref) + string/list helpers, alists
;;   llm.scm    optional scmllama plumbing, prompt output cleanup, streaming
;;   gm.scm     optional debug module: deterministic clock/weather, NL->command
;;   npcs.scm   npc lookups (display/persona/lines/schedule) over data/people.scm
;;   quest.scm  quest state machine, carried/delivered counts, history
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
; Optional debug module (see gm.scm). Remove this line and the file to ship
; without the GM console; nothing else references it.
(require "game.gm")

;; ---- aggregated status -------------------------------------------------------
;; (quest-text carried day hour minute weather) — one reply feeds the whole HUD.

(define (game:status)
  (append (list (quest-text) *carried*) (time-status)))

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
    "game.data.people"))

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
  (report-schedule-problems)
  (reset-quest!)
  (reset-talk!)
  (reset-time!)
  (game:status))
