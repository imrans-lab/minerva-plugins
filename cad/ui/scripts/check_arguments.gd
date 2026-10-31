extends RefCounted
## Shared boundary rule: absence and zero are different clearance requests.
## Consumers: ui/panel_tools.gd, scripts/clearance_client.gd, scripts/design_check.gd.
static func required_mm_error(args: Dictionary) -> String:
	if not args.has("required_mm"):
		return "required_mm is required: state the clearance in millimetres (zero is allowed)"
	var value: Variant = args["required_mm"]
	if not (value is int or value is float):
		return "required_mm must be a number"
	var amount: float = float(value)
	if not is_finite(amount):
		return "required_mm must be finite"
	if amount < 0.0:
		return "required_mm must be greater than or equal to zero"
	return ""
