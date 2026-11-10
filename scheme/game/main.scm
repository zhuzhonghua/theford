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
;;   game:status                (quest.scm)
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
;;   data/people.scm  roster: names, personas, canned lines (loaded by npcs.scm)
;;   util.scm   data DSL (table/table-ref) + string/list helpers, alists
;;   llm.scm    optional scmllama plumbing, prompt output cleanup, streaming
;;   npcs.scm   npc lookups (display/persona/lines) over data/people.scm
;;   quest.scm  quest state machine, carried/delivered counts, history
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
(require "game.llm")
(require "game.npcs")
(require "game.quest")
(require "game.talk")

;; ---- dev hot reload ----------------------------------------------------------
;; Forget every data module, read it again, then reset the quest to its start.
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
  (reload-modules! *data-modules*)
  (reset-quest!)
  (reset-talk!)
  (game:status))
