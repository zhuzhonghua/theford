;; catalog.scm — asset path mapping (data only).
;;
;; Maps game-side keys (npc ids, music keys, sfx events, item types) to
;; asset paths relative to res://. Tile → texture mapping stays in
;; world_tileset.tres; this file only covers characters, facesets, music,
;; sfx and item sprites.
;;
;; Replacing an asset means editing the path here — no GDScript change.
;; Godot reads these via the bridge (catalog-faceset, catalog-music, …).
;;
;; Data DSL: `table` (util.scm). All keys — section names and entries — are
;; symbols; ids that arrive from the bridge as strings are converted once in
;; the game:catalog-* wrappers at the bottom.

(require "game.util")

(define *catalog*
  (table
    ;; characters: id -> (spritesheet faceset) paths relative to res://
    (characters = (table
                    (player
                      (spritesheet = "assets/na/Actor/Character/NinjaRed/SpriteSheet.png")
                      (faceset = ""))
                    (smith
                      (spritesheet = "assets/na/Actor/Character/Villager/SpriteSheet.png")
                      (faceset = "assets/lsw/Faces/Actor/Character/Villager/Faceset.png"))
                    (apothecary
                      (spritesheet = "assets/na/Actor/Character/Woman/SpriteSheet.png")
                      (faceset = "assets/lsw/Faces/Actor/Character/Woman/Faceset.png"))
                    (innkeeper
                      (spritesheet = "assets/na/Actor/Character/Villager2/SpriteSheet.png")
                      (faceset = "assets/lsw/Faces/Actor/Character/Villager2/Faceset.png"))))
    ;; music: key -> path
    (music = (table
               (village = "assets/na/Audio/Musics/4 - Village.ogg")))
    ;; sfx: event key -> path relative to res://. Death is wired by Phase 7;
    ;; the rest are ready for the audio phase.
    (sfx = (table
             (gameover = "assets/na/Audio/Jingles/GameOver2.wav")
             (hit = "assets/na/Audio/Sounds/Hit & Impact/Hit1.wav")
             (kill = "assets/na/Audio/Sounds/Hit & Impact/Impact.wav")))
    ;; items: sprite key -> (path rect) for the bag panel. `rect` is
    ;; (x y w h) inside the sheet; (0 0 0 0) means the whole image. Keys match
    ;; the `sprite` field on data/types.scm rows ("item:axe", "item:ore", ...).
    (items = (table
               (item:axe
                 (path = "assets/na/Items/Tool/Axe.png"))
               (item:ore
                 (path = "assets/na/Items/Resource/Rock.png"))
               (item:stone
                 (path = "assets/na/Items/Resource/Rock.png"))
               (item:log
                 (path = "assets/na/Backgrounds/Tilesets/TilesetNature.png")
                 (rect = '(208 208 32 16)))
               (item:gel
                 (path = "assets/na/Backgrounds/Tilesets/TilesetHouse.png")
                 (rect = '(336 224 16 16)))))))

;; (catalog-section key) — the table for a top-level section, or #f.
(define (catalog-section key)
  (table-ref *catalog* key))

;; (catalog-character id field) — path string for a character's field
;; ('spritesheet | 'faceset), or #f. `id` is a symbol.
(define (catalog-character id field)
  (let ((c (catalog-section 'characters)))
    (and c (let ((entry (table-ref c id)))
             (and entry (table-ref entry field))))))

;; (catalog-music key) — path string for a music track, or #f. `key` is a symbol.
(define (catalog-music key)
  (let ((m (catalog-section 'music)))
    (and m (table-ref m key))))

;; (catalog-sfx key) — path string for a sound effect, or #f. `key` is a symbol.
(define (catalog-sfx key)
  (let ((s (catalog-section 'sfx)))
    (and s (table-ref s key))))

;; (catalog-item key) — (path x y w h) for an item sprite, or #f. A rect of
;; (0 0 0 0) means "use the whole image". `key` is a symbol like item:axe.
(define (catalog-item key)
  (let ((items (catalog-section 'items)))
    (and items
         (let ((entry (table-ref items key)))
           (and entry
                (let ((path (table-ref entry 'path #f)))
                  (and path
                       (append (list path)
                               (table-ref entry 'rect '(0 0 0 0))))))))))

;; Bridge-visible wrappers (Godot calls game:catalog-*).
;; Ids arrive as strings; convert once here, symbols everywhere inside.
(define (game:catalog-music key) (catalog-music (string->symbol key)))
(define (game:catalog-faceset id) (catalog-character (string->symbol id) 'faceset))
(define (game:catalog-spritesheet id) (catalog-character (string->symbol id) 'spritesheet))
(define (game:catalog-sfx key) (catalog-sfx (string->symbol key)))
(define (game:catalog-item key) (catalog-item (string->symbol key)))

;; (game:debug-catalog) — whole catalog, for the 1.6 smoke test.
(define (game:debug-catalog)
  *catalog*)
