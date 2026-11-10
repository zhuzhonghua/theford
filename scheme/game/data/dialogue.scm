;; dialogue.scm — shared conversation text: topic menu labels, player
;; utterances, the system instruction and the LLM prompt template.
;;
;; Pure data. The topic menu is an ordered alist ((id . label) ...) because the
;; dialogue HUD renders entries in data order and hash tables have no order.
;; Quest stages start from *default-topics* and append their own entries.
;;
;; Prompt template placeholders are filled by talk.scm once per turn:
;;   {persona} {sys} {quest} {item} {carried} {status} {reason} {hint}
;;   {history} {player}
;;
;; Data DSL: `table` (util.scm).

(require "game.util")

(define *default-topics*
  '((greet . "打个招呼")
    (village . "聊聊村子")
    (work . "问问活计")))

;; Speaker label for the player inside dialogue history / prompt text.
(define *player-speaker* "玩家")

(define *topic-utterances*
  (table
    (greet = "我路过村子，跟你打个招呼吧。")
    (village = "给我讲讲渡口村的事吧。")
    (work = "你最近手头的活计还顺利么？")))

(define *sys-instruction*
  "你就是这个 NPC。只输出对玩家说的一句台词，不要加引号，不要加名字前缀，只用简短的日常中文，不要思考，不要替玩家说话。")

(define *prompt-template*
  "<|im_start|>system\n{persona}{sys}<|im_end|>\n<|im_start|>user\n当前任务状态：{quest}\n玩家背包：{item} x{carried}\n刚刚的判定：Scheme 结果={status}，原因={reason}\n{hint}\n\n对话记录：\n{history}\n玩家：{player}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>")
