extends RefCounted
## Per-vault password store for the scansort panel.
##
## scansort supports multiple vaults open at once. The panel formerly held a
## single `_vault_password` slot which was overwritten on every vault open, so
## a document in a non-active vault was sent to the backend with no password
## (RCA 019e4ca264). This store keeps one password per opened vault keyed by
## canonicalised vault path.
##
## Off-tree plugin: no class_name — consumers preload() this script.
##
## All keys are path-canonicalised via String.simplify_path() on insert AND on
## every lookup, so "/a/./b.ssort" and "/a//b.ssort" resolve to one entry.
##
## Security: passwords are held in memory only; never logged, never persisted.

## Maps canonicalised vault path -> password string ("" for a non-encrypted vault).
var _passwords: Dictionary = {}


## Record an opened vault's password. Pass "" for a non-encrypted vault — that
## still marks the vault as known (has_vault() becomes true).
func set_password(vault_path: String, password: String) -> void:
	_passwords[vault_path.simplify_path()] = password


## Return the recorded password for a vault, or "" if the vault is unknown.
func get_password(vault_path: String) -> String:
	return str(_passwords.get(vault_path.simplify_path(), ""))


## Whether the vault has been recorded (i.e. opened this session).
func has_vault(vault_path: String) -> bool:
	return _passwords.has(vault_path.simplify_path())


## Drop a single vault from the store (on vault close).
func forget(vault_path: String) -> void:
	_passwords.erase(vault_path.simplify_path())


## Drop all recorded vaults (session reset).
func clear() -> void:
	_passwords.clear()
