;; main.scm — The Ford (渡口) game logic: module manifest.
;;
;; Layer rule (plan_oss_edu_game.md section 3.1):
;;   Godot is presentation only. State changes live in Scheme:
;;   deterministic, serializable, replayable.
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
;;
;; Playable without a model: when *use-llm* is #f every NPC falls back to
;; the canned reply table, and the quest still completes end to end.
;;
;; Modules (each may be read on its own; require caches by module name):
;;   util.scm   string/list helpers, alists
;;   llm.scm    optional scmllama plumbing, prompt output cleanup, streaming
;;   npcs.scm   roster, fallback lines, personas, topic utterances
;;   quest.scm  quest state machine, carried/delivered counts, history
;;   talk.scm   topic menu, greetings, prompt building, learned lines
;;
;; The village map/NPC placement is authored in Godot (scenes/world.tscn);
;; Scheme only owns game state.

(require "game.util")
(require "game.llm")
(require "game.npcs")
(require "game.quest")
(require "game.talk")
