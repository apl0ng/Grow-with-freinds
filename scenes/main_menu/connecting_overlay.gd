extends CanvasLayer
## Full-screen "Connecting..." overlay shown by Game while a client connects (freed when the local player
## spawns or when returning to the menu). Cancel (or Escape) returns to the menu. Hint copy: "Waiting at the gate…".
## Nothing holds the keyboard focus here (the menu that had it is gone), so Escape is the keyboard way out; the
## button is not auto-focused on purpose: a double-pressed Enter on "Report for shift" must not cancel the join.

@onready var text_label: Label = %Text
@onready var dots_label: Label = %Dots
@onready var cancel_button: Button = %CancelButton

var _time: float = 0.0

func _ready() -> void:
	cancel_button.pressed.connect(_on_cancel_pressed)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo() or not (event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"pause")):
		return
	get_viewport().set_input_as_handled()
	_on_cancel_pressed()

func _process(delta: float) -> void:
	_time += delta
	dots_label.text = ".".repeat(1 + int(_time * 3.0) % 3)

func set_text(text: String) -> void:
	if text_label == null:
		await ready
	text_label.text = text

func _on_cancel_pressed() -> void:
	Sfx.play(&"ui_click")
	Game.return_to_menu("")
