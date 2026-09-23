extends Node
## Autoload "Juice": pop/bounce/particle helpers. (STUB - owned by the art agent; see CONTRACTS.md)
func pop_in(_node: Node, _duration: float = 0.35) -> void: pass
func bounce(_node: Node, _strength: float = 0.2) -> void: pass
func pulse(_node: Node) -> void: pass
func stop(_node: Node) -> void: pass
func burst(_position: Vector3, _color: Color, _count: int = 12) -> void: pass
func float_text(_position: Vector3, _text: String, _color: Color = Color.WHITE) -> void: pass
func punch_ui(_control: Control) -> void: pass
