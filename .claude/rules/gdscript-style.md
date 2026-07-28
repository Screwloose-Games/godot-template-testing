---
paths:
    - "**/*.gd"
---

# GDScript file layout

Every `.gd` file declares things in this order. This is not style preference —
`gdlint` enforces it via `class-definitions-order` in `gdlintrc`, and anything out
of order fails the pre-commit hook and CI.

1. `@tool`
2. `class_name`
3. `extends`
4. Docstring comment
5. `signal`
6. `enum`
7. `const`
8. `static var`
9. `@export var`
10. Public `var`
11. Private `var` (`_name`)
12. `@onready` public var
13. `@onready` private var
14. Everything else (functions, inner classes)

Two things that trip people up:

- **`class_name` goes above `extends`**, not below. Both orders run fine in Godot 4,
  only one passes the linter.
- **`@onready` vars go last, below plain `var`s** — not next to the exports they
  relate to. Their assignments run at `_ready()` regardless of source position, so
  moving them is safe unless a plain `var` initializer references one.

```gdscript
class_name SoundEffectConnector
extends Node

enum TryConnectError {
	INSTANCE_INVALID = 49,
}

@export var sound_effect: AudioStream

var try_connect_start_result: int = FAILED

@onready var sound_manager = get_parent()


func _ready() -> void:
	pass
```

Blank lines: two before each function, one between logical blocks. `gdformat` owns
this — don't hand-tune it.

## Checking your work

```bash
gdlint  <file>          # ordering + naming
gdformat --check <file> # formatting; drop --check to rewrite in place
gdformat --diff  <file> # preview what it would change
pre-commit run          # both, on staged files (what the commit hook runs)
```

`pre-commit` blocks commits on failure. Set it up once per clone with
`pip install pre-commit && pre-commit install`. Use `git commit --no-verify` only
in an emergency.

`addons/` is third-party and excluded everywhere — `gdlintrc`, `gdformatrc`,
`.pre-commit-config.yaml`, and CI. Don't lint or reformat it.

Note: `excluded_directories` in `gdlintrc`/`gdformatrc` is ignored when you pass
explicit file paths, so running `gdlint addons/some_file.gd` by hand will report
errors that nothing actually enforces.
