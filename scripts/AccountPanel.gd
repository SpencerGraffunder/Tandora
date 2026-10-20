extends Control
## Account overlay panel (Lobby): sign up, log in, log out, and the current
## session state. All server traffic goes through the Session autoload, so
## this script only owns widgets, mode switching, and user-facing messages.

signal closed

@onready var close_button: Button = $CloseButton
@onready var state_label: Label = $VBoxContainer/StateLabel
@onready var form_box: VBoxContainer = $VBoxContainer/FormBox
@onready var logged_in_box: VBoxContainer = $VBoxContainer/LoggedInBox
@onready var login_mode_button: Button = $VBoxContainer/FormBox/ModeBox/LoginModeButton
@onready var signup_mode_button: Button = $VBoxContainer/FormBox/ModeBox/SignupModeButton
@onready var email_lineedit: LineEdit = $VBoxContainer/FormBox/EmailLineEdit
@onready var password_lineedit: LineEdit = $VBoxContainer/FormBox/PasswordLineEdit
@onready var confirm_row: HBoxContainer = $VBoxContainer/FormBox/ConfirmRow
@onready var confirm_lineedit: LineEdit = $VBoxContainer/FormBox/ConfirmRow/ConfirmLineEdit
@onready var submit_button: Button = $VBoxContainer/FormBox/SubmitButton
@onready var status_label: Label = $VBoxContainer/FormBox/StatusLabel
@onready var logout_button: Button = $VBoxContainer/LoggedInBox/LogoutButton

var _mode: String = "login"  # "login" | "signup"
var _busy: bool = false

# Server error codes (docs/accounts.md) plus the Session transport errors,
# mapped to messages a player can act on.
const ERROR_MESSAGES := {
	"NOT_CONNECTED": "Not connected to the server yet — try again in a moment.",
	"TIMEOUT": "The server didn't respond — check your connection and try again.",
	"INVALID_EMAIL": "That email doesn't look right — check for typos.",
	"WEAK_PASSWORD": "Password needs 8+ characters and at least two of: lowercase, uppercase, number.",
	"EMAIL_TAKEN": "An account with that email already exists — try logging in instead.",
	"INVALID_CREDENTIALS": "Wrong email or password.",
	"INVALID_SESSION": "Your session is no longer valid — log in again.",
	"RATE_LIMITED": "Too many attempts — wait about a minute, then try again.",
	"UNKNOWN_ACTION": "Unexpected response from the server.",
}


func _ready() -> void:
	visible = false
	close_button.pressed.connect(close)
	login_mode_button.pressed.connect(func(): _set_mode("login"))
	signup_mode_button.pressed.connect(func(): _set_mode("signup"))
	submit_button.pressed.connect(_on_submit_pressed)
	logout_button.pressed.connect(_on_logout_pressed)
	Session.session_changed.connect(_on_session_changed)
	_set_mode(_mode)


func open(hint: String = "") -> void:
	visible = true
	_show_status(hint)
	update_state()


func close() -> void:
	if not visible:
		return
	visible = false
	_show_status("")
	closed.emit()


## Refreshes the signed-in / signed-out presentation.
func update_state() -> void:
	if Session.is_logged_in:
		state_label.text = "Signed in as " + Session.user_email
		logged_in_box.visible = true
		form_box.visible = false
	else:
		state_label.text = "Not signed in"
		logged_in_box.visible = false
		form_box.visible = true
		_set_mode(_mode)


func _on_session_changed() -> void:
	update_state()


func _set_mode(mode: String) -> void:
	_mode = mode
	var signup: bool = mode == "signup"
	login_mode_button.button_pressed = not signup
	signup_mode_button.button_pressed = signup
	confirm_row.visible = signup
	submit_button.text = "Create account" if signup else "Log in"


func _show_status(text: String) -> void:
	status_label.text = text


func _message_for(error_code: String) -> String:
	return ERROR_MESSAGES.get(error_code, "Something went wrong — try again.")


func _on_submit_pressed() -> void:
	if _busy or Session.is_logged_in:
		return
	var email := email_lineedit.text.strip_edges()
	var password := password_lineedit.text
	if email == "" or password == "":
		_show_status("Enter your email and password.")
		return
	if not email.contains("@"):
		_show_status("Enter a valid email address.")
		return
	if _mode == "signup" and password != confirm_lineedit.text:
		_show_status("Passwords don't match.")
		return
	_busy = true
	submit_button.disabled = true
	var r: Dictionary
	if _mode == "login":
		_show_status("Signing in…")
		r = await Session.login(email, password)
	else:
		_show_status("Creating account…")
		r = await Session.create_account(email, password)
		if r["ok"]:
			# create doesn't hand back a session — log in right away.
			_show_status("Account created — signing in…")
			r = await Session.login(email, password)
	_busy = false
	submit_button.disabled = false
	if r["ok"]:
		password_lineedit.text = ""
		confirm_lineedit.text = ""
		_show_status("Signed in." if _mode == "login" else "Account created — signed in.")
		update_state()
	else:
		# The connection can drop between create and the follow-up login.
		if _mode == "signup" and r["error"] == "NOT_CONNECTED":
			_show_status("Account created. Reconnect, then log in.")
			_set_mode("login")
			return
		_show_status(_message_for(String(r["error"])))
		update_state()


func _on_logout_pressed() -> void:
	if _busy:
		return
	_busy = true
	logout_button.disabled = true
	_show_status("Signing out…")
	var r: Dictionary = await Session.logout()
	_busy = false
	logout_button.disabled = false
	if r["ok"]:
		_show_status("Signed out.")
	else:
		_show_status("Signed out on this device (server unreachable — the session may still be valid for a while).")
	update_state()
