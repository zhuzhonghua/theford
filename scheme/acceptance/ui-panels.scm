;; ui-panels.scm — the product UI shell: HUD detail moved into four panels.
;; Toggle keys double as close keys; Esc is reserved by the replay runner.

(define (acceptance:steps)
  (list
    (list "note" "UI 验收：C 状态 / L 日志 / M 地图 / H 帮助" "2.4")
    (list "gm" "speed 0")
    (list "place" "village" "village:riverbank")
    (list "gm" "hurt 1")
    (list "assert-hud-message" "你受到")

    (list "press" "c")
    (list "assert-ui-panel" "status" "open")
    (list "press" "c")
    (list "assert-ui-panel" "status" "closed")

    (list "press" "l")
    (list "assert-ui-panel" "log" "open")
    (list "assert-log-panel-text" "你受到")
    (list "press" "l")
    (list "assert-ui-panel" "log" "closed")

    (list "press" "m")
    (list "assert-ui-panel" "map" "open")
    (list "assert-map-panel-items" "4")
    (list "press" "m")
    (list "assert-ui-panel" "map" "closed")

    (list "press" "h")
    (list "assert-ui-panel" "help" "open")
    (list "press" "h")
    (list "assert-ui-panel" "help" "closed")

    (list "note" "不用快捷键：点 HUD 按钮开面板，点面板的 ✕ 关面板" "2.4")
    (list "click-hud-button" "status")
    (list "assert-ui-panel" "status" "open")
    (list "click-panel-close" "status")
    (list "assert-ui-panel" "status" "closed")
    (list "click-hud-button" "bag")
    (list "assert-panel" "open")
    (list "click-panel-close" "bag")
    (list "assert-panel" "closed")
    (list "click-hud-button" "map")
    (list "assert-ui-panel" "map" "open")
    (list "click-panel-close" "map")
    (list "assert-ui-panel" "map" "closed")
    (list "note" "验收完成：按钮与快捷键都能开关所有面板" "2.4")))
