;; npcs.scm — lookups over the roster data in data/people.scm.
;;
;; The data itself (names, personas, canned lines) is not here: this file only
;; answers "who is this npc" questions. Conversation flow lives in talk.scm.

(require "game.util")
(require "game.data.people")

;; Shared empty table returned when an npc has no canned lines, so callers can
;; table-ref it unconditionally.
(define *no-lines* (table))

;; npc ids are symbols here; the bridge converts strings once on entry.
(define (npc-entry npc)
  (table-ref *people* npc))

;; Topic -> canned line table for one npc; empty table for an unknown id.
(define (npc-fallback npc)
  (let ((p (npc-entry npc)))
    (if p (table-ref p 'lines *no-lines*) *no-lines*)))

(define (npc-persona npc)
  (let ((p (npc-entry npc)))
    (if p (table-ref p 'persona "你是村里的一位 NPC。") "你是村里的一位 NPC。")))

(define (npc-display npc)
  (let ((p (npc-entry npc)))
    (if p (table-ref p 'display (symbol->string npc)) (symbol->string npc))))

(define (game:npc-ids) *npcs*)
