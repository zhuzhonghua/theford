;; people.scm — who the villagers are: ids, display names, LLM personas and
;; schedules. Pure data; lookups live in npcs.scm.
;;
;; Dialogue lines are NOT authored here: every NPC turn goes through
;; talk.scm → LLM prompt → local model. Only the persona (system prompt) is
;; authored, plus the clock schedule that decides where the villager is.
;;
;; Data DSL: `table` (util.scm). A row is a key plus `(field = value)` pairs and
;; is itself a hash table; a value may nest another table.
;;
;; One row per villager:
;;   display  name shown in dialogue / history
;;   persona  system prompt that defines the character
;;   schedule list of (from / to / at / activity) tables, hours are clock hours
;;            [from, to); a window whose `to` is not after `from` wraps midnight.
;;            at is "map:anchor" — the anchor names are declared in maps.scm and
;;            resolved to pixel positions by Godot.
;;
;; Shared conversation text (topic menu labels, player utterances, system
;; instruction, prompt template) lives in data/dialogue.scm.

(require "game.util")

(define *npcs* '(smith apothecary innkeeper axun))

(define *people*
  (table
    (smith
      (display = "老王")
      (persona = "你正在扮演老王，渡口村东头的铁匠。老王性格豪爽、说话直来直去，常用『哼』『嘿』『得嘞』这类口头语。他正打算给村里的守卫打一把剑，但手头缺铁矿石，正为此发愁。")
      (schedule = (list
                    (table (from = 6) (to = 12) (at = "smithy:forge") (activity = 'smithing))
                    (table (from = 12) (to = 13) (at = "village:village-square") (activity = 'lunch))
                    (table (from = 13) (to = 19) (at = "smithy:forge") (activity = 'smithing))
                    (table (from = 19) (to = 22) (at = "village:inn-yard") (activity = 'drinking))
                    (table (from = 22) (to = 6) (at = "village:smith-home") (activity = 'sleep)))))

    (apothecary
      (display = "陈婆")
      (persona = "你正在扮演陈婆，渡口村的药师。陈婆细心、说话慢条斯理，喜欢叮咛人煮水喝、注意保暖。她晒草药为生，知道村里不少事。")
      (schedule = (list
                    (table (from = 6) (to = 11) (at = "village:herb-garden") (activity = 'herbs))
                    (table (from = 11) (to = 13) (at = "village:inn-yard") (activity = 'lunch))
                    (table (from = 13) (to = 18) (at = "village:herb-garden") (activity = 'herbs))
                    (table (from = 18) (to = 22) (at = "village:village-square") (activity = 'strolling))
                    (table (from = 22) (to = 6) (at = "village:apothecary-home") (activity = 'sleep)))))

    (innkeeper
      (display = "张掌柜")
      (persona = "你正在扮演张掌柜，渡口村旅店的老板。张掌柜殷勤健谈，爱打听消息，见人先递一句招呼，嘴甜但不油滑。")
      (schedule = (list
                    (table (from = 6) (to = 22) (at = "village:inn") (activity = 'innkeeping))
                    (table (from = 22) (to = 6) (at = "village:innkeeper-home") (activity = 'sleep)))))

    (axun
      (display = "阿笋")
      (persona = "你正在扮演阿笋，渡口村的少年，十四岁。阿笋话少、眼神躲闪，手上总攥着一截旧绳头。他剪断了渡船缆绳——不是为捣乱，而是怕船匠把父亲留下的渡船拖走。被问到渡船时先含糊其辞，慢慢才肯说实话。")
      (schedule = (list
                    (table (from = 6) (to = 11) (at = "village:axun-stand") (activity = 'loitering))
                    (table (from = 11) (to = 13) (at = "village:inn-yard") (activity = 'lunch))
                    (table (from = 13) (to = 19) (at = "village:village-square") (activity = 'loitering))
                    (table (from = 19) (to = 22) (at = "village:axun-stand") (activity = 'loitering))
                    (table (from = 22) (to = 6) (at = "village:smith-home") (activity = 'sleep)))))))
