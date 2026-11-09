;; npcs.scm — lookups over the roster data in data/people.scm.
;;
;; The data itself (names, personas, canned lines, player utterances) is not
;; here: this file only answers "who is this npc" questions. Conversation flow
;; lives in talk.scm.

(require "game.util")
(require "game.data.people")

;; Topic -> canned line alist for one npc; '() for an unknown id.
(define (npc-fallback npc)
  (let ((p (alist-get *people* npc)))
    (if p (alist-get p 'lines) '())))

(define (npc-persona npc)
  (let ((p (alist-get *people* npc)))
    (if p (alist-get p 'persona) "你是村里的一位 NPC。")))

(define (npc-display npc)
  (let ((p (alist-get *people* npc)))
    (if p (alist-get p 'display) npc)))

(define (game:npc-ids) *npcs*)
